#!/usr/bin/env bash
# Sabotage suite for tests/persist.sh — prove the persistence gate can FAIL.
# Each case plants one wrong decision against the real gate, because a test
# written with the code it guards certifies nothing.
# Root only (the gate uses a mount namespace). Run: sudo tests/persist-sabotage.sh
#
#
# NOTE: unlike systemd-gate-sabotage.sh, only the source file is copied and
# pointed at by PERSIST_SRC. The gate already supports that redirection, so
# the defect is in the file under test and nowhere else.

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

# 1. removing auto-claim sends an already-COPPER disk back to the ERASE prompt.
run_case "already-COPPER disks are no longer auto-claimed (back to empty-only)" \
    'if (n == 1 && (disk_is_copper(disks[0]) || !disk_has_fs(disks[0]))) {' \
    'if (n == 1 && !disk_has_fs(disks[0])) {' \
    "the already-COPPER disk was not recognised and reclaimed"

# 2. treating any filesystem as Copper's would silently take someone's data.
run_case "a foreign filesystem is taken without ERASE (label test always true)" \
    'if (n == 1 && (disk_is_copper(disks[0]) || !disk_has_fs(disks[0]))) {' \
    'if (n == 1 && (1 || !disk_has_fs(disks[0]))) {' \
    "a foreign filesystem was taken without asking|a foreign filesystem was formatted without ERASE"

# 3. claiming a COPPER disk but still formatting it destroys its session.
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

# 4. claiming but not rebooting leaves the session in RAM: a silent no-op.
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
