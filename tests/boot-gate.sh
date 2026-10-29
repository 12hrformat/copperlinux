#!/usr/bin/env bash
# boot-gate.sh -- boot the built ISO in QEMU and prove the machine comes up.
#
# Every other gate is structural (grep a unit, extract a function), stubbed
# (fake mkfs, fake sudo), or replayed in a mount namespace. That is how they
# stay fast and rootless, and it is also how they can all be green while the
# disc does not start: GRUB, the kernel, the initramfs, finding the medium,
# the overlay and PID 1 only exist together on the ISO.
#
# So this starts the real image and reads its serial console. In grub mode it
# asserts that copper-init ran and brought the network up -- the last thing it
# says on the serial port before the first-boot wizard takes the console and
# waits for a human. The wizard itself is driven for real by
# tests/account.sh, so stopping there is deliberate: this gate is about the
# boot chain, not about answering questions.
#
#   grub    (default) boot the ISO through its own GRUB. Proves the disc is
#           bootable, the default entry is chosen without input, and the
#           command line the image ships is the one that runs.
#   serial  boot the kernel and initrd extracted from the ISO with ttyS0 as
#           /dev/console, so the wizard draws where this gate can see it.
#           Proves the wizard gets a terminal. The GRUB entry cannot show that:
#           tty0 is the console there, and a headless VM has no tty0.
#
# Uses KVM when /dev/kvm is usable and TCG otherwise. TCG is several times
# slower, which is why the deadline is minutes rather than seconds and why
# BOOT_TIMEOUT exists.
#
#   tests/boot-gate.sh iso/out/copper.iso
#   tests/boot-gate.sh --serial iso/out/copper.iso
#   BOOT_TIMEOUT=600 tests/boot-gate.sh            # slow software emulation
#
# Exit: 0 booted, 1 did not, 2 usage or missing tool/ISO.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
QEMU=${QEMU:-qemu-system-x86_64}
TIMEOUT=${BOOT_TIMEOUT:-300}
MEM=${BOOT_MEM:-1024}
CPUS=${BOOT_CPUS:-2}
MODE=grub
ISO=

usage() {
    cat <<'EOF'
boot-gate.sh -- boot a Copper ISO in QEMU and check it comes up

  tests/boot-gate.sh [--grub|--serial] [--timeout=N] [iso]

  --grub        boot through the disc's own GRUB (default)
  --serial      boot kernel+initrd directly with ttyS0 as the console
  --timeout=N   seconds to wait for a milestone (default 300, BOOT_TIMEOUT)

Environment:
  QEMU          the emulator to run (default qemu-system-x86_64)
  BOOT_TIMEOUT  deadline in seconds (default 300)
  BOOT_MEM      guest memory in MiB (default 1024)
  BOOT_CPUS     guest vCPUs (default 2)

Exit: 0 booted, 1 did not, 2 usage or missing tool/ISO.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
    --grub)     MODE=grub ;;
    --serial)   MODE=serial ;;
    --timeout=*) TIMEOUT=${1#*=} ;;
    --timeout)  shift; TIMEOUT=${1:-} ;;
    --help|-h)  usage; exit 0 ;;
    -*)         echo "boot-gate: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)
        [ -z "$ISO" ] || { echo "boot-gate: more than one ISO given" >&2; exit 2; }
        ISO=$1
        ;;
    esac
    shift
done

[ -n "$ISO" ] || ISO=$REPO/iso/out/copper.iso
[ -f "$ISO" ] || {
    echo "boot-gate: no ISO at $ISO" >&2
    echo "  build one first: sudo bash iso/build.sh iso" >&2
    exit 2
}
command -v "$QEMU" >/dev/null 2>&1 || {
    echo "boot-gate: $QEMU is not installed (Debian: qemu-system-x86)" >&2
    exit 2
}
case "$TIMEOUT" in
    ''|*[!0-9]*) echo "boot-gate: timeout must be a number of seconds" >&2; exit 2 ;;
esac
[ "$TIMEOUT" -gt 0 ] || { echo "boot-gate: timeout must be positive" >&2; exit 2; }

WORK=$(mktemp -d)
LOG=$WORK/serial.log
QEMU_PID=

say() { printf 'boot-gate: %s\n' "$*"; }
note_ok()  { printf '  ok   %s\n' "$1"; }
note_bad() { printf '  FAIL %s\n' "$1"; }

stop_qemu() {
    [ -n "$QEMU_PID" ] || return 0
    kill "$QEMU_PID" 2>/dev/null
    for _ in 1 2 3 4 5; do
        kill -0 "$QEMU_PID" 2>/dev/null || break
        sleep 1
    done
    kill -9 "$QEMU_PID" 2>/dev/null
    wait "$QEMU_PID" 2>/dev/null
    QEMU_PID=
}

cleanup() {
    stop_qemu
    rm -rf "$WORK"
}
trap cleanup EXIT
# Without the exit, a Ctrl-C runs the cleanup and then the loop carries on
# grepping a log that cleanup just deleted, so the gate sits out its deadline
# instead of stopping.
trap 'exit 130' INT
trap 'exit 143' TERM

# KVM is worth several minutes on a slow runner, but only when the device is
# actually usable by this user -- an unreadable /dev/kvm falls back quietly
# rather than failing the gate for a reason that has nothing to do with the ISO.
ACCEL=()
if [ -r /dev/kvm ] && [ -w /dev/kvm ] &&
   "$QEMU" -accel help 2>/dev/null | grep -qw kvm; then
    ACCEL=(-accel kvm -cpu host)
    ACCEL_NAME=kvm
