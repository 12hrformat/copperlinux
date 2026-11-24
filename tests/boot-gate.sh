#!/usr/bin/env bash
# boot-gate.sh -- boot the built ISO in QEMU and prove the machine comes up.
# Every other gate is structural or stubbed, so all can be green while the disc
# does not start: GRUB, kernel, initramfs, medium discovery, overlay and PID 1
# only exist together on the ISO.
# grub asserts the initramfs handover and the network; --serial proves the wizard
# gets a console; --systemd proves /init execs systemd and its units start.
# Uses KVM when usable, TCG otherwise; BOOT_TIMEOUT covers slow emulation.
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

  tests/boot-gate.sh [--grub|--serial|--systemd] [--timeout=N] [iso]

  --grub        boot through the disc's own GRUB (default)
  --serial      boot kernel+initrd directly with ttyS0 as the console
  --systemd     boot kernel+initrd directly, asking for the systemd init
                (copper.init=systemd), and watch it reach the Copper units
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
    --systemd)  MODE=systemd ;;
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
    echo "boot-gate: $QEMU is not installed (install qemu-system-x86)" >&2
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
# Ctrl-C must exit so cleanup is not followed by grepping a deleted log.
trap 'exit 130' INT
trap 'exit 143' TERM

# Use KVM only when this user can open /dev/kvm; fall back quietly otherwise.
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
        -audiodev driver=none,id=aud0 \
        -device intel-hda -device hda-duplex,audiodev=aud0 \
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

# The last console screenful says whether it stopped in GRUB, kernel or PID 1.
dump_log() {
    [ -s "$LOG" ] || { say "the serial console is empty"; return; }
    say "last 40 serial lines:"
    tail -n 40 "$LOG" | sed 's/^/  | /'
}

failed=0

say "booting $ISO in $MODE mode ($ACCEL_NAME, ${MEM}MiB, ${CPUS} vCPU, ${TIMEOUT}s)"

case "$MODE" in
grub)
# -boot d boots the disc; the NIC is explicit because build.sh asserts E1000.
# The skip lines only shorten the wait and are still reported as failures.
    start_qemu -cdrom "$ISO" -boot d -nic user,model=e1000

# The handover is stricter than any prompt: /init must find the medium.
    wait_for 'copper: handing over to copper-init' "the initramfs handover"; rc=$?
    report "$rc" "GRUB, the kernel, the initramfs and the overlay reached PID 1"
    [ "$rc" -eq 0 ] || failed=1

# Without the handover, waiting another deadline only delays the report.
    if [ "$failed" -eq 0 ]; then
        wait_for 'copper(-[a-z]+)?: .*(is up, asking DHCP|no network interface|skipping DHCP)' \
            "the network setup"; rc=$?
# The skip lines mean the interface never came up, so they are failures; they
# just end the wait quickly. The prefix varies: busybox logs "copper:", while
# systemd's DHCP and lease units log as copper-dhcp:/copper-net:.
        if [ "$rc" -eq 0 ] && grep -qE 'copper(-[a-z]+)?: .*is up, asking DHCP' "$LOG"; then
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

# ttyS0 is the only console; nosplash keeps Plymouth off the serial log.
    start_qemu -kernel "$WORK/vmlinuz" -initrd "$WORK/initrd.img" \
        -append 'console=ttyS0,115200 rdinit=/init nosplash' \
        -cdrom "$ISO" -nic user,model=e1000

    wait_for 'Welcome to Copper Linux' "the first-boot wizard"; rc=$?
    report "$rc" "the wizard started on a terminal (kernel, /init, overlay, console)"
    [ "$rc" -eq 0 ] || failed=1
    ;;
systemd)
# The unified image's other half: boot the entry's own command line on serial,
# since a headless guest has no tty0 to read systemd's status from.
    command -v xorriso >/dev/null 2>&1 || {
        echo "boot-gate: --systemd needs xorriso to extract the kernel" >&2
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

    start_qemu -kernel "$WORK/vmlinuz" -initrd "$WORK/initrd.img" \
        -append 'console=ttyS0,115200 rdinit=/init nosplash copper.init=systemd' \
        -cdrom "$ISO" -nic user,model=e1000

# Only the systemd branch prints this handover line.
    wait_for 'handing over to systemd \(copper\.init=systemd\)' \
        "the initramfs handing over to systemd"; rc=$?
    report "$rc" "/init read copper.init=systemd and exec'd /lib/systemd/systemd"
    [ "$rc" -eq 0 ] || failed=1

# Systemd starts the wizard as a unit, so wait for "Starting/Started", not its
# greeting: a busybox boot never prints these. Match the shipped unit NAME and
# Description, since noble wraps the name in colour escapes.
    if [ "$failed" -eq 0 ]; then
        wait_for 'copper-(firstboot|console)\.service.*Copper (first-boot wizard|console)' \
            "systemd starting the Copper units"; rc=$?
        report "$rc" "systemd started the Copper units (wizard/console)"
        [ "$rc" -eq 0 ] || failed=1
    fi
    ;;
esac

# A milestone can be seen and the machine dead a second later. Check again
# after a short pause so a later panic cannot slip through.
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
