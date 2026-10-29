#!/usr/bin/env bash
# Run this branch's tests, and be honest about which ones did not run.
#
# Eighteen gates: smoke.sh always; startxfce-gate.sh,
# account-gate.sh, persist.sh, persist-sabotage.sh and shutdown-gate.sh need
# root, because they exercise sockets, staged rootfs trees,
# a mount namespace and a private /sbin; init-session.sh needs root because it
# calls setuid, and
# systemd-gate.sh and systemd-gate-sabotage.sh need root because they chroot
# into a staged tree to check the units. ingot-gate.sh,
# starthyprland-gate.sh and plymouth-gate.sh do not -- ingot's install lands in
# a scratch INGOT_ROOT and its repo is served on localhost, starthyprland's
# compositor is a stub under a private home, and plymouth-gate.sh only reads
# grub.cfg and copper-init.c -- so all three run unprivileged too.
# kernel-gate.sh and kernel-gate-sabotage.sh run unprivileged as well: they run
# the shipped require_kernel_config() against synthetic configs rather than
# building a kernel.
# font-gate.sh is unprivileged too: it reads the shipped console font (a PSF1
# binary), the fastfetch config and copper-init.c, and needs python3 to walk
# the font's unicode table.
# xprobe-gate.sh needs a C
# compiler and python3, which CI and the build VM have, and skips cleanly where
# neither exists; starthyprland-gate.sh needs python3 for one case and skips the
# same way; plymouth-gate.sh checks options against a real plymouthd when the
# host has one and skips that part when it does not. CI runs this same file with
# sudo, so a green build there means every
# gate ran and none were skipped.
#
# This file used to carry known-failure classifications: the CI workflow came
# over from `untested`, and on the old `gui` tree two of its tests failed
# describing work that branch never had. Those were classified by their exact
# output signatures so a real regression still went red -- and when the port
# landed and both tests passed, the classifications were deleted rather than
# kept as permanent excuses. That was the deal the file stated from the start.
# Any failure from here on is a regression, and it is red.
#
# boot-gate.sh is deliberately not in this list: it needs a built ISO and a
# QEMU, so the workflow runs it beside the build rather than on every host
# that has a checkout.
#
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
#
# Every status the callers use is listed. A status with no arm here prints
# nothing and moves no counter, so the test it describes disappears from the
# summary without a word -- and this runs non-root as well as root, which is
# what most of the skipped paths are for.
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
# A real gate on this branch, not a known gap. The launcher ships before XFCE
# does, so the only thing it can be tested on is its failure behaviour, and
# that is the part that has to be right: each missing piece names itself and
# returns its own exit code, so "XFCE is not built yet" is never confused with
# a broken PATH or a server that would not start.
if [ "$ROOT" -ne 1 ]; then
    record startxfce-gate.sh skipped "needs root for the socket stubs"
