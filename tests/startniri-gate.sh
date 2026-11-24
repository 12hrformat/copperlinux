#!/bin/sh
# Prove startniri does the right thing, and fails the right way.
# The compositor is stubbed: only the launcher, its ordering, environment and
# exit-code contract are testable here; the exit codes are a contract.
# Run: sh tests/startniri-gate.sh

set -u

# The stubs must not see this machine's desktop or bus.
unset DISPLAY WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_SESSION_DESKTOP \
      XDG_CURRENT_DESKTOP XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS SEATD_SOCK \
      NIRI_SOCKET

REPO=$(cd "$(dirname "$0")/.." && pwd)
SUT="$REPO/iso/startniri.sh"
LOCK=/tmp/startniri-gate.lock
fails=0

if ! mkdir "$LOCK" 2>/dev/null; then
    echo "another startniri-gate.sh is running (lock: $LOCK)"
    echo "if that is wrong, remove it and re-run"
    exit 1
fi
TMP=$(mktemp -d /tmp/startniri-gate.XXXXXX) || exit 1
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

hasnt() {
    case "$3" in
        *"$2"*) bad "$1" "should not have mentioned '$2'; it said: $(printf '%s' "$3" | tr '\n' '|')" ;;
        *)      ok "$1" ;;
    esac
}

[ -f "$SUT" ] || { echo "  FAIL  $SUT does not exist"; exit 1; }

# --- isolation -------------------------------------------------------------
# Private home/runtime/skel/DRM and a dummy bus keep cases off this host's
# real $HOME and /dev/dri.
reset() {
    rm -rf "$TMP"
    mkdir -p "$TMP/home" "$TMP/run" "$TMP/.X11-unix" "$TMP/dri"
}

run_sut() {
    niri=$1
    tries=$2
    shift 2
    SKEL=${SKEL:-$TMP/no-skel}
    APPS_MANIFEST=${APPS_MANIFEST:-}
    INGOT_STUB=${INGOT_STUB:-}
    SUT_DRM=${SUT_DRM:-$TMP/dri}
    SUT_SEATD=${SUT_SEATD:-$TMP/no-seatd.sock}
    SUT_RUNTIME=${SUT_RUNTIME:-$TMP/run}
    # Default input tree is absent so the preflight cannot narrate this host.
    SUT_INPUT_SYS=${SUT_INPUT_SYS:-$TMP/no-input}
    SUT_UDEV_DATA=${SUT_UDEV_DATA:-$TMP/no-udevdata}
    # Renderer defaults are fixed here; cases opt into a machine shape.
    SUT_VMWARE=${SUT_VMWARE:-0}
    SUT_HOME=${SUT_HOME:-$TMP/home}
    # stdin is /dev/null so no case waits on a terminal question.
    HOME="$SUT_HOME" XDG_RUNTIME_DIR="$SUT_RUNTIME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/dummy-bus" \
    COPPER_NIRI="$niri" COPPER_NIRI_SKEL="$SKEL" \
    COPPER_SESSIONLOG="$TMP/niri.log" \
    COPPER_NIRI_APPS="${APPS_MANIFEST:-$TMP/no-apps}" \
    COPPER_INGOT="${INGOT_STUB:-ingot}" COPPER_SUDO="" \
    COPPER_DRM_DIR="$SUT_DRM" COPPER_SEATD_SOCK="$SUT_SEATD" \
    COPPER_INPUT_SYS="$SUT_INPUT_SYS" COPPER_UDEV_DATA="$SUT_UDEV_DATA" \
    COPPER_NIRI_VMWARE="$SUT_VMWARE" COPPER_AUDIO=0 \
    WAIT_TRIES="$tries" sh "$SUT" "$@" < /dev/null 2>&1
}

