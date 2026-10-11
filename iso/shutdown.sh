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
# Root only, because signalling PID 1 needs it. The usual incantations:
#     sudo shutdown now
#     sudo shutdown -r now
#
# POSIX sh: the image's /bin/sh is busybox ash.

mode=poweroff
for arg in "$@"; do
    case "$arg" in
        -r|-R|--reboot)   mode=reboot ;;
        -H|--halt)        mode=halt ;;
        -h|-P|--poweroff) mode=poweroff ;;
    esac
done

# Sync here, before the applet runs, so the persisted overlay is on disk even
# if the applet is ever swapped for a `-n` (no-sync) path later.
sync
exec "/sbin/$mode"
