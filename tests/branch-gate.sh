#!/usr/bin/env bash
# Run this branch's tests, and be honest about which ones did not run.
# Root gates exercise real namespaces, sockets and chroots; the rest are
# stubbed or static, and each gate below is named with why it may skip.
# A past known-failure list was deleted when the port landed; red is red.
# boot-gate.sh needs a built ISO and QEMU, so CI runs it beside the build.
# Run as root:  sudo tests/branch-gate.sh
# Non-root runs smoke.sh only, and says so.

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 1

ROOT=0
[ "$(id -u)" -eq 0 ] && ROOT=1

pass=0
fail=0
skip=0

# check <label> <ok|bad|skipped> [detail]
# Every status needs an arm or the test silently vanishes from the summary.
record() {
    case "$2" in
        ok)    printf '  PASS       %-24s %s\n' "$1" "${3:-}" ; pass=$((pass + 1)) ;;
        bad)   printf '  FAIL       %-24s %s\n' "$1" "${3:-}" ; fail=$((fail + 1)) ;;
        skipped)
                printf '  SKIPPED    %-24s %s\n' "$1" "${3:-}"
                printf '             (not run, and not counted as passing)\n'
                skip=$((skip + 1)) ;;
        *)     printf '  FAIL       %-24s unknown status: %s\n' "$1" "$2" ; fail=$((fail + 1)) ;;
    esac
}

echo "=== branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "=== uid $(id -u)"

# ---------------------------------------------------------------------------
echo
echo "--- tests/smoke.sh: a real gate, must pass outright ---"
if out=$(bash tests/smoke.sh 2>&1); then
    record smoke.sh ok "$(printf '%s' "$out" | grep -c '^ok' | tr -d ' ') assertions"
else
    record smoke.sh bad "exit $?"
    printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/startxfce-gate.sh: the startxfce launcher ---"
# A real gate; each missing piece names itself and returns its own exit code.
if [ "$ROOT" -ne 1 ]; then
    record startxfce-gate.sh skipped "needs root for the socket stubs"
elif out=$(bash tests/startxfce-gate.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^  ok' || true)
    record startxfce-gate.sh ok "$n checks"
else
    record startxfce-gate.sh bad "a startxfce check failed"
# Report failures in full: capping at N lines hides failures after N passes.
    printf '%s\n' "$out" | grep -E '^  FAIL|^        ' | sed 's/^/    /'
    oks=$(printf '%s\n' "$out" | grep -cE '^  ok' || true)
    printf '    (%s checks passed; the failures are the lines above)\n' "$oks"
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/xprobe-gate.sh: the real xprobe binary vs a synthetic X server ---"
# Compiles the real xprobe and asserts its 0/1/2/3 exit-code contract; needs a
# C compiler and python3, and skips cleanly where neither exists.
if out=$(bash tests/xprobe-gate.sh 2>&1); then
    case "$out" in
        *SKIPPED*)
            record xprobe-gate.sh skipped "no C compiler on this host" ;;
        *)
            n=$(printf '%s' "$out" | grep -c '^  ok' || true)
            record xprobe-gate.sh ok "$n checks" ;;
    esac
else
    record xprobe-gate.sh bad "a real-xprobe check failed"
    printf '%s\n' "$out" | grep -E '^  FAIL|^        ' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/startniri-gate.sh: the niri launcher ---"
# Stubbed compositor and private paths keep this off the host's session; one
# case needs python3 to bind a real socket and skips without it.
if ! command -v python3 >/dev/null 2>&1; then
    record startniri-gate.sh skipped "no python3 on this host"