# The live stub records its environment and answers the IPC probe only at the
# socket the launcher expects.
write_live_stub() {
    cat > "$TMP/niri" <<EOF
#!/bin/sh
if [ "\$1" = msg ]; then
    [ -n "\${NIRI_SOCKET:-}" ] && [ -e "\$NIRI_SOCKET" ] || exit 1
    printf '{"version":"stub"}\n'
    exit 0
fi
{
  echo "ARG=\${1:-}"
  echo "XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR"
  echo "LIBGL_ALWAYS_SOFTWARE=\${LIBGL_ALWAYS_SOFTWARE:-}"
  echo "GBM_ALWAYS_SOFTWARE=\${GBM_ALWAYS_SOFTWARE:-}"
  echo "GALLIUM_DRIVER=\${GALLIUM_DRIVER:-}"
  echo "NIRI_CONFIG=\${NIRI_CONFIG:-}"
  echo "WLR_RENDERER=\${WLR_RENDERER:-}"
  echo "DBUS_SESSION_BUS_ADDRESS=\${DBUS_SESSION_BUS_ADDRESS:-}"
  printf 'IDENTITY=%s|%s|%s|%s\n' "\$XDG_SESSION_TYPE" "\$XDG_CURRENT_DESKTOP" "\$XDG_SESSION_DESKTOP" "\$DESKTOP_SESSION"
} > "$TMP/niri.env"
mkdir -p "\$XDG_RUNTIME_DIR"
sock="\$XDG_RUNTIME_DIR/niri.wayland-1.\$\$.sock"
: > "\$sock"
trap 'rm -f "\$sock"' EXIT
sleep 1
EOF
    chmod +x "$TMP/niri"
}

# The config-seeding cases need a shipped tree with a config in it.
write_skel() {
    mkdir -p "$TMP/skel/.config/niri" "$TMP/skel/.config/waybar"
    printf '// cfg\n' > "$TMP/skel/.config/niri/config.kdl"
    printf '{}\n' > "$TMP/skel/.config/waybar/config.jsonc"
}

# Shared input setup: the preflight must read the fake tree, not this host's
# real /sys/class/input and /run/udev/data.
setup_input_case() {
    reset
    write_skel
    SKEL="$TMP/skel"
    write_live_stub

    # The working mouse has a type record; the keyboard does not.
    mkdir -p "$TMP/input/input0/capabilities" "$TMP/input/input0/event0" \
             "$TMP/input/input1/capabilities" "$TMP/input/input1/event1" \
             "$TMP/udevdata"
    printf 'AT Translated Set 2 keyboard\n' > "$TMP/input/input0/name"
    printf '13:3\n' > "$TMP/input/input0/event0/dev"
    printf 'ImExPS/2 Generic Explorer Mouse\n' > "$TMP/input/input1/name"
    printf '13:4\n' > "$TMP/input/input1/event1/dev"
    printf 'I:1\nE:ID_INPUT=1\nE:ID_INPUT_MOUSE=1\n' > "$TMP/udevdata/c13:4"
    SUT_INPUT_SYS="$TMP/input"
    SUT_UDEV_DATA="$TMP/udevdata"
}

echo "=== it has to parse as POSIX sh, not just as bash ==="
if sh -n "$SUT" 2>"$TMP/syn.err"; then
    ok "parses under /bin/sh"
else
    bad "parses under /bin/sh" "$(cat "$TMP/syn.err" 2>/dev/null)"
fi

echo
echo "=== case 1: nothing installed at all ==="
reset
out=$(run_sut "$TMP/nope/niri" 40); rc=$?
eq "  exit code is 20 (no niri)" 20 "$rc"
has "  names the compositor it looked for" "$TMP/nope/niri" "$out"
has "  says the niri stage stages it" "niri stage" "$out"

echo
echo "=== case 2: --check starts nothing ==="
reset
printf '#!/bin/sh\nexit 99\n' > "$TMP/niri"; chmod +x "$TMP/niri"
out=$(run_sut "$TMP/niri" 5 --check); rc=$?
eq "  exit code is 0 even with pieces missing" 0 "$rc"
has "  reports the compositor it found" "found niri" "$out"
has "  reports the config it did not find" "NO session config" "$out"
hasnt "  claims to have started something" "starting niri" "$out"

echo
echo "=== case 3: compositor present, no config and none to seed from ==="
reset
printf '#!/bin/sh\nexit 0\n' > "$TMP/niri"; chmod +x "$TMP/niri"
out=$(run_sut "$TMP/niri" 5); rc=$?
eq "  exit code is 21 (no session config)" 21 "$rc"
has "  names the missing config" "no config in" "$out"
has "  says there is nothing to seed from" "no shipped tree" "$out"

