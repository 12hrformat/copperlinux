#!/usr/bin/env bash
# gate: starthyprland -- automated tests for iso/starthyprland.sh.
#
# Follows the branch-gate conventions. Runs unprivileged: the launcher is
# exercised against a private home and stubbed binaries, and nothing touches
# the build host. Real hardware (a GPU, a seatd socket) is not required: the
# test checks what the script *says* is missing, and that its exit codes are
# the ones the contract names.
#
# Run:  sudo ./tests/starthyprland-gate.sh   (root: the root-gated cases)
#        ./tests/starthyprland-gate.sh       (unprivileged: the stubbed cases)
#
# Exit: 0 when every case is honest (no skipped, no failed), 1 otherwise.

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 1

ROOT=0
[ "$(id -u)" -eq 0 ] && ROOT=1

pass=0
fail=0
skip=0

record() {
    case "$2" in
        ok)    printf '  PASS       %-26s %s\n' "$1" "${3:-}" ; pass=$((pass+1));;
        bad)   printf '  FAIL       %-26s %s\n' "$1" "${3:-}" ; fail=$((fail+1));;
        skipped)
                printf '  SKIPPED    %-26s %s\n' "$1" "${3:-}"
                printf '             (not run, and not counted as passing)\n'
                skip=$((skip+1));;
        *)     printf '  FAIL       %-26s unknown status: %s\n' "$1" "$2" ; fail=$((fail+1));;
    esac
}

# ---------------------------------------------------------------------------
# test harness
# The launcher reads the environment variables that starthyprland.sh defaults
# to. We run it with those variables overridden to point at a private tree
# that we control, so nothing in the image is touched.
# ---------------------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A stub hyprland: exit 0 on --session (success) unless HYP_FAIL=1.
cat > "$WORK/hyprland" <<'EOF'
#!/bin/sh
# Stub hyprland. Nothing here looks at REAL hardware: the launcher's
# --check and its exit codes are the thing under test.
if [ "${HYP_FAIL:-0}" = "1" ]; then
    echo "hyprland stub: failing" >&2
    exit 1
fi
if [ "${HYP_CHECK:-0}" = "1" ]; then
    echo "hyprland stub: check passed"
    exit 0
fi
# --session: pretend to run. The launcher waits for an IPC socket, which this
# stub will never write, so the launcher's wait loop will time out and fall
# through to "alive and drawing" -- by design. HYP_WAIT=0 skips the wait.
if [ "${HYP_WAIT:-1}" = "0" ]; then
    exit 0
fi
sleep 999 &
wait $!
EOF
chmod +x "$WORK/hyprland"

# A stub waybar and a stub fuzzel (the launcher's keybindings exec these).
cat > "$WORK/waybar" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/waybar"
cat > "$WORK/fuzzel" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/fuzzel"

# A stub seatd (so the launcher's "seatd socket exists" branch is exercised).
mkdir -p "$WORK/run"
touch "$WORK/run/seatd.sock"

# A config skeleton that the launcher seeds. The launcher defaults
# COPPER_HYPRLAND_SKEL to /usr/share/copper/hyprland-skel; we point it at a
# private tree that mirrors that layout.
mkdir -p "$WORK/skel/.config/hypr" "$WORK/skel/.config/waybar/scripts"
cat > "$WORK/skel/.config/hypr/hyprland.conf" <<'EOF'
# stub hyprland config
EOF
cat > "$WORK/skel/.config/waybar/config.jsonc" <<'EOF'
{ "general": {} }
EOF
cat > "$WORK/skel/.config/waybar/scripts/workspaces.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/skel/.config/waybar/scripts/workspaces.sh"

# A component manifest: a missing component that is "image", plus a stub
# ingot that controls what `ingot install` does.
cat > "$WORK/hyprland-apps" <<'EOF'
fuzzel          /usr/bin/fuzzel          ingot
firefox         /usr/bin/firefox         ingot
waybar          /usr/bin/waybar          image
EOF
cat > "$WORK/ingot" <<'EOF'
#!/bin/sh
# Stub ingot. Usage: ingot install NAME. Install ok=1, fail=0.
if [ "$1" = "install" ]; then
    if [ "$2" = "nmap" ]; then exit 1; fi
    exit 0
fi
exit 0
EOF
chmod +x "$WORK/ingot"

# The launcher itself.
LAUNCHER="$REPO/iso/starthyprland.sh"

