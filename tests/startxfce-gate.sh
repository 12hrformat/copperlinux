#!/bin/sh
# Prove iso/startxfce.sh's ordering, waits, exit codes and DISPLAY hand-off; Xorg/XFCE are stubbed because the real X stack is glibc and cannot run here.
# Every missing piece gets a case with its exact exit code: the codes are a contract and a drift would break callers silently.
# Run: sh tests/startxfce-gate.sh

set -u

# Unset this host's WSLg desktop: stubs inheriting DISPLAY/WAYLAND make it start notification daemons on a real desktop.
# Also keeps the test off the real /tmp/.X11-unix, which belongs to that server.
# The stubs exist only to be an X server for startxfce to find, nothing else.
unset DISPLAY WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_SESSION_DESKTOP \
      XDG_CURRENT_DESKTOP XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS

REPO=$(cd "$(dirname "$0")/.." && pwd)
SUT="$REPO/iso/startxfce.sh"
LOCK=/tmp/startxfce-gate.lock
fails=0

# Private scratch dir plus lock: a shared dir let interrupted runs delete each other's sockets and block for minutes.
# Both copies were observed blocked for eight minutes with no children: a command substitution waiting on a pipe.
# A private dir removes the shared state; the lock stops a second copy racing in.
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "another startxfce-gate.sh is running (lock: $LOCK)"
    echo "if that is wrong, remove it and re-run"
    exit 1
fi
# Trap cleans children and both dirs on early exit; an earlier run left a live instance behind.
# A Ctrl-C, a killed tool call or a failing assertion must still take the children with it.
# An earlier version had no trap and left a live instance to collide with the next run.
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

# run_sut forces an empty private socket dir: a live /tmp/.X11-unix/X0 sends every case down the reuse path.
# Without it this host's live /tmp/.X11-unix/X0 makes startxfce decide a server is already running.
# Thirteen checks then fail against a launcher that was working.
PROBE=$TMP/no-such-xdpyinfo

# Probe cases get their own socket dir: an unlinked socket can stay in /proc/net/unix and read as live.
# See case 16 for the python child that keeps an unlinked socket's path listed.
PSOCK="$TMP/probe-cases/.X11-unix"

run_sut() {
# Save the settings before `shift 3` and keep shift on its own line: a trailing backslash makes the assignments prefix shift, so the launcher sees none of them and falls back to the real /tmp/.X11-unix.
# Logs go to TMP too: fixed /tmp/session.log or /tmp/xorg.log owned by another user makes exec fail with exit 2.
# Measured: with assignments prefixing shift the child saw MYVAR unset; on the command it saw the value.
    xorg=$1
    session=$2
    tries=$3
    shift 3
# "$@" forwards --check/--yes; manifest and ingot globals let component cases point at stubs.
# COPPER_XFCE_APPS and COPPER_INGOT are globals so component cases can point at a manifest and stub installer.
# Anything else sees a missing manifest, which disables the offer.
    APPS_MANIFEST=${APPS_MANIFEST:-}
    INGOT_STUB=${INGOT_STUB:-}
    COPPER_XORG="$xorg" COPPER_STARTXFCE4="$session" COPPER_XLOG="$TMP/xorg.log" \
    COPPER_SESSIONLOG="$TMP/session.log" COPPER_XPROBE="$PROBE" \
    XSOCKDIR="$TMP/.X11-unix" WAIT_TRIES="$tries" \
    COPPER_XORGCONF="$TMP/xorg.conf" \
    COPPER_XFCE_APPS="${APPS_MANIFEST:-$TMP/no-apps}" \
    COPPER_INGOT="${INGOT_STUB:-ingot}" COPPER_SUDO="" \
    COPPER_AUDIO=0 \
    sh "$SUT" "$@" 2>&1
}

reset() { rm -rf "$TMP"; mkdir -p "$TMP/.X11-unix"; }