echo
echo "=== case 4: the shipped tree seeds a bare home, then the session runs ==="
# The happy path: the stub leaves the IPC socket the bounded wait probes.
reset
write_skel
SKEL="$TMP/skel"
write_live_stub
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=
eq "  exit code is 0" 0 "$rc"
has "  says it seeded the config" "seeding the session config" "$out"
has "  says the compositor came up" "niri is up" "$out"
has "  says it started the compositor" "starting niri" "$out"
eq "  passes --session to the compositor" "--session" \
   "$(sed -n 's/^ARG=//p' "$TMP/niri.env" 2>/dev/null)"
eq "  the niri config landed in the user's home" "// cfg" \
   "$(cat "$TMP/home/.config/niri/config.kdl" 2>/dev/null)"
eq "  the waybar config landed in the user's home" "{}" \
   "$(cat "$TMP/home/.config/waybar/config.jsonc" 2>/dev/null)"
eq "  the compositor got the runtime directory" "$TMP/run" \
   "$(sed -n 's/^XDG_RUNTIME_DIR=//p' "$TMP/niri.env" 2>/dev/null)"
eq "  the compositor got the session bus" "unix:path=$TMP/dummy-bus" \
   "$(sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' "$TMP/niri.env" 2>/dev/null)"

echo
echo "=== case 5: no render node forces software rendering ==="
# $TMP/dri exists and has no renderD* node, which is the VM-with-no-3D shape.
has "  says it forced software rendering" "forcing software rendering" "$out"
eq "  LIBGL_ALWAYS_SOFTWARE reached the compositor" 1 \
   "$(sed -n 's/^LIBGL_ALWAYS_SOFTWARE=//p' "$TMP/niri.env" 2>/dev/null)"
eq "  no wlroots-only renderer variable was invented" "" \
   "$(sed -n 's/^WLR_RENDERER=//p' "$TMP/niri.env" 2>/dev/null)"

echo
echo "=== case 6: a render node means hardware rendering, nothing forced ==="
reset
write_skel
SKEL="$TMP/skel"
: > "$TMP/dri/renderD128"
SUT_DRM="$TMP/dri"
write_live_stub
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=; SUT_DRM=
eq "  exit code is 0" 0 "$rc"
hasnt "  does not force software rendering" "forcing software rendering" "$out"
eq "  LIBGL_ALWAYS_SOFTWARE was left unset" "" \
   "$(sed -n 's/^LIBGL_ALWAYS_SOFTWARE=//p' "$TMP/niri.env" 2>/dev/null)"

echo
echo "=== case 7: the compositor dies on the way up ==="
# A config is present so the launch reaches the compositor.
reset
write_skel
SKEL="$TMP/skel"
printf '#!/bin/sh\necho "(EE) no seat: cannot open /dev/dri/card0"\nexit 1\n' > "$TMP/niri"
chmod +x "$TMP/niri"
out=$(run_sut "$TMP/niri" 40); rc=$?
SKEL=
eq "  exit code is 23 (exited while starting)" 23 "$rc"
has "  shows the compositor's own log" "cannot open /dev/dri/card0" "$out"

echo
echo "=== case 8: a missing seat is reported, not fatal ==="
# No seatd socket must be reported but not fatal (logind can suffice).
reset
write_skel
SKEL="$TMP/skel"
write_live_stub
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=
eq "  exit code is 0" 0 "$rc"
has "  says there is no seatd socket" "no seatd socket at" "$out"

echo
echo "=== case 9: XDG_RUNTIME_DIR that is not a directory is refused ==="
reset
write_skel
SKEL="$TMP/skel"
printf 'not a directory\n' > "$TMP/notadir"
SUT_RUNTIME="$TMP/notadir"
printf '#!/bin/sh\nexit 0\n' > "$TMP/niri"; chmod +x "$TMP/niri"
out=$(run_sut "$TMP/niri" 5); rc=$?
SKEL=; SUT_RUNTIME=
eq "  exit code is 22 (runtime not usable)" 22 "$rc"
has "  says the path is not a directory" "which is not a directory" "$out"

