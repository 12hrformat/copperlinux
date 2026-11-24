#!/bin/sh
# Prove iso/starthyprland.sh's preparation, ordering, exit codes, --check report and environment; the real compositor is glibc and cannot run here.
# Both binaries are stubbed (compositor and hyprctl probe) with a pid-named instance dir, matching the real layout.
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

# The launcher reads its config from the environment; defaults are exported once here and cases override one before run_launcher.
# The launcher reads its configuration from the environment, not a file.
# Defaults are exported once, here; a case overrides one by assigning it before run_launcher.

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

# A real [ -S ] seatd socket is needed; a plain file would fake "present". Skip the case without python3.
# python3 binds it; without python3 the one case is skipped rather than faked.
# A plain file would make the "seatd present" case a lie.
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

# libudev drops devices without ID_INPUT_* tags; this tree supplies one.
# PID 1 writes these at boot and libinput drops any device without an ID_INPUT_* tag.
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

# Default manifest has every component present so a plain launch never prompts.
# The launcher reads it at launch, so a missing component would otherwise stop the plain case.
{
    printf 'waybar          %s/waybar          image\n' "$TMP"
    printf 'fuzzel          %s/fuzzel          ingot\n' "$TMP"
} > "$TMP/hyprland-apps"

# Second manifest has a missing component the installer refuses, to prove a failed install does not abort a told-to-install session.
# One component is missing and the installer refuses it.
# That proves an install failure does not abort a session already told to install the rest.
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

# Case assignments land in run_launcher's environment; they are not replaced here, so the launcher sees the case's value.
# HOME and PATH are exported once; the COPPER_* defaults are set with : ${VAR:=}.
# A case's assignment lands in run_launcher's environment and is not replaced here.
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
# Empty stash by default so an ordinary case never touches the real /usr/lib.
# The restore case points both at throwaway trees.
: "${COPPER_LIBSTASH=}";                   export COPPER_LIBSTASH
: "${COPPER_LIBDIR=$TMP/usr-lib}";         export COPPER_LIBDIR
# Short wait budget: the "no answering socket" case would otherwise run the full loop.
# The 'no answering socket' case would otherwise spend its full budget before falling through.
: "${WAIT_TRIES=20}";                      export WAIT_TRIES
# Both stubs talk through this file so hyprctl can tell the live instance's
# signature from a stale socket left by a dead one.
HYP_SIGFILE="$TMP/hypr-signature";           export HYP_SIGFILE

run_launcher() { "$SUT" "$@"; }

# cases

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

# --yes installs a missing compositor on a fresh or clobbered tree without a second manual step.
# A half-installed or later-clobbered tree has to be repairable without a second manual step.
# The install stub actually puts a compositor in place when asked.
cat > "$TMP/ingot-installs" <<EOF
#!/bin/sh
[ "\${1:-}" = install ] || exit 0
[ "\${2:-}" = hyprland ] || exit 0
cp "$TMP/hyprland" "\${COPPER_HYPRLAND:-/usr/bin/Hyprland}"
chmod +x "\${COPPER_HYPRLAND:-/usr/bin/Hyprland}"
EOF
chmod +x "$TMP/ingot-installs"
rm -f "$TMP/installed-hyprland"
out=$(COPPER_HYPRLAND="$TMP/installed-hyprland" COPPER_INGOT="$TMP/ingot-installs" \
      run_launcher --yes 2>&1); rc=$?
eq "--yes installs a missing compositor and starts it" 0 "$rc"
has "the on-demand install is announced" "installing hyprland with ingot" "$out"

# --check is a report, not a launch: exit 0 even with the compositor missing so units don't read it as a dead session.
# --check reports the compositor and still exits 0: a report is not a launch.
# A unit running it must not read a nonzero as 'the session died'.
out=$(COPPER_HYPRLAND=/nonexistent/hyprland run_launcher --check 2>&1); rc=$?
eq "--check exits 0 even when the compositor is missing" 0 "$rc"
has "--check says NOT INSTALLED" "NOT INSTALLED" "$out"
has "--check points at the payload install" "sudo ingot install hyprland" "$out"

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
# Logind wording differs by host; both forms name the path and deny a live socket, so only those are asserted.
# Without logind it says 'NO seatd socket'; with logind 'logind present (no seatd socket at ...)'.
# Both name the path checked and deny that it is live, which is what is under test.
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

# --check must not prepare: no instance socket may appear in a private runtime dir.
# With a private runtime directory --check creates no compositor socket there.
# Preparing anything in a report would leave a false instance behind.
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