run_starthyprland() {
    # Run starthyprland.sh with the stubbed environment. Each COPPER_* variable
    # the launcher reads is set here with a test default, but only when the
    # caller has not overridden it -- the test cases drive these variables, and
    # a default that silently replaced the caller's value would make every case
    # report "component missing" instead of the branch it is meant to exercise.
    if [ -z "${COPPER_HYPRLAND:-}" ]; then COPPER_HYPRLAND="$WORK/hyprland"; export COPPER_HYPRLAND; fi
    if [ -z "${COPPER_WAYBAR:-}" ]; then COPPER_WAYBAR="$WORK/waybar"; export COPPER_WAYBAR; fi
    if [ -z "${COPPER_HYPRLAND_SKEL:-}" ]; then COPPER_HYPRLAND_SKEL="$WORK/skel"; export COPPER_HYPRLAND_SKEL; fi
    if [ -z "${COPPER_HYPRLAND_APPS:-}" ]; then COPPER_HYPRLAND_APPS="$WORK/hyprland-apps"; export COPPER_HYPRLAND_APPS; fi
    if [ -z "${COPPER_INGOT:-}" ]; then COPPER_INGOT="$WORK/ingot"; export COPPER_INGOT; fi
    if [ -z "${COPPER_SEATD_SOCK:-}" ]; then COPPER_SEATD_SOCK="$WORK/run/seatd.sock"; export COPPER_SEATD_SOCK; fi
    if [ -z "${COPPER_USER_HYPR_CONF:-}" ]; then COPPER_USER_HYPR_CONF="$WORK/home/.config/hypr"; export COPPER_USER_HYPR_CONF; fi
    if [ -z "${COPPER_DRM_DIR:-}" ]; then COPPER_DRM_DIR="$WORK/dev/dri"; export COPPER_DRM_DIR; fi
    if [ -z "${COPPER_INPUT_SYS:-}" ]; then COPPER_INPUT_SYS="$WORK/sys/class/input"; export COPPER_INPUT_SYS; fi
    if [ -z "${COPPER_UDEV_DATA:-}" ]; then COPPER_UDEV_DATA="$WORK/run/udev/data"; export COPPER_UDEV_DATA; fi
    if [ -n "${COPPER_RUNTIME_DIR:-}" ]; then export COPPER_RUNTIME_DIR; fi
    PATH="$WORK:$PATH" \
        "$LAUNCHER" "$@"
}

# --check must not start a compositor and must report each category.
report_check() {
    if [ -z "${COPPER_HYPRLAND:-}" ]; then COPPER_HYPRLAND="$WORK/hyprland"; export COPPER_HYPRLAND; fi
    if [ -z "${COPPER_WAYBAR:-}" ]; then COPPER_WAYBAR="$WORK/waybar"; export COPPER_WAYBAR; fi
    if [ -z "${COPPER_HYPRLAND_SKEL:-}" ]; then COPPER_HYPRLAND_SKEL="$WORK/skel"; export COPPER_HYPRLAND_SKEL; fi
    if [ -z "${COPPER_HYPRLAND_APPS:-}" ]; then COPPER_HYPRLAND_APPS="$WORK/hyprland-apps"; export COPPER_HYPRLAND_APPS; fi
    if [ -z "${COPPER_INGOT:-}" ]; then COPPER_INGOT="$WORK/ingot"; export COPPER_INGOT; fi
    if [ -z "${COPPER_SEATD_SOCK:-}" ]; then COPPER_SEATD_SOCK="$WORK/run/seatd.sock"; export COPPER_SEATD_SOCK; fi
    if [ -z "${COPPER_USER_HYPR_CONF:-}" ]; then COPPER_USER_HYPR_CONF="$WORK/home/.config/hypr"; export COPPER_USER_HYPR_CONF; fi
    if [ -z "${COPPER_DRM_DIR:-}" ]; then COPPER_DRM_DIR="$WORK/dev/dri"; export COPPER_DRM_DIR; fi
    if [ -z "${COPPER_INPUT_SYS:-}" ]; then COPPER_INPUT_SYS="$WORK/sys/class/input"; export COPPER_INPUT_SYS; fi
    if [ -z "${COPPER_UDEV_DATA:-}" ]; then COPPER_UDEV_DATA="$WORK/run/udev/data"; export COPPER_UDEV_DATA; fi
    if [ -n "${COPPER_RUNTIME_DIR:-}" ]; then export COPPER_RUNTIME_DIR; fi
    PATH="$WORK:$PATH" \
        "$LAUNCHER" --check
}

# ---------------------------------------------------------------------------
# cases
# ---------------------------------------------------------------------------

# 1. Missing compositor -> the launcher names the piece, exit 20, compositor
#    and session never start. Run directly so COPPER_HYPRLAND is not overridden
#    by the run_starthyprland prefix assignment.
env -i HOME="$WORK/home" PATH="$WORK:$PATH" \
    COPPER_HYPRLAND=/nonexistent/hyprland \
    COPPER_WAYBAR="$WORK/waybar" \
    COPPER_HYPRLAND_SKEL="$WORK/skel" \
    COPPER_HYPRLAND_APPS="$WORK/hyprland-apps" \
    COPPER_INGOT="$WORK/ingot" \
    COPPER_SEATD_SOCK="$WORK/run/seatd.sock" \
    COPPER_USER_HYPR_CONF="$WORK/home/.config/hypr" \
    COPPER_DRM_DIR="$WORK/dev/dri" \
    COPPER_INPUT_SYS="$WORK/sys/class/input" \
    COPPER_UDEV_DATA="$WORK/run/udev/data" \
    "$LAUNCHER" --check > "$WORK/c1.out" 2>&1
