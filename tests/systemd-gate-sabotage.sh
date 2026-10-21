#!/usr/bin/env bash
# Sabotage suite for tests/systemd-gate.sh — prove the gate can FAIL.
#
# A gate that only ever goes green is not a gate. tests/systemd-gate.sh checks a
# migration that cannot be booted here, so its whole value is that it goes red
# when the swap is wrong; that claim is what this file tests.
#
# Each case copies the repo, plants one defect with an exact-string edit (so a
# no-op is impossible: a planting that does not match the file is reported as a
# broken test, not a passing one), runs the gate in the copy, and asserts both
# that the gate exits non-zero and that it names the right thing.
#
# This is not busywork. Writing it found three real bugs that the gate had been
# hiding:
#
#   1. the gate called build_systemd in a context where its `exit 1` ended the
#      GATE, so a failure died silently right after the parse checks;
#   2. `set -e` in a subshell does not reach a function defined in the parent,
#      so the gate ran the stage with errexit off and passed a stage that the
#      real build cannot get through;
#   3. under that corrected errexit, the SHIPPED stage aborted on its own
#      `readelf | sed | head` pipeline — head closes the pipe, sed takes
#      SIGPIPE, and `set -o pipefail` makes the pipeline non-zero. A real build
#      would have died there too.
#
# Root only (the gate chroots). Run: sudo tests/systemd-gate-sabotage.sh
#
# handcrafted by 12hrformat (SYSTEMD-MIGRATION.md, phase 1)

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)

if [ "$(id -u)" -ne 0 ]; then
    echo "tests/systemd-gate-sabotage.sh must run as root: sudo tests/systemd-gate-sabotage.sh" >&2
    exit 1
fi
if [ ! -f "$REPO/tests/systemd-gate.sh" ]; then
    echo "FAIL $REPO/tests/systemd-gate.sh does not exist" >&2
    exit 1
fi
command -v python3 >/dev/null 2>&1 || {
    echo "FAIL no python3 (used for exact-string sabotage edits)" >&2
    exit 1
}

fails=0

# edit <file> <old> <new> — exact, single replacement, or fail loudly.
edit() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
if old not in s:
    sys.exit("NO-MATCH: " + old[:60])
open(path, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
}

# run_case <label> <file> <old> <new> <expected-text>
run_case() {
    label=$1; file=$2; old=$3; new=$4; expect=$5
    T=$(mktemp -d /tmp/systemd-sabotage.XXXXXX) || exit 1
    cp -a "$REPO" "$T/repo"
    if ! msg=$(edit "$T/repo/$file" "$old" "$new" 2>&1); then
        echo "BROKEN sabotage (did not apply): $label -- $msg"
        fails=$((fails + 1)); rm -rf "$T"; return
    fi
    out=$(bash "$T/repo/tests/systemd-gate.sh" 2>&1); rc=$?
    # $expect is a REGEX, not a fixed string: systemd-analyze's wording moves
    # between releases (255: "Unknown key name 'X'"; 256+: "Unknown key 'X'"),
    # and a fixed-string expectation makes the SUITE fail when the GATE is
    # right. See case 1 for the run that proved it.
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "$expect"; then
        echo "  ok    gate rejects: $label"
    else
        echo "  FAIL  gate MISSED: $label (rc=$rc, expected to see: $expect)"
        printf '%s\n' "$out" | grep -i "fail" | head -4 | sed 's/^/          /'
        fails=$((fails + 1))
    fi
    rm -rf "$T"
}

B=iso/build.sh
C=iso/src-init/copper-init.c
U=iso/systemd

echo "sabotaging the systemd migration, one defect at a time:"