# A real listening socket is needed (-S); close stdout/stderr so the sleeping child cannot hold a pipe and hang command substitution.
# python3 is used only to bind it; the launcher under test never talks to it.
# Inheriting the caller's open pipe would block a shell waiting for end-of-file.
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
# Parse under /bin/sh: busybox ash dies on bashisms that work here. Error file in TMP avoids a foreign /tmp/sfg.err faking a FAIL.
# A bashism works on the build host and dies on the machine.
# The error file is in TMP because a fixed /tmp/sfg.err owned by another user turns a clean parse into FAIL.
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
# Assert the full path: "no/Xorg" could never match "nope/Xorg" -- the assertion was wrong, not the launcher.
# The path ends 'nope/Xorg', and no is followed by pe rather than a slash.
# The assertion failed identically on CI and here while exit 20 and the rest were correct.
has "  names the X server it looked for" "$TMP/nope/Xorg" "$out"
has "  says the X stack is not built yet" "not in this image yet" "$out"

echo
echo "=== case 2: Xorg present, XFCE absent ==="
# Blame XFCE, not X, or the next hour goes to the wrong component.
# The error must name the missing piece or the next hour is spent in the wrong place.
reset
printf '#!/bin/sh\necho "must not be reached"\n' > "$TMP/Xorg"; chmod +x "$TMP/Xorg"
out=$(run_sut "$TMP/Xorg" "$TMP/nope/startxfce4" 40); rc=$?
eq "  exit code is 21 (no XFCE)" 21 "$rc"
has "  blames the missing XFCE" "no XFCE session" "$out"
has "  says the X server alone is not a desktop" "not a desktop" "$out"
hasnt "  does not claim X is missing" "there is no X server" "$out"

echo
echo "=== case 3: Xorg dies while starting ==="
# A server that exits on a bad card must be caught, not waited on forever.
# A launcher that only waits on the socket hangs the boot here.
reset
printf '#!/bin/sh\necho "(EE) fbdev: cannot open /dev/fb0"\nexit 1\n' > "$TMP/Xorg"
chmod +x "$TMP/Xorg"
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
out=$(run_sut "$TMP/Xorg" "$TMP/startxfce4" 40); rc=$?
eq "  exit code is 23 (X exited while starting)" 23 "$rc"
has "  shows the server's own log" "cannot open /dev/fb0" "$out"

echo
echo "=== case 4: Xorg stays up but never opens a display ==="
# Alive but no display: bound timeout, not a hang or a bogus DISPLAY hand-off.
# It must time out and say so rather than hand DISPLAY to a session with nothing to talk to.
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
# Happy path: assert ordering, the DISPLAY hand-off and the session exec.
# The real Xorg is 13MB linked against 21 glibc libraries and this image is static musl.
# What is under test is the launcher: ordering, wait, codes and the DISPLAY hand-off.
reset
cat > "$TMP/Xorg" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$TMP/xorg.args"
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
# Input line and config are contract: even with no matching device the user is told, and xorg.conf pins the server away from udev.
# A machine whose devices match nothing ahead of the login still has to tell its user.
# The config has to exist so the server is pinned away from udev even when empty.
has "  reports what it found (or found nothing)" "input devices:" "$out"
if [ -f "$TMP/xorg.conf" ]; then
    ok "  the input config was written"
else
    bad "  the input config was written" "no $TMP/xorg.conf"
fi
# Root must not pass the non-root VT flags: the image has booted for months on this invocation.
# The image booted for months on this exact root invocation; the fix must not quietly change it.
if [ -f "$TMP/xorg.args" ] && grep -q -- '-keeptty' "$TMP/xorg.args"; then
    bad "  root does not pass the non-root VT flags" \
        "-keeptty was passed while running as root: $(cat "$TMP/xorg.args")"
else
    ok "  root does not pass the non-root VT flags"
fi

