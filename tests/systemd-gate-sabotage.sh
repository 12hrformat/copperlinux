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
#      would have died there too;
#   4. and the suite itself was red: five of its own cases had never been run
#      against the tree they were written for. Two planted a shell syntax
#      error instead of the defect they meant — the replacement left an `fi`
#      behind, so build.sh could not be sourced at all and the gate went red
#      for a reason that had nothing to do with the case. One was anchored to
#      a line that had since been re-wrapped, so it never applied. And two
#      asked the gate to catch something in a stage the gate does not run,
#      which no planting can make happen. A suite that is red for its own
#      reasons teaches its reader to ignore it, which is the one thing a
#      sabotage suite exists to prevent.
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
#    The systemctl links live in power_links, which the systemd stage calls
#    after it swaps PID 1 -- one definition, so the stage and the stages that
#    re-run over the tree later cannot disagree about what a systemd machine
#    wants.
run_case "power commands left as busybox" "$B" \
    'ln -sf /usr/bin/systemctl "$root/sbin/$cmd"' \
    'ln -sf /bin/busybox "$root/sbin/$cmd"' \
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

# 16. The seatd binary is absent from the tree. The stage asserts it is there
#     (a boot found the unit pointing at a path that did not exist), and the
#     gate's fixture is what makes the tree the stage sees. Deleting the binary
#     from the FIXTURE is the honest way to plant this: the tree the stage
#     builds is the tree the gate checks, and a stage that accepted a tree
#     without seatd would ship a unit that execs nothing.
#
#     Planting it in the stage's own assertion instead would prove nothing --
#     the assertion is the thing that catches this.
run_case "seatd binary missing from the tree" "tests/systemd-gate.sh" \
    '         usr/bin/seatd sbin/udhcpc; do' \
    '         sbin/udhcpc; do' \
    "no seatd binary at /usr/bin/seatd or /usr/sbin/seatd"

# 17. The _seatd group is missing. build_gui appends it, build_rootfs' second
#     pass clobbers /etc/group, and a boot found seatd unable to start because
#     of it. The stage asserts the group; the gate's fixture carries it. Take
#     the line out of the fixture and the assertion must fire.
run_case "_seatd group lost from /etc/group" "tests/systemd-gate.sh" \
    "_seatd:x:999:\\n' \\" \
    "' \\" \
    "no _seatd group"

# 18. The unit hard-codes ONE directory again. The gate reads the INSTALLED unit
#     and checks for both paths; edit the unit AFTER it's installed in the copy by
#     sabotaging the stage to replace it with a hard-coded version.
run_case "copper-seatd.service hard-codes /usr/bin/seatd again" "$B" \
    'ln -sf /etc/systemd/system/copper.target \
         "$TGT/etc/systemd/system/multi-user.target.wants/copper.target"' \
    'ln -sf /etc/systemd/system/copper.target \
         "$TGT/etc/systemd/system/multi-user.target.wants/copper.target"
  printf '\''[Unit]\nDescription=Copper seat daemon (seatd)\nAfter=systemd-udev-settle.service\nBefore=copper-console.service\n[Service]\nType=simple\nExecStart=/usr/bin/seatd -g _seatd\nRestart=on-failure\nRuntimeDirectory=seatd\n[Install]\nWantedBy=copper.target\n'\'' > "$TGT/etc/systemd/system/copper-seatd.service"' \
    "copper-seatd.service searches both /usr/bin and /usr/sbin"

# 19. ldconfig is left unmasked. The image has no ldconfig and no ld.so.cache, so
#     systemd's own unit fails on every boot -- which is what put it in
#     `systemctl --failed` on the first boot. Removing the mask must go red.
run_case "ldconfig.service left unmasked" "$B" \
    'ln -sf /dev/null "$TGT/etc/systemd/system/ldconfig.service"' \
    ':' \
    "ldconfig.service is masked"

# 20. The hypr skip guard stops checking seatd. The guard decides whether a
#     cached tree can be skipped; a guard that doesn't check its own guarantees
#     skips the stage that would rebuild a missing binary -- and the tree that
#     ships points copper-seatd.service at a binary that is not there, which is
#     what the first boot found (bug 47).
#
#     The gate does not run build_hypr -- it runs the systemd stage over a
#     mocked tree -- so there is no runtime path here to break. What the gate
#     CAN do, and what section 8 of the gate does, is hold the shipped guard to
#     its contract: so this case plants the blindness and expects the gate to
#     say so.
run_case "hypr skip guard blind to seatd" "$B" \
    '     && [ -n "$(find "$TGT/usr" -name seatd -type f -print -quit 2>/dev/null)" ] \
' \
    $'     && true \\\n' \
    "build_hypr's skip guard still checks for seatd"

