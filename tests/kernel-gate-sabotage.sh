#!/usr/bin/env bash
# Sabotage suite for tests/kernel-gate.sh — prove the gate can FAIL.
#
# A gate that only ever goes green is not a gate. tests/kernel-gate.sh asserts
# that every symbol Copper needs is =y in the generated kernel config, and its
# whole value is that it goes red when the build stops asserting something or
# asserts the wrong name; that claim is what this file tests.
#
# Each case copies the repo, plants one defect in iso/build.sh with an
# exact-string edit (a planting that does not match the file is reported as a
# broken test, not a passing one), runs the gate in the copy, and asserts both
# that it exits non-zero and that it names the right thing.
#
# The defects are the realistic ones: a symbol dropped from a loop by a refactor,
# a misspelling that scripts/config would accept and olddefconfig would drop in
# silence (the DRM_VMWARE mistake, again), and a whole block removed. This suite
# is the reason tests/kernel-gate.sh is not just a second copy of the list.
#
# No root needed. Run: bash tests/kernel-gate-sabotage.sh
#
# handcrafted by 12hrformat (bug 46: a VMware guest with no disk to offer)

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$REPO/tests/kernel-gate.sh" ] || { echo "FAIL no tests/kernel-gate.sh" >&2; exit 1; }
[ -f "$REPO/iso/build.sh" ]        || { echo "FAIL no iso/build.sh" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL no python3 (exact-string edits)" >&2; exit 1; }

fails=0

# edit <file> <old> <new> — exact, single replacement, or fail loudly.
edit() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
if old not in s:
    sys.exit("NO-MATCH: " + old[:70])
open(path, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
}

# run_case <label> <old> <new> <expected-text-regex>
run_case() {
    label=$1; old=$2; new=$3; expect=$4
    T=$(mktemp -d /tmp/kernel-sabotage.XXXXXX) || exit 1
    cp -a "$REPO" "$T/repo"
    if ! msg=$(edit "$T/repo/iso/build.sh" "$old" "$new" 2>&1); then
        echo "BROKEN sabotage (did not apply): $label -- $msg"
        fails=$((fails + 1)); rm -rf "$T"; return
    fi
    out=$(bash "$T/repo/tests/kernel-gate.sh" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "$expect"; then
        echo "  ok    gate rejects: $label"
    else
        echo "  FAIL  gate MISSED: $label (rc=$rc, expected to see: $expect)"
        printf '%s\n' "$out" | grep -iE 'FAIL' | head -4 | sed 's/^/          /'
        fails=$((fails + 1))
    fi
    rm -rf "$T"
}

echo "sabotaging the kernel config gate, one defect at a time:"

# 1. A storage symbol is dropped from the assert loop by a refactor. This is the
#    shape of bug 46 itself: the flag list is right, the assert list forgot a
#    controller, and a machine with that controller gets no disk.
run_case "SCSI_MPT3SAS dropped from the assert loop" \
    '  for sym in SCSI SCSI_LOWLEVEL SCSI_MPT3SAS VMWARE_PVSCSI SCSI_VIRTIO ; do' \
    '  for sym in SCSI SCSI_LOWLEVEL VMWARE_PVSCSI SCSI_VIRTIO ; do' \
    "SCSI_MPT3SAS|not in the asserted symbol list"

# 2. The controller is asked for under a name kconfig does not have. This is the
#    DRM_VMWARE mistake the display comment was written about: scripts/config
#    accepts any name, olddefconfig drops it silently, and the build goes green
#    with a kernel that cannot see the disk. The realistic form is that somebody
#    typed VMW_PVSCSI in BOTH the flag list and the assert loop -- so both are
#    planted, and the gate's completeness check has to notice that the symbol it
#    expects (VMWARE_PVSCSI) is no longer asserted. (A flags-only change is a
#    different case and is the negative control below.)
T=$(mktemp -d /tmp/kernel-sabotage.XXXXXX) || exit 1
cp -a "$REPO" "$T/repo"
python3 - "$T/repo/iso/build.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
before = s
# the enable flag
s = s.replace('--enable VMWARE_PVSCSI', '--enable VMW_PVSCSI', 1)
# the asserted loop
s = s.replace('for sym in SCSI SCSI_LOWLEVEL SCSI_MPT3SAS VMWARE_PVSCSI SCSI_VIRTIO ; do',
              'for sym in SCSI SCSI_LOWLEVEL SCSI_MPT3SAS VMW_PVSCSI SCSI_VIRTIO ; do', 1)
if s == before:
    sys.exit('NO-MATCH: neither occurrence found')
open(p, 'w', encoding='utf-8').write(s)
PY
if [ $? -ne 0 ]; then
    echo "BROKEN sabotage (did not apply): VMWARE_PVSCSI misspelled"
    fails=$((fails + 1))
else
    out=$(bash "$T/repo/tests/kernel-gate.sh" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "VMWARE_PVSCSI|not in the asserted symbol list"; then
        echo "  ok    gate rejects: VMWARE_PVSCSI misspelled as VMW_PVSCSI"
    else
        echo "  FAIL  gate MISSED: VMWARE_PVSCSI misspelled as VMW_PVSCSI (rc=$rc)"
        printf '%s\n' "$out" | grep -iE 'FAIL' | head -4 | sed 's/^/          /'
        fails=$((fails + 1))
    fi
fi
rm -rf "$T"

# 3. The whole storage block is deleted from require_kernel_config -- the
#    "somebody tidied up" case. Nothing asks, nothing asserts, and the gate has
#    to notice SCSI is no longer claimed.
run_case "the whole storage assert block is removed" \
    '  for sym in SCSI SCSI_LOWLEVEL SCSI_MPT3SAS VMWARE_PVSCSI SCSI_VIRTIO ; do
    grep -qx "CONFIG_$sym=y" "$cfg" || missing="$missing $sym"
  done' \
    '  true' \
    "SCSI|not in the asserted symbol list"

# 4. The assert loop is emptied but left in place, so it *looks* present and
#    checks nothing. A gate that only greps for the loop's text passes this; a
#    gate that enumerates the symbols it expects does not.
run_case "the storage assert loop is emptied (looks present, checks nothing)" \
    '  for sym in SCSI SCSI_LOWLEVEL SCSI_MPT3SAS VMWARE_PVSCSI SCSI_VIRTIO ; do' \
    '  for sym in ; do' \
    "SCSI|asserted symbol list|empty"

# 5. The enable flags are removed but the asserts kept. The gate still passes
#    THIS file (the assert list is intact), which is correct -- the flags are
#    build_kernel's business and the gate tests require_kernel_config. Kept as a
#    NEGATIVE control: it proves the gate is testing the assertion contract it
#    claims to, and not accidentally grepping the flag list next to it.
T=$(mktemp -d /tmp/kernel-sabotage.XXXXXX) || exit 1
cp -a "$REPO" "$T/repo"
if edit "$T/repo/iso/build.sh" \
    '      --enable SCSI --enable SCSI_LOWLEVEL \
      --enable SCSI_MPT3SAS --enable VMWARE_PVSCSI --enable SCSI_VIRTIO \' \
    '' >/dev/null 2>&1; then
    out=$(bash "$T/repo/tests/kernel-gate.sh" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  ok    negative control: assert list intact still passes (gate tests the contract)"
    else
        echo "  FAIL  negative control: gate went red on a flags-only change it does not test"
        printf '%s\n' "$out" | grep -iE 'FAIL' | head -3 | sed 's/^/          /'
        fails=$((fails + 1))
    fi
else
    echo "  WARN  negative-control planting did not apply (flags moved); skipping"
fi
rm -rf "$T"

echo
if [ "$fails" -eq 0 ]; then
    echo "kernel config sabotage suite: the gate catches every planted defect"
    exit 0
fi
echo "kernel config sabotage suite: $fails planting(s) NOT caught"
exit 1
