#!/bin/sh
# Prove startxfce does the right thing, and fails the right way.
#
# startxfce's whole value right now is that XFCE is NOT in the image. So the
# interesting cases are the failures, and a test that only checked the happy
# path would be checking the one case that cannot happen yet. Every missing
# piece therefore gets a case here, with the exact exit code asserted -- the
# codes are a contract, and a script branching on them is broken silently if
# one of them changes.
#
# The X server and the XFCE session are stubbed. That is not a shortcut: the
# real Xorg is a 13MB binary linked against 21 glibc libraries, and this image
# is static musl, so it cannot run here no matter what. What is under test is
# the launcher -- the ordering, the wait, the codes, and the hand-off of
# DISPLAY to the session.
#
# Run: sh tests/startxfce-gate.sh

set -u

# The stubs must not see this machine's desktop.
#
# WSLg runs a real X server on :0 and exports DISPLAY=:0 and
# WAYLAND_DISPLAY=wayland-0. A backgrounded stub that inherits those makes
# WSLg try to start a notification daemon, which is a popup on the desktop of
# whoever happens to be running the test. The stubs exist to be an X server for
# startxfce to find, and nothing else, so they get an environment with no
# desktop in it. This also keeps the test off the real /tmp/.X11-unix, which
# belongs to that server.
unset DISPLAY WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_SESSION_DESKTOP \
      XDG_CURRENT_DESKTOP XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS

REPO=$(cd "$(dirname "$0")/.." && pwd)
SUT="$REPO/iso/startxfce.sh"
LOCK=/tmp/startxfce-gate.lock
fails=0

# One run at a time, and a private directory per run.
#
# A fixed scratch directory is shared by every copy of this script, so two
# copies -- an interrupted one still alive, and the next one -- delete and
# recreate each other's sockets mid-case. Both were observed blocked for eight
# minutes with no children, which is what a command substitution does while
# something still holds the write end of its pipe. Which process held it was not
# established, so rather than guess at it: a unique directory removes the shared
# state entirely, and the lock stops a second copy racing in the first place.
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "another startxfce-gate.sh is running (lock: $LOCK)"
    echo "if that is wrong, remove it and re-run"
    exit 1
fi
# Anything that exits without reaching the end -- a Ctrl-C, a killed tool call,
# a failing assertion -- still takes the children and the directory with it.
# An earlier version had no trap at all, which is how an interrupted run left
# a live instance behind to collide with the next one.
TMP=$(mktemp -d /tmp/startxfce-gate.XXXXXX) || exit 1
cleanup() {
    pkill -P $$ 2>/dev/null
    rm -f "$TMP"/Xorg 2>/dev/null
    rm -rf "$TMP" "$LOCK" 2>/dev/null
}
trap cleanup EXIT INT TERM HUP

ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }

eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$2', got '$3'"; fi; }

has() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *)      bad "$1" "expected '$2' in the output; it said: $(printf '%s' "$3" | tr '\n' '|')" ;;
    esac
}

hasnt() {
    case "$3" in
        *"$2"*) bad "$1" "should not have mentioned '$2'; it said: $(printf '%s' "$3" | tr '\n' '|')" ;;
        *)      ok "$1" ;;
    esac
}

[ -f "$SUT" ] || { echo "  FAIL  $SUT does not exist"; exit 1; }

# --- isolation -------------------------------------------------------------
#
# Every case runs through run_sut, which forces a private socket directory and
# a probe that does not exist. Without that, this host's own /tmp/.X11-unix/X0
# is a live display, startxfce correctly decides a server is already running,
# and every case goes down the "reuse the existing server" path -- 13 checks
# failing against a launcher that was working. The socket directory has to be
# empty for cases 1, 2 and 7, where "is a server already there" must be false.
PROBE=$TMP/no-such-xdpyinfo