echo
echo "=== case 5b: a non-root session keeps the console VT ==="
# Non-root Xorg needs -sharevts to skip the VT grab (xf86OpenConsole guards VT_ACTIVATE on ShareVTs); -novtswitch alone is not enough.
# It also needs -keeptty and no VT switching; id is stubbed to exercise that branch while the test runs as root.
# A real boot died on 'xf86OpenConsole: Switching VT failed' with -novtswitch alone.
reset
mkdir -p "$TMP/bin"
cat > "$TMP/bin/id" <<EOF
#!/bin/sh
# Only the launcher's uid check is being answered; anything else is real.
if [ "\$1" = "-u" ]; then echo 1000; exit 0; fi
exec /usr/bin/id "\$@"
EOF
chmod +x "$TMP/bin/id"
cat > "$TMP/Xorg" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$TMP/xorg.args"
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
out=$(PATH="$TMP/bin:$PATH"; export PATH; run_sut "$TMP/Xorg" "$TMP/startxfce4" 80); rc=$?
pkill -f "$TMP/Xorg" 2>/dev/null
eq "  exit code is 0" 0 "$rc"
args=$(cat "$TMP/xorg.args" 2>/dev/null)
has "  the non-root server is told to keep the tty" "-keeptty" "$args"
has "  the non-root server is told to share the VT (skips the VT grab)" "-sharevts" "$args"
has "  the non-root server is told not to switch VT" "-novtswitch" "$args"
has "  the server still gets the display" ":0" "$args"

echo
echo "=== case 5c: an unwritable input-config path does not kill the launcher ==="
# Bug 44: a failed `: > file` redirection exits POSIX shells, so an unwritable first xorg.conf candidate killed the launcher before its /tmp fallback.
# Use a directory here and keep the fallback out of shared /tmp.
# COPPER_XORGCONF_FALLBACK keeps the fallback out of the shared /tmp.
reset
mkdir -p "$TMP/adir"
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
      COPPER_XORGCONF="$TMP/adir" COPPER_XORGCONF_FALLBACK="$TMP/xorg.conf" \
      XSOCKDIR="$TMP/.X11-unix" WAIT_TRIES=80 sh "$SUT" 2>&1); rc=$?
pkill -f "$TMP/Xorg" 2>/dev/null
# Assert both exit 0 and the carried-on input step: surviving with no config is still broken.
# The abort was exit 1 with the input step never reached.
# A launcher that survived but wrote nothing would still be broken.
eq "  exit code is 0, not the shell's" 0 "$rc"
hasnt "  the failed candidate did not print a shell error" "can't create" "$out"
has "  it fell back to the second path" "input config written: $TMP/xorg.conf" "$out"
has "  it carried on past the write" "input devices:" "$out"
if [ -s "$TMP/xorg.conf" ]; then
    ok "  the fallback config was actually written"
else
    bad "  the fallback config was actually written" "no $TMP/xorg.conf"
fi

echo
echo "=== case 6: a live X server on the display is reused, not replaced ==="
# A second server on a live display races clients; a real socket is needed because -S is the check.
# Starting a second server on a live display is how a client ends up talking to whichever won the race.
# The launcher checks -S, so a regular file would not do.
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
# The install check must precede the reuse branch, or Xorg up/XFCE absent gives a raw 127 naming nothing.
# The check has to run before the reuse branch, not inside the branch that starts a server.
# Otherwise Xorg up and XFCE absent gives raw exit 127 naming no missing piece.
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
# X leaves stale sockets; with a probe the file is believed only if the display answers.
# X does not remove its socket on exit, so an unclean session leaves X0 behind.
# A startxfce that trusts the file alone starts XFCE against a server that is gone.
reset
# Bind then close so the path survives with no listener; a live binder would give the new stub EADDRINUSE.
# Leaving the binder running holds the address, so the stub below dies with EADDRINUSE.
# That failure would be unrelated to the case.
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
# A probe stuck at exit 1 makes a healthy display look dead: it is also used after start, so the wait can never succeed.
# Connecting is what distinguishes a listener from a leftover file; measured states 1/0 vs 1/1.
# Measured states: live 1/connects, stale file 1/refuses, no socket 1/refuses.
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
# Measured: the PS/2 mouse delivers events on VMware, the USB tablet does not; prefer PS/2 though sysfs sorts it first.
# The emulated ImPS/2 mouse delivers events on VMware; the Virtual USB Mouse tablet delivers none.
# vmmouse is retired from the archive, so the matcher must prefer PS/2 though it sorts first.
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
# Preference, not requirement: a generic USB mouse must still become the pointer.
# A machine whose only mouse is generic still has to end up with a pointer.
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
# No TTY behind command substitution: exit 25 instead of silently guessing.
# The manifest names an ingot component whose probe does not exist.
# The command substitution has no terminal, so the question cannot be answered.
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

