#!/usr/bin/env bash
# Sabotage suite for tests/persist.sh — prove the persistence gate can FAIL.
#
# tests/persist.sh asserts decisions, not devices: which disk the wizard takes,
# what it refuses, and what it runs. A gate like that is only worth its lines if
# it goes red when a decision is wrong, and that claim is what this file tests.
#
# It exists because of the pattern the systemd work kept hitting: a test that
# agrees with the code because both were written by the same hand at the same
# moment certifies nothing. So each case plants one defect, against the real
# gate, and requires the gate to notice.
#
# Root only (the gate uses a mount namespace). Run: sudo tests/persist-sabotage.sh
#
# handcrafted by 12hrformat (PERSISTENCE.md; claim a disk we already own)
#
# NOTE: unlike tests/systemd-gate-sabotage.sh, this copies ONLY the source file
# it sabotages, and points tests/persist.sh at it with PERSIST_SRC. The gate
# already supports that redirection (there is a comment on the variable), and it
# keeps the sabotage honest: the defect is in the file under test and nowhere
# else.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)

if [ "$(id -u)" -ne 0 ]; then
    echo "tests/persist-sabotage.sh must run as root: sudo tests/persist-sabotage.sh" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL no python3 (used for exact-string sabotage edits)" >&2
    exit 1
fi

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

# run_case <label> <old> <new> <expected-text>
#   Compiles the sabotaged wizard and runs the real persistence gate at it.
run_case() {
    label=$1; old=$2; new=$3; expect=$4
    T=$(mktemp -d /tmp/persist-sabotage.XXXXXX) || exit 1
    mkdir -p "$T/iso/firstboot"
    cp "$REPO/iso/firstboot/copper-firstboot.c" "$T/iso/firstboot/copper-firstboot.c"
    if ! msg=$(edit "$T/iso/firstboot/copper-firstboot.c" "$old" "$new" 2>&1); then
        echo "BROKEN sabotage (did not apply): $label -- $msg"
        fails=$((fails + 1)); rm -rf "$T"; return
    fi
    # A private ROOT so concurrent/interrupted runs cannot collide.
    out=$(PERSIST_SRC="$T/iso/firstboot/copper-firstboot.c" \
          PERSIST_ROOT="$T/root" \
          bash "$REPO/tests/persist.sh" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "$expect"; then
        echo "  ok    gate rejects: $label"
    else
        echo "  FAIL  gate MISSED: $label (rc=$rc, expected to see: $expect)"
        printf '%s\n' "$out" | grep -E '^FAIL' | head -4 | sed 's/^/          /'
        fails=$((fails + 1))
    fi
    rm -rf "$T"
}

echo "sabotaging persistence, one decision at a time:"

# 1. The new feature is removed: the branch goes back to "empty disk only", so
#    a disk that already carries the COPPER label falls through to the ERASE
#    prompt again. This is the change PERSISTENCE.md exists to make, and the
#    reason case 9 is in the gate.
run_case "already-COPPER disks are no longer auto-claimed (back to empty-only)" \
    'if (n == 1 && (disk_is_copper(disks[0]) || !disk_has_fs(disks[0]))) {' \
    'if (n == 1 && !disk_has_fs(disks[0])) {' \
    "the already-COPPER disk was not recognised and reclaimed"

# 2. The label test is inverted in the other direction: ANY filesystem is now
#    treated as Copper's, so a disk holding somebody's data is silently claimed
#    and formatted -- the one mistake that costs a person their files. Case 10
#    exists to catch exactly this.
run_case "a foreign filesystem is taken without ERASE (label test always true)" \
    'if (n == 1 && (disk_is_copper(disks[0]) || !disk_has_fs(disks[0]))) {' \
    'if (n == 1 && (1 || !disk_has_fs(disks[0]))) {' \
    "a foreign filesystem was taken without asking|a foreign filesystem was formatted without ERASE"

# 3. The COPPER disk is claimed but still formatted first, which would erase the
#    previous Copper session the disk exists to hold. The gate's "nothing was
#    formatted" line is the assertion.
run_case "the already-COPPER path formats the disk anyway (loses the session)" \
    '        if (already) {
            /* Nothing to format, and no countdown: the disk is already a
               persistence disk and there is no destructive act to escape. The
               session that was on it comes back on the next boot. */
            printf("  Already on: your files are kept on /dev/%s and are still\n",
                   disks[0]);
            printf("  here after a reboot. Nothing to set up.\n");
        } else {' \
    '        if (already) {
            format_persistence_disk(disks[0]);
            printf("  Already on: your files are kept on /dev/%s and are still\n",
                   disks[0]);
            printf("  here after a reboot. Nothing to set up.\n");
        } else {' \
    "an already-COPPER disk was formatted"

# 4. The already-COPPER path claims the disk but never reboots into it, so the
#    session stays in RAM and the disk is dead weight -- a silent no-op that
#    looks exactly like success in the transcript. The call is deleted outright;
#    the gate's "still takes the boot into persistence" line is what catches it.
run_case "the already-COPPER path forgets to reboot into the disk" \
    '        carry_firstboot_answers(disks[0]);
        reboot_into_persistence();
        return 1;
    }

    /* More than one candidate' \
    '        carry_firstboot_answers(disks[0]);
        return 1;
    }

    /* More than one candidate' \
    "already-COPPER path did not reach the reboot"

echo
if [ "$fails" -eq 0 ]; then
    echo "persistence sabotage suite: the gate catches every planted defect"
    exit 0
fi
echo "persistence sabotage suite: $fails planting(s) NOT caught"
exit 1