else
    ACCEL=(-accel tcg,thread=multi)
    ACCEL_NAME=tcg
fi

# start_qemu <extra args...>
start_qemu() {
    : > "$LOG"
    "$QEMU" -m "$MEM" -smp "$CPUS" -no-reboot \
        -display none -serial stdio -monitor none \
        "${ACCEL[@]}" "$@" </dev/null >"$LOG" 2>&1 &
    QEMU_PID=$!
}

# wait_for <extended-regex> <what>
#   0 seen, 1 deadline, 2 the kernel panicked, 3 qemu exited
wait_for() {
    local rx=$1 what=$2
    local deadline=$((SECONDS + TIMEOUT))

    while [ "$SECONDS" -lt "$deadline" ]; do
        if grep -qE "$rx" "$LOG" 2>/dev/null; then
            return 0
        fi
        if grep -qE 'Kernel panic|Attempted to kill init|not syncing:' \
                "$LOG" 2>/dev/null; then
            say "the kernel panicked while waiting for $what"
            return 2
        fi
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            say "QEMU exited while waiting for $what"
            return 3
        fi
        sleep 1
    done
    say "timed out after ${TIMEOUT}s waiting for $what"
    return 1
}

report() { # report <wait_for status> <description>
    case "$1" in
        0) note_ok "$2" ;;
        *) note_bad "$2" ;;
    esac
}

# A failed boot is only diagnosable from the console, and the last screenful is
# what says whether it stopped in GRUB, the kernel, the initramfs or PID 1.
dump_log() {
    [ -s "$LOG" ] || { say "the serial console is empty"; return; }
    say "last 40 serial lines:"
    tail -n 40 "$LOG" | sed 's/^/  | /'
}

failed=0

say "booting $ISO in $MODE mode ($ACCEL_NAME, ${MEM}MiB, ${CPUS} vCPU, ${TIMEOUT}s)"

case "$MODE" in
grub)
    # -boot d: the CD is the boot device. The NIC is explicit, and build.sh
    # asserts CONFIG_E1000=y, so the interface has to come up -- the gate's
    # pattern also accepts the no-interface line only so a missing driver is
    # reported in a second instead of waiting out the deadline.
    start_qemu -cdrom "$ISO" -boot d -nic user,model=e1000

    # The initramfs says this immediately before switch_root. It is a stricter
    # milestone than any "copper:" line, because /init is what finds the
    # medium and builds the overlay: nothing after it can run unless both
    # worked.
    wait_for 'copper: handing over to copper-init' "the initramfs handover"; rc=$?
    report "$rc" "GRUB, the kernel, the initramfs and the overlay reached PID 1"
    [ "$rc" -eq 0 ] || failed=1

    # If the handover never happened, the network milestone cannot, and waiting
    # another full deadline only delays the failure report.
    if [ "$failed" -eq 0 ]; then
        wait_for 'copper: .*(is up, asking DHCP|no network interface|skipping DHCP)' \
            "the network setup"; rc=$?
        # The emulated card is always attached and the kernel is built with the
        # driver, so the skip lines mean the interface never came up. Those are
        # failures, not a machine without a NIC -- but matching them ends the
        # wait immediately instead of letting it time out.
        if [ "$rc" -eq 0 ] && grep -qE 'copper: .*is up, asking DHCP' "$LOG"; then
            note_ok "copper-init brought the emulated NIC up and said so on the serial port"
        else
            [ "$rc" -eq 0 ] && say "copper-init reported no usable network interface"
            note_bad "copper-init brought the emulated NIC up and said so on the serial port"
            failed=1
        fi
    fi
    ;;
serial)
    command -v xorriso >/dev/null 2>&1 || {
        echo "boot-gate: --serial needs xorriso to extract the kernel" >&2
        exit 2
    }
    xorriso -osirrox on -indev "$ISO" \
        -extract /boot/vmlinuz "$WORK/vmlinuz" \
        -extract /boot/initrd.img "$WORK/initrd.img" \
        >/dev/null 2>"$WORK/xorriso.err" || {
        say "could not extract the kernel and initrd from the ISO"
        sed 's/^/  | /' "$WORK/xorriso.err" >&2
        exit 1
    }

    # ttyS0 is /dev/console here because it is the only console=, so the
    # wizard's stdout is this log. nosplash keeps Plymouth out of the way: a
    # headless guest has no framebuffer, and the splash is not what this mode
    # is asking about.
    start_qemu -kernel "$WORK/vmlinuz" -initrd "$WORK/initrd.img" \
        -append 'console=ttyS0,115200 rdinit=/init nosplash' \
        -cdrom "$ISO" -nic user,model=e1000

    wait_for 'Welcome to Copper Linux' "the first-boot wizard"; rc=$?
    report "$rc" "the wizard started on a terminal (kernel, /init, overlay, console)"
    [ "$rc" -eq 0 ] || failed=1
    ;;
esac

# A milestone can be seen and the machine still be dead a second later: a
# panic after the last 'copper:' line is exactly the failure this gate exists
# to catch, and a grep that stops at the first match would miss it. Give the
# guest a moment, then look again.
if [ "$failed" -eq 0 ]; then
    sleep 3
    if grep -qE 'Kernel panic|Attempted to kill init|not syncing:' "$LOG"; then
        note_bad "the kernel panicked after the milestones were seen"
        failed=1
    else
        note_ok "the guest was still alive after the milestones"
    fi
fi

if [ "$failed" -ne 0 ]; then
    dump_log
    echo "boot-gate: FAILED"
    exit 1
fi

stop_qemu
echo "boot-gate: the image booted"
exit 0
