#!/bin/sh
# Prove starthyprland does the right thing, and fails the right way.
#
# handcrafted by dragon
#
# Hyprland is a Wayland compositor: there is no second process to hand a display
# to, so the launcher's whole job is the preparation around the compositor --
# seed the config, make the runtime directory, start the session bus, notice that
# the seat is missing, choose a renderer -- and then the exit-code contract when
# one of those cannot be done or the compositor dies on the way up. Every one of
# those gets a case here, with the exact exit code asserted: the codes are a
# contract, and a script branching on them breaks silently when one moves.
#
# The compositor is stubbed. The real Hyprland is a glibc binary linked against
# the PPA's Wayland/DRM stack, which this image is not, so it cannot run here no
# matter what. What is under test is the launcher: the ordering, the preparation,
# the codes, and the environment the compositor is handed.
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

hasnt() {
    case "$3" in
        *"$2"*) bad "$1" "should not have mentioned '$2'; it said: $(printf '%s' "$3" | tr '\n' '|')" ;;
        *)      ok "$1" ;;
    esac
}

[ -f "$SUT" ] || { echo "  FAIL  $SUT does not exist"; exit 1; }

# --- isolation -------------------------------------------------------------
#
# Every case runs through run_sut, which points the launcher at a private home, a
# private runtime directory, a private skel and a private DRM directory, and sets
# a dummy DBUS_SESSION_BUS_ADDRESS so it never starts a real bus. Without the
# private home, the config-seeding step writes into the real $HOME; without the
# private DRM directory, the renderer choice reads this machine's /dev/dri.
reset() {
    rm -rf "$TMP"
    mkdir -p "$TMP/home" "$TMP/run" "$TMP/.X11-unix" "$TMP/dri"
}

