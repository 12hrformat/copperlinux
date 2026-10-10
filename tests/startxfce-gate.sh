#!/bin/sh
# Prove startxfce does the right thing, and fails the right way.
#
# The desktop is in the image now, so the launcher's daily job is the component
# offer and the happy launch -- but the failure paths carried the exit-code
# contract, and a test that stopped checking them would let one drift silently.
# Every missing piece therefore gets a case here, with the exact exit code
# asserted -- the codes are a contract, and a script branching on them is broken
# silently if one of them changes.
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
    #
    # COPPER_SESSIONLOG and COPPER_XLOG are forced into TMP for the same reason
    # as the socket directory: their defaults (/tmp/session.log, /tmp/xorg.log)
    # are fixed names in the shared /tmp, and a file left there by an unrelated
    # or earlier run -- owned by another user -- makes the exec's redirection
    # fail with exit 2 and the case report a bug that is not there.
    xorg=$1
    session=$2
    tries=$3
    shift 3
    # The trailing "$@" carries options like --check through to the launcher.
    # COPPER_XFCE_APPS and COPPER_INGOT are driven by globals so the component
    # cases can point the launcher at a manifest and a stub installer; anything
    # else sees a manifest path that does not exist, which disables the offer.
    APPS_MANIFEST=${APPS_MANIFEST:-}
    INGOT_STUB=${INGOT_STUB:-}
    COPPER_XORG="$xorg" COPPER_STARTXFCE4="$session" COPPER_XLOG="$TMP/xorg.log" \
    COPPER_SESSIONLOG="$TMP/session.log" COPPER_XPROBE="$PROBE" \
    XSOCKDIR="$TMP/.X11-unix" WAIT_TRIES="$tries" \
    COPPER_XORGCONF="$TMP/xorg.conf" \
    COPPER_XFCE_APPS="${APPS_MANIFEST:-$TMP/no-apps}" \
    COPPER_INGOT="${INGOT_STUB:-ingot}" COPPER_SUDO="" \
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
# The error file lives in TMP, not /tmp: a fixed /tmp/sfg.err owned by another
# user turns a clean parse into "Permission denied" and a false FAIL.
if sh -n "$SUT" 2>"$TMP/sfg.err"; then
    ok "parses under /bin/sh"
else
    bad "parses under /bin/sh" "$(cat "$TMP/sfg.err" 2>/dev/null)"
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
# The input line and the config are contract: a machine whose devices match
# nothing ahead of the login still has to tell its user that, and the config
# file has to exist so the server is pinned away from udev even when empty.
has "  reports what it found (or found nothing)" "input devices:" "$out"
if [ -f "$TMP/xorg.conf" ]; then
    ok "  the input config was written"
else
    bad "  the input config was written" "no $TMP/xorg.conf"
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
      COPPER_XLOG="$TMP/xorg.log" COPPER_SESSIONLOG="$TMP/session.log" \
      COPPER_XPROBE="$TMP/probe" \
      COPPER_XORGCONF="$TMP/xorg.conf" \
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
has "  --help documents the component flags" "--yes" "$out"
has "  --help lists exit 25" "25 no way to ask" "$out"

echo
echo "=== case 10: the PS/2 mouse wins the pointer over a USB tablet ==="
# Measured on the machine (blocking dd): the emulated ImPS/2 mouse delivers
# events on VMware, the "Virtual USB Mouse" tablet delivers none (vmmouse is
# retired from Ubuntu). The matcher must prefer the PS/2 device even though
# it sorts before the tablet in sysfs.
reset
mkdir -p "$TMP/sys/class/input/event1/device" \
         "$TMP/sys/class/input/event2/device" \
         "$TMP/sys/class/input/event3/device"
printf 'AT Translated Set 2 keyboard\n'  > "$TMP/sys/class/input/event1/device/name"
printf 'ImPS/2 Generic Wheel Mouse\n'    > "$TMP/sys/class/input/event2/device/name"
printf 'VMware Virtual USB Mouse\n'      > "$TMP/sys/class/input/event3/device/name"
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
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
out=$(COPPER_XORG="$TMP/Xorg" COPPER_STARTXFCE4="$TMP/startxfce4" \
      COPPER_XLOG="$TMP/xorg.log" COPPER_SESSIONLOG="$TMP/session.log" \
      COPPER_XPROBE="$PROBE" \
      COPPER_XORGCONF="$TMP/xorg.conf" COPPER_SYSINPUT="$TMP/sys/class/input" \
      XSOCKDIR="$TMP/.X11-unix" WAIT_TRIES=80 sh "$SUT" 2>&1); rc=$?
pkill -f "$TMP/Xorg" 2>/dev/null
eq "  exit code is 0" 0 "$rc"
has "  names the PS/2 device as the pointer" "pointer=event2" "$out"
if grep -q '/dev/input/event2' "$TMP/xorg.conf" 2>/dev/null; then
    ok "  the config points the pointer at the PS/2 mouse"
