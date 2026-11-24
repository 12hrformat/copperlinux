#!/usr/bin/env bash
# Sabotage suite for tests/kernel-gate.sh — prove the gate can FAIL.
# A gate that only ever goes green is not a gate; this one must go red when
# the build stops asserting something or asserts the wrong name.
# Each case copies the repo, plants one exact-string defect in iso/build.sh,
# runs the gate in the copy, and requires a non-zero exit naming the right thing.
# Defects: a dropped symbol, a misspelling olddefconfig would silently drop,
# an emptied loop and a removed block. Flags-only changes are a control.
# No root needed. Run: bash tests/kernel-gate-sabotage.sh
#

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

# 1. a storage symbol drops out of the assert loop by refactor: the flag list
# is right but the assert list forgot a controller, so that machine has no disk.
run_case "SCSI_MPT3SAS dropped from the assert loop" \
    '  for sym in SCSI SCSI_LOWLEVEL SCSI_MPT3SAS VMWARE_PVSCSI SCSI_VIRTIO \
             SCSI_SYM53C8XX_2 MEGARAID_SAS ; do' \
    '  for sym in SCSI SCSI_LOWLEVEL VMWARE_PVSCSI SCSI_VIRTIO \
             SCSI_SYM53C8XX_2 MEGARAID_SAS ; do' \
    "SCSI_MPT3SAS|not in the asserted symbol list"

# 2. a misspelling that scripts/config accepts and olddefconfig silently drops
# (the DRM_VMWARE mistake). Both the flag and the assert loop are misspelled;
# a flags-only change is the negative control below.
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
s = s.replace('for sym in SCSI SCSI_LOWLEVEL SCSI_MPT3SAS VMWARE_PVSCSI SCSI_VIRTIO \\\n'
              '             SCSI_SYM53C8XX_2 MEGARAID_SAS ; do',
              'for sym in SCSI SCSI_LOWLEVEL SCSI_MPT3SAS VMW_PVSCSI SCSI_VIRTIO \\\n'
              '             SCSI_SYM53C8XX_2 MEGARAID_SAS ; do', 1)
# both halves have to land: a flags-only misspelling is the negative
# control's territory, not this case, so a half-applied planting is
# reported as broken instead of run as something weaker than intended
if s.count('VMW_PVSCSI') != 2:
    sys.exit('NO-MATCH: expected to misspell both the flag and the assert loop')
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

# 3. the whole storage block is removed: nothing asserts SCSI any more.
run_case "the whole storage assert block is removed" \
    '  for sym in SCSI SCSI_LOWLEVEL SCSI_MPT3SAS VMWARE_PVSCSI SCSI_VIRTIO \
             SCSI_SYM53C8XX_2 MEGARAID_SAS ; do
    grep -qx "CONFIG_$sym=y" "$cfg" || missing="$missing $sym"
  done' \
    '  true' \
    "SCSI|not in the asserted symbol list"

# 4. the loop is emptied but still present: a text grep would pass this.
run_case "the storage assert loop is emptied (looks present, checks nothing)" \
    '  for sym in SCSI SCSI_LOWLEVEL SCSI_MPT3SAS VMWARE_PVSCSI SCSI_VIRTIO \
             SCSI_SYM53C8XX_2 MEGARAID_SAS ; do' \
    '  for sym in ; do' \
    "SCSI|asserted symbol list|empty"

# 5. negative control: enable flags removed, asserts kept. The gate still
# passes because flags are build_kernel's business, not this contract.
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
