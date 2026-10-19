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
    # Point the input preflight at a tree that does not exist unless a case
    # builds one: on a Linux host /sys/class/input is real and has devices, and
    # the preflight would then narrate this machine's own input instead of the
    # case under test.
    SUT_INPUT_SYS=${SUT_INPUT_SYS:-$TMP/no-input}
    SUT_UDEV_DATA=${SUT_UDEV_DATA:-$TMP/no-udevdata}
    # stdin is /dev/null, so the launcher's interactive questions are never put
    # to a terminal here: every case below is deterministic whether or not the
    # person running the gate has one, and the pty case at the end drives the
    # one question that is meant to be interactive.
    HOME="$TMP/home" XDG_RUNTIME_DIR="$SUT_RUNTIME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/dummy-bus" \
    COPPER_HYPRLAND="$hypr" COPPER_HYPR_SKEL="$SKEL" \
    COPPER_SESSIONLOG="$TMP/hyprland.log" \
    COPPER_HYPR_APPS="${APPS_MANIFEST:-$TMP/no-apps}" \
    COPPER_INGOT="${INGOT_STUB:-ingot}" COPPER_SUDO="" \
    COPPER_DRM_DIR="$SUT_DRM" COPPER_SEATD_SOCK="$SUT_SEATD" \
    COPPER_INPUT_SYS="$SUT_INPUT_SYS" COPPER_UDEV_DATA="$SUT_UDEV_DATA" \
    WAIT_TRIES="$tries" sh "$SUT" "$@" < /dev/null 2>&1
}

# The one case that must see a real terminal. run_sut sends stdin from /dev/null,
# which is right for every deterministic case but hides the interactive config
# question; this runs the launcher inside `script` (a pty) with the same
# isolation and feeds it one line.
run_sut_pty() { # run_sut_pty <answer-line>
    printf '%s\n' "$1" | env \
        HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/dummy-bus" \
        COPPER_HYPRLAND="$TMP/Hyprland" COPPER_HYPR_SKEL="$TMP/skel" \
        COPPER_SESSIONLOG="$TMP/hyprland.log" COPPER_HYPR_APPS="$TMP/no-apps" \
        COPPER_INGOT="$TMP/ingot" COPPER_SUDO="" COPPER_DRM_DIR="$TMP/dri" \
        COPPER_SEATD_SOCK="$TMP/no-seatd.sock" WAIT_TRIES=80 \
        script -qec "sh '$SUT'" /dev/null 2>&1
}

# The config-question cases share one shape: a bare home, a shipped config to
# seed from, a compositor stub that comes up, and an ingot stub that records
# what it was asked to do. The helper leaves SKEL and INGOT_STUB set for
# run_sut; each case clears them after it.
setup_cfg_case() {
    reset
    mkdir -p "$TMP/skel/.config/hypr"
    printf -- '-- cfg\n' > "$TMP/skel/.config/hypr/hyprland.lua"
    cat > "$TMP/Hyprland" <<EOF
#!/bin/sh
mkdir -p "\$XDG_RUNTIME_DIR/hypr/gate"
: > "\$XDG_RUNTIME_DIR/hypr/gate/.socket.sock"
sleep 1
exit 0
EOF
    chmod +x "$TMP/Hyprland"
    cat > "$TMP/ingot" <<'EOF'
#!/bin/sh
echo "ingot-stub: $*" >&2
exit 0
EOF
    chmod +x "$TMP/ingot"
    SKEL="$TMP/skel"
    INGOT_STUB="$TMP/ingot"
}