run_sut() {
    hypr=$1
    tries=$2
    shift 2
    SKEL=${SKEL:-$TMP/no-skel}
    APPS_MANIFEST=${APPS_MANIFEST:-}
    INGOT_STUB=${INGOT_STUB:-}
    SUT_DRM=${SUT_DRM:-$TMP/dri}
    SUT_SEATD=${SUT_SEATD:-$TMP/no-seatd.sock}
    SUT_RUNTIME=${SUT_RUNTIME:-$TMP/run}
    HOME="$TMP/home" XDG_RUNTIME_DIR="$SUT_RUNTIME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/dummy-bus" \
    COPPER_HYPRLAND="$hypr" COPPER_HYPR_SKEL="$SKEL" \
    COPPER_SESSIONLOG="$TMP/hyprland.log" \
    COPPER_HYPR_APPS="${APPS_MANIFEST:-$TMP/no-apps}" \
    COPPER_INGOT="${INGOT_STUB:-ingot}" COPPER_SUDO="" \
    COPPER_DRM_DIR="$SUT_DRM" COPPER_SEATD_SOCK="$SUT_SEATD" \
    WAIT_TRIES="$tries" sh "$SUT" "$@" 2>&1
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
out=$(run_sut "$TMP/nope/Hyprland" 40); rc=$?
eq "  exit code is 20 (no Hyprland)" 20 "$rc"
has "  names the compositor it looked for" "$TMP/nope/Hyprland" "$out"
has "  says the hypr stage stages it" "hypr stage" "$out"

echo
echo "=== case 2: --check starts nothing ==="
reset
printf '#!/bin/sh\nexit 99\n' > "$TMP/Hyprland"; chmod +x "$TMP/Hyprland"
out=$(run_sut "$TMP/Hyprland" 5 --check); rc=$?
eq "  exit code is 0 even with pieces missing" 0 "$rc"
has "  reports the compositor it found" "found Hyprland" "$out"
has "  reports the config it did not find" "NO session config" "$out"
hasnt "  claims to have started something" "starting Hyprland" "$out"

echo
echo "=== case 3: compositor present, no config and none to seed from ==="
reset
printf '#!/bin/sh\nexit 0\n' > "$TMP/Hyprland"; chmod +x "$TMP/Hyprland"
out=$(run_sut "$TMP/Hyprland" 5); rc=$?
eq "  exit code is 21 (no session config)" 21 "$rc"
has "  names the missing config" "no config in" "$out"
has "  says there is nothing to seed from" "no shipped tree" "$out"

echo
echo "=== case 4: the shipped tree seeds a bare home, then the session runs ==="
# The happy path. The stub writes the environment it was handed and drops an
# instance socket so the launcher's bounded wait sees the compositor come up.
reset
mkdir -p "$TMP/skel/.config/hypr"
printf -- '-- ml4w hyprland config\n' > "$TMP/skel/.config/hypr/hyprland.lua"
SKEL="$TMP/skel"
cat > "$TMP/Hyprland" <<EOF
#!/bin/sh
{
  echo "XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR"
  echo "WLR_RENDERER=\${WLR_RENDERER:-}"
  echo "LIBGL_ALWAYS_SOFTWARE=\${LIBGL_ALWAYS_SOFTWARE:-}"
  echo "DBUS_SESSION_BUS_ADDRESS=\${DBUS_SESSION_BUS_ADDRESS:-}"
} > "$TMP/hypr.env"
mkdir -p "\$XDG_RUNTIME_DIR/hypr/gate"
: > "\$XDG_RUNTIME_DIR/hypr/gate/.socket.sock"
sleep 1
exit 0
EOF
chmod +x "$TMP/Hyprland"
out=$(run_sut "$TMP/Hyprland" 80); rc=$?
SKEL=
eq "  exit code is 0" 0 "$rc"
has "  says it seeded the config" "seeding the session config" "$out"
has "  says the compositor came up" "Hyprland is up" "$out"
has "  says it started the compositor" "starting Hyprland" "$out"
if [ -f "$TMP/home/.config/hypr/hyprland.lua" ]; then
    ok "  the config landed in the user's home"
else
    bad "  the config landed in the user's home" "no $TMP/home/.config/hypr/hyprland.lua"
fi
eq "  the compositor got the runtime directory" "$TMP/run" \
   "$(sed -n 's/^XDG_RUNTIME_DIR=//p' "$TMP/hypr.env" 2>/dev/null)"
eq "  the compositor got the session bus" "unix:path=$TMP/dummy-bus" \
   "$(sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' "$TMP/hypr.env" 2>/dev/null)"

echo
echo "=== case 5: no render node forces software rendering ==="
# $TMP/dri exists and has no renderD* node, which is the VM-with-no-3D shape.
has "  says it forced software rendering" "forcing software rendering" "$out"
eq "  WLR_RENDERER reached the compositor" "pixman" \
   "$(sed -n 's/^WLR_RENDERER=//p' "$TMP/hypr.env" 2>/dev/null)"
eq "  LIBGL_ALWAYS_SOFTWARE reached the compositor" 1 \
   "$(sed -n 's/^LIBGL_ALWAYS_SOFTWARE=//p' "$TMP/hypr.env" 2>/dev/null)"

echo
echo "=== case 6: a render node means hardware rendering, nothing forced ==="
reset
mkdir -p "$TMP/skel/.config/hypr"
printf -- '-- ml4w hyprland config\n' > "$TMP/skel/.config/hypr/hyprland.lua"
SKEL="$TMP/skel"
: > "$TMP/dri/renderD128"
SUT_DRM="$TMP/dri"
cat > "$TMP/Hyprland" <<EOF
#!/bin/sh
{
  echo "WLR_RENDERER=\${WLR_RENDERER:-}"
  echo "LIBGL_ALWAYS_SOFTWARE=\${LIBGL_ALWAYS_SOFTWARE:-}"
} > "$TMP/hypr.env"
mkdir -p "\$XDG_RUNTIME_DIR/hypr/gate"
: > "\$XDG_RUNTIME_DIR/hypr/gate/.socket.sock"
sleep 1
exit 0
EOF
chmod +x "$TMP/Hyprland"
out=$(run_sut "$TMP/Hyprland" 80); rc=$?
SKEL=; SUT_DRM=
eq "  exit code is 0" 0 "$rc"
hasnt "  does not force software rendering" "forcing software rendering" "$out"
eq "  WLR_RENDERER was left unset" "" \
   "$(sed -n 's/^WLR_RENDERER=//p' "$TMP/hypr.env" 2>/dev/null)"

echo
echo "=== case 7: the compositor dies on the way up ==="
# With a config in place, so the launch actually reaches the compositor rather
# than stopping at case 3's early exit.
reset
mkdir -p "$TMP/skel/.config/hypr"
printf -- '-- cfg\n' > "$TMP/skel/.config/hypr/hyprland.lua"
SKEL="$TMP/skel"
printf '#!/bin/sh\necho "(EE) no seat: cannot open /dev/dri/card0"\nexit 1\n' > "$TMP/Hyprland"
chmod +x "$TMP/Hyprland"
out=$(run_sut "$TMP/Hyprland" 40); rc=$?
SKEL=
eq "  exit code is 23 (exited while starting)" 23 "$rc"
has "  shows the compositor's own log" "cannot open /dev/dri/card0" "$out"

echo
echo "=== case 8: a missing seat is reported, not fatal ==="
# No seatd socket: the launcher must say so and still start the compositor,
# because a machine with a working logind would not need seatd at all.
reset
mkdir -p "$TMP/skel/.config/hypr"
printf -- '-- cfg\n' > "$TMP/skel/.config/hypr/hyprland.lua"
SKEL="$TMP/skel"
cat > "$TMP/Hyprland" <<EOF
#!/bin/sh
mkdir -p "\$XDG_RUNTIME_DIR/hypr/gate"
: > "\$XDG_RUNTIME_DIR/hypr/gate/.socket.sock"
sleep 1
exit 0
EOF
chmod +x "$TMP/Hyprland"
out=$(run_sut "$TMP/Hyprland" 80); rc=$?
SKEL=
eq "  exit code is 0" 0 "$rc"
has "  says there is no seatd socket" "no seatd socket at" "$out"

echo
echo "=== case 9: XDG_RUNTIME_DIR that is not a directory is refused ==="
reset
mkdir -p "$TMP/skel/.config/hypr"
printf -- '-- cfg\n' > "$TMP/skel/.config/hypr/hyprland.lua"
SKEL="$TMP/skel"
printf 'not a directory\n' > "$TMP/notadir"
SUT_RUNTIME="$TMP/notadir"
printf '#!/bin/sh\nexit 0\n' > "$TMP/Hyprland"; chmod +x "$TMP/Hyprland"
out=$(run_sut "$TMP/Hyprland" 5); rc=$?
SKEL=; SUT_RUNTIME=
eq "  exit code is 22 (runtime not usable)" 22 "$rc"
has "  says the path is not a directory" "which is not a directory" "$out"

echo
echo "=== case 10: usage ==="
out=$(sh "$SUT" --nonsense 2>&1); rc=$?
eq "  an unknown option exits 24" 24 "$rc"
out=$(sh "$SUT" --help 2>&1); rc=$?
eq "  --help exits 0" 0 "$rc"
has "  --help lists the exit codes" "23 Hyprland exited while starting" "$out"
has "  --help documents the component flags" "--yes" "$out"
has "  --help lists exit 25" "25 no way to ask" "$out"

echo
echo "=== case 11: a component is missing, nothing to ask on, no --yes/--no ==="
reset
mkdir -p "$TMP/skel/.config/hypr"
printf -- '-- cfg\n' > "$TMP/skel/.config/hypr/hyprland.lua"
SKEL="$TMP/skel"
printf '#!/bin/sh\nexit 0\n' > "$TMP/Hyprland"; chmod +x "$TMP/Hyprland"
cat > "$TMP/apps" <<EOF
firefox $TMP/missing/firefox ingot
EOF
APPS_MANIFEST="$TMP/apps"
out=$(run_sut "$TMP/Hyprland" 5); rc=$?
SKEL=; APPS_MANIFEST=
eq "  exit code is 25 (cannot ask)" 25 "$rc"
has "  explains there is no terminal" "not a terminal" "$out"
has "  points at --yes" "--yes" "$out"

echo
echo "=== case 12: --no skips the install and the session starts anyway ==="
reset
mkdir -p "$TMP/skel/.config/hypr"
printf -- '-- cfg\n' > "$TMP/skel/.config/hypr/hyprland.lua"
SKEL="$TMP/skel"
cat > "$TMP/Hyprland" <<EOF
#!/bin/sh
mkdir -p "\$XDG_RUNTIME_DIR/hypr/gate"
: > "\$XDG_RUNTIME_DIR/hypr/gate/.socket.sock"
sleep 1
exit 0
EOF
chmod +x "$TMP/Hyprland"
cat > "$TMP/apps" <<EOF
firefox $TMP/missing/firefox ingot
EOF
APPS_MANIFEST="$TMP/apps"
out=$(run_sut "$TMP/Hyprland" 80 --no); rc=$?
SKEL=; APPS_MANIFEST=
eq "  exit code is 0" 0 "$rc"
has "  says it is not installing components" "not installing components" "$out"
hasnt "  never printed the question" "do you want to install" "$out"

echo
echo "=== case 13: --yes installs the missing components, then proceeds ==="
reset
mkdir -p "$TMP/skel/.config/hypr"
printf -- '-- cfg\n' > "$TMP/skel/.config/hypr/hyprland.lua"
SKEL="$TMP/skel"
cat > "$TMP/Hyprland" <<EOF
#!/bin/sh
mkdir -p "\$XDG_RUNTIME_DIR/hypr/gate"
: > "\$XDG_RUNTIME_DIR/hypr/gate/.socket.sock"
sleep 1
exit 0
EOF
chmod +x "$TMP/Hyprland"
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
out=$(run_sut "$TMP/Hyprland" 80 --yes); rc=$?
SKEL=; APPS_MANIFEST=; INGOT_STUB=
eq "  exit code is 0" 0 "$rc"
has "  the installer really was invoked" "ingot-stub: install firefox" "$out"
has "  says the components were installed" "components installed, running hyprland now" "$out"

echo
echo "=== case 14: a present component is not offered at all ==="
reset
mkdir -p "$TMP/skel/.config/hypr"
printf -- '-- cfg\n' > "$TMP/skel/.config/hypr/hyprland.lua"
SKEL="$TMP/skel"
: > "$TMP/present-probe"
cat > "$TMP/Hyprland" <<EOF
#!/bin/sh
mkdir -p "\$XDG_RUNTIME_DIR/hypr/gate"
: > "\$XDG_RUNTIME_DIR/hypr/gate/.socket.sock"
sleep 1
exit 0
EOF
chmod +x "$TMP/Hyprland"
cat > "$TMP/apps" <<EOF
firefox $TMP/present-probe ingot
EOF
APPS_MANIFEST="$TMP/apps"
out=$(run_sut "$TMP/Hyprland" 80); rc=$?
SKEL=; APPS_MANIFEST=
eq "  exit code is 0" 0 "$rc"
hasnt "  never asked about components" "do you want to install" "$out"

echo
echo "=== case 15: a seatd socket is reported when one is listening ==="
# A real launch, not --check: the seat line is printed on the way to the
# compositor. The socket is a real unix socket, bound by python, because -S is
# what the launcher tests for.
reset
mkdir -p "$TMP/skel/.config/hypr"
printf -- '-- cfg\n' > "$TMP/skel/.config/hypr/hyprland.lua"
SKEL="$TMP/skel"
python3 -c "import socket,time
s=socket.socket(socket.AF_UNIX); s.bind('$TMP/seatd.sock'); s.listen(1)
time.sleep(60)" &
seatsrv=$!
sleep 1
SUT_SEATD="$TMP/seatd.sock"
cat > "$TMP/Hyprland" <<EOF
#!/bin/sh
mkdir -p "\$XDG_RUNTIME_DIR/hypr/gate"
: > "\$XDG_RUNTIME_DIR/hypr/gate/.socket.sock"
sleep 1
exit 0
EOF
chmod +x "$TMP/Hyprland"
out=$(run_sut "$TMP/Hyprland" 80); rc=$?
kill "$seatsrv" 2>/dev/null
SKEL=; SUT_SEATD=
eq "  exit code is 0" 0 "$rc"
has "  reports the seatd socket" "seat: $TMP/seatd.sock" "$out"
hasnt "  does not warn about a missing seat" "no seatd socket" "$out"

pkill -f "$TMP" 2>/dev/null
rm -rf "$TMP"
echo
if [ "$fails" -ne 0 ]; then
    echo "FAILED: $fails check(s)"
    exit 1
fi
echo "all starthyprland checks passed"
