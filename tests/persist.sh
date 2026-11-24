#!/bin/sh
# Persistence: which disks does the wizard take, does it format the right one,
# and does it ever touch a disk it must not?
# Run as root:  sudo tests/persist.sh
# A disk labelled COPPER is the writable layer, so the wizard's disk choice is
# destructive. One blank spare is taken automatically, anything else returns
# to a list where ERASE must be typed, and the boot medium, mounted disks and
# the disk in upper= are never offered.
# The gate runs in a mount namespace with stub mkfs/blkid and a fake /sys/block;
# COPPER_PERSIST_NO_REBOOT keeps the wizard from rebooting the test machine.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
ROOT=${PERSIST_ROOT:-/tmp/copper-persist-test}
WIZ=$ROOT/wizard
DRIVER="$REPO/tests/firstboot-drive.py"
# PERSIST_SRC exists so a gate test can point this at a sabotaged copy later.
SRC=${PERSIST_SRC:-$REPO/iso/firstboot/copper-firstboot.c}

if [ "$(id -u)" -ne 0 ]; then
    echo "tests/persist.sh must run as root: sudo tests/persist.sh" >&2
    exit 1
fi

fail=0
ok()  { printf 'ok   : %s\n' "$1"; }
bad() { fail=1; printf 'FAIL : %s\n' "$1"; }

echo "persistence: which disks does the wizard offer, and what does it run?"
echo

command -v unshare >/dev/null 2>&1 || { echo "FAIL : unshare not available" >&2; exit 1; }

rm -rf "$ROOT"
mkdir -p "$ROOT/etc" "$ROOT/home" "$ROOT/mnt" "$ROOT/bin" "$ROOT/calls" \
         "$ROOT/var/lib/copper" \
         "$ROOT/sys/block/sdy" "$ROOT/sys/block/sdz" "$ROOT/sys/block/sr0"

# Build the wizard from the real source, so the test tracks shipped code.
if ! gcc -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter \
         -I "$(dirname "$SRC")" "$SRC" -o "$WIZ"; then
    echo "FAIL : copper-firstboot.c did not build" >&2
    exit 1
fi

cp -a /etc/. "$ROOT/etc/" 2>/dev/null
printf 'root:x:0:0:root:/root:/bin/sh\n'   > "$ROOT/etc/passwd"
printf 'root:x:0:\n'                         > "$ROOT/etc/group"
printf 'root:!:19000:0:99999:7:::\n'         > "$ROOT/etc/shadow"

# media=/dev/sdz1 means sdz is the boot medium and is never a candidate;
# upper=ram means no writable layer is attached yet.
printf 'media=/dev/sdz1\nupper=ram\n' > "$ROOT/var/lib/copper/live-boot"

# Whole disks and the disc. Sizes are 512-byte sectors, the unit sysfs uses.
echo 41943040 > "$ROOT/sys/block/sdy/size"   # 20 GiB, spare: the one to offer
echo 83886080 > "$ROOT/sys/block/sdz/size"   # 40 GiB, but it is the medium
echo 1048576  > "$ROOT/sys/block/sr0/size"   # the disc; never a disk to offer

# Stub mkfs records its command line; no device is ever formatted.
cat > "$ROOT/bin/mkfs.ext4" <<EOF
#!/bin/sh
echo "\$@" >> "$ROOT/calls/mkfs"
exit 0
EOF
chmod +x "$ROOT/bin/mkfs.ext4"

# Stub blkid distinguishes "has a filesystem" from "is Copper's": case 9 needs
# a disk that answers yes to one and no to the other.
cat > "$ROOT/bin/blkid" <<EOF
#!/bin/sh
if [ -f "$ROOT/is-copper" ] && grep -qx "\$1" "$ROOT/is-copper"; then
    echo "\$1: LABEL=\"COPPER\" UUID=1234-5678 TYPE=ext4"
elif [ -f "$ROOT/has-fs" ] && grep -qx "\$1" "$ROOT/has-fs"; then
    echo "\$1: UUID=1234-5678 TYPE=ext4"
fi
exit 0
EOF
chmod +x "$ROOT/bin/blkid"

