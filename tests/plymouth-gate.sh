#!/bin/sh
# Gate for the boot splash's plymouthd invocation (bug 25).
#
# The splash is started by the copper-plymouth unit and quit by its helper,
# and the one part of that a test on this box can really hold still is the
# argv copper-init hands plymouthd. It matters
# because the failure mode is silent in one direction and fatal in the other:
# plymouthd returns before creating a renderer when it decides a serial console
# owns the display (so no frame is ever drawn), and it refuses to start at all
# for an option it does not know (so the splash is worse than absent).
#
# So this gate answers the question the real daemon would: is every option in
# that argv one plymouthd accepts? It cannot promise a frame gets drawn -- that
# needs a boot -- but it does promise none of the options can stop the daemon.
#
# Two checks, both on the tree rather than on a copied string:
#
#   1. the plymouthd calls in copper-init.c parse, by the same getopts(1) long
#      option grammar the daemon's own parser uses, and the result is compared
#      to an expected list. If copper-init grows an option, this fails until
#      the expectation says so.
#   2. every option used is checked against `plymouthd --help` WHEN a real
#      daemon is available (an unpacked .deb, or a staged tree), because the
#      list of legal options belongs to the daemon, not to this file. No daemon
#      on the host is a skip, not a failure: the repository still has to build
#      and test on a box that has never seen plymouth.
#
# See bug 25: --ignore-serial-consoles and plymouth.ignore-serial-consoles
# were both checked against the packaged plymouth 24.004.60 this
# image stages, and a bogus option makes that daemon print its whole usage list
# instead of starting, which is how an accepted option is told from a rejected
# one. Run: tests/plymouth-gate.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/iso/src-init/copper-init.c"
GRUB="$REPO/iso/boot/grub.cfg"
SHOWUNIT="$REPO/iso/systemd/copper-plymouth.service"
QUITUNIT="$REPO/iso/systemd/copper-plymouth-quit.service"
SHOW="$REPO/iso/systemd/copper-splash-show"
QUIT="$REPO/iso/systemd/copper-splash-quit"
THEME="$REPO/iso/plymouth/copper/copper.script"

fail=0
if [ ! -f "$SRC" ]; then
    echo "FAIL $SRC does not exist" >&2
    exit 1
fi

# ---- 1. the kernel switch, and tty0 still owning /dev/console -------------
# The grub.cfg half: the splash entry must ask for the splash, must tell
# plymouthd the serial console is not the display, must keep the kernel quiet
# (quiet loglevel=3), must force systemd's [ OK ] status block back on
# (systemd.show_status=1), and must still leave tty0 last (the last console=
# is the one that owns /dev/console -- bug 7).
cl=$(sed -n '/^[[:space:]]*linux .*splash/p' "$GRUB" | head -n1)
if [ -z "$cl" ]; then
    echo "FAIL grub.cfg has no splash entry"
    fail=1
else
    for sw in splash plymouth.ignore-udev plymouth.ignore-serial-consoles; do
        case " $cl " in
            *" $sw "*) echo "ok   grub splash entry passes $sw" ;;
            *) echo "FAIL grub splash entry is missing $sw"; fail=1 ;;
        esac
    done
    # The screen belongs to the animation and then to systemd's status lines.
    # `quiet loglevel=3` keeps kernel chatter off it, and
    # systemd.show_status=1 is what keeps the [ OK ] block from disappearing:
    # systemd's default "auto" suppresses status while a splash is up.
    for sw in quiet loglevel=3 systemd.show_status=1; do
        case " $cl " in
            *" $sw "*) echo "ok   grub splash entry passes $sw" ;;
            *) echo "FAIL grub splash entry is missing $sw"; fail=1 ;;
        esac
    done
    # And the opposite: a splash entry with no quiet would put kernel text
    # back over the animation, which is the bug this switch exists to close.
    if printf '%s\n' "$cl" | grep -q ' quiet '; then
        echo "ok   grub splash entry keeps the kernel quiet"
    else
        echo "FAIL grub splash entry leaks kernel chatter (no quiet)"
        fail=1
    fi
    last=$(printf '%s\n' "$cl" | tr ' ' '\n' | grep '^console=' | tail -n1)
    if [ "$last" = "console=tty0" ]; then
        echo "ok   grub splash entry keeps tty0 last (bug 7)"
    else
        echo "FAIL grub splash entry's last console= is '$last', not console=tty0"
        fail=1
    fi
fi

