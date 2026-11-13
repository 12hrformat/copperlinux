#!/bin/sh
# Gate for iso/shutdown.sh (bugs 18 and 33, and the live-ISO "sudo reboot stops
# halfway" report).
#
# busybox ships halt, poweroff and reboot but no `shutdown`, so Copper ships
# its own. The wrapper's whole job is to map the usual flags onto one of those
# applets -- and the mapping is the risk: `shutdown -r now` must not power the
# machine off, and `shutdown -h now` must not reboot it.
#
# It is also installed under the other power-command names: power_links makes
# /sbin/reboot, /sbin/poweroff and /sbin/halt symlinks to it, so `sudo reboot`
# reaches this file with argv[0]="reboot". The NAME has to pick the mode, or
# `sudo reboot` powers the machine off. That half is checked here by invoking
# the wrapper through real symlinks.
#
# On the systemd image the wrapper must run `systemctl --no-block`. A blocking
# systemctl waits for a transaction that stops the very unit the caller's shell
# belongs to; systemd SIGTERMs the client, the client cancels its own job, and
# the machine returns a half-stopped prompt instead of rebooting. That is the
# path `sudo reboot` takes on the shipped ISO, so it is checked here too, with
# systemctl stubbed.
#
# The rejection path (bug 33): an argument the wrapper does not understand used
# to fall through the flag loop and power the machine off immediately --
# `shutdown +10` powered off at once -- so every rejected form must exit
# non-zero AND never reach an applet.
#
# The wrapper execs an absolute /sbin path, so to observe which one it picks
# without shutting anything down, this replaces /sbin inside a private mount
# namespace with stubs that print their own name. The mount is chained with
# `&&`, so if the namespace is unavailable the wrapper never runs at all --
# this test can never reach the real poweroff. /sbin/init is a stub too, so the
# host's real init decides nothing: the systemd and busybox branches are each
# exercised deliberately.
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

NS_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

# The busybox tree: power applets print their own name, and /sbin/init is a
# REGULAR FILE, so `readlink /sbin/init` prints nothing and the wrapper must
# take the applet branch.
mkdir -p "$TMP/sbin"
for n in reboot poweroff halt; do
    printf '#!/bin/sh\necho %s\n' "$n" > "$TMP/sbin/$n"
    chmod 0755 "$TMP/sbin/$n"
done
: > "$TMP/sbin/init"

# The systemd tree: /sbin/init is the link systemd installs, and systemctl is a
# stub. The applet stubs are still there, printing "<name>-applet", so a wrapper
# that wrongly falls through to /sbin/poweroff is visible as the wrong answer
# instead of quietly shutting the test machine down.
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

# Run <program> with /sbin replaced by <stubdir>. `&&` is deliberate: no mount,
# no run. PATH starts with the stub dir so a stubbed systemctl wins over the
# host's real one; readlink and sync still resolve from the usual places.
ns_run() {   # ns_run <stubdir> <program> [args...]
    d=$1; p=$2; shift 2
    unshare -m sh -c "mount --bind '$d' /sbin && PATH='$d:$NS_PATH' '$p' $*" 2>/dev/null
}
ns_err() {   # ns_err <stubdir> <program> [args...] -- stderr merged
    d=$1; p=$2; shift 2
    unshare -m sh -c "mount --bind '$d' /sbin && PATH='$d:$NS_PATH' '$p' $*" 2>&1
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

check "$TMP/sbin" "$TMP/links/shutdown" reboot   -r now
check "$TMP/sbin" "$TMP/links/shutdown" reboot   --reboot now
check "$TMP/sbin" "$TMP/links/shutdown" poweroff -h now
check "$TMP/sbin" "$TMP/links/shutdown" poweroff -P now
check "$TMP/sbin" "$TMP/links/shutdown" poweroff now
check "$TMP/sbin" "$TMP/links/shutdown" halt     -H now
check "$TMP/sbin" "$TMP/links/shutdown" poweroff          # no args: poweroff
check "$TMP/sbin" "$TMP/links/shutdown" reboot   -r -r now # repeated flag is ok

# ---- argv[0] picks the mode (power_links installs these links) ---------------
# Without the name logic, `sudo reboot` -- which is a symlink to this file --
# would power the machine off.
check "$TMP/sbin" "$TMP/links/reboot"   reboot
check "$TMP/sbin" "$TMP/links/poweroff" poweroff
check "$TMP/sbin" "$TMP/links/halt"     halt
# A flag still wins over the name: `poweroff -r` means reboot.
check "$TMP/sbin" "$TMP/links/poweroff" reboot -r now

# ---- the systemd image: systemctl --no-block --------------------------------
# The request must be handed to PID 1 and returned, not waited on. --no-block
# is what stops the shutdown from cancelling itself by stopping the caller.
check "$TMP/sysbin" "$TMP/links/shutdown" "systemctl --no-block poweroff" now
check "$TMP/sysbin" "$TMP/links/shutdown" "systemctl --no-block reboot"   -r now
check "$TMP/sysbin" "$TMP/links/shutdown" "systemctl --no-block halt"     -H now
check "$TMP/sysbin" "$TMP/links/reboot"   "systemctl --no-block reboot"
check "$TMP/sysbin" "$TMP/links/poweroff" "systemctl --no-block poweroff"

# The recursion guard: if /sbin/init ever fails to read as systemd on a systemd
# machine, the link /sbin/poweroff -> this wrapper would exec itself forever.
# The guard turns that into an error. Its stub tree is the busybox branch with
# /sbin/poweroff pointing back at the wrapper, which is exactly that shape.
mkdir -p "$TMP/loopbin"
: > "$TMP/loopbin/init"
ln -sf "$WRAP" "$TMP/loopbin/poweroff"
loop_out=$(unshare -m sh -c \
    "mount --bind '$TMP/loopbin' /sbin && PATH='$TMP/loopbin:$NS_PATH' \
     COPPER_POWER_WRAPPER=1 '$WRAP' now" 2>&1)
loop_rc=$?
if [ "$loop_rc" -ne 0 ] && printf '%s\n' "$loop_out" | grep -q 're-entered'; then
    echo "ok   the power wrapper refuses to re-enter itself"
else
    echo "FAIL power wrapper recursion guard (exit $loop_rc, '$loop_out')"
    fail=1
fi

# ---- the rejection path (bug 33) ---------------------------------------
# Same namespace, but the wrapper must refuse BEFORE exec: non-zero exit and
# no applet's name on stdout/stderr. run_err merges stderr so the refusal
# message is visible; the stubs only ever print their own bare name (or
# "systemctl ..."), so a line that IS a stub name means an applet ran.
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