echo
echo "=== case 10: usage ==="
out=$(sh "$SUT" --nonsense 2>&1); rc=$?
eq "  an unknown option exits 24" 24 "$rc"
out=$(sh "$SUT" --help 2>&1); rc=$?
eq "  --help exits 0" 0 "$rc"
has "  --help lists the exit codes" "23 niri exited while starting" "$out"
has "  --help documents the component flags" "--no" "$out"
hasnt "  --help no longer lists a retired exit 25" "25 no way to ask" "$out"

echo
echo "=== case 11: a component is missing with no terminal, so it installs ==="
# No tty means install by default: a question nobody can see must not block.
reset
write_skel
SKEL="$TMP/skel"
write_live_stub
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
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=; APPS_MANIFEST=; INGOT_STUB=
eq "  exit code is 0 (installed, then started)" 0 "$rc"
has "  says the components are being installed" "installing the missing components" "$out"
has "  the installer really was invoked" "ingot-stub: install firefox" "$out"
hasnt "  never printed the question" "do you want to install" "$out"

echo
echo "=== case 12: --no skips the install and the session starts anyway ==="
reset
write_skel
SKEL="$TMP/skel"
write_live_stub
cat > "$TMP/apps" <<EOF
firefox $TMP/missing/firefox ingot
EOF
APPS_MANIFEST="$TMP/apps"
out=$(run_sut "$TMP/niri" 80 --no); rc=$?
SKEL=; APPS_MANIFEST=
eq "  exit code is 0" 0 "$rc"
has "  says it is not installing components" "not installing components" "$out"
hasnt "  never printed the question" "do you want to install" "$out"

echo
echo "=== case 13: --yes installs the missing components, then proceeds ==="
reset
write_skel
SKEL="$TMP/skel"
write_live_stub
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
out=$(run_sut "$TMP/niri" 80 --yes); rc=$?
SKEL=; APPS_MANIFEST=; INGOT_STUB=
eq "  exit code is 0" 0 "$rc"
has "  the installer really was invoked" "ingot-stub: install firefox" "$out"
has "  says the components were installed" "components installed, running niri now" "$out"

echo
echo "=== case 14: a present component is not offered at all ==="
reset
write_skel
SKEL="$TMP/skel"
write_live_stub
: > "$TMP/present-probe"
cat > "$TMP/apps" <<EOF
firefox $TMP/present-probe ingot
EOF
APPS_MANIFEST="$TMP/apps"
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=; APPS_MANIFEST=
eq "  exit code is 0" 0 "$rc"
hasnt "  never asked about components" "do you want to install" "$out"

echo
echo "=== case 15: a seatd socket is reported when one is listening ==="
# A real launch: -S needs a listening unix socket, so python binds one.
if ! command -v python3 >/dev/null 2>&1; then
    echo "  skip  no python3 on this host (CI has one)"
else
    reset
    write_skel
    SKEL="$TMP/skel"
    python3 -c "import socket,time
s=socket.socket(socket.AF_UNIX); s.bind('$TMP/seatd.sock'); s.listen(1)
time.sleep(60)" &
    seatsrv=$!
    sleep 1
    SUT_SEATD="$TMP/seatd.sock"
    write_live_stub
    out=$(run_sut "$TMP/niri" 80); rc=$?
    kill "$seatsrv" 2>/dev/null
    SKEL=; SUT_SEATD=
    eq "  exit code is 0" 0 "$rc"
    has "  reports the seatd socket" "seat: $TMP/seatd.sock" "$out"
    hasnt "  does not warn about a missing seat" "no seatd socket" "$out"
fi

echo
echo "=== case 16: an unattended first start seeds the config without asking ==="
# No config prompt exists; a first boot must seed silently without ingot.
reset
write_skel
SKEL="$TMP/skel"
write_live_stub
cat > "$TMP/ingot" <<'EOF'
#!/bin/sh
echo "ingot-stub: $*" >&2
exit 0
EOF
chmod +x "$TMP/ingot"
INGOT_STUB="$TMP/ingot"
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=; INGOT_STUB=
eq "  exit code is 0" 0 "$rc"
has "  still seeds the shipped config" "session config seeded" "$out"
hasnt "  never invokes the installer for config" "ingot-stub: install" "$out"
hasnt "  never puts a config question to a terminal" "config files?" "$out"