echo
echo "=== case 16: a stale socket with NO probe is still not trusted (socket table) ==="
# With no probe (older image or failed staging) ask /proc/net/unix instead; a missing probe must not make a stale socket live.
# Probe cases use their own socket dir: an unlinked-but-open socket keeps its path in the table and would make another case's socket read live.
# COPPER_XPROBE points at a nonexistent binary so the fallback is exercised.
reset
mkdir -p "$PSOCK"
python3 -c "import socket,sys
s = socket.socket(socket.AF_UNIX)
s.bind('$PSOCK/X0')
s.close()"
if [ -S "$PSOCK/X0" ]; then
    ok "  set up: a stale socket file exists with nothing listening on it"
else
    bad "  set up: a stale socket" "could not create one"
fi
cat > "$TMP/Xorg" <<EOF
#!/bin/sh
# Binds without unlinking: success proves the launcher cleared the stale
# socket first (a leftover file makes python's bind raise EADDRINUSE).
sleep 1
python3 -c "import socket,time
s = socket.socket(socket.AF_UNIX)
s.bind('$PSOCK/X0')
s.listen(1)
time.sleep(60)"
EOF
chmod +x "$TMP/Xorg"
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
out=$(COPPER_XORG="$TMP/Xorg" COPPER_STARTXFCE4="$TMP/startxfce4" \
      COPPER_XLOG="$TMP/xorg.log" COPPER_SESSIONLOG="$TMP/session.log" \
      COPPER_XPROBE="$PROBE" COPPER_XORGCONF="$TMP/xorg.conf" \
      COPPER_XFCE_APPS="$TMP/no-apps" COPPER_INGOT=ingot COPPER_SUDO="" \
      XSOCKDIR="$PSOCK" WAIT_TRIES=80 sh "$SUT" 2>&1); rc=$?
pkill -f "$TMP/Xorg" 2>/dev/null; pkill -f "$PSOCK" 2>/dev/null
eq "  a missing probe is not false success; a fresh server was started" 0 "$rc"
has "  says the probe is missing and names the fallback" "no X liveness probe" "$out"
has "  names the socket-table fallback" "checking the kernel's socket table" "$out"
has "  started its own server" "starting $TMP/Xorg" "$out"
has "  the display came up (so the stale socket was cleared)" "X server is up" "$out"

echo
echo "=== case 17: a probe that answers live reuses the display ==="
# Probe exit 0 means live: reuse the display instead of fighting a second server for the socket.
# The probe's exit codes are the whole contract: 0 means live.
# Starting a second server would fight for the same socket.
reset
mkdir -p "$PSOCK"
python3 -c "import socket,time
s = socket.socket(socket.AF_UNIX)
s.bind('$PSOCK/X0')
s.listen(1)
time.sleep(60)" &
spid=$!
sleep 1
printf '#!/bin/sh\necho "ERROR: this stub must not run"\nexit 99\n' > "$TMP/Xorg"
chmod +x "$TMP/Xorg"
printf '#!/bin/sh\necho "DISPLAY=$DISPLAY" > %s/session.env\n' "$TMP" > "$TMP/startxfce4"
chmod +x "$TMP/startxfce4"
cat > "$TMP/probe" <<'PROBE_EOF'
#!/bin/sh
exit 0
PROBE_EOF
chmod +x "$TMP/probe"
out=$(COPPER_XORG="$TMP/Xorg" COPPER_STARTXFCE4="$TMP/startxfce4" \
      COPPER_XLOG="$TMP/xorg.log" COPPER_SESSIONLOG="$TMP/session.log" \
      COPPER_XPROBE="$TMP/probe" COPPER_XORGCONF="$TMP/xorg.conf" \
      XSOCKDIR="$PSOCK" WAIT_TRIES=5 sh "$SUT" 2>&1); rc=$?
