#!/bin/sh
# Prove starthyprland does the right thing, and fails the right way.
#
# Hyprland is a Wayland compositor: there is no second process to hand a display
# to, so the launcher's whole job is the preparation around the compositor --
# seed the config, make the runtime directory, start the session bus, notice
# whether the seat is there, choose a renderer -- and then the exit-code
# contract when one of those cannot be done or the compositor dies on the way
# up. Every one of those gets a case here, with the exact exit code asserted:
# the codes are a contract, and a script branching on them breaks silently when
# one moves.
#
# The compositor is stubbed. The real Hyprland is a glibc binary linked against
# the PPA's Wayland/DRM stack, which this image is not, so it cannot run here no
# matter what. What is under test is the launcher: the ordering, the
# preparation, the codes, the report --check prints, and the environment the
# compositor is handed.
#
# The stub answers two ways, because Hyprland itself is both binaries:
# the compositor takes no arguments, and hyprctl is the liveness probe the
# launcher runs against the instance directory. The socket is a plain file
# inside a directory whose name is the stub's pid -- which is the pid the
# launcher backgrounds and goes looking for.
#
# Run: sh tests/starthyprland-gate.sh

set -u

# The stubs must not see this machine's desktop or bus.
unset DISPLAY WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_SESSION_DESKTOP \
      XDG_CURRENT_DESKTOP XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS SEATD_SOCK

REPO=$(cd "$(dirname "$0")/.." && pwd)
SUT="$REPO/iso/starthyprland.sh"
LOCK=/tmp/starthyprland-gate.lock
fails=0

if ! mkdir "$LOCK" 2>/dev/null; then
    echo "another starthyprland-gate.sh is running (lock: $LOCK)"
    echo "if that is wrong, remove it and re-run"
    exit 1
fi
TMP=$(mktemp -d /tmp/starthyprland-gate.XXXXXX) || exit 1
cleanup() {
    pkill -P $$ 2>/dev/null
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

# ---------------------------------------------------------------------------
# fixture: a private, writable world for the launcher to act in.
#
# The launcher reads its configuration from the environment. Defaults are
# exported once, here; a case overrides one by assigning it before calling
# run_launcher, and that assignment reaches the launcher unchanged.
# ---------------------------------------------------------------------------

# A stub compositor, in the two roles the real binary plays.
cat > "$TMP/hyprland" <<'EOF'
#!/bin/sh
# Stub compositor. Real Hyprland takes no arguments: its option parser rejects
# `--session` outright ("Unknown option '--session'"), so this stub takes none
# either. It creates the instance directory where real Hyprland puts it --
# $XDG_RUNTIME_DIR/hypr/<signature>/, holding .socket.sock -- because that is
# what the launcher searches, then stays alive until the launcher reaps it.
# HYP_FAIL=1 makes startup fail, which is how the "exited while starting" path
# is exercised.
if [ "${HYP_FAIL:-0}" = "1" ]; then
    echo "hyprland stub: cannot take the DRM master" >&2
    exit 1
fi
sig="stub$$"
dir="$XDG_RUNTIME_DIR/hypr/$sig"
mkdir -p "$dir" 2>/dev/null || exit 1
[ -n "${HYP_SIGFILE:-}" ] && printf '%s\n' "$sig" > "$HYP_SIGFILE" 2>/dev/null
: > "$dir/.socket.sock" 2>/dev/null || exit 1
trap 'rm -rf "$dir"' EXIT
sleep "${HYP_STUB_SLEEP:-1}"
exit 0
EOF
chmod +x "$TMP/hyprland"

cat > "$TMP/hyprctl" <<'EOF'
#!/bin/sh
# Stub hyprctl. Real hyprctl speaks the IPC protocol to the instance named by
# HYPRLAND_INSTANCE_SIGNATURE and fails for any other -- including a socket
# left behind by a dead instance. Answering unconditionally would hide exactly
# the bug this guard exists for.
live=
[ -n "${HYP_SIGFILE:-}" ] && live=$(head -n1 "$HYP_SIGFILE" 2>/dev/null)
[ -n "$live" ] && [ "$HYPRLAND_INSTANCE_SIGNATURE" = "$live" ] && exit 0
exit 1
EOF
chmod +x "$TMP/hyprctl"

# The other utilities --check reports on.
for u in waybar fuzzel kitty hyprlock dunst; do
    cat > "$TMP/$u" <<EOF
#!/bin/sh
exit 0
EOF
    chmod +x "$TMP/$u"
done

# A seatd socket, so the "seatd present" branch is exercised. It has to be a
# real unix socket, not a regular file: the launcher tests [ -S ], and a plain
# file would make the "seatd present" case a lie. python3 binds it; without
# python3 that one case is skipped rather than faked.
mkdir -p "$TMP/run"
rm -f "$TMP/run/seatd.sock"
SEATD_SOCK_PID=
if command -v python3 >/dev/null 2>&1; then
    python3 - "$TMP/run/seatd.sock" <<'PY' &
import os, socket, sys, time
path = sys.argv[1]
try:
    os.unlink(path)
except OSError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(1)
time.sleep(600)
PY
    SEATD_SOCK_PID=$!
    sleep 0.3
fi

# A libudev record tree: PID 1 writes these at boot, and libinput drops any
# device whose record has no ID_INPUT_* tag.
mkdir -p "$TMP/sys/class/input/input0" "$TMP/run/udev/data"
printf 'stub keyboard\n' > "$TMP/sys/class/input/input0/name"
mkdir -p "$TMP/sys/class/input/input0/event0"
printf '9:1234\n' > "$TMP/sys/class/input/input0/event0/dev"
printf 'E:ID_INPUT_KEYBOARD\nE:ID_INPUT=1\n' > "$TMP/run/udev/data/c9:1234"

# A config skeleton in the layout the shipped tree uses.
mkdir -p "$TMP/skel/.config/hypr" "$TMP/skel/.config/waybar/scripts" "$TMP/home"
printf '# stub hyprland config\n' > "$TMP/skel/.config/hypr/hyprland.lua"
printf '{}\n' > "$TMP/skel/.config/waybar/config.jsonc"
printf '#!/bin/sh\nexit 0\n' > "$TMP/skel/.config/waybar/scripts/workspaces.sh"
chmod +x "$TMP/skel/.config/waybar/scripts/workspaces.sh"

# The component manifest the launcher reads. By default every component is
# present, so a plain launch never stops to ask about installing anything.
{
    printf 'waybar          %s/waybar          image\n' "$TMP"
    printf 'fuzzel          %s/fuzzel          ingot\n' "$TMP"
} > "$TMP/hyprland-apps"

# A second manifest with two components that are genuinely missing, one of
# which the installer refuses -- to prove an install failure does not abort a
# session that has already been told to install the rest.
{
    printf 'fuzzel          /usr/bin/fuzzel          ingot\n'
    printf 'nmap            /usr/bin/nmap            ingot\n'
} > "$TMP/hyprland-apps-missing"

# A stub installer. Everything installs except nmap.
cat > "$TMP/ingot" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "install" ]; then
    [ "${2:-}" = "nmap" ] && exit 1
    exit 0
