#!/bin/sh
# shutdown -- Copper Linux's `shutdown`.
#
# busybox ships halt, poweroff and reboot but no `shutdown` applet, so
# `sudo shutdown now` was "shutdown: not found" and there was no clean way off
# the machine (bug 18). The three applets it does ship do not call
# reboot(2) themselves -- they signal PID 1 and let it do the orderly
# shutdown -- and copper-init now answers those signals (see
# on_power_signal() in copper-init.c). So this only maps the usual flags onto
# an applet.
#
# Root only, because signalling PID 1 needs it. The exact interface:
#
#     shutdown                    power off now (the default)
#     shutdown now                power off now
#     shutdown -r now             reboot          (-R and --reboot the same)
#     shutdown -h now             power off       (-P and --poweroff the same)
#     shutdown -H now             halt            (--halt the same)
#     shutdown --help             print this usage and exit 0
#
# It is also installed under the other power-command names (power_links links
# /sbin/reboot, /sbin/poweroff and /sbin/halt to this file), and then the name
# picks the default: `reboot` reboots, `poweroff` powers off, `halt` halts.
# Flags still win over the name, so `poweroff -r` reboots.
#
# Everything else exits 1 WITHOUT running an applet. That validation is the
# point: the flag loop used to ignore anything it did not recognise, so
# `shutdown +10` -- a real util-linux idiom -- powered the machine off
# immediately instead of in ten minutes, and `shutdown --bogus` powered it off
# too. There is no scheduler in this image, so a time other than "now" is
# refused rather than silently dropped, and a second, conflicting mode flag is
# refused rather than guessed at (last one used to win). On a live ISO,
# refusing loudly beats powering off someone's machine for a typo
# (bug 33).
#
# POSIX sh: the image's /bin/sh is busybox ash.

usage() {
    cat <<'EOF'
usage: shutdown [-r|-h|-H|-P] [now]
       shutdown --help
  -r, -R, --reboot     reboot
  -h, -P, --poweroff   power off (the default)
  -H, --halt           halt
only "now" is accepted as a time: this image has no scheduler.
EOF
}

die() {
    echo "shutdown: $1" >&2
    echo "Try 'shutdown --help' for the accepted arguments." >&2
    exit 1
}

mode=                           # the mode flag seen, empty until one is
time=                           # the time operand seen, empty until "now"

# Invoked through one of the power-command names (power_links makes /sbin/reboot
# and friends symlinks to this file), the name itself picks the mode. Without
# this, `sudo reboot` would run the wrapper and power the machine OFF.
case "${0##*/}" in
    reboot)   name_mode=reboot ;;
    halt)     name_mode=halt ;;
    *)        name_mode=poweroff ;;      # shutdown, poweroff, anything else
esac

for arg in "$@"; do
    case "$arg" in
        -r|-R|--reboot)   want=reboot ;;
        -H|--halt)        want=halt ;;
        -h|-P|--poweroff) want=poweroff ;;
        --help|-help)     usage; exit 0 ;;
        now)
            [ -z "$time" ] || die "time given twice"
            time=now; continue ;;
        -*)                die "unknown option: $arg" ;;
        *)
            [ -z "$time" ] || die "unexpected argument: $arg"
            die "unsupported time: $arg (only 'now' is supported)" ;;
    esac
    [ -z "$mode" ] || [ "$mode" = "$want" ] \
        || die "conflicting modes: $mode and $want"
    mode=$want
done

mode=${mode:-$name_mode}

# Sync here, before the request is handed over, so the persisted overlay is on
# disk even if the applet is ever swapped for a `-n` (no-sync) path later.
sync

# ---- systemd or busybox? ----------------------------------------------------
#
# One image can boot either init (the GRUB menu's "systemd init" entry, or the
# wizard's saved /etc/copper-init), so /sbin/init's target is NOT the question
# any more: on the unified image both inits are present and /sbin/init points at
# copper-init by default. Ask the running system instead.
#
# /run/systemd/system exists as soon as systemd is PID 1 and does not exist on a
# busybox boot -- copper-init mounts a fresh tmpfs over /run and never creates
# it. The readlink test stays as a fallback for a tree where systemd was the
# only init. COPPER_INIT lets the gate force either answer without rebooting
# (tests/shutdown-gate.sh sets it; nothing on a real boot does).
init_kind=${COPPER_INIT:-}
if [ -z "$init_kind" ]; then
    if [ -d /run/systemd/system ]; then
        init_kind=systemd
    elif [ "$(readlink /sbin/init 2>/dev/null)" = /lib/systemd/systemd ]; then
        init_kind=systemd
    else
        init_kind=busybox
    fi
fi

if [ "$init_kind" = systemd ]; then
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "shutdown: systemd image, but systemctl is not on PATH" >&2
        exit 1
    fi
    exec systemctl --no-block "$mode"
fi

# ---- busybox image ---------------------------------------------------------
#
# The applets do not call reboot(2) themselves; they signal PID 1, and
# copper-init's on_power_signal() does the orderly shutdown. Nothing here waits,
# so there is no transaction to cancel.
#
# If /sbin/$mode is this same wrapper (the unified image installs the wrapper
# under all four names), exec busybox directly: going back through /sbin/$mode
# would re-enter this script. If it is an applet link, hand over to it as
# before. The COPPER_POWER_WRAPPER guard still turns any other re-entry into an
# error rather than a loop.
if [ "${COPPER_POWER_WRAPPER:-}" = 1 ]; then
    echo "shutdown: power wrapper re-entered; refusing to loop" >&2
    exit 1
fi
COPPER_POWER_WRAPPER=1
export COPPER_POWER_WRAPPER
if [ "$(readlink "/sbin/$mode" 2>/dev/null)" = /sbin/shutdown ]; then
    exec /bin/busybox "$mode"
fi
exec "/sbin/$mode"