kill "$spid" 2>/dev/null
eq "  exit code is 0" 0 "$rc"
has "  reused the running server" "already on" "$out"
hasnt "  did not start a second server" "starting $TMP/Xorg" "$out"
if [ -s "$TMP/session.env" ]; then
    ok "  the session ran on the existing server"
else
    bad "  the session ran on the existing server" "session.env missing"
fi

echo
echo "=== case 18: an unanswered ('unknown') probe does NOT clear the socket ==="
# Exit 3 means "there but not answering"; no proof of staleness, so leave the socket and let a fresh server try.
# That could be a server still starting, one this user may not speak to, or a kernel that will not report.
# None of it proves the socket is stale, so the launcher leaves the file alone.
reset
mkdir -p "$PSOCK"
python3 -c "import socket,sys
s = socket.socket(socket.AF_UNIX)
s.bind('$PSOCK/X0')
s.close()"
cat > "$TMP/probe" <<'PROBE_EOF'
#!/bin/sh
exit 3
PROBE_EOF
chmod +x "$TMP/probe"
# The stub exits immediately: a clean failure proves the unknown answer did not let the launcher delete the socket.
# The 'unknown' answer forbids deleting the socket before starting a fresh server.
printf '#!/bin/sh\nexit 0\n' > "$TMP/Xorg"; chmod +x "$TMP/Xorg"
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
out=$(COPPER_XORG="$TMP/Xorg" COPPER_STARTXFCE4="$TMP/startxfce4" \
      COPPER_XLOG="$TMP/xorg.log" COPPER_SESSIONLOG="$TMP/session.log" \
      COPPER_XPROBE="$TMP/probe" COPPER_XORGCONF="$TMP/xorg.conf" \
      XSOCKDIR="$PSOCK" WAIT_TRIES=5 sh "$SUT" 2>&1); rc=$?
eq "  an unknown display still fails cleanly, not a hang or false success" 23 "$rc"
has "  says it is leaving the socket in place" "leaving it in place" "$out"
has "  blames the display that did not answer" "did not answer" "$out"
if [ -S "$PSOCK/X0" ]; then
    ok "  the socket survived the unknown answer"
else
    bad "  the socket survived the unknown answer" "it was removed despite 'unknown'"
fi

echo
echo "=== case 19: a server that never answers times out instead of hanging ==="
# A mute (exit 3) display must be bounded and named, not hang or false-success.
# The handshake never completes -- the 'mute' state xprobe reports as exit 3.
# It polls, the probe keeps saying unknown, and the bounded wait runs out with exit 22 naming the display.
reset
mkdir -p "$PSOCK"
python3 -c "import socket,sys
s = socket.socket(socket.AF_UNIX)
s.bind('$PSOCK/X0')
s.close()"
cat > "$TMP/probe" <<'PROBE_EOF'
#!/bin/sh
exit 3
PROBE_EOF
chmod +x "$TMP/probe"
cat > "$TMP/Xorg" <<EOF
#!/bin/sh
sleep 1
python3 -c "import os,socket,time
if os.path.exists('$PSOCK/X0'): os.unlink('$PSOCK/X0')
s = socket.socket(socket.AF_UNIX)
s.bind('$PSOCK/X0')
s.listen(1)
time.sleep(60)"
EOF
chmod +x "$TMP/Xorg"
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
out=$(COPPER_XORG="$TMP/Xorg" COPPER_STARTXFCE4="$TMP/startxfce4" \
      COPPER_XLOG="$TMP/xorg.log" COPPER_SESSIONLOG="$TMP/session.log" \
      COPPER_XPROBE="$TMP/probe" COPPER_XORGCONF="$TMP/xorg.conf" \
      XSOCKDIR="$PSOCK" WAIT_TRIES=5 sh "$SUT" 2>&1); rc=$?
pkill -f "$TMP/Xorg" 2>/dev/null; pkill -f "$PSOCK" 2>/dev/null
eq "  bounded wait, nonzero exit, no hang" 22 "$rc"
has "  says the display never opened" "never opened" "$out"
has "  still kept the socket for the unknown display" "leaving it in place" "$out"