else
    bad "  the config points the pointer at the PS/2 mouse" \
        "xorg.conf does not name /dev/input/event2: $(tr '\n' '|' < "$TMP/xorg.conf" 2>/dev/null)"
fi
if grep -q '/dev/input/event3' "$TMP/xorg.conf" 2>/dev/null; then
    bad "  the dead USB tablet was rejected" "xorg.conf names /dev/input/event3"
else
    ok "  the dead USB tablet was rejected"
fi

echo
echo "=== case 11: no PS/2 device, a plain USB mouse is still the pointer ==="
# The preference is a preference, not a requirement: a machine whose only
# mouse is generic still has to end up with a pointer.
reset
mkdir -p "$TMP/sys/class/input/event1/device" \
         "$TMP/sys/class/input/event3/device"
printf 'AT Translated Set 2 keyboard\n' > "$TMP/sys/class/input/event1/device/name"
printf 'Logitech USB Optical Mouse\n'   > "$TMP/sys/class/input/event3/device/name"
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
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
out=$(COPPER_XORG="$TMP/Xorg" COPPER_STARTXFCE4="$TMP/startxfce4" \
      COPPER_XLOG="$TMP/xorg.log" COPPER_SESSIONLOG="$TMP/session.log" \
      COPPER_XPROBE="$PROBE" \
      COPPER_XORGCONF="$TMP/xorg.conf" COPPER_SYSINPUT="$TMP/sys/class/input" \
      XSOCKDIR="$TMP/.X11-unix" WAIT_TRIES=80 sh "$SUT" 2>&1); rc=$?
pkill -f "$TMP/Xorg" 2>/dev/null
eq "  exit code is 0" 0 "$rc"
has "  the generic mouse won the pointer" "pointer=event3" "$out"

echo
echo "=== case 12: a component is missing, nothing to ask on, no --yes/--no ==="
# The manifest names an ingot component whose probe does not exist. The test
# has no terminal behind its command substitution, so the question cannot be
# answered: startxfce must stop with exit 25 instead of silently guessing.
reset
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
cat > "$TMP/apps" <<EOF
firefox $TMP/missing/firefox ingot
EOF
APPS_MANIFEST="$TMP/apps"
out=$(run_sut "$TMP/nope/Xorg" "$TMP/startxfce4" 5); rc=$?
APPS_MANIFEST=
eq "  exit code is 25 (cannot ask)" 25 "$rc"
has "  explains there is no terminal" "not a terminal" "$out"
has "  points at --yes" "--yes" "$out"

echo
echo "=== case 13: --no skips the install and the desktop starts anyway ==="
reset
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
cat > "$TMP/apps" <<EOF
firefox $TMP/missing/firefox ingot
EOF
APPS_MANIFEST="$TMP/apps"
out=$(run_sut "$TMP/nope/Xorg" "$TMP/startxfce4" 5 --no); rc=$?
APPS_MANIFEST=
# Past the component block (so no exit 25) to the missing-server check.
eq "  gets past the prompt to the X check" 20 "$rc"
has "  says it is not installing components" "not installing components" "$out"
hasnt "  never printed the question" "do you want to install" "$out"

echo
echo "=== case 14: --yes installs the missing components, then proceeds ==="
reset
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
cat > "$TMP/apps" <<EOF
firefox $TMP/missing/firefox ingot
EOF
cat > "$TMP/ingot" <<'EOF'
#!/bin/sh
echo "ingot-stub: $*" >&2
exit 0
EOF
chmod +x "$TMP/ingot"
APPS_MANIFEST="$TMP/apps"; INGOT_STUB="$TMP/ingot"
out=$(run_sut "$TMP/nope/Xorg" "$TMP/startxfce4" 5 --yes); rc=$?
APPS_MANIFEST=; INGOT_STUB=
eq "  installs first, then reaches the X check" 20 "$rc"
has "  the installer really was invoked" "ingot-stub: install firefox" "$out"
has "  says the components were installed" "components installed, running xfce now" "$out"

echo
echo "=== case 15: a present component is not offered at all ==="
reset
: > "$TMP/present-probe"
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
cat > "$TMP/apps" <<EOF
firefox $TMP/present-probe ingot
EOF
APPS_MANIFEST="$TMP/apps"
out=$(run_sut "$TMP/nope/Xorg" "$TMP/startxfce4" 5); rc=$?
APPS_MANIFEST=
eq "  no prompt, straight to the X check" 20 "$rc"
hasnt "  never asked about components" "do you want to install" "$out"

pkill -f "$TMP" 2>/dev/null
rm -rf "$TMP"
echo
if [ "$fails" -ne 0 ]; then
    echo "FAILED: $fails check(s)"
    exit 1
fi
echo "all startxfce checks passed"