elif out=$(bash tests/startxfce-gate.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^  ok' || true)
    record startxfce-gate.sh ok "$n checks"
else
    record startxfce-gate.sh bad "a startxfce check failed"
    # The failures come first, in full, with the detail line that follows each
    # one. Capping the report by taking its first N lines hides the failure
    # whenever the test passed more than N checks first: this gate reported
    # twenty green ticks and no reason, because the one failing check was the
    # twenty-first line. The passes are then a count, which is all they were
    # for.
    printf '%s\n' "$out" | grep -E '^  FAIL|^        ' | sed 's/^/    /'
    oks=$(printf '%s\n' "$out" | grep -cE '^  ok' || true)
    printf '    (%s checks passed; the failures are the lines above)\n' "$oks"
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/xprobe-gate.sh: the real xprobe binary vs a synthetic X server ---"
# Compiles the actual iso/x11/probe/xprobe.c and drives it through every socket
# state (no socket, stale file, mute listener, live handshake, usage errors,
# bounded timeout), asserting the 0/1/2/3 exit-code contract, plus a static
# check that iso/build.sh stages the result as /usr/bin/xprobe. Needs a C
# compiler and python3 -- both present in CI and on the build VM. Skips cleanly
# on a host with neither (the Windows box this tree is maintained on).
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
echo "--- tests/starthyprland-gate.sh: the Hyprland launcher ---"
# Unprivileged, like xprobe-gate.sh: it stubs the compositor and points the
# launcher at a private home, runtime directory, DRM path and seatd socket, so
# it never touches this machine's session. It needs python3 for the one case
# that binds a real unix socket to prove the seatd line, so it skips cleanly
# where python3 is absent -- the same shape as xprobe-gate.sh without a
# compiler.
if ! command -v python3 >/dev/null 2>&1; then
    record starthyprland-gate.sh skipped "no python3 on this host"
elif out=$(sh tests/starthyprland-gate.sh 2>&1); then
    n=$(printf '%s' "$out" | grep -c '^  ok' || true)
    record starthyprland-gate.sh ok "$n checks"
else
    record starthyprland-gate.sh bad "a Hyprland launcher check failed"
    printf '%s\n' "$out" | grep -E '^  FAIL|^        ' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/plymouth-gate.sh: the splash switches and the daemon's argv ---"
# Unprivileged and self-contained: it reads grub.cfg and copper-init.c, and
# only checks options against a real plymouthd when the host happens to have
# one (a skip, not a failure, when it does not).
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
    # This used to carry a known-signature arm for the sabotages that could
    # not apply to this branch's short wizard. The long wizard is in the tree
    # now and all three apply, so nothing is left to classify: red is red.
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
    # The whole transcript, not just the FAIL lines: when a wizard run dies on
    # the runner the reason is what it printed before it died.
    printf '%s\n' "$out" | tail -60 | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo
echo "--- tests/shutdown-gate.sh: shutdown maps flags onto the right applet ---"
# Needs root for the private mount namespace it uses to replace /sbin with
# stubs. The mapping is the whole risk (bug 18): `shutdown -r now` must reboot,
# not power off.
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
# Needs python3 (serves the fake repo), wget, tar, sha256sum. No root: it
# installs into a scratch INGOT_ROOT and never touches the live tree.
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
# Needs root: the stage verifies its units by chrooting into the staged tree,
# so ExecStart resolves the way it will at boot. It runs the REAL build_systemd
# against a mock rootfs with apt/dpkg stubbed, so it downloads and execs
# nothing. Nothing here claims the image boots -- SYSTEMD-MIGRATION.md says so
# plainly -- but a red gate means the swap is incoherent.
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
# The gate above checks a migration nothing here can boot, so its whole value
# is that it fails when the swap is wrong. This plants nine defects, one at a
# time, and asserts every one is caught. Needs root, as systemd-gate.sh does.
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
# tests/persist.sh asserts DECISIONS (which disk the wizard takes, what it
# refuses, what it runs), not devices. A gate like that is worth its lines only
# if it goes red when a decision is wrong, so this plants four defects in the
# wizard, one at a time, and asserts every one is caught. Needs root, as
# persist.sh does -- it uses the same mount namespace.
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
# The kernel config is where a dropped symbol turns into a machine that boots to
# a shell -- no disk (bug 46), no screen, no network. require_kernel_config()
# asserts every symbol is =y after olddefconfig, and until this gate nothing
# tested it. No root needed: it runs the shipped function against synthetic
# configs, deleting each asserted symbol in turn.
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
# For the same reason as the two sabotage suites above: a gate that only ever
# goes green certifies nothing. Plants a dropped symbol, a misspelled symbol (the
# DRM_VMWARE mistake, again), a deleted block and an emptied loop.
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
# No root. The console has ONE bitmap font and no fallback, so a codepoint it
# lacks is a question mark -- the same fastfetch separator that renders in
# xfce4-terminal. Reads the font's real unicode table (python3) and the real
# fastfetch config, so a renamed font, a dropped package or a config that
# starts printing emoji goes red here rather than on a user's tty1.
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
# Unprivileged, needs a C compiler. Compiles the real shell and drives it
# through the crashers: a trailing pipe (NULL argv segfault), a non-octal
# chmod (used to become mode 0 silently), a 300-word line (argv overflow),
# and a redirect-only line; plus a static check that refresh_line clamps its
# write length so the stack overread cannot come back.
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
# Unprivileged, needs a C compiler and setsid. Runs the real wizard with
# closed stdin and no controlling tty (so getpass falls back to stdin, the
# path where the bug lived) and asserts it exits 1 instead of spinning on
# "Password can't be empty" forever. The apply path shells out to absolute
# /bin/busybox, absent on any non-Copper host, so a regression cannot touch
# this machine's accounts.
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