# A stale socket must not satisfy the probe; hyprctl must answer for the live signature.
# hyprctl must answer for the instance signature, not merely see a socket file.
# A deadbeef socket left by an earlier instance must not satisfy the probe.
mkdir -p "$TMP/rt-stale/hypr/deadbeef"
: > "$TMP/rt-stale/hypr/deadbeef/deadbeef.0.sock"
out=$(COPPER_RUNTIME_DIR="$TMP/rt-stale" run_launcher 2>&1); rc=$?
eq "a stale socket does not stop the live session" 0 "$rc"
has "the live instance was recognised" "hyprland is up" "$out"

# A compositor that dies on the way up exits 23 and shows the log.
out=$(HYP_FAIL=1 run_launcher 2>&1); rc=$?
eq "compositor failing at startup exits 23" 23 "$rc"
has "startup failure prints the reason" "exited while starting up" "$out"

# An install that fails must not abort a session already told to install the rest.
# The installer stub refuses nmap while installing the rest.
# A failed install is reported, not swallowed, and the session still starts.
out=$(COPPER_HYPRLAND_APPS="$TMP/hyprland-apps-missing" run_launcher --yes 2>&1); rc=$?
eq "install failure still starts the session" 0 "$rc"
has "install failure is reported, not swallowed" "could not install nmap" "$out"

# Nothing Hyprland-specific is baked into the ISO: the payload supplies compositor, config and launcher; only the repo copy is gated.
# The compositor, Lua config tree and launcher all come from the ingot payload.
# The launcher lives in this repo only so the payload can be built and this gate can test it.
if [ -e "$REPO/iso/rootfs-overlay/usr/share/copper/hyprland-skel" ]; then
    bad "no Hyprland skeleton is baked into the image" \
        "the tree still carries a stale copy"
else
    ok "no Hyprland skeleton is baked into the image"
fi
if [ -e "$REPO/iso/rootfs-overlay/etc/copper/hyprland-apps" ]; then
    bad "no Hyprland manifest is baked into the image" \
        "the tree still carries a stale copy"
else
    ok "no Hyprland manifest is baked into the image"
fi
has "the launcher names the payload install" "sudo ingot install hyprland" \
    "$(cat "$SUT")"

# ingot payloads can replace noble's libxkbcommon with an older one and kill launch with a version error; the launcher must restore the stashed libraries.
# The stub clobbers the tree the way such a payload does, replacing the newer library.
# The launcher must put the libraries back before starting the compositor.
rm -rf "$TMP/libstash" "$TMP/libdir"
mkdir -p "$TMP/libstash" "$TMP/libdir"
printf 'LIBINPUT_1.30\n' > "$TMP/libstash/libinput.so.10"
printf 'LIBINPUT_1.30\n' > "$TMP/libstash/libinput.so.10.13.0"
printf 'V_1.11.0\n'     > "$TMP/libstash/libxkbcommon.so.0"
printf 'V_1.11.0\n'     > "$TMP/libstash/libxkbcommon.so.0.12.3"
printf 'no symbol here\n' > "$TMP/libdir/libinput.so.10"
printf 'no symbol here\n' > "$TMP/libdir/libxkbcommon.so.0"
printf 'widget          %s/widget          ingot\n' "$TMP" > "$TMP/apps-widget"
cat > "$TMP/ingot-clobber" <<EOF
#!/bin/sh
[ "\${1:-}" = install ] || exit 0
printf 'clobbered by a payload\n' > "$TMP/libdir/libxkbcommon.so.0"
exit 0
EOF
chmod +x "$TMP/ingot-clobber"
out=$(COPPER_LIBSTASH="$TMP/libstash" COPPER_LIBDIR="$TMP/libdir" \
      COPPER_HYPRLAND_APPS="$TMP/apps-widget" COPPER_INGOT="$TMP/ingot-clobber" \
      run_launcher --yes 2>&1); rc=$?
eq "session starts with a payload-clobbered library" 0 "$rc"
has "the restore is announced" "restoring hyprland's input libraries" "$out"
if grep -qa "LIBINPUT_1.30" "$TMP/libdir/libinput.so.10" &&
   grep -qa "V_1.11.0" "$TMP/libdir/libxkbcommon.so.0"; then
    ok "both libraries were put back in the tree"
else
    bad "both libraries were put back in the tree" "still the payload's copies"
fi

# With no stash there is nothing to restore; say so plainly rather than linking a broken library.
# Handing the compositor a library it cannot link against is the failure this names.
rm -rf "$TMP/libdir2"; mkdir -p "$TMP/libdir2"
printf 'no symbol here\n' > "$TMP/libdir2/libinput.so.10"
printf 'no symbol here\n' > "$TMP/libdir2/libxkbcommon.so.0"
out=$(COPPER_LIBSTASH="" COPPER_LIBDIR="$TMP/libdir2" run_launcher --yes 2>&1); rc=$?
eq "session still starts when there is no stash" 0 "$rc"

echo
if [ "$fails" -gt 0 ]; then
    printf '  FAIL  %s checks failed\n' "$fails"
    exit 1
fi
exit 0