# 21. The gui skip guard stops checking _seatd. The group is appended by build_gui;
#     build_rootfs' second pass clobbers it. A guard that stops asking skips the
#     stage that would put it back, and seatd cannot start without the group.
#
#     Same shape as 20: the guard is the gate's to hold, not a runtime path.
run_case "gui skip guard blind to the _seatd group" "$B" \
    '     && grep -q '"'"'^_seatd:'"'"' "$TGT/etc/group" \
     && stamped_skip "$WORK/gui.stamp" "$SELF"; then' \
    '     && stamped_skip "$WORK/gui.stamp" "$SELF"; then' \
    "build_gui's skip guard still checks for the _seatd group"

# 22. The ordering cycle that shipped. copper-tty-clear.service was ordered
#     after sysinit.target AND before systemd-udevd.service, while systemd's
#     own udevd unit is ordered before sysinit.target -- a loop on
#     sysinit.target, which fails the boot's initial transaction outright (not
#     a degraded boot: no boot).
#
#     Planted by putting the After= back. The point of this case is that it
#     must be caught by the TRANSACTION check: verified one unit at a time,
#     every unit in the loop looks perfect, and that is how the cycle shipped
#     in the first place.
run_case "copper-tty-clear.service ordered into a cycle with sysinit.target" \
    "$U/copper-tty-clear.service" \
    'Before=sysinit.target systemd-udevd.service copper-firstboot.service copper-console.service' \
    'After=sysinit.target
Before=sysinit.target systemd-udevd.service copper-firstboot.service copper-console.service' \
    "form no ordering cycle"

# 23. The STAGE stops checking for an ordering cycle. The gate's own
#     transaction check would still see a planted cycle, but the stage is what
#     runs on the CI runner -- a gate that only proves itself is not the same
#     as a build that is protected. Removing the stage's check must go red.
T=$(mktemp -d /tmp/systemd-sabotage.XXXXXX); cp -a "$REPO" "$T/repo"
python3 - "$T/repo/$B" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "grep -qiE 'ordering cycle|cyclic ordering|order is cyclic|break cycle'"
assert old in s, "the stage's cycle check is not where it was expected"
s = s.replace(old, "grep -qiE 'nothing at all'", 1)
open(p, 'w', encoding='utf-8').write(s)
PY
out=$(bash "$T/repo/tests/systemd-gate.sh" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "stage checks the units for an ordering cycle"; then
    echo "  ok    gate rejects: the stage's ordering-cycle check disabled"
else
    echo "  FAIL  gate MISSED: the stage's ordering-cycle check disabled (rc=$rc)"
    printf '%s\n' "$out" | grep -i "fail" | head -4 | sed 's/^/          /'
    fails=$((fails + 1))
fi
rm -rf "$T"

# 24. The fixture goes back to modelling systemd's udevd unit wrongly. The
#     fixture used to say "Description=udev" and nothing else, so the ordering
#     graph the stage's chrooted verify walked was not the graph the boot
#     builds -- and the stage's cycle check could not see the cycle even with
#     the right code. The real noble udev unit carries DefaultDependencies=no
#     and Before=sysinit.target; without both, the stage is blind.
if grep -q 'Before=sysinit.target' "$REPO/tests/systemd-gate.sh" \
   && grep -q 'DefaultDependencies=no' "$REPO/tests/systemd-gate.sh"; then
    echo "  ok    fixture models systemd's own udevd unit (ordering included)"
else
    echo "  FAIL  fixture does not model systemd's udevd unit; the stage's cycle check is blind"
    fails=$((fails + 1))
fi

# 25. power_links stops asking which init the tree carries. This is the bug
#     the last CI run shipped: the `iso` chain re-runs the desktop stages over
#     the systemd tree -- build_rootfs clobbers /etc/group and takes the
#     _seatd group with it, and that group is part of what those stages' skip
#     guards ask about -- and each of them calls power_links. A power_links
#     that always wrote busybox undid the systemd flavour's systemctl links on
#     the way to the disc, and the systemd ISO failed its own read-back gate:
#
#         iso: the ISO boots systemd but its power commands are wrong: ...
#
#     Planted by making the flavour question answer "no" for every tree, so the
#     systemd branch is dead code and every tree gets busybox's links.
run_case "power_links blind to the tree's init" "$B" \
    'if [ "$(init_flavour "$root")" = systemd ]; then' \
    'if false; then' \
    "power_links on a systemd tree"

echo
if [ "$fails" -eq 0 ]; then
    echo "sabotage suite: the gate catches every planted defect"
    exit 0
fi
echo "sabotage suite: $fails planted defect(s) NOT caught"
exit 1
