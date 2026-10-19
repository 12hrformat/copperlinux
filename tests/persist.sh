#!/bin/sh
# Persistence: which disks does the wizard take, does it format the right one
# with the label /init looks for, and does it ever touch a disk it must not?
#
# Run as root:  sudo tests/persist.sh
#
# The bug this guards against
# ---------------------------
# Copper ran entirely from RAM, so every reboot threw the session away. The fix
# is a disk labelled COPPER: the wizard writes that label on first boot and
# /init mounts it as the overlay's writable layer. That makes the wizard's disk
# choice a destructive operation, so the thing worth testing is not that it
# formats -- it is that it takes the right disk and refuses the rest:
#
#   - one blank spare disk is taken automatically, with no question to answer
#     (the ordinary first boot), but only after the countdown said which disk
#     and offered the way out;
#   - anything else -- two candidates, or one that already holds files -- goes
#     back to the list, and a disk is only wiped there once it was printed and
#     ERASE was typed at it;
#   - it never offers the disc it booted from, anything already mounted, or the
#     disk /init has attached as the writable layer (the marker's upper=).
#
# Running it safely
# -----------------
# Nothing real is ever formatted, and the machine is never rebooted. In a mount
# namespace this gives the wizard a fake /sys/block (whole disks and a disc), a
# fake /etc, /home and /mnt, and the live marker /init leaves, and it puts stub
# mkfs.ext4 and blkid first on PATH. The stubs record what they were handed and
# touch no device at all -- so the assertions are about the decisions, and the
# machine underneath is untouched.
#
# COPPER_PERSIST_NO_REBOOT is not optional here. The wizard reboots by itself
# once the disk is ready, which is the point of the change -- and that would
# reboot the machine running the tests.

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

# The marker /init writes. media=/dev/sdz1 says the medium is a partition of
# sdz, so sdz is the disk this machine booted from and must never be offered,
# however its label may look. upper=ram says nothing is attached as the
# writable layer yet.
printf 'media=/dev/sdz1\nupper=ram\n' > "$ROOT/var/lib/copper/live-boot"

# Whole disks and the disc. Sizes are 512-byte sectors, the unit sysfs uses.
echo 41943040 > "$ROOT/sys/block/sdy/size"   # 20 GiB, spare: the one to offer
echo 83886080 > "$ROOT/sys/block/sdz/size"   # 40 GiB, but it is the medium
echo 1048576  > "$ROOT/sys/block/sr0/size"   # the disc; never a disk to offer

# Stub mkfs.ext4. It records the whole command line and formats nothing, so the
# test can assert what the wizard *would* have run without risking a device.
cat > "$ROOT/bin/mkfs.ext4" <<EOF
#!/bin/sh
echo "\$@" >> "$ROOT/calls/mkfs"
exit 0
EOF
chmod +x "$ROOT/bin/mkfs.ext4"

# Stub blkid, the probe that decides whether a disk still has files on it. A
# disk named in $ROOT/has-fs reports a filesystem; every other disk reports
# nothing, which is what an empty disk does.
cat > "$ROOT/bin/blkid" <<EOF
#!/bin/sh
if [ -f "$ROOT/has-fs" ] && grep -qx "\$1" "$ROOT/has-fs"; then
    echo "\$1: UUID=1234-5678 TYPE=ext4"
fi
exit 0
EOF
chmod +x "$ROOT/bin/blkid"

# Run the driver from inside the sandbox directory rather than from the repo.
# The wizard runs with a private /home (see below), and on a CI runner the repo
# lives *under* /home -- so calling "$REPO/tests/firstboot-drive.py" would have
# that path disappear the moment /home is bound, and python3 would report the
# script missing. The copy is in $ROOT under /tmp, which nothing here shadows.
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

# -------------------------------------------- 1. one empty disk: automatic
# No disk is named and no ERASE is typed: this is the whole point of the change.
# The only prompt answered is main()'s closing hold.
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

# --------------------------------- 3. a disk that already has files on it
# Same single disk, but not empty: that is not a decision to make by counting,
# so the list comes back and nothing happens on Enter alone.
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

# ----------------------------- 7. the disk /init already attached is not free
# upper= names the writable layer. It is the disk whose whole purpose is holding
# this machine's files, so it is never a candidate -- even when it is the only
# spare-looking disk there is. This is the bug 35 case, where the disk showed up
# in the list because /proc/mounts alone did not rule it out.
printf 'media=/dev/sdz1\nupper=/dev/sdy\n' > "$ROOT/var/lib/copper/live-boot"
run_wizard "Press Enter to continue|"
if printf '%s' "$out" | grep -q 'no spare disk is attached'; then
    ok "the disk /init had already attached was not offered"
else
    bad "the wizard offered the disk that is already the writable layer"
    show
fi
if [ -s "$ROOT/calls/mkfs" ]; then
    bad "the writable layer disk was formatted: $(cat "$ROOT/calls/mkfs")"
else
    ok "nothing was formatted when the only disk was already in use"
fi
printf 'media=/dev/sdz1\nupper=ram\n' > "$ROOT/var/lib/copper/live-boot"

# ------------------------------------------------- 8. not a live Copper boot
# Without /init's marker the page must not appear at all: that is what keeps a
# test bench -- which has a spare disk of its own -- from being offered a format.
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

echo
if [ $fail -gt 0 ]; then
    echo "$fail check(s) failed"
    exit 1
fi
echo "persistence: all good"