echo
echo "=== case 17: a record with no type is named, per device ==="
# A missing type on one device must be named, not hidden by an any-record check.
setup_input_case
printf 'I:1\nE:ID_INPUT=1\n' > "$TMP/udevdata/c13:3"
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=; SUT_INPUT_SYS=; SUT_UDEV_DATA=
eq "  exit code is 0" 0 "$rc"
has "  says a device will be ignored" "will ignore at least one input device" "$out"
has "  names the device it will drop" "AT Translated Set 2 keyboard" "$out"
has "  shows the event node" "event0" "$out"
has "  says the record has no type line" "no ID_INPUT_* line" "$out"
has "  shows the working mouse with its type" \
    'Generic Explorer Mouse" -> E:ID_INPUT_MOUSE=1' "$out"
hasnt "  does not flag the typed mouse as dropped" \
    'Generic Explorer Mouse" -> (no ID_INPUT_* line' "$out"

echo
echo "=== case 18: every device typed -> the preflight stays quiet ==="
setup_input_case
printf 'I:1\nE:ID_INPUT=1\nE:ID_INPUT_KEY=1\nE:ID_INPUT_KEYBOARD=1\n' \
    > "$TMP/udevdata/c13:3"
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=; SUT_INPUT_SYS=; SUT_UDEV_DATA=
eq "  exit code is 0" 0 "$rc"
hasnt "  says nothing about dropping devices" \
    "will ignore at least one input device" "$out"

echo
echo "=== case 19: a device with no record at all is named too ==="
# With no records, report what is missing rather than claiming a device list.
setup_input_case
rm -f "$TMP/udevdata"/c*
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=; SUT_INPUT_SYS=; SUT_UDEV_DATA=
eq "  exit code is 0" 0 "$rc"
has "  says there are no records" "no libudev records under" "$out"

echo
echo "=== case 20: a partial home is repaired, and the user's files are kept ==="
# A partial home needs repair: missing files appear, existing user files stay.
reset
write_skel
SKEL="$TMP/skel"
mkdir -p "$TMP/skel/.config/waybar/scripts"
: > "$TMP/skel/.config/waybar/scripts/window.sh"
mkdir -p "$TMP/home/.config/niri" "$TMP/home/.config/waybar"
printf '// the user edited this\n' > "$TMP/home/.config/niri/config.kdl"
printf '{}\n' > "$TMP/home/.config/waybar/config.jsonc"
write_live_stub
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=
eq "  exit code is 0" 0 "$rc"
has "  says it repaired the config" "repaired the session config: added 1 missing file(s)" "$out"
hasnt "  does not re-seed over a config that exists" "seeding the session config" "$out"
eq "  the user's config.kdl is untouched" "// the user edited this" \
   "$(cat "$TMP/home/.config/niri/config.kdl" 2>/dev/null)"
if [ -f "$TMP/home/.config/waybar/scripts/window.sh" ]; then
    ok "  the missing file was put back"
else
    bad "  the missing file was put back" "no waybar/scripts/window.sh in the home"
fi

echo
echo "=== case 21: a home that is already whole is left alone ==="
reset
write_skel
SKEL="$TMP/skel"
mkdir -p "$TMP/home/.config/niri" "$TMP/home/.config/waybar"
printf '// cfg\n' > "$TMP/home/.config/niri/config.kdl"
printf '{}\n' > "$TMP/home/.config/waybar/config.jsonc"
write_live_stub
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=
eq "  exit code is 0" 0 "$rc"
hasnt "  says nothing about repairing" "repaired the session config" "$out"
hasnt "  does not re-seed" "seeding the session config" "$out"
eq "  the config is byte-for-byte what it was" "// cfg" \
   "$(cat "$TMP/home/.config/niri/config.kdl" 2>/dev/null)"

echo
echo "=== case 22: a fresh seed carries the exec bits ==="
# Exec bits must survive seeding or the bar's helper scripts never run.
reset
write_skel
SKEL="$TMP/skel"
mkdir -p "$TMP/skel/.config/waybar/scripts"
printf '#!/bin/sh\ntrue\n' > "$TMP/skel/.config/waybar/scripts/workspaces.sh"
chmod 0755 "$TMP/skel/.config/waybar/scripts/workspaces.sh"
write_live_stub
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=
eq "  exit code is 0" 0 "$rc"
has "  seeds the shipped config" "session config seeded" "$out"
if [ -x "$TMP/home/.config/waybar/scripts/workspaces.sh" ]; then
    ok "  the script arrived executable"
