#!/bin/sh
# Gate for iso/shutdown.sh (bugs 18 and 33, and the live-ISO reboot report).
# Copper ships a wrapper: flags map to busybox applets, argv[0] picks the mode
# for `sudo reboot`, systemd uses --no-block, and unknown arguments must exit
# non-zero without reaching an applet.
# /sbin is bound to stubs in a mount namespace so nothing is really shut down;
# COPPER_INIT forces the branch except in the final real-detector group.
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

NS_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

# The busybox tree: applets print their name; /sbin/init is a regular file,
# so readlink finds nothing and the wrapper takes the applet branch.
mkdir -p "$TMP/sbin"
for n in reboot poweroff halt; do
    printf '#!/bin/sh\necho %s\n' "$n" > "$TMP/sbin/$n"
    chmod 0755 "$TMP/sbin/$n"
done
: > "$TMP/sbin/init"

# The systemd tree: /sbin/init is the real link and stubs print "<name>-applet",
# so a wrong fall-through is visible instead of shutting the machine down.
mkdir -p "$TMP/sysbin"
ln -sf /lib/systemd/systemd "$TMP/sysbin/init"
printf '#!/bin/sh\necho systemctl "$@"\n' > "$TMP/sysbin/systemctl"
chmod 0755 "$TMP/sysbin/systemctl"
for n in reboot poweroff halt; do
    printf '#!/bin/sh\necho %s-applet\n' "$n" > "$TMP/sysbin/$n"
    chmod 0755 "$TMP/sysbin/$n"
done

# argv[0] names, exactly as power_links installs them.
mkdir -p "$TMP/links"
for n in shutdown reboot poweroff halt; do
    ln -sf "$WRAP" "$TMP/links/$n"
done

# Run with /sbin replaced by the stub dir; `&&` means no mount, no run, and
# PATH prefers stubbed systemctl. COPPER_INIT forces the branch because the
# test host is not the image; the last group binds a fake comm file instead.
ns_run() {   # ns_run <stubdir> <program> [args...]
    d=$1; p=$2; shift 2
    unshare -m sh -c "mount --bind '$d' /sbin && PATH='$d:$NS_PATH' COPPER_INIT='${COPPER_INIT:-busybox}' '$p' $*" 2>/dev/null
}
ns_err() {   # ns_err <stubdir> <program> [args...] -- stderr merged
    d=$1; p=$2; shift 2
    unshare -m sh -c "mount --bind '$d' /sbin && PATH='$d:$NS_PATH' COPPER_INIT='${COPPER_INIT:-busybox}' '$p' $*" 2>&1
}

# Production detector, not the override: bind a fake comm file over PID 1's.
# COPPER_INIT is set to the EMPTY string so the wrapper takes its normal path.
comm_run() { # comm_run <comm> <stubdir> <program> [args...]
    c=$1; d=$2; p=$3; shift 3
    printf '%s\n' "$c" > "$TMP/pid1comm"
    unshare -m sh -c "mount --bind '$TMP/pid1comm' /proc/1/comm && mount --bind '$d' /sbin && PATH='$d:$NS_PATH' COPPER_INIT= '$p' $*" 2>/dev/null
}

comm_probe() { # print the bound comm value, or nothing if the mount is barred
    printf 'probe\n' > "$TMP/pid1comm-probe"
    unshare -m sh -c "mount --bind '$TMP/pid1comm-probe' /proc/1/comm && cat /proc/1/comm" 2>/dev/null
}

if [ "$(ns_run "$TMP/sbin" "$WRAP" now)" != "poweroff" ]; then
    echo "skip: private mount namespace unavailable; cannot observe the wrapper"
    exit 0
fi

fail=0
check() {   # check <stubdir> <program> <want> [args...]
    d=$1; p=$2; want=$3; shift 3
    got=$(ns_run "$d" "$p" "$@")
    if [ "$got" = "$want" ]; then
        echo "ok   ${p##*/} $* -> $want"
    else
        echo "FAIL ${p##*/} $* -> $want (got '$got')"
        fail=1
    fi
}

