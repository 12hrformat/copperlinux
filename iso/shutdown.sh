#!/bin/sh
# shutdown -- Copper Linux's `shutdown`.
# busybox ships halt, poweroff and reboot but no `shutdown` applet, so this maps
# the usual flags onto them; those applets signal PID 1, which does the orderly
# shutdown. Root only, since signalling PID 1 needs it.
#
#     shutdown                    power off now (the default)
#     shutdown now                power off now
#     shutdown -r now             reboot          (-R and --reboot the same)
#     shutdown -h now             power off       (-P and --poweroff the same)
#     shutdown -H now             halt            (--halt the same)
#     shutdown --help             print this usage and exit 0
#
# Also installed under the other power-command names: the name picks the default
# but flags still win. Everything else exits 1 -- a time other than "now", or a
# second conflicting mode, is refused rather than guessed (bugs 18 and 33).
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

# Invoked as reboot/poweroff/halt, the name picks the mode; without this, `sudo reboot` would power OFF.
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

# Sync before handing over, so a persisted overlay is on disk even if an applet later skips it.
sync

# ---- systemd or busybox? ----------------------------------------------------
# Both inits ship in one image and /sbin/init points at copper-init, so ask the
# running system: /proc/1/comm is the kernel's own name for PID 1 ("systemd" or
# "copper-init"), read with the shell's `read`. /run/systemd/system can be baked
# into the tree and readlink /sbin/init says nothing about what is running.
# Older tests stay as a fallback; COPPER_INIT lets the gate force either answer.
init_kind=${COPPER_INIT:-}
if [ -z "$init_kind" ] && [ -r /proc/1/comm ]; then
    initcomm=
    IFS= read -r initcomm < /proc/1/comm 2>/dev/null || initcomm=
    case "$initcomm" in
        systemd) init_kind=systemd ;;
        *)       init_kind=busybox ;;
    esac
fi
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
# The applets signal PID 1; copper-init's on_power_signal() does the orderly
# shutdown. If /sbin/$mode is this wrapper, exec busybox directly to avoid
# re-entry; COPPER_POWER_WRAPPER turns any other loop into an error.
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