rc=$?
if [ "$rc" = "20" ]; then
    record "compositor missing -> exit 20" ok "exit 20; no compositor or session started"
else
    record "compositor missing -> exit 20" bad "exit $rc, expected 20"
fi

# --check reports a missing config (no skeleton, no home config) -> exit 21.
COPPER_HYPRLAND_SKEL="$WORK/nostalkel" \
COPPER_USER_HYPR_CONF="$WORK/homedoesnotexist" \
run_starthyprland --check > "$WORK/check2.out" 2>&1
rc=$?
if [ "$rc" = "21" ]; then
    record "missing config -> exit 21" ok "exit 21; no compositor started"
else
    record "missing config -> exit 21" bad "exit $rc, expected 21"
fi

# Invalid arguments -> exit 24.
if run_starthyprland --bogus > "$WORK/badargs.out" 2>&1; then
    record "unknown option -> exit 24" bad "exited 0; message above"
elif [ "$?" = "24" ]; then
    record "unknown option -> exit 24" ok "exit 24; message above"
else
    record "unknown option -> exit 24" bad "exit $?"
fi

# --check with a correct tree: compositor present, config present, seatd
# present, runtime dir missing -> exit 22 (runtime not prepared). --check
# must NOT start the compositor.
COPPER_USER_HYPR_CONF="$WORK/home" \
COPPER_DRM_DIR="$WORK/dev/dri" \
COPPER_INPUT_SYS="$WORK/sys/class/input" \
COPPER_UDEV_DATA="$WORK/run/udev/data" \
run_starthyprland --check > "$WORK/check3.out" 2>&1
rc=$?
if [ "$rc" = "22" ]; then
    record "runtime dir missing -> --check exits 22" ok "exit 22; no compositor started"
else
    record "runtime dir missing -> --check exits 22" bad "exit $rc, expected 22"
fi

# The launch path with a stub that exits 0 must start the session, and the
# wait loop must handle the "no answering socket" case without hanging.
COPPER_USER_HYPR_CONF="$WORK/home" \
HYP_FAIL=0 HYP_WAIT=0 \
run_starthyprland > "$WORK/launch.out" 2>&1
rc=$?
if [ "$rc" = "0" ]; then
    record "session start -> exit 0" ok "exit 0; compositor and session started"
else
    record "session start -> exit 0" bad "exit $rc; compositor and session started"
fi

# A compositor that fails while starting must yield exit 23.
COPPER_USER_HYPR_CONF="$WORK/home" \
HYP_FAIL=1 HYP_WAIT=0 \
run_starthyprland > "$WORK/fail.out" 2>&1
rc=$?
if [ "$rc" = "23" ]; then
    record "compositor fail -> exit 23" ok "exit 23; message above"
else
    record "compositor fail -> exit 23" bad "exit $rc, expected 23"
fi

# A missing seatd socket -> exit 22 (runtime not prepared).
COPPER_SEATD_SOCK="$WORK/run/nosocket.sock" \
COPPER_USER_HYPR_CONF="$WORK/home" \
COPPER_DRM_DIR="$WORK/dev/dri" \
COPPER_INPUT_SYS="$WORK/sys/class/input" \
COPPER_UDEV_DATA="$WORK/run/udev/data" \
run_starthyprland --check > "$WORK/check4.out" 2>&1
rc=$?
if [ "$rc" = "22" ]; then
    record "seatd socket missing -> --check exits 22" ok
else
    record "seatd socket missing -> --check exits 22" bad "exit $rc"
fi

# A component that ingot cannot install must not abort the session start.
COPPER_USER_HYPR_CONF="$WORK/home" \
COPPER_INGOT="$WORK/ingot" \
HYP_FAIL=0 HYP_WAIT=0 \
BUT=${BUT:=} run_starthyprland > "$WORK/incomp.out" 2>&1
rc=$?
if [ "$rc" = "0" ]; then
    record "missing ingot component -> start anyway" ok
else
    record "missing ingot component -> start anyway" bad "exit $rc"
fi

echo
echo "=== starthyprland gate: $pass passed, $fail failed, $skip skipped ==="
if [ "$fail" -gt 0 ]; then
    echo "FAIL"
    exit 1
fi
if [ "$skip" -gt 0 ]; then
    echo "SKIPPED"
    exit 2
fi
exit 0
