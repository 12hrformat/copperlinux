#!/bin/sh
# Prove startniri does the right thing, and fails the right way.
#
# niri is a Wayland compositor: there is no second process to hand a display
# to, so the launcher's whole job is the preparation around the compositor --
# seed the config, make the runtime directory, start the session bus, notice
# that the seat is missing, choose a renderer -- and then the exit-code
# contract when one of those cannot be done or the compositor dies on the way
# up. Every one of those gets a case here, with the exact exit code asserted:
# the codes are a contract, and a script branching on them breaks silently
# when one moves.
#
# The compositor is stubbed. The real niri is a glibc binary linked against the
# PPA's Wayland/DRM stack, which this image is not, so it cannot run here no
# matter what. What is under test is the launcher: the ordering, the
# preparation, the codes, and the environment the compositor is handed.
#
# The stub answers two ways, because niri itself is both binaries: `--session`
# is the compositor, and `msg --json version` is the liveness probe that the
# launcher runs against the instance socket. The socket is a plain file whose
# name carries the stub's pid and the wayland socket name, which is exactly the
# name niri uses.
#
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
    niri=$1
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
    # stdin is /dev/null, so the launcher's interactive question is never put
    # to a terminal here: every case below is deterministic whether or not the
    # person running the gate has one.
    HOME="$TMP/home" XDG_RUNTIME_DIR="$SUT_RUNTIME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/dummy-bus" \
    COPPER_NIRI="$niri" COPPER_NIRI_SKEL="$SKEL" \
    COPPER_SESSIONLOG="$TMP/niri.log" \
    COPPER_NIRI_APPS="${APPS_MANIFEST:-$TMP/no-apps}" \
    COPPER_INGOT="${INGOT_STUB:-ingot}" COPPER_SUDO="" \
    COPPER_DRM_DIR="$SUT_DRM" COPPER_SEATD_SOCK="$SUT_SEATD" \
    COPPER_INPUT_SYS="$SUT_INPUT_SYS" COPPER_UDEV_DATA="$SUT_UDEV_DATA" \
    WAIT_TRIES="$tries" sh "$SUT" "$@" < /dev/null 2>&1
}

# A compositor stub that comes up: it records the environment it was handed and
# leaves the IPC socket the launcher looks for. `msg --json version` answers
# only when pointed at that socket, which is how the launcher proves liveness.
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

# The input-records cases share one shape: a bare home, a config to seed from, a
# compositor that comes up, and a fake input tree under $TMP whose records the
# case decides. The preflight reads /sys/class/input and /run/udev/data for real,
# which is this host's own input on Linux, so run_sut points it at this tree
# instead.
setup_input_case() {
    reset
    write_skel
    SKEL="$TMP/skel"
    write_live_stub

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
# The happy path. The stub records the environment it was handed and leaves the
# IPC socket the launcher's bounded wait probes.
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
# With a config in place, so the launch actually reaches the compositor rather
# than stopping at case 3's early exit.
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
# No seatd socket: the launcher must say so and still start the compositor,
# because a machine with a working logind would not need seatd at all.
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
has "  --help documents the component flags" "--yes" "$out"
has "  --help lists exit 25" "25 no way to ask" "$out"

echo
echo "=== case 11: a component is missing, nothing to ask on, no --yes/--no ==="
reset
write_skel
SKEL="$TMP/skel"
printf '#!/bin/sh\nexit 0\n' > "$TMP/niri"; chmod +x "$TMP/niri"
cat > "$TMP/apps" <<EOF
firefox $TMP/missing/firefox ingot
EOF
APPS_MANIFEST="$TMP/apps"
out=$(run_sut "$TMP/niri" 5); rc=$?
SKEL=; APPS_MANIFEST=
eq "  exit code is 25 (cannot ask)" 25 "$rc"
has "  explains there is no terminal" "not a terminal" "$out"
has "  points at --yes" "--yes" "$out"

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
# A real launch, not --check: the seat line is printed on the way to the
# compositor. The socket is a real unix socket, bound by python, because -S is
# what the launcher tests for.
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
# There is no config-question prompt in this launcher: the tree is pinned in the
# repo, so the shipped copy is simply seeded. The case is still worth asserting:
# a first boot is often not a terminal, and it must not block or reach for ingot.
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
# The shape this was written for: the mouse's record names a type (the pointer
# works), the keyboard's names only ID_INPUT, so libinput drops it and the
# session comes up with a pointer that moves and a keyboard that types nowhere.
# The old preflight asked "does any record carry a type" and went quiet here;
# it has to name the device instead.
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
# No event node has a record: the first branch fires, and it must not claim to
# list devices when it cannot, but it must say what is missing.
setup_input_case
rm -f "$TMP/udevdata"/c*
out=$(run_sut "$TMP/niri" 80); rc=$?
SKEL=; SUT_INPUT_SYS=; SUT_UDEV_DATA=
eq "  exit code is 0" 0 "$rc"
has "  says there are no records" "no libudev records under" "$out"

echo
echo "=== case 20: a partial home is repaired, and the user's files are kept ==="
# The home a bug-26-era image left behind: config.kdl is there, so the seeding
# branch never runs again, but the zero-byte include the old config required was
# dropped by that build's empty-file gate. The old seeding could not have fixed
# it even if it had run -- busybox's `cp -a -n` skips an existing directory
# outright -- so this is the shape the repair pass exists for. Two things have
# to be true at once: the missing file appears, and the file that was already
# there is not rewritten.
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
# The bar runs its helper scripts by path, and git does not carry the exec bit
# across platforms; the build restores it, and the seed must preserve it. A seed
# that drops it gives a session with no workspace chips.
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
# The launcher's liveness test is `niri msg --json version` against the instance
# socket, not the socket file alone: a stale file from an earlier instance would
# otherwise read as a live compositor. This stub creates the socket and refuses
# the probe; the launcher has to say it did not answer and keep waiting.
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

# The bus is where D-Bus-activated services get their environment, and the
# portal frontend is one. The identity therefore has to be set before dbus
# starts, and pushed into an inherited bus's activation environment too.
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

# Copper layers its own tweaks over the pinned configuration tree through
# niri's positional `include`. This checks both halves of that wiring still
# exist, because either one disappearing leaves the session on upstream defaults
# with nothing to show why.
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

pkill -f "$TMP" 2>/dev/null
rm -rf "$TMP"
echo
if [ "$fails" -ne 0 ]; then
    echo "FAILED: $fails check(s)"
    exit 1
fi
echo "all startniri checks passed"