else
    bad "  the script arrived executable" \
        "$(ls -l "$TMP/home/.config/waybar/scripts/" 2>/dev/null | tr '\n' '|')"
fi

echo
echo "=== case 23: a socket that appears but does not answer is not declared up ==="
# A stale socket file is not liveness: the IPC probe must answer first.
reset
write_skel
SKEL="$TMP/skel"
cat > "$TMP/niri" <<EOF
#!/bin/sh
if [ "\$1" = msg ]; then exit 1; fi
mkdir -p "\$XDG_RUNTIME_DIR"
sock="\$XDG_RUNTIME_DIR/niri.wayland-1.\$\$.sock"
: > "\$sock"
trap 'rm -f "\$sock"' EXIT
sleep 2
EOF
chmod +x "$TMP/niri"
out=$(run_sut "$TMP/niri" 5); rc=$?
SKEL=
eq "  exit code is 0 (the session still ran)" 0 "$rc"
has "  says the probe got no answer" "no answering IPC socket" "$out"
hasnt "  does not claim the compositor came up" "niri is up" "$out"

echo
echo "=== case 24: the compositor is told which session it is ==="
reset
write_skel
SKEL="$TMP/skel"
write_live_stub
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=
eq "  exit code is 0" 0 "$rc"
eq "  session type/desktop reach the compositor" \
   "wayland|niri|niri|niri" "$(sed -n 's/^IDENTITY=//p' "$TMP/niri.env" 2>/dev/null)"

# Session identity must precede dbus-launch so activated services inherit it.
ident_line=$(grep -n '^XDG_SESSION_TYPE=wayland' "$SUT" | head -n1 | cut -d: -f1)
bus_line=$(grep -n 'dbus-launch --sh-syntax' "$SUT" | head -n1 | cut -d: -f1)
if [ -n "$ident_line" ] && [ -n "$bus_line" ] && [ "$ident_line" -lt "$bus_line" ]; then
    ok "  the session identity is set before the bus starts"
else
    bad "  the session identity is set before the bus starts" \
        "identity at ${ident_line:-?}, bus at ${bus_line:-?}"
fi
if grep -qF 'dbus-update-activation-environment XDG_SESSION_TYPE' "$SUT"; then
    ok "  pushes the identity into the bus activation environment"
else
    bad "  pushes the identity into the bus activation environment" "no call found"
fi

# Both halves of the overlay include must exist or tweaks silently vanish.
echo
echo "=== case 25: the copper tweaks overlay is present and wired ==="
TWEAKS="$REPO/iso/rootfs-overlay/usr/share/copper/niri-overlay/.config/niri/copper-tweaks.kdl"
if [ -s "$TWEAKS" ]; then
    ok "  copper-tweaks.kdl ships with content"
else
    bad "  copper-tweaks.kdl ships with content" "missing or empty: $TWEAKS"
fi
if grep -q '^animations {' "$TWEAKS" && grep -q 'workspace-switch {' "$TWEAKS"; then
    ok "  the overlay tunes the animation springs"
else
    bad "  the overlay tunes the animation springs" "no animations/workspace-switch node"
fi
if grep -q 'match is-active=false' "$TWEAKS" && grep -q 'opacity 0\.' "$TWEAKS"; then
    ok "  the overlay dims unfocused windows"
else
    bad "  the overlay dims unfocused windows" "no is-active=false opacity rule"
fi
if grep -q $'\r' "$TWEAKS"; then
    bad "  the overlay has no CR bytes" "CRLF found; the target has no editor to fix it"
else
    ok "  the overlay has no CR bytes"
fi
if grep -qF 'include "copper-tweaks.kdl"' "$REPO/iso/build.sh" &&
   grep -q 'niri-overlay/.config/niri/copper-tweaks.kdl' "$REPO/iso/build.sh"; then
    ok "  build_niri includes the overlay and stamps it as an input"
else
    bad "  build_niri includes the overlay and stamps it as an input" \
        "the include or a stamp input is gone from iso/build.sh"