check_comm() { # check_comm <comm> <stubdir> <program> <want> [args...]
    c=$1; d=$2; p=$3; want=$4; shift 4
    got=$(comm_run "$c" "$d" "$p" "$@")
    if [ "$got" = "$want" ]; then
        echo "ok   /proc/1/comm=$c: ${p##*/} $* -> $want"
    else
        echo "FAIL /proc/1/comm=$c: ${p##*/} $* -> $want (got '$got')"
        fail=1
    fi
}

check "$TMP/sbin" "$TMP/links/shutdown" reboot   -r now
check "$TMP/sbin" "$TMP/links/shutdown" reboot   --reboot now
check "$TMP/sbin" "$TMP/links/shutdown" poweroff -h now
check "$TMP/sbin" "$TMP/links/shutdown" poweroff -P now
check "$TMP/sbin" "$TMP/links/shutdown" poweroff now
check "$TMP/sbin" "$TMP/links/shutdown" halt     -H now
check "$TMP/sbin" "$TMP/links/shutdown" poweroff          # no args: poweroff
check "$TMP/sbin" "$TMP/links/shutdown" reboot   -r -r now # repeated flag is ok

# argv[0] picks the mode: `sudo reboot` would otherwise power off.
check "$TMP/sbin" "$TMP/links/reboot"   reboot
check "$TMP/sbin" "$TMP/links/poweroff" poweroff
check "$TMP/sbin" "$TMP/links/halt"     halt
# A flag still wins over the name: `poweroff -r` means reboot.
check "$TMP/sbin" "$TMP/links/poweroff" reboot -r now

# --no-block hands the request to PID 1 and returns instead of letting the
# shutdown stop the caller's own unit. COPPER_INIT forces this branch.
COPPER_INIT=systemd
check "$TMP/sysbin" "$TMP/links/shutdown" "systemctl --no-block poweroff" now
check "$TMP/sysbin" "$TMP/links/shutdown" "systemctl --no-block reboot"   -r now
check "$TMP/sysbin" "$TMP/links/shutdown" "systemctl --no-block halt"     -H now
check "$TMP/sysbin" "$TMP/links/reboot"   "systemctl --no-block reboot"
check "$TMP/sysbin" "$TMP/links/poweroff" "systemctl --no-block poweroff"
COPPER_INIT=busybox

# /run/systemd/system exists on both the host and the busybox ISO, so it must
# not win over PID 1's comm; comm_run leaves COPPER_INIT empty on purpose.
if [ "$(comm_probe)" = probe ]; then
    check_comm copper-init "$TMP/sbin"  "$TMP/links/shutdown" reboot -r now
    check_comm systemd     "$TMP/sysbin" "$TMP/links/shutdown" "systemctl --no-block reboot" -r now
else
    echo "skip: cannot bind-mount /proc/1/comm; runtime detector not exercised"
fi

# If /sbin/init fails to read as systemd, /sbin/poweroff -> wrapper would
# recurse forever; the guard turns that into an error.
mkdir -p "$TMP/loopbin"
: > "$TMP/loopbin/init"
ln -sf "$WRAP" "$TMP/loopbin/poweroff"
loop_out=$(unshare -m sh -c \
    "mount --bind '$TMP/loopbin' /sbin && PATH='$TMP/loopbin:$NS_PATH' \
     COPPER_INIT=busybox COPPER_POWER_WRAPPER=1 '$WRAP' now" 2>&1)
loop_rc=$?
if [ "$loop_rc" -ne 0 ] && printf '%s\n' "$loop_out" | grep -q 're-entered'; then
    echo "ok   the power wrapper refuses to re-enter itself"
else
    echo "FAIL power wrapper recursion guard (exit $loop_rc, '$loop_out')"
    fail=1
fi

# Rejections must exit non-zero before any exec; stderr is merged so a bare
# stub name on either stream proves an applet ran.
reject() {
    out=$(ns_err "$TMP/sbin" "$TMP/links/shutdown" "$@"); rc=$?
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
help_out=$(ns_err "$TMP/sbin" "$TMP/links/shutdown" --help); help_rc=$?
if [ "$help_rc" -eq 0 ] && printf '%s' "$help_out" | grep -q '^usage:'; then
    echo "ok   shutdown --help prints usage and exits 0"
else
    echo "FAIL shutdown --help (exit $help_rc, '$help_out')"
    fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "shutdown wrapper: all good"