fi
exit 0
EOF
chmod +x "$TMP/ingot"

# Defaults, exported once. A case that needs something else assigns it before
# calling run_launcher; the assignment lands in run_launcher's environment and
# is not replaced here, which is why the launcher sees the case's value.
HOME="$TMP/home";                         export HOME
PATH="$TMP:$PATH";                        export PATH
: "${COPPER_HYPRLAND:=$TMP/hyprland}";     export COPPER_HYPRLAND
: "${COPPER_WAYBAR:=$TMP/waybar}";         export COPPER_WAYBAR
: "${COPPER_HYPRLAND_SKEL:=$TMP/skel}";    export COPPER_HYPRLAND_SKEL
: "${COPPER_HYPRLAND_APPS:=$TMP/hyprland-apps}"; export COPPER_HYPRLAND_APPS
: "${COPPER_INGOT:=$TMP/ingot}";           export COPPER_INGOT
: "${COPPER_SEATD_SOCK:=$TMP/run/seatd.sock}"; export COPPER_SEATD_SOCK
: "${COPPER_USER_HYPR_CONF:=$TMP/home/.config/hypr}"; export COPPER_USER_HYPR_CONF
: "${COPPER_DRM_DIR:=$TMP/dev/dri}";       export COPPER_DRM_DIR
: "${COPPER_INPUT_SYS:=$TMP/sys/class/input}"; export COPPER_INPUT_SYS
: "${COPPER_UDEV_DATA:=$TMP/run/udev/data}"; export COPPER_UDEV_DATA
# No sudo: the gate must exercise the install path without a password prompt.
: "${COPPER_SUDO=}";                       export COPPER_SUDO
# Keep the wait loop short: the "no answering socket" case would otherwise
# spend its full budget before falling through.
: "${WAIT_TRIES=20}";                      export WAIT_TRIES
# Both stubs talk through this file so hyprctl can tell the live instance's
# signature from a stale socket left by a dead one.
HYP_SIGFILE="$TMP/hypr-signature";           export HYP_SIGFILE

run_launcher() { "$SUT" "$@"; }

# ---------------------------------------------------------------------------
# cases
# ---------------------------------------------------------------------------

# Usage and argument handling.
out=$(run_launcher --help 2>&1); rc=$?
eq "--help exits 0" 0 "$rc"
has "--help prints usage" "starthyprland -- start" "$out"

out=$(run_launcher --bogus 2>&1); rc=$?
eq "unknown option exits 24" 24 "$rc"

out=$(run_launcher unexpected 2>&1); rc=$?
eq "unexpected argument exits 24" 24 "$rc"

