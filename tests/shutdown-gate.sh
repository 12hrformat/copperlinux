#!/bin/sh
# Gate for iso/shutdown.sh (BUGS.md #18).
#
# busybox ships halt, poweroff and reboot but no `shutdown`, so Copper ships
# its own. The wrapper's whole job is to map the usual flags onto one of those
# applets -- and the mapping is the risk: `shutdown -r now` must not power the
# machine off, and `shutdown -h now` must not reboot it. The applets themselves
# signal PID 1 (they only call reboot(2) with -f), which copper-init answers;
# that half is covered by the mapping check in tests/init-session.c.
#
# The wrapper execs an absolute /sbin path, so to observe which one it picks
# without shutting anything down, this replaces /sbin inside a private mount
# namespace with stubs that print their own name. The mount is chained with
# `&&`, so if the namespace is unavailable the wrapper never runs at all --
# this test can never reach the real poweroff.
#
# Root only (mount namespace). Run: sudo tests/shutdown-gate.sh

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

[ "$fail" -eq 0 ] || exit 1
echo "shutdown wrapper: all good"
