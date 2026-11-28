#!/bin/sh
# hardening-gate.sh -- the live-image findings that are build/shape promises.
# Rootless and buildless: it reads the shipped scripts and runs the ones with a
# stable host-side contract. Behavioural gates (validators, identity, launchers)
# live in their own files; this one keeps the small fixes from rotting.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
fail=0

ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

has() { # has <file> <literal> <description>
    if grep -qF -- "$2" "$REPO/$1" 2>/dev/null; then ok "$3"; else bad "$3"; fi
}

hasnt() { # hasnt <file> <literal> <description>
    if grep -qF -- "$2" "$REPO/$1" 2>/dev/null; then bad "$3"; else ok "$3"; fi
}

hasnt_any() { # hasnt_any <literal> <description> <file>...
    literal=$1; desc=$2; shift 2
    for f in "$@"; do
        if grep -qF -- "$literal" "$REPO/$f" 2>/dev/null; then
            bad "$desc (still in $f)"
            return
        fi
    done
    ok "$desc"
}

# Finding 1: cached-tree ownership must be pinned and then asserted, both at
# the top level and across every system directory.
has iso/build.sh 'find "$TGT" \( ! -uid 0 -o ! -gid 0 \) -exec chown -h 0:0 {} +' \
    "the cached tree is chowned before the ISO is stamped"
has iso/build.sh '-type d -exec chmod go-w {} +' \
    "group/other write is removed from every system directory"
has iso/build.sh '-type d \( ! -uid 0 -o -perm /022 \)' \
    "every system directory is checked for non-root ownership and group/other write"
has iso/build.sh '$TGT/usr/local/bin' \
    "the PATH directory /usr/local/bin is created"
has iso/build.sh '$TGT/usr/local/sbin' \
    "the PATH directory /usr/local/sbin is created"

# Finding 2: /tmp is noexec,nosuid,nodev at boot, and no launcher uses a fixed
# name that another local user could plant as a symlink.
has iso/rootfs-overlay/etc/fstab 'nosuid,nodev,noexec,size=50%' \
    "fstab states the hardened /tmp mount"
hasnt iso/rootfs-overlay/etc/fstab 'defaults,size=50%' \
    "fstab no longer uses permissive defaults"
has iso/live/init 'mount -t tmpfs -o nosuid,nodev,noexec,size=50% tmpfs /mnt/merged/tmp' \
    "live/init mounts /tmp with the hardened flags before PID 1"
has iso/startniri.sh 'mktemp "${TMPDIR:-/tmp}/copper-niri-log.XXXXXX"' \
    "niri's log is a private mktemp file"
has iso/starthyprland.sh 'mktemp "${TMPDIR:-/tmp}/copper-hyprland-log.XXXXXX"' \
    "hyprland's log is a private mktemp file"
has iso/startxfce.sh 'mktemp "${TMPDIR:-/tmp}/copper-xorg-log.XXXXXX"' \
    "Xorg's log is a private mktemp file"
has iso/startxfce.sh 'mktemp "${TMPDIR:-/tmp}/copper-session-log.XXXXXX"' \
    "XFCE's output is a private mktemp file"
has iso/startxfce.sh 'mktemp "${TMPDIR:-/tmp}/copper-xorg-conf.XXXXXX"' \
    "the fallback xorg.conf is a private mktemp file"
has iso/startniri.sh 'mktemp -d "${TMPDIR:-/tmp}/startniri-seed.XXXXXX"' \
    "niri's seed list lives in a private directory"
has iso/starthyprland.sh 'mktemp -d "${TMPDIR:-/tmp}/starthyprland-seed.XXXXXX"' \
    "hyprland's seed list lives in a private directory"
hasnt_any 'SESSIONLOG=${COPPER_SESSIONLOG:-/tmp/' \
    "no launcher has a fixed default session log" \
    iso/startniri.sh iso/starthyprland.sh iso/startxfce.sh
hasnt iso/startxfce.sh 'xorgconf2=${COPPER_XORGCONF_FALLBACK:-/tmp/xorg.conf}' \
    "no fixed fallback xorg.conf path"

# Finding 2 (the eval smell) and finding 7's remaining small items.
hasnt_any 'dbus-launch --sh-syntax' \
    "no launcher evals dbus-launch output" \
    iso/startniri.sh iso/starthyprland.sh iso/startxfce.sh
hasnt_any 'eval "$bus"' \
    "no launcher executes a generated shell string" \
    iso/startniri.sh iso/starthyprland.sh iso/startxfce.sh
has iso/startniri.sh 'dbus-launch --print-address=1' \
    "niri takes the bus address as data"
has iso/starthyprland.sh 'dbus-launch --print-address=1' \
    "hyprland takes the bus address as data"
has iso/rootfs-overlay/etc/group 'shadow:x:42:' \
    "the shadow group exists for gshadow"
has iso/build.sh 'chmod 0640 "$TGT/etc/gshadow"' \
    "gshadow is pinned to 0640 root:shadow"
has iso/copper.sh 'cmd_help; exit 1' \
    "bare 'copper' reports usage with a failure status"
has iso/systemd/copper-zram 'if [ "$(id -u)" = 0 ]; then' \
    "zram tuning is attempted only by root"
has iso/systemd/copper-zram 'if [ "$swapped_on" = 1 ]; then' \
    "zram's success line needs a swapon by this run"
hasnt iso/systemd/copper-zram 'echo 100 > /proc/sys/vm/swappiness 2>/dev/null || true' \
    "the old unconditional tuning write is gone"

# Finding 4/5: stale identity lines are generated, never hand-copied.
for f in lsb-release issue issue.net; do
    if [ -e "$REPO/iso/rootfs-overlay/etc/$f" ]; then
        bad "etc/$f is generated, not hand-copied in the overlay"
    else
        ok "etc/$f is generated, not hand-copied in the overlay"
    fi
done
has iso/build.sh 'bash "$ROOT/identity.sh"' \
    "the build generates every identity file from os-release"
has iso/build.sh '$ROOT/identity.sh"; tree_hash "$TGT"' \
    "identity.sh is part of the ISO stamp"

# Finding 7: home should not be setgid, on either account path.
has iso/firstboot/copper-firstboot.c 'if (*h == '\''-'\'') return 0;' \
    "the wizard rejects a leading-dash hostname"
has iso/firstboot/copper-firstboot.c 'if (*z == '\''-'\'') return 0;' \
    "the wizard rejects a leading-dash timezone"
has iso/firstboot/copper-firstboot.c 'chmod(home, 0755);' \
    "the direct account path clears home's setgid bit"
has iso/firstboot/copper-firstboot.c '/bin/busybox chmod 0755 /home/%s' \
    "the adduser path clears home's setgid bit"

# Run the one launcher with a host-stable contract, not just grep its source.
out=$(sh "$REPO/iso/copper.sh" 2>&1)
rc=$?
if [ "$rc" -eq 1 ]; then
    ok "'copper' with no arguments exits 1"
else
    bad "'copper' with no arguments exits 1 (got $rc)"
fi

exit "$fail"