echo
echo "=== case 20: XPROBE_TIMEOUT reaches the probe ==="
# The probe must receive XPROBE_TIMEOUT=7, or the bounded-wait guarantee silently reverts to the default.
# display_state runs the probe with the caller's XPROBE_TIMEOUT.
# If it saw the default 5 instead of 7, the bounded-wait guarantee silently reverts.
reset
mkdir -p "$PSOCK"
python3 -c "import socket,time
s = socket.socket(socket.AF_UNIX)
s.bind('$PSOCK/X0')
s.listen(1)
time.sleep(60)" &
spid=$!
sleep 1
printf '#!/bin/sh\necho "ERROR: this stub must not run"\nexit 99\n' > "$TMP/Xorg"
chmod +x "$TMP/Xorg"
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
cat > "$TMP/probe" <<PROBE_EOF
#!/bin/sh
echo "timeout=\$XPROBE_TIMEOUT" > "$TMP/probe.env"
exit 0
PROBE_EOF
chmod +x "$TMP/probe"
out=$(COPPER_XORG="$TMP/Xorg" COPPER_STARTXFCE4="$TMP/startxfce4" \
      COPPER_XLOG="$TMP/xorg.log" COPPER_SESSIONLOG="$TMP/session.log" \
      COPPER_XPROBE="$TMP/probe" COPPER_XORGCONF="$TMP/xorg.conf" \
      XSOCKDIR="$PSOCK" WAIT_TRIES=5 XPROBE_TIMEOUT=7 \
      sh "$SUT" 2>&1); rc=$?
kill "$spid" 2>/dev/null
eq "  exit code is 0" 0 "$rc"
has "  reused the running server" "already on" "$out"
if grep -q '^timeout=7$' "$TMP/probe.env" 2>/dev/null; then
    ok "  the probe was given XPROBE_TIMEOUT=7"
else
    bad "  the probe was given XPROBE_TIMEOUT=7" "probe saw: $(cat "$TMP/probe.env" 2>/dev/null)"
fi

echo
echo "=== case 21: a probe stuck at 'not live' cannot wedge the launcher ==="
# A probe answering 1 to everything reports a live server as dead; reaching 22 also proves the stale socket was cleared (else 23).
# It reports a healthy server as dead; the launcher must not hang or claim success.
# The Xorg stub binds without unlinking: reaching 22 proves the stale socket was cleared.
reset
mkdir -p "$PSOCK"
python3 -c "import socket,sys
s = socket.socket(socket.AF_UNIX)
s.bind('$PSOCK/X0')
s.close()"
cat > "$TMP/probe" <<'PROBE_EOF'
#!/bin/sh
exit 1
PROBE_EOF
chmod +x "$TMP/probe"
cat > "$TMP/Xorg" <<EOF
#!/bin/sh
sleep 1
python3 -c "import socket,time
s = socket.socket(socket.AF_UNIX)
s.bind('$PSOCK/X0')
s.listen(1)
time.sleep(60)"
EOF
chmod +x "$TMP/Xorg"
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
out=$(COPPER_XORG="$TMP/Xorg" COPPER_STARTXFCE4="$TMP/startxfce4" \
      COPPER_XLOG="$TMP/xorg.log" COPPER_SESSIONLOG="$TMP/session.log" \
      COPPER_XPROBE="$TMP/probe" COPPER_XORGCONF="$TMP/xorg.conf" \
      XSOCKDIR="$PSOCK" WAIT_TRIES=5 sh "$SUT" 2>&1); rc=$?
pkill -f "$TMP/Xorg" 2>/dev/null; pkill -f "$PSOCK" 2>/dev/null
eq "  the wait ends, with a nonzero exit" 22 "$rc"
has "  says the display never opened" "never opened" "$out"