fi

echo
echo "=== case 26: VMware with a render node keeps hardware rendering ==="
# VMware with a render node must keep it: forcing llvmpipe left a live socket
# with nothing drawn. SUT_VMWARE=1 stands in for the DMI match.
reset
write_skel
SKEL="$TMP/skel"
: > "$TMP/dri/renderD128"
SUT_DRM="$TMP/dri"
SUT_VMWARE=1
write_live_stub
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=; SUT_DRM=; SUT_VMWARE=
eq "  exit code is 0" 0 "$rc"
has "  says it kept the 3D render node" \
    "keeping the 3D render node" "$out"
hasnt "  does not force software rendering" "forcing software rendering" "$out"
eq "  LIBGL_ALWAYS_SOFTWARE was left unset" "" \
    "$(sed -n 's/^LIBGL_ALWAYS_SOFTWARE=//p' "$TMP/niri.env" 2>/dev/null)"
eq "  GBM_ALWAYS_SOFTWARE was left unset" "" \
    "$(sed -n 's/^GBM_ALWAYS_SOFTWARE=//p' "$TMP/niri.env" 2>/dev/null)"
eq "  GALLIUM_DRIVER was left unset" "" \
    "$(sed -n 's/^GALLIUM_DRIVER=//p' "$TMP/niri.env" 2>/dev/null)"
vmconfig=$(sed -n 's/^NIRI_CONFIG=//p' "$TMP/niri.env" 2>/dev/null)
eq "  the wrapper lives in the runtime dir" \
    "$TMP/run/niri-vmware-config.kdl" "$vmconfig"
if [ -s "$vmconfig" ] 2>/dev/null; then
    ok "  the generated niri config exists and is not empty"
else
    bad "  the generated niri config exists and is not empty" "NIRI_CONFIG='$vmconfig'"
fi
eq "  the wrapper includes the user's config" \
    "include \"$TMP/home/.config/niri/config.kdl\"" \
    "$(sed -n '1p' "$vmconfig" 2>/dev/null)"
if grep -q '^    disable-direct-scanout$' "$vmconfig" 2>/dev/null &&
   grep -q '^    disable-cursor-plane$' "$vmconfig" 2>/dev/null; then
    ok "  direct scanout and the cursor plane are disabled"
else
    bad "  direct scanout and the cursor plane are disabled" \
        "$(cat "$vmconfig" 2>/dev/null | tr '\n' '|')"
fi
eq "  the user's config.kdl was not rewritten" "// cfg" \
    "$(cat "$TMP/home/.config/niri/config.kdl" 2>/dev/null)"

echo
echo "=== case 27: a quote in the home path is escaped in the KDL include ==="
# KDL needs an escaped quote or the VMware wrapper is a config error.
reset
mkdir -p "$TMP/home\"q"
write_skel
SKEL="$TMP/skel"
SUT_HOME="$TMP/home\"q"
SUT_VMWARE=1
write_live_stub
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=; SUT_HOME=; SUT_VMWARE=
eq "  exit code is 0" 0 "$rc"
vmconfig=$(sed -n 's/^NIRI_CONFIG=//p' "$TMP/niri.env" 2>/dev/null)
eq "  the include escapes the quote" \
    "include \"$TMP/home\\\"q/.config/niri/config.kdl\"" \
    "$(sed -n '1p' "$vmconfig" 2>/dev/null)"

echo
echo "=== case 28: VMware with no render node still forces software rendering ==="
# No render node still forces software rendering, VMware or not.
reset
write_skel
SKEL="$TMP/skel"
SUT_VMWARE=1
write_live_stub
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=; SUT_VMWARE=
eq "  exit code is 0" 0 "$rc"
has "  says it forced software rendering" "forcing software rendering" "$out"
eq "  GBM_ALWAYS_SOFTWARE reached the compositor" 1 \
    "$(sed -n 's/^GBM_ALWAYS_SOFTWARE=//p' "$TMP/niri.env" 2>/dev/null)"

pkill -f "$TMP" 2>/dev/null
rm -rf "$TMP"
echo
if [ "$fails" -ne 0 ]; then
    echo "FAILED: $fails check(s)"
    exit 1
fi
echo "all startniri checks passed"