run_sut() {
    # The three settings are saved before the shift, because shift renumbers the
    # positional parameters and they are gone afterwards.
    #
    # shift comes first, on its own line. A trailing backslash on the line above
    # would join the assignments to shift instead, and what an assignment prefixes
    # is the command on the NEXT line -- so they would configure shift, and the
    # launcher would be invoked with none of them. Measured, not read:
    #
    #     with the assignments prefixing shift:       child sees MYVAR=[<unset>]
    #     with the assignments prefixing the command: child sees MYVAR=[what was set]
    #
    # With the environment silently absent the launcher used its defaults, and
    # its default XSOCKDIR is the real /tmp/.X11-unix. So the test drove the
    # machine's actual X display instead of its own, which is both why every case
    # failed and why running it started notification daemons on a desktop.
    xorg=$1
    session=$2
    tries=$3
    shift 3
    # The trailing "$@" carries options like --check through to the launcher.
    COPPER_XORG="$xorg" COPPER_STARTXFCE4="$session" COPPER_XLOG="$TMP/xorg.log" \
    COPPER_XPROBE="$PROBE" XSOCKDIR="$TMP/.X11-unix" WAIT_TRIES="$tries" \
    sh "$SUT" "$@" 2>&1
}

reset() { rm -rf "$TMP"; mkdir -p "$TMP/.X11-unix"; }

# A real listening unix socket, because startxfce tests for a socket with -S and
# a regular file would not do. python3 is used only to bind one; the launcher
# under test never talks to it.
#
# stdout and stderr are closed deliberately. Backgrounded, this process would
# otherwise inherit whatever the caller had open, and hold the write end of that
# pipe for as long as it sleeps -- long enough for a shell waiting on end-of-file
# to block indefinitely instead of returning the command substitution's result.
open_socket() {
    python3 - "$TMP/.X11-unix/X0" >/dev/null 2>&1 <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(1)
time.sleep(60)
PY
}

echo "=== it has to parse as POSIX sh, not just as bash ==="
# The live image's shell is busybox ash. A bashism here works on the build host
# and dies on the machine, so the parse check is against /bin/sh explicitly.
if sh -n "$SUT" 2>/tmp/sfg.err; then
    ok "parses under /bin/sh"
else
    bad "parses under /bin/sh" "$(cat /tmp/sfg.err)"
fi

echo
echo "=== case 1: nothing installed at all ==="
# The real state of the image today: both pieces absent.
reset
out=$(run_sut "$TMP/nope/Xorg" "$TMP/nope/startxfce4" 40); rc=$?
eq "  exit code is 20 (no X server)" 20 "$rc"
# The whole path, not a fragment of it. "no/Xorg" was here before and could never
# match: the path ends "nope/Xorg", and no is followed by pe rather than by the
# slash. The assertion was wrong, not the launcher -- it failed identically on CI
# and here while exit 20 and the rest of the message were correct.
has "  names the X server it looked for" "$TMP/nope/Xorg" "$out"
has "  says the X stack is not built yet" "not in this image yet" "$out"

echo
echo "=== case 2: Xorg present, XFCE absent ==="
# Someone installs the X stack first and tries. The error must be about XFCE
# and not about X, or the next hour of work is spent in the wrong place.
reset
printf '#!/bin/sh\necho "must not be reached"\n' > "$TMP/Xorg"; chmod +x "$TMP/Xorg"
out=$(run_sut "$TMP/Xorg" "$TMP/nope/startxfce4" 40); rc=$?
eq "  exit code is 21 (no XFCE)" 21 "$rc"
has "  blames the missing XFCE" "no XFCE session" "$out"
has "  says the X server alone is not a desktop" "not a desktop" "$out"
hasnt "  does not claim X is missing" "there is no X server" "$out"

echo
echo "=== case 3: Xorg dies while starting ==="
# The common real failure: the server rejects the card or finds no mode and
# exits. A launcher that only waits on the socket hangs the boot here.
reset
printf '#!/bin/sh\necho "(EE) fbdev: cannot open /dev/fb0"\nexit 1\n' > "$TMP/Xorg"
chmod +x "$TMP/Xorg"
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
out=$(run_sut "$TMP/Xorg" "$TMP/startxfce4" 40); rc=$?
eq "  exit code is 23 (X exited while starting)" 23 "$rc"
has "  shows the server's own log" "cannot open /dev/fb0" "$out"