# 1. A key in the wrong section — the exact bug the gate caught in real life.
#    (Deleting the key outright is NOT used here: that is a valid unit and the
#    gate would be right to pass it. The key has to genuinely be misplaced.)
T=$(mktemp -d /tmp/systemd-sabotage.XXXXXX); cp -a "$REPO" "$T/repo"
python3 - "$T/repo/$U/copper-console.service" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
assert 'StartLimitIntervalSec=0' in s
s = s.replace('StartLimitIntervalSec=0\n', '', 1)
s = s.replace('[Service]\n', '[Service]\nStartLimitIntervalSec=0\n', 1)
open(p, 'w', encoding='utf-8').write(s)
PY
out=$(bash "$T/repo/tests/systemd-gate.sh" 2>&1); rc=$?
# The expectation is a REGEX and deliberately does not pin systemd's wording:
# 255 says "Unknown key name 'X' in section 'Service'", 256+ dropped the word
# "name" ("Unknown key 'X' ..."). A fixed string made this case MISS on the CI
# runner while the gate had in fact gone red for the right reason -- the suite
# reporting a hole that was really its own spelling. Match the key name and let
# "Unknown key" be a prefix.
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "Unknown key( name)? 'StartLimitIntervalSec'"; then
    echo "  ok    gate rejects: StartLimitIntervalSec genuinely in [Service]"
else
    echo "  FAIL  gate MISSED: StartLimitIntervalSec in [Service] (rc=$rc)"
    fails=$((fails + 1))
fi
rm -rf "$T"

# 2. A directive that does not exist at all.
run_case "SocketMode= (not a directive)" "$U/copper-seatd.service" \
    'RuntimeDirectory=seatd' \
    'RuntimeDirectory=seatd
SocketMode=0660' \
    "Unknown key( name)? 'SocketMode'"

