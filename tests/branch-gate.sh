#!/usr/bin/env bash
# Run this branch's tests, and be honest about which ones did not run.
#
# Four gates: smoke.sh always; startxfce-gate.sh, charge.sh and
# account-gate.sh need root, because they exercise sockets, staged rootfs
# trees and the hotfix database. CI runs this same file with sudo, so a green
# build there means every gate ran and none were skipped.
#
# This file used to carry known-failure classifications: the CI workflow came
# over from `untested`, and on the old `gui` tree two of its tests failed
# describing work that branch never had. Those were classified by their exact
# output signatures so a real regression still went red -- and when the port
# landed (the hotfix feature and the 902-line wizard are in this tree now) and
# both tests passed, the classifications were deleted rather than kept as
# permanent excuses. That was the deal the file stated from the start. Any
# failure from here on is a regression, and it is red.
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
echo "--- tests/charge.sh: covers hotfix charge/rollback ---"
if [ "$ROOT" -ne 1 ]; then
    record charge.sh skipped "needs root; CI runs it with sudo"
elif out=$(bash tests/charge.sh 2>&1); then
    record charge.sh ok "passed"
else
    nfail=$(printf '%s\n' "$out" | grep -c '^ *FAIL ' || true)
    # This used to carry a known-signature arm for the missing hotfix logic.
    # The feature is in the tree now and the test passes, so there is nothing
    # left to classify: a failure here is a regression, and it goes red.
    record charge.sh bad "exit $? with $nfail failed assertions"
    printf '%s\n' "$out" | grep '^ *FAIL ' | head -10 | sed 's/^/    /'
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