echo
echo "=== case 4: Xorg stays up but never opens a display ==="
# Alive, and useless. Must time out and say so rather than hang or hand
# DISPLAY to a session with nothing to talk to.
reset
printf '#!/bin/sh\necho "(WW) running, but no screen"\nwhile : ; do sleep 1; done\n' > "$TMP/Xorg"
chmod +x "$TMP/Xorg"
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
out=$(run_sut "$TMP/Xorg" "$TMP/startxfce4" 3); rc=$?
pkill -f "$TMP/Xorg" 2>/dev/null
eq "  exit code is 22 (no display)" 22 "$rc"
has "  says it never opened the display" "never opened" "$out"

echo
echo "=== case 5: both present, the server opens the display ==="
# The happy path, with stubs for the pieces that cannot exist here. Proves the
# ordering and the hand-off: Xorg is started, waited for, DISPLAY is exported,
# and the session is exec'd so it inherits the environment rather than a guess.
reset
cat > "$TMP/Xorg" <<EOF
#!/bin/sh
sleep 1
python3 - <<'PY'
import socket, time
s = socket.socket(socket.AF_UNIX)
s.bind("$TMP/.X11-unix/X0")
s.listen(1)
time.sleep(60)
PY
EOF
chmod +x "$TMP/Xorg"
cat > "$TMP/startxfce4" <<EOF
#!/bin/sh
echo "DISPLAY=\$DISPLAY" > "$TMP/session.env"
exit 0
EOF
chmod +x "$TMP/startxfce4"
out=$(run_sut "$TMP/Xorg" "$TMP/startxfce4" 80); rc=$?
pkill -f "$TMP/Xorg" 2>/dev/null
eq "  exit code is 0" 0 "$rc"
has "  says it started the server" "starting" "$out"
has "  says it started XFCE" "starting XFCE" "$out"
eq "  the session was handed the display" ":0" \
   "$(sed -n 's/^DISPLAY=//p' "$TMP/session.env" 2>/dev/null)"
if [ -s "$TMP/session.env" ]; then
    ok "  the session actually ran"
else
    bad "  the session actually ran" "no session.env, so startxfce4 was never exec'd"
fi

echo
echo "=== case 6: a live X server on the display is reused, not replaced ==="
# Starting a second server on a live display is how a client ends up talking to
# whichever of the two won the race. A real listening socket is used, because
# the launcher checks for a socket and a plain file would not be one.
reset
open_socket &
spid=$!
sleep 1
printf '#!/bin/sh\necho "ERROR: this stub must not run"\nexit 99\n' > "$TMP/Xorg"
chmod +x "$TMP/Xorg"
printf '#!/bin/sh\necho "DISPLAY=$DISPLAY" > %s/session.env\n' "$TMP" > "$TMP/startxfce4"
chmod +x "$TMP/startxfce4"
out=$(run_sut "$TMP/Xorg" "$TMP/startxfce4" 5); rc=$?
kill "$spid" 2>/dev/null
eq "  exit code is 0" 0 "$rc"
has "  says it reused the running server" "already on" "$out"
hasnt "  did not start a second server" "starting $TMP/Xorg" "$out"
if [ -s "$TMP/session.env" ]; then
    ok "  the session still ran, on the existing server"
else
    bad "  the session still ran" "session.env missing"
fi

echo
echo "=== case 6b: a live server but no XFCE is still a clear failure ==="
# The installation check has to run before the "server already running" branch,
# not inside the branch that starts a server. Xorg up and XFCE absent gives
#
#     sh: /usr/bin/startxfce4: not found
#
# and exit 127, naming no missing piece. A running server is not a desktop.
reset
open_socket &
spid=$!
sleep 1
printf '#!/bin/sh\necho "must not be run"\nexit 99\n' > "$TMP/Xorg"
chmod +x "$TMP/Xorg"
out=$(run_sut "$TMP/Xorg" "$TMP/nope/startxfce4" 5); rc=$?
kill "$spid" 2>/dev/null
eq "  exit code is 21, not a raw 127" 21 "$rc"
has "  names the missing XFCE session" "no XFCE session" "$out"
has "  says a server is not a desktop" "not a desktop" "$out"
hasnt "  did not try to exec it anyway" "not found" "$out"