elif out=$(sh tests/startniri-gate.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^  ok' || true)
    record startniri-gate.sh ok "$n checks"
else
    record startniri-gate.sh bad "a niri launcher check failed"
    printf '%s\n' "$out" | grep -E '^  FAIL|^        ' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/starthyprland-gate.sh: the Hyprland launcher ---"
# Stubbed compositor and private paths; the exit-code contract is the thing
# under test, since a script branching on 20/21/22/23 breaks silently.
if out=$(sh tests/starthyprland-gate.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^  ok' || true)
    ns=$(printf '%s' "$out" | grep -c '^  skip' || true)
    if [ "$ns" -gt 0 ]; then
        record starthyprland-gate.sh ok "$n checks ($ns skipped: no python3 to bind a seatd socket)"
    else
        record starthyprland-gate.sh ok "$n checks"
    fi
else
    record starthyprland-gate.sh bad "a hyprland launcher check failed"
    printf '%s\n' "$out" | grep -E '^  FAIL|^        ' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/bootloader-gate.sh: shared entries and the provider hooks ---"
# Buildless: renders the shipped provider and reads the build wiring.
if out=$(sh tests/bootloader-gate.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^ok' || true)
    record bootloader-gate.sh ok "$n checks"
else
    record bootloader-gate.sh bad "a bootloader provider check failed"
    printf '%s\n' "$out" | grep -E '^FAIL' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/plymouth-gate.sh: the splash switches and the daemon's argv ---"
# Reads the shipped entries and units; checks a real plymouthd only if present.
if out=$(sh tests/plymouth-gate.sh 2>&1); then
    n=$(printf '%s\n' "$out" | grep -c '^ok' || true)
    ns=$(printf '%s\n' "$out" | grep -c '^skip' || true)
    if [ "$ns" -gt 0 ]; then
        record plymouth-gate.sh ok "$n checks ($ns skipped: no plymouthd/strings here)"
    else
        record plymouth-gate.sh ok "$n checks"
    fi
else
    record plymouth-gate.sh bad "a splash check failed"
    printf '%s\n' "$out" | grep -E '^FAIL' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/account-gate.sh: proves tests/account.sh catches real bugs ---"
if [ "$ROOT" -ne 1 ]; then
    record account-gate.sh skipped "needs root; CI runs it with sudo"
elif out=$(bash tests/account-gate.sh 2>&1); then
    record account-gate.sh ok "all three sabotages proved"
else
# All three sabotages apply now; there is nothing left to classify.
    record account-gate.sh bad "exit $?"
    printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/init-session.sh: the console shell drops to the wizard user ---"
if [ "$ROOT" -ne 1 ]; then
    record init-session.sh skipped "needs root to call setuid"
elif out=$(bash tests/init-session.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^ok' || true)
    record init-session.sh ok "$n checks"
else
    record init-session.sh bad "a session-privilege check failed"
    printf '%s\n' "$out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/persist.sh: the wizard's disk choice for persistence ---"
if [ "$ROOT" -ne 1 ]; then
    record persist.sh skipped "needs root for the mount namespace"
elif out=$(bash tests/persist.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^ok' || true)
    record persist.sh ok "$n checks"
else
    record persist.sh bad "a persistence check failed"
# Keep the whole transcript: a death before the FAIL line is the reason.
    printf '%s\n' "$out" | tail -60 | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/shutdown-gate.sh: shutdown maps flags onto the right applet ---"
# Root for the mount namespace; `shutdown -r now` must reboot, not power off.
if [ "$ROOT" -ne 1 ]; then
    record shutdown-gate.sh skipped "needs root for the mount namespace"
elif out=$(bash tests/shutdown-gate.sh 2>&1); then
    if printf '%s' "$out" | grep -q '^skip:'; then
        record shutdown-gate.sh skipped "no private mount namespace"
    else
        n=$(printf '%s' "$out" | grep -c '^ok' || true)
        record shutdown-gate.sh ok "$n checks"
    fi
else
    record shutdown-gate.sh bad "a shutdown-wrapper check failed"
    printf '%s\n' "$out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/ingot-gate.sh: ingot against a fake Pages repo ---"
# Needs python3/wget/tar; installs into a scratch root, never the live tree.
if out=$(bash tests/ingot-gate.sh 2>&1); then
    record ingot-gate.sh ok "all ingot checks passed"
else
    nfail=$(printf '%s\n' "$out" | grep -c '^  FAIL ' || true)
    record ingot-gate.sh bad "exit $? with $nfail failed assertions"
    printf '%s\n' "$out" | grep -E '^  FAIL |^    summary' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/systemd-gate.sh: the systemd PID-1 swap, structurally ---"
# Root: chroots into the staged tree so ExecStart resolves as at boot. Runs the
# real build_systemd with apt/dpkg stubbed; structural, not a boot claim.
if [ "$ROOT" -ne 1 ]; then
    record systemd-gate.sh skipped "needs root to chroot for the unit check"
elif out=$(bash tests/systemd-gate.sh 2>&1); then
    n=$(printf '%s\n' "$out" | grep -c '^  ok' || true)
    record systemd-gate.sh ok "$n checks (structural -- not a boot)"
else
    record systemd-gate.sh bad "a systemd-migration check failed"
    printf '%s\n' "$out" | grep -E '^  FAIL' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/systemd-gate-sabotage.sh: prove that gate can go red ---"
# Nine planted defects, one at a time, must each be caught; needs root.
if [ "$ROOT" -ne 1 ]; then
    record systemd-gate-sabotage.sh skipped "needs root to chroot for the unit check"
elif out=$(bash tests/systemd-gate-sabotage.sh 2>&1); then
    n=$(printf '%s\n' "$out" | grep -c '^  ok' || true)
    record systemd-gate-sabotage.sh ok "$n sabotages, all caught"
else
    record systemd-gate-sabotage.sh bad "the gate missed a planted defect"
    printf '%s\n' "$out" | grep -E '^  FAIL|^BROKEN' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/persist-sabotage.sh: prove the persistence gate can go red ---"
# persist.sh asserts decisions, not devices; this plants four wrong decisions
# in the wizard and requires the gate to catch each. Needs root.
if [ "$ROOT" -ne 1 ]; then
    record persist-sabotage.sh skipped "needs root for the mount namespace"
elif out=$(bash tests/persist-sabotage.sh 2>&1); then
    n=$(printf '%s\n' "$out" | grep -c '^  ok' || true)
    record persist-sabotage.sh ok "$n sabotages, all caught"
else
    record persist-sabotage.sh bad "the gate missed a planted defect"
    printf '%s\n' "$out" | grep -E '^  FAIL|^BROKEN' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/kernel-gate.sh: the kernel config asserts what it needs ---"
# A dropped kernel symbol boots to a shell with no disk, screen or network;
# the shipped function is run against synthetic configs, each symbol deleted.
if out=$(bash tests/kernel-gate.sh 2>&1); then
    n=$(printf '%s\n' "$out" | grep -c '^  ok' || true)
    record kernel-gate.sh ok "$n checks"
else
    record kernel-gate.sh bad "a kernel-config assertion is missing or wrong"
    printf '%s\n' "$out" | grep -E '^  FAIL' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/kernel-gate-sabotage.sh: prove that gate can go red ---"
# A gate that only goes green certifies nothing; four defects are planted.
if out=$(bash tests/kernel-gate-sabotage.sh 2>&1); then
    n=$(printf '%s\n' "$out" | grep -c '^  ok' || true)
    record kernel-gate-sabotage.sh ok "$n sabotages, all caught"
else
    record kernel-gate-sabotage.sh bad "the gate missed a planted defect"
    printf '%s\n' "$out" | grep -E '^  FAIL|^BROKEN' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/font-gate.sh: the console font and the glyphs Copper draws ---"
# One bitmap font, no fallback: a missing glyph is a question mark on tty1.
# Reads the real font table and fastfetch config; needs python3.
if ! command -v python3 >/dev/null 2>&1; then
    record font-gate.sh skipped "no python3 on this host"
elif out=$(bash tests/font-gate.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^  ok' || true)
    record font-gate.sh ok "$n checks"
else
    record font-gate.sh bad "a console-font check failed"
    printf '%s\n' "$out" | grep -E '^  FAIL' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/shell-gate.sh: copper-sh against the defects the audit found ---"
# Compiles the real shell and drives the audit's crashers; needs a C
# compiler, plus a static check that the refresh_line clamp survives.
if out=$(sh tests/shell-gate.sh 2>&1); then
    case "$out" in
        *SKIPPED*)
            record shell-gate.sh skipped "no C compiler on this host" ;;
        *)
            n=$(printf '%s' "$out" | grep -c '^  ok' || true)
            record shell-gate.sh ok "$n checks" ;;
    esac
else
    record shell-gate.sh bad "a copper-sh check failed"
    printf '%s\n' "$out" | grep -E '^  FAIL|^       ' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/firstboot-eof-gate.sh: the wizard cannot hot-loop on EOF ---"
# Runs the real wizard on closed stdin with no tty; needs a C compiler and
# setsid, and the apply path uses absolute /bin/busybox paths for safety.
if out=$(sh tests/firstboot-eof-gate.sh 2>&1); then
    case "$out" in
        *SKIPPED*)
            record firstboot-eof-gate.sh skipped "no C compiler or setsid here" ;;
        *)
            n=$(printf '%s' "$out" | grep -c '^  ok' || true)
            record firstboot-eof-gate.sh ok "$n checks" ;;
    esac
else
    record firstboot-eof-gate.sh bad "the wizard looped or mis-reported on EOF"
    printf '%s\n' "$out" | grep -E '^  FAIL|^       ' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/polkit-gate.sh: the bus, the daemon and the agent can meet ---"
# Static wiring checks; actual dbus-daemon binding needs a boot (bug 45).
if out=$(sh tests/polkit-gate.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^  ok' || true)
    record polkit-gate.sh ok "$n checks"
else
    record polkit-gate.sh bad "a system-bus/polkit check failed"
    printf '%s\n' "$out" | grep -E '^  FAIL|^       ' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/network-gate.sh: a lease always leaves a resolver ---"
# A lease without a search domain left only public DNS and broke lookups on
# networks that block it; the real lease script runs against a stub ip(8).
if out=$(sh tests/network-gate.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^  ok' || true)
    record network-gate.sh ok "$n checks"
else
    record network-gate.sh bad "the lease script does not always leave a resolver"
    printf '%s\n' "$out" | grep -E '^  FAIL|^       ' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/console-gate.sh: the prompt names you, the shell knows its tty ---"
# The prompt shipped as a literal with no user and nothing set TERM; both
# startup files are exercised against a stub tty(1). Unprivileged.
if out=$(bash tests/console-gate.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^  ok' || true)
    record console-gate.sh ok "$n checks"
else
    record console-gate.sh bad "the console prompt or TERM fallback regressed"
    printf '%s\n' "$out" | grep -E '^  FAIL|^       ' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/config-gate.sh: every image-wide switch agrees with itself ---"
# Reads both ends of the init, shell and audio switches; a rename on one side
# still boots but ignores the user's answer, so every pair is checked here.
if out=$(sh tests/config-gate.sh 2>&1); then
    n=$(printf '%s\n' "$out" | grep -c '^  ok' || true)
    record config-gate.sh ok "$n checks"
else
    record config-gate.sh bad "a config-switch check failed"
    printf '%s\n' "$out" | grep -E '^  FAIL' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/hardening-gate.sh: ownership, /tmp, launchers, gshadow, home ---"
# Reads the shipped scripts and runs `copper` with no arguments. Rootless.
if out=$(sh tests/hardening-gate.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^  ok' || true)
    record hardening-gate.sh ok "$n checks"
else
    record hardening-gate.sh bad "a live-image hardening check regressed"
    printf '%s\n' "$out" | grep -E '^  FAIL' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/identity-gate.sh: all version files come from os-release ---"
if out=$(sh tests/identity-gate.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^  ok' || true)
    record identity-gate.sh ok "$n checks"
else
    record identity-gate.sh bad "a generated identity file drifted"
    printf '%s\n' "$out" | grep -E '^  FAIL|^       ' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/firstboot-validators.sh: wizard input cannot reach a shell ---"
# Compiles the shipped validators, including the leading-dash rejection.
if out=$(sh tests/firstboot-validators.sh 2>&1); then
    case "$out" in
        *SKIPPED*)
            record firstboot-validators.sh skipped "no C compiler on this host" ;;
        *)
            n=$(printf '%s' "$out" | grep -c '^  ok' || true)
            record firstboot-validators.sh ok "$n checks" ;;
    esac
else
    record firstboot-validators.sh bad "a wizard validator accepted unsafe input"
    printf '%s\n' "$out" | grep -E '^  FAIL|^       ' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "=== summary ==="
echo "  passed    $pass"
echo "  skipped   $skip"
echo "  failed    $fail"
echo
if [ "$fail" -ne 0 ]; then
    echo "FAILED: a gate above failed. That is a regression, not a known gap."
    exit 1
fi
if [ "$skip" -ne 0 ]; then
    echo "PASSED, with tests not run."
    echo
    echo "The skips are named above and they are all root requirements. CI runs"
    echo "this file with sudo, so a green CI build has no skips in it."
    exit 0
fi
echo "PASSED, no tests skipped."
exit 0