# Run the driver from $ROOT under /tmp: the private /home bind would hide a
# driver living in the repo on CI runners.
cp "$DRIVER" "$ROOT/driver.py"

# run_wizard [prompt|answer ...]
#   Drives the wizard in the namespace and leaves its transcript in $out and its
#   exit status in $rc. The extra steps are passed through to the driver.
run_wizard() {
    : > "$ROOT/calls/mkfs"
    out=$(unshare --mount --uts --propagation private /bin/sh -c "
        mount --bind '$ROOT/var'  /var  || exit 1
        mount --bind '$ROOT/sys'  /sys  || exit 1
        mount --bind '$ROOT/etc'  /etc  || exit 1
        mount --bind '$ROOT/home' /home || exit 1
        mount --bind '$ROOT/mnt'  /mnt  || exit 1
        cd /tmp
        export PATH='$ROOT/bin:/usr/bin:/bin'
        export COPPER_PERSIST_SECONDS=1
        export COPPER_PERSIST_NO_REBOOT=1
        exec python3 '$ROOT/driver.py' '$WIZ' \"\$@\"
    " sh "$@" 2>&1)
    rc=$?
}

show() { printf '%s\n' "$out" | tail -25 | sed 's/^/      /'; }

# 1. one blank disk is taken without a question; only main()'s closing hold
# is answered.
run_wizard "Press Enter to continue|"
if [ "$rc" -eq 0 ]; then
    ok "wizard finished the automatic run"
else
    bad "wizard exited $rc on the automatic run"
    show
fi

if printf '%s' "$out" | grep -q 'empty disk is attached'; then
    ok "one empty spare disk was taken without being asked about"
else
    bad "the wizard did not take the single empty disk automatically"
    show
fi
if printf '%s' "$out" | grep -q 'Disk to keep files on'; then
    bad "the disk list was still shown when there was only one candidate"
    show
else
    ok "no disk list when the choice was not a choice"
fi
if printf '%s' "$out" | grep -q 'press Enter to skip'; then
    ok "the countdown said which disk it was about and offered the way out"
else
    bad "the automatic format gave no countdown and no way to stop it"
    show
fi
if printf '%s' "$out" | grep -q 'Reboot to turn persistence on'; then
    ok "the run did not reboot the machine (COPPER_PERSIST_NO_REBOOT honored)"
else
    bad "the automatic path ignored COPPER_PERSIST_NO_REBOOT"
    show
fi

if printf '%s' "$out" | grep -q 'sdz'; then
    bad "sdz was offered -- it carries the medium this machine booted from"
    show
else
    ok "the boot medium sdz was never offered"
fi
if printf '%s' "$out" | grep -q 'sr0'; then
    bad "sr0 was offered -- that is the disc, not a disk to erase"
    show
else
    ok "the disc sr0 was never offered"
fi

if grep -q -- '-q -F -L COPPER /dev/sdy' "$ROOT/calls/mkfs"; then
    ok "mkfs.ext4 ran as: $(cat "$ROOT/calls/mkfs")"
else
    bad "mkfs.ext4 was not called with the COPPER label on /dev/sdy"
    printf '      calls recorded: %s\n' "$(cat "$ROOT/calls/mkfs" 2>/dev/null || echo none)"
fi

# ------------------------------------------------- 2. the countdown can stop
run_wizard "press Enter to skip|" \
           "Press Enter to continue|"
if printf '%s' "$out" | grep -q 'Skipped'; then
    ok "pressing Enter at the countdown stopped it"
else
    bad "the countdown could not be stopped"
    show
fi
if [ -s "$ROOT/calls/mkfs" ]; then
    bad "the disk was formatted even though the countdown was stopped: $(cat "$ROOT/calls/mkfs")"
else
    ok "nothing was formatted when the countdown was stopped"
fi

# 3. a disk with files is not a counting decision: the list comes back.
echo /dev/sdy > "$ROOT/has-fs"
run_wizard "Disk to keep files on|" \
           "Press Enter to continue|"
if printf '%s' "$out" | grep -q 'Disk to keep files on'; then
    ok "a single disk with a filesystem on it was listed instead of taken"
else
    bad "a disk with files on it was taken automatically"
    show
fi
if [ -s "$ROOT/calls/mkfs" ]; then
    bad "a disk with a filesystem on it was formatted: $(cat "$ROOT/calls/mkfs")"
else
    ok "nothing was formatted when that disk was left alone"
fi
rm -f "$ROOT/has-fs"

# --------------------------------------- 4. two disks: the choice is a choice
mkdir -p "$ROOT/sys/block/sdw"
echo 20971520 > "$ROOT/sys/block/sdw/size"   # 10 GiB

run_wizard "Disk to keep files on|sdy" \
           "Type ERASE (capital letters) to go ahead|ERASE" \
           "Press Enter to continue|"
if printf '%s' "$out" | grep -q 'sdw'; then
    ok "both spare disks were listed when there was more than one"
else
    bad "the second spare disk was not offered"
    show
fi
if grep -q -- '-q -F -L COPPER /dev/sdy' "$ROOT/calls/mkfs"; then
    ok "the picked disk was the one formatted: $(cat "$ROOT/calls/mkfs")"
else
    bad "the picked disk was not the one formatted"
    printf '      calls recorded: %s\n' "$(cat "$ROOT/calls/mkfs" 2>/dev/null || echo none)"
fi

# ------------------------------- 5. a disk that was never listed, typed by hand
run_wizard "Disk to keep files on|sdz" \
           "Press Enter to continue|"
if printf '%s' "$out" | grep -q 'not one of the disks'; then
    ok "typing the boot medium by hand was refused"
else
    bad "the wizard did not say it refused sdz"
    show
fi
if [ -s "$ROOT/calls/mkfs" ]; then
    bad "sdz was formatted even though it was never offered: $(cat "$ROOT/calls/mkfs")"
else
    ok "nothing was formatted when an unoffered disk was typed"
fi

# ------------------------------------------------------------- 6. no pick
run_wizard "Disk to keep files on|" \
           "Press Enter to continue|"
if printf '%s' "$out" | grep -q 'Nothing selected'; then
    ok "pressing Enter alone skipped persistence"
else
    bad "the skip path did not say it was skipping"
    show
fi
if [ -s "$ROOT/calls/mkfs" ]; then
    bad "a disk was formatted on the skip path: $(cat "$ROOT/calls/mkfs")"
else
    ok "nothing was formatted when no disk was picked"
fi
rm -rf "$ROOT/sys/block/sdw"

# 7. upper= names the disk holding this machine's files: never a candidate.
# With a real disk there persistence is already on, so the page must say so,
# print no "nothing is saved", and name upper= as a device path.
printf 'media=/dev/sdz1\nupper=/dev/sdy\n' > "$ROOT/var/lib/copper/live-boot"
run_wizard "Press Enter to continue|"
if printf '%s' "$out" | grep -q 'Already on'; then
    ok "a boot with persistence already on says so"
else
    bad "the wizard did not report that persistence was already on"
    show
fi
if printf '%s' "$out" | grep -q 'nothing is saved'; then
    bad "the wizard claimed nothing is saved while upper= was /dev/sdy"
    show
else
    ok "no 'nothing is saved' text when persistence was already on"
fi
# upper= is a device path, so print it back as one, not a bare name.
if printf '%s' "$out" | grep -q 'kept on /dev/sdy'; then
    ok "the disk already in use was named as a device path"
else
    bad "the page did not name /dev/sdy as the disk already in use"
    show
fi
if printf '%s' "$out" | grep -q 'Disk to keep files on'; then
    bad "a disk list was shown when persistence needed nothing"
    show
else
    ok "no disk list when there was nothing left to set up"
fi
if [ -s "$ROOT/calls/mkfs" ]; then
    bad "the writable layer disk was formatted: $(cat "$ROOT/calls/mkfs")"
else
    ok "nothing was formatted when the only disk was already in use"
fi
printf 'media=/dev/sdz1\nupper=ram\n' > "$ROOT/var/lib/copper/live-boot"

# 8. without /init's marker the persistence page must not appear at all.
mv "$ROOT/var/lib/copper/live-boot" "$ROOT/var/lib/copper/live-boot.off"
run_wizard
if printf '%s' "$out" | grep -q 'Keeping your files'; then
    bad "the persistence page ran without /init's live marker"
    show
else
    ok "no persistence page without the live marker"
fi
if [ -s "$ROOT/calls/mkfs" ]; then
    bad "a disk was formatted without the live marker"
else
    ok "the wizard left the disks alone when it was not a Copper boot"
fi
mv "$ROOT/var/lib/copper/live-boot.off" "$ROOT/var/lib/copper/live-boot"

# 9. a COPPER-labelled disk is already a persistence disk: reuse it silently,
# with no list, countdown or mkfs, even though upper=ram says persistence is
# not on yet. That is the re-run-a-VM case.
echo /dev/sdy > "$ROOT/is-copper"
run_wizard "Press Enter to continue|"
rm -f "$ROOT/is-copper"
if printf '%s' "$out" | grep -q 'Already on'; then
    ok "a disk already carrying the COPPER label was claimed without a question"
else
    bad "the already-COPPER disk was not recognised and reclaimed"
    show
fi
if printf '%s' "$out" | grep -q 'Disk to keep files on'; then
    bad "the ERASE list was shown for a disk that is already Copper's"
    show
else
    ok "no disk list for an already-COPPER disk"
fi
if printf '%s' "$out" | grep -q 'press Enter to skip\|Type ERASE'; then
    bad "an already-COPPER disk still offered a format or an ERASE"
    show
else
    ok "neither a countdown nor an ERASE was offered for a disk Copper owns"
fi
if [ -s "$ROOT/calls/mkfs" ]; then
    bad "an already-COPPER disk was formatted (losing its previous session): $(cat "$ROOT/calls/mkfs")"
else
    ok "nothing was formatted -- the disk's existing contents are kept"
fi
if printf '%s' "$out" | grep -q 'Reboot to turn persistence on'; then
    ok "the reclaimed disk still takes the boot into persistence"
else
    bad "the already-COPPER path did not reach the reboot"
    show
fi

# 10. a foreign filesystem is still not taken silently: the label, not the
# presence of a filesystem, decides whether ERASE is required.
echo /dev/sdy > "$ROOT/has-fs"
run_wizard "Disk to keep files on|" \
           "Press Enter to continue|"
rm -f "$ROOT/has-fs"
if printf '%s' "$out" | grep -q 'Disk to keep files on'; then
    ok "a foreign filesystem was still listed, not claimed"
else
    bad "a foreign filesystem was taken without asking"
    show
fi
if [ -s "$ROOT/calls/mkfs" ]; then
    bad "a foreign filesystem was formatted without ERASE: $(cat "$ROOT/calls/mkfs")"
else
    ok "nothing was formatted when the disk held foreign data"
fi

# 11. IDE disks enumerate as /dev/hdX; the candidate predicate and /init's
# find_upper used to stop at sd/vd/nvme/mmcblk and miss them.
mkdir -p "$ROOT/sys/block/hda"
echo 20971520 > "$ROOT/sys/block/hda/size"   # 10 GiB, IDE spare
run_wizard "Disk to keep files on|hda" \
           "Type ERASE (capital letters) to go ahead|ERASE" \
           "Press Enter to continue|"
if printf '%s' "$out" | grep -q 'hda'; then
    ok "an IDE spare was offered as the persistence disk"
else
    bad "an IDE spare was not offered"
    show
fi
if grep -q -- '-q -F -L COPPER /dev/hda' "$ROOT/calls/mkfs"; then
    ok "the IDE disk was the one formatted: $(cat "$ROOT/calls/mkfs")"
else
    bad "the IDE disk was not the one formatted"
    printf '      calls recorded: %s\n' "$(cat "$ROOT/calls/mkfs" 2>/dev/null || echo none)"
fi
rm -rf "$ROOT/sys/block/hda"

echo
if [ $fail -gt 0 ]; then
    echo "$fail check(s) failed"
    exit 1
fi
echo "persistence: all good"
