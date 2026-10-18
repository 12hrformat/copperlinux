#!/bin/sh
# shutdown -- Copper Linux's `shutdown`.
#
# busybox ships halt, poweroff and reboot but no `shutdown` applet, so
# `sudo shutdown now` was "shutdown: not found" and there was no clean way off
# the machine (BUGS.md #18). The three applets it does ship do not call
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
# Everything else exits 1 WITHOUT running an applet. That validation is the
# point: the flag loop used to ignore anything it did not recognise, so
# `shutdown +10` -- a real util-linux idiom -- powered the machine off
# immediately instead of in ten minutes, and `shutdown --bogus` powered it off
# too. There is no scheduler in this image, so a time other than "now" is
# refused rather than silently dropped, and a second, conflicting mode flag is
# refused rather than guessed at (last one used to win). On a live ISO,
# refusing loudly beats powering off someone's machine for a typo
# (BUGS.md #33).
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

mode=${mode:-poweroff}

# Sync here, before the applet runs, so the persisted overlay is on disk even
# if the applet is ever swapped for a `-n` (no-sync) path later.
sync
exec "/sbin/$mode"