# sudo startxfce must drop to the wizard's account from /etc/copper-firstboot.done, or the desktop writes to /root while the account sits unused.
# COPPER_USER_MARKER and a sudo stub keep the decision under test without depending on the host.
# The account comes from /etc/copper-firstboot.done, read the way copper-init reads it.
reset
mkdir -p "$TMP/bin"
cat > "$TMP/bin/sudo" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/sudo.args"
exit 0
EOF
chmod +x "$TMP/bin/sudo"
printf '#!/bin/sh\nexit 0\n' > "$TMP/startxfce4"; chmod +x "$TMP/startxfce4"
printf '#!/bin/sh\nexit 0\n' > "$TMP/Xorg";       chmod +x "$TMP/Xorg"

run_drop() { # run_drop [VAR=value...] -- the launcher, with the stubs above
    rm -f "$TMP/sudo.args"
    env PATH="$TMP/bin:$PATH" "$@" \
        COPPER_XORG="$TMP/Xorg" COPPER_STARTXFCE4="$TMP/startxfce4" \
        COPPER_XLOG="$TMP/xorg.log" COPPER_SESSIONLOG="$TMP/session.log" \
        COPPER_XPROBE="$PROBE" COPPER_XORGCONF="$TMP/xorg.conf" \
        COPPER_XFCE_APPS="$TMP/no-apps" COPPER_INGOT=ingot COPPER_SUDO="" \
        XSOCKDIR="$TMP/.X11-unix" sh "$SUT" 2>&1
}

if [ "$(id -u)" != 0 ]; then
    printf '  --    the marker check needs root; this is uid %s\n' "$(id -u)"
elif ! id nobody >/dev/null 2>&1; then
    printf '  --    no account to test with (looked for nobody)\n'
else
    marker="$TMP/firstboot.done"
    printf 'nobody\n' > "$marker"
    out=$(run_drop COPPER_USER_MARKER="$marker")
    has "  the marker's account is who it becomes" "as nobody" "$out"
    has "  ...and sudo is asked for that account" "-u nobody" "$(cat "$TMP/sudo.args" 2>/dev/null)"

    out=$(run_drop)
    hasnt "  with no marker at all it says nothing about becoming one" \
          "starting the desktop as" "$out"
    if [ -s "$TMP/sudo.args" ]; then
        bad "  ...and does not reach for sudo" "$(cat "$TMP/sudo.args")"
    else
        ok "  ...and does not reach for sudo"
    fi

    out=$(run_drop COPPER_USER=root COPPER_USER_MARKER="$marker")
    hasnt "  COPPER_USER=root keeps a root desktop, on purpose" \
          "starting the desktop as" "$out"
    if [ -s "$TMP/sudo.args" ]; then
        bad "  ...and does not reach for sudo" "$(cat "$TMP/sudo.args")"
    else
        ok "  ...and does not reach for sudo"
    fi
fi

# A default wallpaper naming a path not on the disc is a grey gradient; check both the xfconf value and the real PNG.
# xfdesktop reads system defaults from /etc/xdg/xfce4, and a home that never chose a wallpaper gets them.
# A default naming a path the disc does not carry is a grey gradient with extra steps.
XDG_DESKTOP="$REPO/iso/rootfs-overlay/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
WALLPAPER="$REPO/iso/rootfs-overlay/usr/share/copper/wallpapers/copper-default.png"
if [ -f "$XDG_DESKTOP" ] \
   && grep -qF 'value="/usr/share/copper/wallpapers/copper-default.png"' "$XDG_DESKTOP"; then
    ok "  the XFCE session has Copper's default wallpaper"
else
    bad "  the XFCE session has Copper's default wallpaper" \
        "no $XDG_DESKTOP, or it does not name the shipped picture"
fi
if [ -f "$WALLPAPER" ] \
   && [ "$(od -An -tx1 -N8 "$WALLPAPER" | tr -d ' \n')" = "89504e470d0a1a0a" ]; then
    ok "  the default wallpaper is a real PNG"
else
    bad "  the default wallpaper is a real PNG" "$WALLPAPER"
fi

pkill -f "$TMP" 2>/dev/null
rm -rf "$TMP"
echo
if [ "$fails" -ne 0 ]; then
    echo "FAILED: $fails check(s)"
    exit 1
fi
echo "all startxfce checks passed"