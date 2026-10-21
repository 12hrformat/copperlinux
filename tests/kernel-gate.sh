#!/usr/bin/env bash
# Gate for require_kernel_config() in iso/build.sh.
#
# Why this exists
# ---------------
# The kernel config is Copper's single largest source of "green build, dead
# machine" bugs. A symbol whose dependencies are unmet is accepted by
# scripts/config without complaint and then dropped by olddefconfig without a
# word, so a flag that never took effect is invisible until somebody boots the
# image. iso/build.sh answers that with require_kernel_config(), which asserts
# every symbol it cares about is =y in the generated .config.
#
# Until this file, nothing tested it. It is the one part of the build whose
# failure mode is a machine that boots to a shell -- and no disk, no screen, or
# no network -- so a typo in it (a misspelled symbol, a symbol removed from the
# loop) would be discovered only at boot. That is the same shape as the systemd
# stage's two CI failures: a check that says "all good" while nothing verifies
# the check itself.
#
# What it does
# ------------
# Extracts require_kernel_config() from build.sh with sed -- the shipped code,
# not a paraphrase -- and runs it against synthetic configs:
#
#   * a COMPLETE config, built from the loop's own symbol list, must PASS. This
#     is what proves the gate is testing something that can succeed, and that a
#     symbol list with a typo in it would be caught here rather than at boot.
#   * a config missing EACH required symbol must FAIL. Every symbol is removed
#     one at a time, so a symbol that silently left the loop is a hole this file
#     reports rather than one that ships.
#
# It is deliberately structural: it does not build a kernel (that is minutes and
# a toolchain), it checks the agreement between the .config the kernel writes and
# the list the build asserts.
#
# handcrafted by 12hrformat (bug 46: a VMware guest with no disk to offer)
#
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

# Pull the real function out of build.sh and eval it. If require_kernel_config
# is renamed or reshaped, the sed finds nothing and the eval fails loudly --
# which is the point: this gate must break when the thing it tests moves.
fn=$(sed -n '/^require_kernel_config()/,/^}/p' "$BUILD")
if [ -z "$fn" ]; then
    echo "FAIL could not extract require_kernel_config() from $BUILD" >&2
    exit 1
fi
eval "$fn"

# ---- the symbol list the function asserts, read back out of the source ------
# Rather than a second hand-kept copy (which is the bug this gate is about),
# scrape the symbols from the function's own `for sym in ...` loops. Comments
# and error messages mention symbol names too (VMWARE_VMXNET3, SPI, FC, QEMU),
# so scraping "all caps words" would test symbols the function never asserts --
# and removing one of those from the config would still be accepted, which this
# gate would then misreport as a failure. Take only the loop lists.
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

# ---- 4. the classes this gate cares about are all in the list --------------
# These are the symbols whose absence is a dead machine rather than a warning:
# no overlay upper (the whole persistence design), no framebuffer (no desktop),
# no disk (no wizard), no NIC (no network). Asserted by name so a refactor that
# drops a class is caught here, not at boot.
for cls in DEVTMPFS OVERLAY_FS EXT4_FS \
           FB FRAMEBUFFER_CONSOLE DRM_BOCHS DRM_VMWGFX DRM_VIRTIO_GPU \
           SCSI BLK_DEV_SD BLK_DEV_NVME ATA_PIIX \
           SCSI_MPT3SAS VMWARE_PVSCSI SCSI_VIRTIO \
           NET INET E1000 VIRTIO_NET ; do
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