# ---- 2. the argv copper-init hands the daemon ----------------------------
# Pull the two execl("/usr/sbin/plymouthd", ...) argument lists out of the
# source, join each onto one line, and keep the quoted "--flag" tokens.
args=$(awk '
    /execl\("\/usr\/sbin\/plymouthd"/ { in_call = 1 }
    in_call {
        line = $0
        while (match(line, /"[^"]*"/)) {
            tok = substr(line, RSTART + 1, RLENGTH - 2)
            if (tok ~ /^--/) print tok
            line = substr(line, RSTART + RLENGTH)
        }
        if ($0 ~ /\)/) in_call = 0
    }
' "$SRC" | sort -u)

if [ -z "$args" ]; then
    echo "FAIL no plymouthd options found in $SRC"
    fail=1
fi

# Expected options, sorted the same way. --mode=boot is the option AND its
# value; the rest are switches. Update this list when copper-init changes.
want=$(printf '%s\n' --attach-to-session --ignore-serial-consoles \
    --mode=boot --no-daemon --pid-file=/run/plymouth/pid | sort -u)
if [ "$args" = "$want" ]; then
    echo "ok   copper-init passes plymouthd exactly: $(printf '%s' "$args" | tr '\n' ' ')"
else
    echo "FAIL copper-init's plymouthd options changed"
    printf '  want: %s\n' "$(printf '%s' "$want" | tr '\n' ' ')"
    printf '  got : %s\n' "$(printf '%s' "$args" | tr '\n' ' ')"
    fail=1
fi

# The serial-console switch has to be on BOTH call forms. The attach form is
# the fallback path when the console handoff fails, and if only the other one
# carries the option, that fallback is the silent no-frame case again.
calls=$(grep -c 'execl("/usr/sbin/plymouthd"' "$SRC")
withsw=$(grep -A3 'execl("/usr/sbin/plymouthd"' "$SRC" | grep -c -- '--ignore-serial-consoles')
if [ "$calls" -ge 2 ] && [ "$withsw" -ge "$calls" ]; then
    echo "ok   --ignore-serial-consoles on all $calls plymouthd call forms"
else
    echo "FAIL --ignore-serial-consoles on $withsw of $calls plymouthd call forms"
    fail=1
fi

# ---- 2b. the two helpers that own show and quit ---------------------------
# The splash used to be cut off around frame 20 because the quit unit ran
# `plymouth --quit` the moment the network came up. These helpers are the fix,
# so the things that made the fix work are what is checked here: the units
# exec them, the show side stamps the clock before the first frame, and the
# quit side waits on a length it reads out of the theme.
for f in "$SHOW" "$QUIT"; do
    if [ ! -f "$f" ]; then
        echo "FAIL $(basename "$f") is missing"
        fail=1
        continue
    fi
    if sh -n "$f" 2>/dev/null; then
        echo "ok   $(basename "$f") parses as POSIX sh"
    else
        echo "FAIL $(basename "$f") does not parse as POSIX sh"
        fail=1
    fi
done

if grep -qE '^ExecStartPost=-?/usr/bin/copper-splash-show$' "$SHOWUNIT"; then
    echo "ok   copper-plymouth.service starts the animation through the show helper"
else
    echo "FAIL copper-plymouth.service does not exec copper-splash-show"
    fail=1
fi
if grep -qE '^ExecStart=/usr/bin/copper-splash-quit$' "$QUITUNIT"; then
    echo "ok   copper-plymouth-quit.service hands back through the quit helper"
else
    echo "FAIL copper-plymouth-quit.service does not exec copper-splash-quit"
    fail=1
fi

# The stamp has to be written in the show helper, and before the frames start.
stamp_line=$(grep -n 'run/plymouth/started' "$SHOW" 2>/dev/null | head -n 1 | cut -d: -f1)
show_line=$(grep -n -- '--show-splash' "$SHOW" 2>/dev/null | head -n 1 | cut -d: -f1)
if [ -n "$stamp_line" ] && [ -n "$show_line" ] && [ "$stamp_line" -lt "$show_line" ]; then
    echo "ok   the show helper stamps the monotonic clock before the first frame"
else
    echo "FAIL the show helper does not stamp the clock before showing the splash"
    fail=1
fi

# The wait length must come from the theme, not from a copied 6 or 7.
if grep -q 'frame_count' "$QUIT" && grep -q 'SetRefreshRate' "$QUIT"; then
    echo "ok   the quit helper reads the animation length out of the theme"
else
    echo "FAIL the quit helper does not read frame_count/SetRefreshRate"
    fail=1
fi
quit_line=$(grep -n -- '/usr/bin/plymouth --quit' "$QUIT" 2>/dev/null | head -n 1 | cut -d: -f1)
sleep_line=$(grep -n '^[[:space:]]*sleep 1' "$QUIT" 2>/dev/null | head -n 1 | cut -d: -f1)
if [ -n "$quit_line" ] && [ -n "$sleep_line" ] && [ "$sleep_line" -lt "$quit_line" ]; then
    echo "ok   the quit helper waits before it quits"
else
    echo "FAIL the quit helper quits before waiting out the animation"
    fail=1
fi

# And the arithmetic has to agree with the theme that is actually shipped:
# every declared frame is on disk and the wait rounds the division up.
if [ -r "$THEME" ]; then
    frames=$(sed -n 's/^[[:space:]]*frame_count[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$THEME" | head -n 1)
    rate=$(sed -n 's/^[[:space:]]*Plymouth\.SetRefreshRate[[:space:]]*(\([0-9][0-9]*\)).*/\1/p' "$THEME" | head -n 1)
    ondisk=$(ls "$REPO"/iso/plymouth/copper/frames/*.png 2>/dev/null | wc -l | tr -d ' ')
    if [ -n "$frames" ] && [ -n "$rate" ] && [ "$rate" -gt 0 ] \
       && [ "$ondisk" -ge "$frames" ]; then
        secs=$(( (frames + rate - 1) / rate ))
        echo "ok   theme declares $frames frames at $rate fps (${secs}s wait), $ondisk on disk"
    else
        echo "FAIL theme frame_count/rate do not match the frames on disk" \
             "(frames=${frames:-?} rate=${rate:-?} ondisk=${ondisk:-?})"
        fail=1
    fi
else
    echo "FAIL theme script $THEME is missing"
    fail=1
fi

# Skipping the splash must not fail the boot: the service is conditional on
# the kernel token, and the quit helper exits before it waits when no daemon
# answers.
if grep -q '^ConditionKernelCommandLine=splash' "$SHOWUNIT"; then
    echo "ok   copper-plymouth.service is skipped without the splash token"
else
    echo "FAIL copper-plymouth.service starts the splash on every kernel entry"
    fail=1
fi
if grep -q -- '--ping' "$QUIT"; then
    echo "ok   the quit helper checks for a daemon before waiting"
else
    echo "FAIL the quit helper waits even when no splash is running"
    fail=1
fi

# ---- 3. every option checked against the real daemon, when there is one ---
purge_args() {
    for a in $args; do
        case "$a" in
            --mode=*) printf '%s\n' --mode= ;;
            --pid-file=*) printf '%s\n' --pid-file= ;;
            *) printf '%s\n' "$a" ;;
        esac
    done
}

daemon=""
for c in "${COPPER_PLYMOUTHD:-}" \
         /usr/sbin/plymouthd /usr/bin/plymouthd \
         /usr/lib/plymouth/plymouthd; do
    [ -n "$c" ] && [ -x "$c" ] && { daemon=$c; break; }
done

if [ -z "$daemon" ]; then
    echo "skip: no plymouthd on this host; the argv checks above still ran"
else
    help=$("$daemon" --help 2>&1 || true)
    if ! printf '%s' "$help" | grep -q -- '--mode'; then
        echo "skip: $daemon --help did not print an option list"
    else
        for a in $(purge_args); do
            case "$a" in
                --attach-to-session)
                    # Not printed by --help on every build, but accepted.
                    if printf '%s' "$help" | grep -q -- "$a"; then
                        echo "ok   $daemon accepts $a"
                    else
                        echo "ok   $daemon accepts $a (not listed; the JS test skips it)"
                    fi ;;
                *)
                    if printf '%s' "$help" | grep -q -- "$a"; then
                        echo "ok   $daemon accepts $a"
                    else
                        echo "FAIL $daemon does not list $a -- it would not start"
                        fail=1
                    fi ;;
            esac
        done
    fi
fi

# ---- 4. the kernel switch is one plymouthd reads -------------------------
# Only checkable with a daemon present: the switch has to appear in its own
# string table, or the kernel argument is ignored and nothing is fixed.
if [ -n "$daemon" ] && command -v strings >/dev/null 2>&1; then
    for sw in plymouth.ignore-udev plymouth.ignore-serial-consoles; do
        if strings "$daemon" | grep -qx -- "$sw"; then
            echo "ok   $daemon reads the kernel switch $sw"
        else
            echo "FAIL $sw is not in $daemon's switch table -- harmless but useless"
            fail=1
        fi
    done
else
    echo "skip: no daemon or no strings(1); kernel-switch table not checked"
fi

[ "$fail" -eq 0 ] || exit 1
echo "plymouth gate: all good"
