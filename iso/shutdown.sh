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

# ---- systemd image ---------------------------------------------------------
#
# On the systemd flavour power_links() points reboot/poweroff/halt here too, so
# this branch is what `sudo reboot` runs. It must NOT wait.
#
# A plain `systemctl reboot` waits for the shutdown transaction. The shell that
# ran it belongs to copper-console.service (or a getty), and the transaction
# stops that very unit -- so systemd SIGTERMs the waiting systemctl, which
# cancels its own job. What the user sees is the log stopping after
# "Stopped systemd-user-sessions.service", a returned shell prompt, and a
# half-stopped machine. The same applies to Ctrl-C: it kills the waiting client
# and takes the queued shutdown with it.
#
# --no-block hands the request to PID 1 and returns immediately. Nothing is
# waiting in a unit that the shutdown will stop, and an interrupt after that
# point has nothing to cancel: the job is already PID 1's.
#
# The init is read off /sbin/init, the same question build.sh's init_flavour()
# asks. It is a symlink on both flavours, so readlink (not -e) is the right
# test: -e would follow /lib/systemd/systemd on a build host that lacks it.
if [ "$(readlink /sbin/init 2>/dev/null)" = /lib/systemd/systemd ]; then
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
# If /sbin/init ever failed to read as systemd on a systemd machine, /sbin/$mode
# is this same wrapper (power_links made it so) and this exec would re-enter the
# script forever. The environment variable turns that into an error: the one
# legitimate path never sets it, because no flavour links an applet back here.
if [ "${COPPER_POWER_WRAPPER:-}" = 1 ]; then
    echo "shutdown: power wrapper re-entered; refusing to loop" >&2
    exit 1
fi
COPPER_POWER_WRAPPER=1
export COPPER_POWER_WRAPPER
exec "/sbin/$mode"