echo
echo "=== case 7: a stale socket is NOT treated as a live server ==="
# X does not remove its socket on exit, so a session that did not end cleanly
# leaves /tmp/.X11-unix/X0 behind. A startxfce that trusts the file alone starts
# XFCE against a server that is gone, and it hangs with nothing to show for it.
# With a probe present the socket is only believed if the display answers.
reset
# Bind, then close, in one process: the socket file survives and nothing is
# listening. Leaving the binder running instead holds the address, and the stub
# server below then dies with EADDRINUSE for a reason unrelated to this case.
python3 -c "import socket,sys
s = socket.socket(socket.AF_UNIX)
s.bind('$TMP/.X11-unix/X0')
s.close()"
if [ -S "$TMP/.X11-unix/X0" ]; then
    ok "  set up: a socket file exists with nothing listening on it"
else
    bad "  set up: a stale socket" "could not create one"
fi
cat > "$TMP/Xorg" <<EOF
#!/bin/sh
# Stands in for a healthy server. startxfce clears the stale socket before
# starting anything, so binding here must succeed -- and that is the point:
# if it does not, the handover is still broken on a dirty /tmp.
sleep 1
python3 -c "import socket,time
s = socket.socket(socket.AF_UNIX)
s.bind('$TMP/.X11-unix/X0')
s.listen(1)
time.sleep(60)"
EOF
chmod +x "$TMP/Xorg"
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
# A probe that always fails is not a stand-in for xdpyinfo. display_live() also
# runs the probe after starting a server, to decide the display came up, so a
# probe stuck at exit 1 reports a healthy display as dead and the wait loop can
# never succeed. Measured against a real listening socket:
#
#     state          exit 1     connects
#     live              1            0
#     stale file        1            1
#     no socket         1            1
#
# Connecting is what xdpyinfo does, and it is what distinguishes the two states a
# socket file cannot: a listener accepts, a leftover file refuses.
cat > "$TMP/probe" <<'PROBE_EOF'
#!/usr/bin/env python3
import os, socket, sys
num = os.environ.get("DISPLAY", ":0").lstrip(":") or "0"
path = os.path.join(os.environ.get("XSOCKDIR", "/tmp/.X11-unix"), "X" + num)
s = socket.socket(socket.AF_UNIX)
s.settimeout(2)
try:
    s.connect(path)
except OSError as e:
    print("cannot reach %s: %s" % (path, e), file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PROBE_EOF
chmod +x "$TMP/probe"
out=$(COPPER_XORG="$TMP/Xorg" COPPER_STARTXFCE4="$TMP/startxfce4" \
      COPPER_XLOG="$TMP/xorg.log" COPPER_XPROBE="$TMP/probe" \
      XSOCKDIR="$TMP/.X11-unix" WAIT_TRIES=80 sh "$SUT" 2>&1); rc=$?
pkill -f "$TMP/Xorg" 2>/dev/null
eq "  a dead display is not reused; a fresh server was started" 0 "$rc"
has "  it started its own server instead" "starting" "$out"

echo
echo "=== case 8: --check starts nothing ==="
# --check has to be safe at any time, including while a session is up.
reset
printf '#!/bin/sh\nexit 99\n' > "$TMP/Xorg"; chmod +x "$TMP/Xorg"
out=$(run_sut "$TMP/Xorg" "$TMP/nope" 5 --check); rc=$?
eq "  exit code is 0 even with pieces missing" 0 "$rc"
has "  reports the server it found" "found the X server" "$out"
has "  reports the XFCE it did not find" "NO XFCE" "$out"
hasnt "  claims to have started nothing" "starting" "$out"

echo
echo "=== case 9: usage ==="
out=$(sh "$SUT" --nonsense 2>&1); rc=$?
eq "  an unknown option exits 24" 24 "$rc"
out=$(sh "$SUT" --help 2>&1); rc=$?
eq "  --help exits 0" 0 "$rc"
has "  --help lists the exit codes" "22 X gave no display" "$out"

pkill -f "$TMP" 2>/dev/null
rm -rf "$TMP"
echo
if [ "$fails" -ne 0 ]; then
    echo "FAILED: $fails check(s)"
    exit 1
fi
echo "all startxfce checks passed"