# 3. The bare-glob trap that killed the first version of the stage: a bare
#    `install ... *.network` with no matching file. This only fails the build
#    under `set -e`, so it is also the case that proves the gate runs the stage
#    with build.sh's flags.
run_case "bare *.network glob reinstated" "$B" \
    'for f in "$ROOT/systemd"/*.network; do' \
    'install -m 0644 "$ROOT/systemd"/*.network "$TGT/etc/systemd/network/"
  for f in "$ROOT/systemd"/*.network; do' \
    "build_systemd ran"

# 4. The swap itself not happening.
run_case "sbin/init not repointed to systemd" "$B" \
    'ln -sf /lib/systemd/systemd "$TGT/sbin/init"' \
    'true' \
    "init_flavour reads the staged tree as systemd"

# 5. A unit present but not wired into the target (a service that never starts).
run_case "copper-seatd.service left unwired" "$B" \
    'for u in copper-seatd.service copper-network.service; do' \
    'for u in copper-network.service; do' \
    "wired copper.target.wants/copper-seatd.service"

# 6. --console removed from the C entry point: copper-console.service would then
#    start PID-1 copper-init under systemd (mounts, signals, a second seatd).
run_case "--console no longer recognised" "$C" \
    'strcmp(argv[1], "--console") == 0' \
    '0' \
    "copper-init recognises --console"

# 7. Power commands left pointing at busybox (bug 29's shape, inverted).
run_case "power commands left as busybox" "$B" \
    'ln -sf /usr/bin/systemctl "$TGT/sbin/$cmd"' \
    'ln -sf /bin/busybox "$TGT/sbin/$cmd"' \
    "sbin/reboot -> systemctl"

# 8. Units installed at the wrong mode. A world-writable unit is one systemd
#    reads with a warning, and the source tree is 777 on a Windows checkout.
run_case "units installed 0777" "$B" \
    'install -m 0644 "$ROOT/systemd"/*.service "$TGT/etc/systemd/system/"' \
    'install -m 0777 "$ROOT/systemd"/*.service "$TGT/etc/systemd/system/"' \
    "installed copper-console.service"

# 9. The build-time verifier left in the image: the build host's libc riding
#    into the ISO.
run_case "systemd-analyze left in the tree" "$B" \
    'while IFS= read -r f; do
      [ -n "$f" ] || continue
      rm -f "$TGT$f"
    done < "$added"' \
    ':' \
    "build-time systemd-analyze not left in the tree"

# 10. tree_hash blind to symlinks again -- the hole that would let CI report a
#     green "systemd" artifact while shipping the busybox one.
run_case "tree_hash blind to the init swap" "$B" \
    '      find . -type l -printf '"'"'link %p -> %l\n'"'"' | LC_ALL=C sort' \
    '      :' \
    "tree_hash sees the init swap"

# 11. The dispatch line drops build_musl -- the exact defect CI found on a real
#     runner ("line 638: CC: unbound variable"), which section 2 cannot see
#     because it calls build_systemd alone. Planted by removing the toolchain
#     prerequisite from the `systemd)` arm and leaving everything else intact.
run_case "systemd stage loses its toolchain prerequisite" "$B" \
    'systemd)    build_musl; build_busybox; build_rootfs' \
    'systemd)    build_rootfs' \
    "systemd stage runs its prerequisites"

# 12. The stage's verify filter goes back to a deny-list -- the SECOND CI
#     failure. A deny-list tuned on the dev box's systemd 261 kept a
#     host-artifact line on the runner's 255 and failed the build. Planted by
#     replacing the allow-list regex with the old deny-list.
run_case "verify filter weakened to a version-specific deny-list" "$B" \
    '          | grep -E "Unknown (key|lvalue|section)|Failed to parse|Empty (ExecStart|section)|not a valid" \' \
    '          | grep -vE "Can'"'"'t show |failed with exit status|\(man\)" \' \
    "verify filter"

# 13. The merged-usr bridge is gone -- the THIRD CI failure, and the one that
#     would have made the ISO unbootable rather than merely failing a check.
#     Ubuntu's systemd deb ships PID 1 at usr/lib/systemd/systemd; Copper's tree
#     has a real /lib, so without the bridge /lib/systemd/systemd does not
#     exist and the kernel has nothing to exec. CI said exactly this: "39
#     packages unpacked (58M)" then "/lib/systemd/systemd did not arrive". The
#     stage's own gate does catch it, but the gate was green locally because the
#     fixture was wrong -- so the case plants the missing bridge in a stage whose
#     fixture is now honest, and asserts the check fires.
#
#     The whole bridge is disabled at its entry condition rather than one branch
#     of it: the fixture has a squatter lib/systemd, so the stage reaches the
#     "real directory" branch, and neutering only the "absent" branch would
#     remove dead code and pass. Short-circuiting the outer `if` covers every
#     shape the fixture can present -- which is the point: the defect is "no
#     bridge ran", not "this one branch of it did not".
run_case "merged-usr bridge disabled entirely (PID 1 unreachable at /lib)" "$B" \
    '  if [ -x "$TGT/usr/lib/systemd/systemd" ]; then' \
    '  if false; then' \
    "lib/systemd/systemd resolves to a real executable"

# 15. The bridge exists but declines to run when /lib/systemd is already a real
#     directory. This is the shape the SECOND post-fix CI failure had: the guard
#     asked "is lib/systemd absent?" and answered no, so it skipped, and the
#     stage died claiming the packages never arrived. Planted by making the
#     squatter branch a no-op, so the real directory keeps the name and PID 1 is
#     never linked into place.
run_case "bridge no-ops when lib/systemd is already a real directory" "$B" \
    '      if [ ! -e "$TGT/lib/systemd/systemd" ]; then
        rm -rf "$TGT/lib/systemd"
        ln -sfn ../usr/lib/systemd "$TGT/lib/systemd"
        echo "  lib/systemd (real dir) -> usr/lib/systemd (merged-usr bridge)"' \
    '      if [ ! -e "$TGT/lib/systemd/systemd" ]; then
        echo "  (sabotage: squatter left in place)"' \
    "lib/systemd/systemd resolves to a real executable"

# 14. The fixture goes back to the non-merged layout. This is the false green
#     itself: with the fake PID 1 at payload/lib/systemd/systemd, the stage's
#     own `[ -x $TGT/lib/systemd/systemd ]` passes no matter what the stage does
#     with the packages' usr/lib tree, so dropping the bridge goes unnoticed.
#     Planting it back must make the gate MISS the bridge removal -- proving the
#     behavioural check in 13 is load-bearing only because the fixture is honest,
#     and that a fixture modelling the input wrongly certifies the wrong code.
if grep -q 'payload/usr/lib/systemd/systemd\|PD/usr/lib/systemd/systemd' \
        "$REPO/tests/systemd-gate.sh"; then
    echo "  ok    fixture models a real noble deb (PID 1 at usr/lib/systemd)"
else
    echo "  FAIL  fixture is not merged-usr-shaped; gate can false-green again"
    fails=$((fails + 1))
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "sabotage suite: the gate catches every planted defect"
    exit 0
fi
echo "sabotage suite: $fails planted defect(s) NOT caught"
exit 1
