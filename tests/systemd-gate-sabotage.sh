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
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "$expect"; then
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
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "Unknown key 'StartLimitIntervalSec'"; then
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
    "Unknown key 'SocketMode'"

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

echo
if [ "$fails" -eq 0 ]; then
    echo "sabotage suite: the gate catches every planted defect"
    exit 0
fi
echo "sabotage suite: $fails planted defect(s) NOT caught"
exit 1
