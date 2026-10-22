#!/bin/sh
# Gate for iso/shutdown.sh (bugs 18 and 33).
#
# busybox ships halt, poweroff and reboot but no `shutdown`, so Copper ships
# its own. The wrapper's whole job is to map the usual flags onto one of those
# applets -- and the mapping is the risk: `shutdown -r now` must not power the
# machine off, and `shutdown -h now` must not reboot it. The applets themselves
# signal PID 1 (they only call reboot(2) with -f), which copper-init answers;
# that half is covered by the mapping check in tests/init-session.c.
#
# The second half is the rejection path (bug 33): an argument the wrapper does
# not understand used to fall through the flag loop and power the machine off
# immediately -- `shutdown +10` powered off at once -- so every rejected form
# must exit non-zero AND never reach an applet.
#
# The wrapper execs an absolute /sbin path, so to observe which one it picks
# without shutting anything down, this replaces /sbin inside a private mount
# namespace with stubs that print their own name. The mount is chained with
# `&&`, so if the namespace is unavailable the wrapper never runs at all --
# this test can never reach the real poweroff.
#
# Root only (mount namespace). Run: sudo tests/shutdown-gate.sh
# updated by farcrowx, bug 33, tests/shutdown-gate.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
WRAP="$REPO/iso/shutdown.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "tests/shutdown-gate.sh must run as root: sudo tests/shutdown-gate.sh" >&2
    exit 1
fi
if [ ! -f "$WRAP" ]; then
    echo "FAIL $WRAP does not exist" >&2
    exit 1
fi
command -v unshare >/dev/null 2>&1 || {
    echo "skip: no unshare"; exit 0; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/sbin"
for n in reboot poweroff halt; do
    printf '#!/bin/sh\necho %s\n' "$n" > "$TMP/sbin/$n"
    chmod 0755 "$TMP/sbin/$n"
done

# Run the wrapper with /sbin replaced. `&&` is deliberate: no mount, no run.
run_in_ns() {
    unshare -m sh -c "mount --bind '$TMP/sbin' /sbin && '$WRAP' $*" 2>/dev/null
}

if [ "$(run_in_ns now)" != "poweroff" ]; then
    echo "skip: private mount namespace unavailable; cannot observe the wrapper"
    exit 0
fi

fail=0
check() {
    want=$1; shift
    got=$(run_in_ns "$@")
    if [ "$got" = "$want" ]; then
        echo "ok   shutdown $* -> $want"
    else
        echo "FAIL shutdown $* -> $want (got '$got')"
        fail=1
    fi
}

check reboot   -r now
check reboot   --reboot now
check poweroff -h now
check poweroff -P now
check poweroff now
check halt     -H now
check poweroff               # no args: default is poweroff now
check reboot   -r -r now     # repeated same flag is not a conflict

# ---- the rejection path (bug 33) ---------------------------------------
# Same namespace, but the wrapper must refuse BEFORE exec: non-zero exit and
# no applet's name on stdout/stderr. run_err merges stderr so the refusal
# message is visible; the stubs only ever print their own bare name, so a
# line that IS a stub name means an applet ran.
run_err() {
    unshare -m sh -c "mount --bind '$TMP/sbin' /sbin && '$WRAP' $*" 2>&1
}
reject() {
    out=$(run_err "$@"); rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL shutdown $* was accepted (exit 0, '$out')"
        fail=1
        return
    fi
    if printf '%s\n' "$out" | grep -qx -e reboot -e poweroff -e halt; then
        echo "FAIL shutdown $* ran an applet anyway (exit $rc, '$out')"
        fail=1
        return
    fi
    echo "ok   shutdown $* rejected (exit $rc): $(printf '%s' "$out" | head -n 1)"
}

reject +10                 # util-linux idiom: used to power off immediately
reject 10:00
reject -r +10              # time it cannot honour must not pick a default
reject --bogus
reject -x
reject -r -h now           # conflicting modes must not be guessed at
reject now now
reject now "wall message"  # no wall support: refuse, do not power off

# --help is the one unknown-shaped flag that must succeed without exec'ing.
help_out=$(run_err --help); help_rc=$?
if [ "$help_rc" -eq 0 ] && printf '%s' "$help_out" | grep -q '^usage:'; then
    echo "ok   shutdown --help prints usage and exits 0"
else
    echo "FAIL shutdown --help (exit $help_rc, '$help_out')"
    fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "shutdown wrapper: all good"
