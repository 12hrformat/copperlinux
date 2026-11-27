#!/usr/bin/env bash
# Gate for require_kernel_config() in iso/build.sh.
# A symbol whose dependencies are unmet is accepted by scripts/config, dropped
# by olddefconfig without a word, and only discovered at boot: a dead machine
# with no disk, screen or network. Until this file, nothing tested the tester.
# Extract the shipped function with sed and run it on synthetic configs:
# a complete one must pass, and one with each symbol removed in turn must fail
# and name it. Structural only -- no kernel build.
# Run: bash tests/kernel-gate.sh   (no root needed)

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$REPO/iso/build.sh"
[ -f "$BUILD" ] || { echo "FAIL no $BUILD" >&2; exit 1; }

pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1${2:+ -- $2}"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Pull the real function out of build.sh; if it moves, sed finds nothing and
# the eval fails loudly, which is the point.
fn=$(sed -n '/^require_kernel_config()/,/^}/p' "$BUILD")
if [ -z "$fn" ]; then
    echo "FAIL could not extract require_kernel_config() from $BUILD" >&2
    exit 1
fi
eval "$fn"

# Scrape symbols from the function's own `for sym in` loops, not from all caps
# words: comments and messages mention VMWARE_VMXNET3, SPI, FC and QEMU too, and
# deleting one of those from the config must not be misreported here.
symbols() {
    printf '%s\n' "$fn" \
        | awk '
            /for sym in/ { inlist=1; sub(/.*for sym in/, "") }
            inlist {
                line=$0
                done = (line ~ /; *do/)
                sub(/; *do.*/, "", line)
                gsub(/\\/, " ", line)
                print line
                if (done) inlist=0
            }
        ' \
        | tr -s ' \t' '\n' \
        | grep -E '^[A-Z][A-Za-z0-9_]+$' \
        | sort -u
}

# A config that satisfies EVERY symbol the function asks for.
write_complete_config() {
    local out="$1" s
    : > "$out"
    for s in $(symbols); do
        printf 'CONFIG_%s=y\n' "$s" >> "$out"
    done
}

complete="$TMP/complete.config"
write_complete_config "$complete"

# ---- 1. the complete config passes -----------------------------------------
if out=$(require_kernel_config "$complete" 2>&1); then
    ok "a config carrying every asserted symbol passes"
else
    bad "a config carrying every asserted symbol passes" "$out"
fi

# ---- 2. each symbol, removed, is caught ------------------------------------
n=0
for s in $(symbols); do
    n=$((n + 1))
    c="$TMP/missing-$s.config"
    grep -v "^CONFIG_$s=y\$" "$complete" > "$c"
    if out=$(require_kernel_config "$c" 2>&1); then
        bad "$s missing is rejected" "the function accepted a config with no CONFIG_$s"
    elif printf '%s' "$out" | grep -q "$s"; then
        ok "$s missing is rejected, and named"
    else
        bad "$s missing is rejected, and named" "rejected but did not name it: $out"
    fi
done
echo "  (checked $n asserted symbols, one deletion each)"

# ---- 3. a file that is not a config at all is rejected, not crashed on ------
: > "$TMP/empty.config"
if out=$(require_kernel_config "$TMP/empty.config" 2>&1); then
    bad "an empty config is rejected" "accepted an empty file"
else
    ok "an empty config is rejected"
fi

# These are the dead-machine classes: overlay upper, framebuffer, disk, NIC.
# Asserted by name so a refactor dropping a class is caught here, not at boot.
for cls in DEVTMPFS OVERLAY_FS EXT4_FS \
           FB FRAMEBUFFER_CONSOLE DRM_BOCHS DRM_VMWGFX DRM_VIRTIO_GPU \
           SCSI BLK_DEV_SD BLK_DEV_NVME ATA_PIIX \
           SCSI_MPT3SAS VMWARE_PVSCSI SCSI_VIRTIO \
           SWAP ZRAM ZSMALLOC \
           NET INET E1000 VIRTIO_NET \
           SOUND SND SND_ENS1370 SND_ENS1371 SND_AC97_CODEC SND_USB_AUDIO ; do
    if symbols | grep -qx "$cls"; then
        ok "asserts $cls"
    else
        bad "asserts $cls" "not in the asserted symbol list"
    fi
done

echo
if [ "$fail" -eq 0 ]; then
    echo "kernel config gate: all checks passed ($pass checks)"
    exit 0
fi
echo "kernel config gate: $fail failed"
exit 1
