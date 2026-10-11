#!/bin/sh
# Persistence: does the wizard offer only disks that are safe to erase, and
# format the one that is picked with the label /init looks for?
#
# Run as root:  sudo tests/persist.sh
#
# The bug this guards against
# ---------------------------
# Copper ran entirely from RAM, so every reboot threw the session away. The fix
# is a disk labelled COPPER: the wizard writes that label on first boot and
# /init mounts it as the overlay's writable layer. That makes the wizard's disk
# choice a destructive operation, so the thing worth testing is not that it
# formats -- it is that it refuses. It must not offer the disc it booted from,
# it must not offer anything already mounted, and it must not format a disk the
# user typed by hand unless that disk was printed in the list first.
#
# Running it safely
# -----------------
# Nothing real is ever formatted. In a mount namespace this gives the wizard a
# fake /sys/block (two whole disks and a disc), a fake /etc and /home, and the
# live marker /init leaves, and it puts a stub mkfs.ext4 first on PATH. The stub
# records the command line it was handed and touches no device at all -- so the
# assertions are about the decisions, and the machine underneath is untouched.

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
mkdir -p "$ROOT/etc" "$ROOT/home" "$ROOT/bin" "$ROOT/calls" \
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
# however its label may look.
printf 'media=/dev/sdz1\nupper=ram\n' > "$ROOT/var/lib/copper/live-boot"

# Two whole disks and the disc. Sizes are 512-byte sectors, the unit sysfs uses.
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
        cd /tmp
        PATH='$ROOT/bin:/usr/bin:/bin' exec python3 '$ROOT/driver.py' '$WIZ' \"\$@\"
    " sh "$@" 2>&1)
    rc=$?
}

show() { printf '%s\n' "$out" | tail -25 | sed 's/^/      /'; }

# ---------------------------------------------------------- 1. the good path
run_wizard "Disk to keep files on|sdy" \
           "Type ERASE (capital letters) to go ahead|ERASE" \
           "Press Enter to continue|"
if [ "$rc" -eq 0 ]; then
    ok "wizard finished the pick-and-format run"
else
    bad "wizard exited $rc on the pick-and-format run"
    show
fi

if printf '%s' "$out" | grep -q 'sdy'; then
    ok "the spare disk sdy was offered"
else
    bad "sdy was not offered at all"
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

# ------------------------------------------- 2. a disk that was not offered
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

# ------------------------------------------------------------- 3. no pick
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

# ------------------------------------------------- 4. not a live Copper boot
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