# The compositor is missing: the launch names the piece and stops.
out=$(COPPER_HYPRLAND=/nonexistent/hyprland run_launcher 2>&1); rc=$?
eq "compositor missing exits 20" 20 "$rc"
has "compositor missing names the path" "/nonexistent/hyprland" "$out"

# --check on the same machine reports it and still exits 0: a report is not a
# launch, and a unit that runs it must not read a nonzero as "the session died".
out=$(COPPER_HYPRLAND=/nonexistent/hyprland run_launcher --check 2>&1); rc=$?
eq "--check exits 0 even when the compositor is missing" 0 "$rc"
has "--check says NOT INSTALLED" "NOT INSTALLED" "$out"
has "--check points at the stage that stages it" "hyprland stage" "$out"

# No configuration anywhere: launch stops with 21.
out=$(COPPER_HYPRLAND_SKEL="$TMP/noskel" \
      COPPER_USER_HYPR_CONF="$TMP/nohome/.config/hypr" \
      run_launcher 2>&1); rc=$?
eq "no config exits 21" 21 "$rc"
has "no config names the place it looked" "nohome" "$out"

# Runtime directory forced to a path that is not a directory: 22.
out=$(COPPER_RUNTIME_DIR="$TMP/not-a-dir" run_launcher 2>&1); rc=$?
eq "runtime directory missing exits 22" 22 "$rc"
has "runtime failure names the directory" "not-a-dir" "$out"

# Seat management is reported both ways.
if [ -S "$TMP/run/seatd.sock" ]; then
    out=$(run_launcher --check 2>&1)
    has "--check reports a present seatd socket" "seatd socket present" "$out"
else
    printf '  skip  --check reports a present seatd socket (no python3 to bind one)\n'
fi

out=$(COPPER_SEATD_SOCK="$TMP/run/absent.sock" run_launcher --check 2>&1)
# The wording of this line depends on the host: without logind the launcher says
# "NO seatd socket", with logind it says "logind present (no seatd socket at
# ...)". Both name the path it looked at and both deny that it is live, which is
# what is actually under test here.
has "--check names the absent seatd socket it checked" "absent.sock" "$out"
case "$out" in
    *"seatd socket present"*)
        bad "--check did not mistake the absent socket for a live one" \
            "it said: $(printf '%s' "$out" | tr '\n' '|')" ;;
    *) ok "--check did not mistake the absent socket for a live one" ;;
esac

# --check covers the categories a session can die on.
out=$(run_launcher --check 2>&1)
has "--check reports the compositor" "hyprland: present" "$out"
has "--check reports runtime libraries" "runtime libraries:" "$out"
has "--check reports the configuration" "config:" "$out"
has "--check reports the Wayland utilities" "utility waybar:" "$out"
has "--check reports the runtime environment" "runtime:" "$out"
has "--check reports the session bus" "session bus:" "$out"

# --check must not prepare anything: with a private runtime directory it
# creates no compositor socket there.
mkdir -p "$TMP/rt-check"
out=$(COPPER_RUNTIME_DIR="$TMP/rt-check" run_launcher --check 2>&1); rc=$?
eq "--check on a complete tree exits 0" 0 "$rc"
if [ -z "$(find "$TMP/rt-check" -name "*.sock" 2>/dev/null)" ]; then
    ok "--check starts no compositor (no instance socket left behind)"
else
    bad "--check starts no compositor" "an instance socket appeared under the runtime directory"
fi

# A session that comes up cleanly exits 0.
out=$(run_launcher 2>&1); rc=$?
eq "session start exits 0" 0 "$rc"
has "session start says the compositor came up" "hyprland is up" "$out"

# A socket left behind by an earlier, dead instance must not satisfy the
# probe: the launcher has to find the live instance's signature and hyprctl
# has to answer for it, not merely see a socket file.
mkdir -p "$TMP/rt-stale/hypr/deadbeef"
: > "$TMP/rt-stale/hypr/deadbeef/deadbeef.0.sock"
out=$(COPPER_RUNTIME_DIR="$TMP/rt-stale" run_launcher 2>&1); rc=$?
eq "a stale socket does not stop the live session" 0 "$rc"
has "the live instance was recognised" "hyprland is up" "$out"

# A compositor that dies on the way up exits 23 and shows the log.
out=$(HYP_FAIL=1 run_launcher 2>&1); rc=$?
eq "compositor failing at startup exits 23" 23 "$rc"
has "startup failure prints the reason" "exited while starting up" "$out"

# A component that cannot be installed does not abort a session that has
# already been told to install the rest.
out=$(COPPER_HYPRLAND_APPS="$TMP/hyprland-apps-missing" run_launcher --yes 2>&1); rc=$?
eq "install failure still starts the session" 0 "$rc"
has "install failure is reported, not swallowed" "could not install nmap" "$out"

echo
if [ "$fails" -gt 0 ]; then
    printf '  FAIL  %s checks failed\n' "$fails"
    exit 1
fi
exit 0