# The input-records cases share one shape: a bare home, a config to seed from, a
# compositor that comes up, and a fake input tree under $TMP whose records the
# case decides. The preflight reads /sys/class/input and /run/udev/data for real,
# which is this host's own input on Linux, so run_sut points it at this tree
# instead. setup_input_case leaves SUT_INPUT_SYS and SUT_UDEV_DATA set; the
# caller clears them after the case.
setup_input_case() {
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

    # The two devices from the machine this bug was found on: an AT keyboard and
    # a PS/2 mouse, each with one event node carrying the device number its
    # record is named after. The mouse's record always names a type, because the
    # mouse works -- that is what makes the keyboard's silence the bug.
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

echo
echo "=== case 16: unattended, no flag -- uses the shipped config, installs nothing ==="
# The first Hyprland login, answered by nothing at all: the launcher must fall
# back to the config the image baked instead of blocking on a prompt no one can
# see. This is also the shape a first boot takes when it is not a terminal.
setup_cfg_case
out=$(run_sut "$TMP/Hyprland" 80); rc=$?
SKEL=; INGOT_STUB=
eq "  exit code is 0" 0 "$rc"
has "  says there is no terminal to ask on" "no terminal to ask about the config files" "$out"
hasnt "  never invokes the installer" "ingot-stub: install" "$out"
has "  still seeds the shipped config" "session config seeded" "$out"

echo
echo "=== case 17: --yes installs hypr-configs, then seeds ==="
setup_cfg_case
out=$(run_sut "$TMP/Hyprland" 80 --yes); rc=$?
SKEL=; INGOT_STUB=
eq "  exit code is 0" 0 "$rc"
has "  announces the config install" "installing the hyprland config files (hypr-configs)" "$out"
has "  the installer really was invoked" "ingot-stub: install hypr-configs" "$out"
has "  says the config was seeded" "session config seeded" "$out"
hasnt "  does not print the unattended message" "no terminal to ask about the config files" "$out"

echo
echo "=== case 18: --no keeps the shipped config, installs nothing ==="
setup_cfg_case
out=$(run_sut "$TMP/Hyprland" 80 --no); rc=$?
SKEL=; INGOT_STUB=
eq "  exit code is 0" 0 "$rc"
has "  says it is not installing the config" "not installing the config files (--no)" "$out"
hasnt "  never invokes the installer" "ingot-stub: install" "$out"
has "  still seeds the shipped config" "session config seeded" "$out"

echo
echo "=== case 19: the interactive question (needs a pty) ==="
# The only case that must be answered by a person: run_sut sends stdin from
# /dev/null, so the question only exists under a terminal. `script` supplies
# one; where it is absent (the Windows box this tree is kept on) the case is
# skipped rather than failed, the same shape as the python3-gated seat case.
if ! command -v script >/dev/null 2>&1; then
    echo "  skip  no 'script' for a pty on this host (CI has one)"
else
    setup_cfg_case
    out=$(run_sut_pty 'n'); rc=$?
    eq "  'n' run still starts the session" 0 "$rc"
    has "  the question is put to the terminal" "would you like your hyprland config files?" "$out"
    has "  'n' prints the ellipsis" "..." "$out"
    has "  'n' prints the tsundere line" "b-baka! humph" "$out"
    hasnt "  'n' did not invoke the installer" "ingot-stub: install" "$out"
    has "  'n' still seeds the shipped config" "session config seeded" "$out"

    setup_cfg_case
    out=$(run_sut_pty ''); rc=$?
    eq "  an empty answer still starts the session" 0 "$rc"
    has "  Enter defaults to installing" "installing the hyprland config files (hypr-configs)" "$out"
    has "  the installer really was invoked" "ingot-stub: install hypr-configs" "$out"
fi

echo
echo "=== case 20: a record with no type is named, per device ==="
# The shape this was written for: the mouse's record names a type (the pointer
# works), the keyboard's names only ID_INPUT, so libinput drops it and the
# session comes up with a pointer that moves and a keyboard that types nowhere.
# The old preflight asked "does any record carry a type" and went quiet here;
# it has to name the device instead.
setup_input_case
printf 'I:1\nE:ID_INPUT=1\n' > "$TMP/udevdata/c13:3"
out=$(run_sut "$TMP/Hyprland" 80); rc=$?
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
echo "=== case 21: every device typed -> the preflight stays quiet ==="
setup_input_case
printf 'I:1\nE:ID_INPUT=1\nE:ID_INPUT_KEY=1\nE:ID_INPUT_KEYBOARD=1\n' \
    > "$TMP/udevdata/c13:3"
out=$(run_sut "$TMP/Hyprland" 80); rc=$?
SKEL=; SUT_INPUT_SYS=; SUT_UDEV_DATA=
eq "  exit code is 0" 0 "$rc"
hasnt "  says nothing about dropping devices" \
    "will ignore at least one input device" "$out"

echo
echo "=== case 22: a device with no record at all is named too ==="
# No event node has a record: the first branch fires, and it must not claim to
# list devices when it cannot, but it must say what is missing.
setup_input_case
rm -f "$TMP/udevdata"/c*
out=$(run_sut "$TMP/Hyprland" 80); rc=$?
SKEL=; SUT_INPUT_SYS=; SUT_UDEV_DATA=
eq "  exit code is 0" 0 "$rc"
has "  says there are no records" "no libudev records under" "$out"

echo
echo "=== case 23: a partial home is repaired, and the user's files are kept ==="
# The home a bug-26-era image left behind: hyprland.lua is there, so the seeding
# branch never runs again, but the zero-byte Lua stub the config require()s was
# dropped by that build's empty-file gate. The old seeding could not have fixed
# it even if it had run -- busybox's `cp -a -n` skips an existing directory
# outright -- so this is the shape the repair pass exists for. Two things have
# to be true at once: the missing file appears, and the file that was already
# there is not rewritten.
setup_cfg_case
mkdir -p "$TMP/skel/.config/hypr/conf/environments"
: > "$TMP/skel/.config/hypr/conf/environments/default.lua"
mkdir -p "$TMP/home/.config/hypr"
printf -- '-- the user edited this\n' > "$TMP/home/.config/hypr/hyprland.lua"
out=$(run_sut "$TMP/Hyprland" 80); rc=$?
SKEL=; INGOT_STUB=
eq "  exit code is 0" 0 "$rc"
has "  says it repaired the config" "repaired the session config: added 1 missing file(s)" "$out"
hasnt "  does not re-seed over a config that exists" "seeding the session config" "$out"
hasnt "  does not offer the config install again" "installing the hyprland config files" "$out"
eq "  the user's hyprland.lua is untouched" "-- the user edited this" \
   "$(cat "$TMP/home/.config/hypr/hyprland.lua" 2>/dev/null)"
if [ -f "$TMP/home/.config/hypr/conf/environments/default.lua" ]; then
    ok "  the missing stub was put back"
else
    bad "  the missing stub was put back" "no conf/environments/default.lua in the home"
fi

echo
echo "=== case 24: a home that is already whole is left alone ==="
setup_cfg_case
mkdir -p "$TMP/home/.config/hypr"
printf -- '-- cfg\n' > "$TMP/home/.config/hypr/hyprland.lua"
out=$(run_sut "$TMP/Hyprland" 80); rc=$?
SKEL=; INGOT_STUB=
eq "  exit code is 0" 0 "$rc"
hasnt "  says nothing about repairing" "repaired the session config" "$out"
hasnt "  does not re-seed" "seeding the session config" "$out"
eq "  the config is byte-for-byte what it was" "-- cfg" \
   "$(cat "$TMP/home/.config/hypr/hyprland.lua" 2>/dev/null)"

echo
echo "=== case 25: a fresh seed carries the empty stubs and the exec bits ==="
# Bug 26 in one case: the tree ships zero-byte Lua include stubs whose presence
# and emptiness are both load-bearing (empty is valid Lua), and scripts whose +x
# bit is restored at build time. A seed that drops either gives a config that
# partly loads or a session with no bar.
setup_cfg_case
mkdir -p "$TMP/skel/.config/hypr/conf/environments" "$TMP/skel/.config/ml4w/scripts"
: > "$TMP/skel/.config/hypr/conf/environments/default.lua"
printf '#!/bin/sh\ntrue\n' > "$TMP/skel/.config/ml4w/scripts/ml4w-autostart"
chmod 0755 "$TMP/skel/.config/ml4w/scripts/ml4w-autostart"
out=$(run_sut "$TMP/Hyprland" 80); rc=$?
SKEL=; INGOT_STUB=
eq "  exit code is 0" 0 "$rc"
has "  seeds the shipped config" "session config seeded" "$out"
if [ -f "$TMP/home/.config/hypr/conf/environments/default.lua" ] &&
   [ ! -s "$TMP/home/.config/hypr/conf/environments/default.lua" ]; then
    ok "  the zero-byte Lua stub arrived, and still empty"
else
    bad "  the zero-byte Lua stub arrived, and still empty" \
        "$(ls -l "$TMP/home/.config/hypr/conf/environments/" 2>/dev/null | tr '\n' '|')"
fi
if [ -x "$TMP/home/.config/ml4w/scripts/ml4w-autostart" ]; then
    ok "  the script arrived executable"
else
    bad "  the script arrived executable" \
        "$(ls -l "$TMP/home/.config/ml4w/scripts/" 2>/dev/null | tr '\n' '|')"
fi

pkill -f "$TMP" 2>/dev/null
rm -rf "$TMP"
echo
if [ "$fails" -ne 0 ]; then
    echo "FAILED: $fails check(s)"
    exit 1
fi
echo "all starthyprland checks passed"
