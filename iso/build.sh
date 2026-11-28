#!/usr/bin/env bash
# Copper Linux
# build.sh — assemble Copper Linux, a from-source Linux distro, into a
# bootable live ISO. The base system is built from upstream source in this
# script (kernel, musl, busybox, coreutils and friends) plus Copper's own
# pieces (copper-sh, copper-init, first-boot wizard). The display stack is
# the one exception: Xorg and XFCE are real distributions' packages,
# downloaded and unpacked into the rootfs by the gui stage, because
# building a desktop and the glibc toolchain behind it here would be a
# distribution of its own. That happens at build time; the image itself
# never asks the network for anything.
#
# Usage:
#   sudo bash iso/build.sh               # everything, in order
#   sudo bash iso/build.sh <stage>       # one stage only
#
# Stages: kernel | base | tools | copper | rootfs | gui | niri |
#         plymouth | sudo | systemd | unified | initramfs | iso
#
# systemd is opt-in and deliberately NOT part of `all`: see build_systemd. A
# normal build is the busysbox-init image the gates and the ISO expect; the
# systemd stage is the migration, run on purpose.
#
# Stages share iso/work/, so CI can run them one step at a time and each
# step skips straight past whatever is already built.

set -euo pipefail

# Every stage below stamps itself with a hash of this script, because that is
# where the kernel version and the config flags live. $0 is whatever was
# typed on the command line — CI runs `sudo bash iso/build.sh kernel`, so it
# is the relative "iso/build.sh" — and the cd on the next line stops it
# resolving. Pin it down first.
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
cd "$(dirname "$0")"
ROOT=$(pwd)
# ROOT is iso/; REPO is the parent for gates that list tracked files and run top-level scripts.
# Without this assignment `set -u` aborts thirteen minutes into a build with "REPO: unbound variable".
REPO=$(cd "$ROOT/.." && pwd)
WORK="$ROOT/work"; OUT="$ROOT/out"; DL="$WORK/downloads"
SYS="$WORK/sys"            # our toolchain prefix (musl + musl-gcc)
TGT="$WORK/rootfs"         # copper rootfs staging tree
JOBS=${JOBS:-$(nproc)}
export MAKEFLAGS="-j$JOBS"
# coreutils' configure refuses to run as root; CI builds via sudo, so
# pass its documented bypass (cross checks have no runtime step anyway).
export FORCE_UNSAFE_CONFIGURE=1

# Kernel version to build. Pinned LTS on purpose — distro builds should be
# reproducible, not "latest at build time". Bump this when we want a newer
# LTS; override with KREL=6.6.x if you need a different series.
KREL=${KREL:-6.12.10}
KPATH="v${KREL%%.*}.x"

# The niri session's configuration tree is vendored in this repository under
# iso/rootfs-overlay/usr/share/copper/niri-skel; build_niri copies it into the
# image. It was originally fetched from 12hrformat/copper-niriconfig, and these
# two constants record the commit and tarball hash it was vendored from, so the
# provenance of the shipped bytes is not lost.
NIRI_CFG_SHA=31f547783a964bad3be73fafa0f7215a035aea9c
NIRI_CFG_SHA256=5834dc358e8f0df9691b2c33dd3b2808d172aac771c07a249e5549bd6f0e76ce

# The praksharma/ubuntu-niri PPA for noble, with a verified fingerprint.
NIRI_PPA_URL="https://ppa.launchpadcontent.net/praksharma/ubuntu-niri/ubuntu"
NIRI_PPA_FPR="B2AA0C43F73505B5A65A53D26EE0350540BB4F59"

# Boot media is pluggable. build.sh asks the selected provider to render the
# shared iso/boot/entries list and to package the staged tree; GRUB is the
# provider that ships, but setting COPPER_BOOTLOADER=<name> selects any
# directory under iso/bootloaders/ that exports the two hooks documented in
# iso/bootloaders/README.md.
BOOTLOADER=${COPPER_BOOTLOADER:-grub}
BOOTLOADER_DIR="$ROOT/bootloaders/$BOOTLOADER"
if [ ! -f "$BOOTLOADER_DIR/provider.sh" ]; then
  echo "build.sh: no bootloader provider at iso/bootloaders/$BOOTLOADER/provider.sh" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$BOOTLOADER_DIR/provider.sh"
for hook in bootloader_configure bootloader_make_iso; do
  if ! declare -F "$hook" >/dev/null; then
    echo "build.sh: bootloader provider '$BOOTLOADER' does not define $hook" >&2
    exit 2
  fi
done
# Optional: the GRUB provider reads its own menu back off the disc. A provider
# with a different layout may check something else, or nothing.
BOOTLOADER_HAS_CHECK=0
if declare -F bootloader_check >/dev/null; then BOOTLOADER_HAS_CHECK=1; fi

STAGE=${1:-all}

[ "$(id -u)" = 0 ] || { echo "build.sh: run with sudo/root"; exit 1; }
command -v wget >/dev/null || { echo "build.sh: need wget"; exit 1; }

mkdir -p "$DL" "$OUT" "$SYS"/{bin,lib} \
  "$TGT"/{bin,sbin,usr/bin,usr/sbin,usr/share,etc,dev,proc,sys,run,tmp,home,root,var/log,mnt,boot}

# The scripts we ship are read by busybox ash on a machine with no shell
# anybody can ssh into, so a typo in one is found the hard way. Parse them
# here, where failing costs a second instead of a boot.
lint_scripts() {
  local s
  for s in "$ROOT/live/init" "$ROOT/rootfs-overlay/usr/share/udhcpc/default.script" \
           "$ROOT/rootfs-overlay/usr/bin/ingot" \
           "$ROOT/rootfs-overlay/usr/bin/copper-audio" \
           "$ROOT/startxfce.sh" "$ROOT/startniri.sh" "$ROOT/starthyprland.sh" \
           "$ROOT/bootloaders/grub/provider.sh"; do
    sh -n "$s" || { echo "build.sh: syntax error in $s"; exit 1; }
  done
  echo "scripts: live/init, the udhcpc lease script, ingot, copper-audio, startxfce, startniri, starthyprland and the GRUB provider parse clean"
}
lint_scripts

# ---- stage caching -----------------------------------------------------
# A stale cached tree once shipped an old initrd; hash each stage's inputs so a warm cache cannot lie.
stamped_skip() {   # stamped_skip <stamp> <input>...
  local stamp="$1" want f; shift
  # An input we can't read means we can't know whether the stage is current.
  # Rebuild rather than guess, and say which file is missing.
  for f in "$@"; do
    [ -r "$f" ] || { echo "build.sh: cannot read stamp input $f" >&2; return 1; }
  done
  want=$(cat "$@" | sha256sum | cut -d' ' -f1)
  [ -s "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$want" ]
}

stamp_set() {      # stamp_set <stamp> <input>...
  local stamp="$1" f missing=0; shift
  for f in "$@"; do
    [ -r "$f" ] || { echo "build.sh: cannot read stamp input $f" >&2; missing=1; }
  done
  if [ "$missing" -ne 0 ]; then
    # Leave the stamp empty rather than recording a hash of half the inputs.
    # An empty stamp never matches, so this stage rebuilds next time too.
    : > "$stamp"
    return 0
  fi
  cat "$@" | sha256sum | cut -d' ' -f1 > "$stamp"
}

# Hash the staged tree from inside it so paths stay runner-independent; include symlink targets,
# because a different init link is a different image. This is what stops a stale artifact with a green light.
tree_hash() {      # tree_hash <dir>
  ( cd "$1" && {
      find . -type f -exec sha256sum {} + | LC_ALL=C sort
      find . -type l -printf 'link %p -> %l\n' | LC_ALL=C sort
      find . \! -type f \! -type l \! -type d -printf 'other %p %y\n' | LC_ALL=C sort
    } ) | sha256sum | cut -d' ' -f1
}

fetch() {                   # fetch url -> prints tarball path (stdout only)
  local url="$1"
  local f="$DL/${1##*/}"
  [ -s "$f" ] && { echo "$f"; return; }
  echo "  < $url" >&2
  # Download to the side and rename: an interrupted wget leaves a partial
  # file, and the existence test above would trust that file forever after.
  wget -t 3 -O "$f.part" "$url"
  [ -s "$f.part" ] || { echo "fetch failed: $url" >&2; exit 1; }
  mv "$f.part" "$f"
  echo "$f"
}

unpack() {                  # unpack tarball -> prints its dir
  local f="$1"
  local d="${f%.tar.*}"
  [ "$d" != "$f" ] || { echo "build.sh: unexpected archive name: $f" >&2; exit 1; }
  # A directory without the marker is an extraction that was interrupted --
  # make then dies on the first file that is not there, far from the cause,
  # and the half-tree gets reused on every following run because it exists.
  # Throw it away and unpack it again instead.
  if [ ! -f "$d/.unpacked" ]; then
    if [ -d "$d" ]; then rm -rf "$d"; fi
    tar -xf "$f" -C "$DL"
    touch "$d/.unpacked"
  fi
  echo "$d"
}

# PPA indexes flap: apt-get update can exit 0 with a missing package list, so ask apt-cache for an
# installable Candidate instead. Acquire::Retries plus this loop ride out the outage.
apt_update_for() {
  local pkg="$1" log="$2" try policy
  shift 2
  : > "$log"
  for try in 1 2 3 4 5 6 7 8; do
    apt-get "$@" update -qq >>"$log" 2>&1 || :
# Capture apt-cache output before grep: piping straight to grep -q can SIGPIPE under pipefail and report a false miss.
    policy=$(apt-cache "$@" policy "$pkg" 2>/dev/null) || policy=
    if grep -q '^ *Candidate: [^ (]' <<<"$policy"; then
      echo "  apt indexes ready for $pkg (attempt $try)"
      return 0
    fi
    [ "$try" -ge 8 ] && break
    echo "apt: no candidate for $pkg after attempt $try; retrying in 15s" >&2
    sleep 15
  done
  echo "apt: $pkg never appeared in the indexes; apt said:" >&2
  tail -n 40 "$log" >&2 2>/dev/null || :
  return 1
}

# ---------------------------------------------------------------
# 1. Linux kernel, from kernel.org, with Copper's .config subset
# ---------------------------------------------------------------

# Assert the symbols Copper needs after olddefconfig: kconfig can silently drop a flag and leave a black
# screen or no DHCP. Only symbols that exist in $KREL belong here; BLK_DEV_IDE is gone in 6.12 (libata
# covers PIIX), and asking for a symbol that was never enabled could not have worked either way.
require_kernel_config() {
  local cfg="$1" sym missing=""
  for sym in \
      DEVTMPFS DEVTMPFS_MOUNT TMPFS OVERLAY_FS ISO9660_FS BLK_DEV_SR \
      FUSE_FS \
      VT VGA_CONSOLE UNIX98_PTYS \
      EXT4_FS BLK_DEV_SD ATA ATA_PIIX SATA_AHCI BLK_DEV_NVME \
      VIRTIO_PCI VIRTIO_BLK \
      NET NETDEVICES INET PACKET UNIX E1000 E1000E VMXNET3 VIRTIO_NET \
      SWAP ZRAM ZSMALLOC ; do
    grep -qx "CONFIG_$sym=y" "$cfg" || missing="$missing $sym"
  done
  if [ -n "$missing" ]; then
    echo "kernel: these options did not survive olddefconfig:$missing" >&2
    exit 1
  fi

  # FUSE_FS is in the base list for AppImages. They are self-mounting squashfs
  # files: the runtime calls fusermount, which needs /dev/fuse and a kernel that
  # speaks the FUSE protocol. This image builds with MODULES disabled, so a
  # defconfig that carries FUSE as a module (or not at all) gives a machine where
  # double-clicking an .AppImage only says "Fuse not installed". Built in, and
  # devtmpfs publishes /dev/fuse at boot with no udev to ask.

# Assert display drivers =y after olddefconfig: kconfig accepts a request then drops it without a word,
# and DRM_BOCHS alone only drives QEMU's 1234:1111. FONT_8x16 keeps the text console readable.
  for sym in DRM DRM_FBDEV_EMULATION DRM_BOCHS DRM_SIMPLEDRM \
             DRM_VMWGFX DRM_VIRTIO_GPU DRM_QXL DRM_VBOXVIDEO DRM_I915 \
             FB FB_VESA FB_EFI \
             FRAMEBUFFER_CONSOLE FONT_8x16 ; do
    grep -qx "CONFIG_$sym=y" "$cfg" || missing="$missing $sym"
  done
  if [ -n "$missing" ]; then
    echo "kernel: the desktop needs these, and they did not survive" >&2
    echo "        olddefconfig:$missing" >&2
    echo "        Without them there is no /dev/fb0, so nothing can put" >&2
    echo "        anything on the screen. This build would boot to a shell." >&2
    exit 1
  fi

  # Sound, asserted for the same reason as the display: a symbol kconfig drops
  # is a machine with no /dev/snd and an audio stack that can only report "no
  # sound card". HDA is the one device both VMware Workstation and QEMU's
  # intel-hda present, and the codecs are what the driver needs to find a PCM
  # on it -- SND_HDA_GENERIC is the parser for a codec nobody wrote a driver
  # for, which is exactly what an emulated card looks like.
  # VMware's default guest card is the Ensoniq AudioPCI ES1371, not HDA, so
  # the AudioPCI driver and its AC97 codec have to be built in too. USB audio
  # covers headsets and docks that never appear on a PCI bus.
  for sym in SOUND SND SND_PCM SND_TIMER SND_HDA SND_HDA_INTEL SND_HDA_GENERIC \
             SND_ENS1370 SND_ENS1371 SND_AC97_CODEC SND_USB_AUDIO ; do
    grep -qx "CONFIG_$sym=y" "$cfg" || missing="$missing $sym"
  done
  if [ -n "$missing" ]; then
    echo "kernel: sound support did not survive olddefconfig:$missing" >&2
    echo "        Without it there is no /dev/snd: cava has nothing to draw," >&2
    echo "        and the desktop has no audio at all." >&2
    exit 1
  fi

  # The disk controllers, asserted for the same reason the display drivers are:
  # a symbol whose dependencies are unmet is dropped by olddefconfig without a
  # word, and a kernel with no driver for the machine's disk boots to a shell
  # that cannot find its own root.
  #
  # This block exists because of a real gap. The first-boot wizard offers the
  # user every spare disk it can see, and on a VMware Quick Setup VM it saw
  # NONE -- the wizard had nothing to offer, so a fresh machine could not be set
  # up at all. The cause was not the wizard: ATA_PIIX, BLK_DEV_SD and BLK_DEV_NVME
  # were all built in, but a SCSI disk needs a SCSI HOST ADAPTER, and none was.
  # VMware's default controller for a Linux guest is LSI Logic SAS, which is
  # SCSI_MPT3SAS (in 6.12 the old parallel mptspi driver is gone; MPT3SAS covers
  # SAS, SPI and FC). An NVMe disk was detected only because BLK_DEV_NVME *is* in
  # the list -- which is exactly the workaround the report described, and exactly
  # the kind of accidental coverage that hides a missing driver.
  #
  # BLK_DEV_SD depends on SCSI, so asking for the SCSI disk without SCSI itself
  # would drop both: that is why SCSI and SCSI_LOWLEVEL are asserted here and not
  # merely enabled.
  #
  # SATA_AHCI is asserted in the base loop above even though x86_64 defconfig
  # already carries it: a symbol that arrives by accident disappears by accident,
  # and silent coverage of exactly that kind hid the VMware gap for months.
  # Being a SATA host rather than a SCSI one, it belongs beside ATA_PIIX in the
  # base list, not with the host adapters below.
  #
  #   SCSI            the base any SCSI disk needs (BLK_DEV_SD depends on it)
  #   SCSI_LOWLEVEL   the menu the host-adapter drivers live under
  #   SCSI_MPT3SAS    LSI Logic SAS/SPI/FC -- VMware's default guest controller
  #   VMWARE_PVSCSI   VMware Paravirtual SCSI (not VMWARE_VMXNET3: that is the
  #                   network adapter, a different symbol entirely)
  #   SCSI_VIRTIO     virtio-scsi, the common QEMU/KVM alternative to virtio-blk
  #   SCSI_SYM53C8XX_2 the NCR53C8XX/SYM53C8XX family of PCI parallel SCSI
  #                   controllers, plus the LSI53C10XX Ultra-160 subset -- and
  #                   QEMU's lsi53c895a, the adapter a -drive if=scsi disk
  #                   lands on when nobody picks a fancier one
  #   MEGARAID_SAS    LSI Logic MegaRAID SAS RAID -- QEMU's megasas and the
  #                   real SAS RAID cards; selects IRQ_POLL, so enabling it
  #                   pulls that in too
  #
  # The same limit applies as to the display list: asserted =y means it compiles,
  # not that it has initialised on that hardware. SCSI_VIRTIO and VMWARE_PVSCSI
  # are untested until somebody boots a machine that uses them; SCSI_MPT3SAS is
  # the one the VMware report is about, and SYM53C8XX/MEGARAID_SAS are covered
  # by booting QEMU's lsi53c895a and megasas with a disk behind each.
  for sym in SCSI SCSI_LOWLEVEL SCSI_MPT3SAS VMWARE_PVSCSI SCSI_VIRTIO \
             SCSI_SYM53C8XX_2 MEGARAID_SAS ; do
    grep -qx "CONFIG_$sym=y" "$cfg" || missing="$missing $sym"
  done
  if [ -n "$missing" ]; then
    echo "kernel: these disk drivers did not survive olddefconfig:$missing" >&2
    echo "        Without a driver for the machine's disk there is no /dev/sda," >&2
    echo "        so the first-boot wizard has no disk to offer and a VMware" >&2
    echo "        guest cannot be set up at all. This build would boot to an" >&2
    echo "        empty wizard." >&2
    exit 1
  fi

  echo "kernel: config looks fit to boot, to reach the network, to draw, and to"
  echo "kernel: find a disk"
}

build_kernel() {
  # The kernel's real inputs are the version and the scripts/config flags
  # below, and all of those live in this script, hence $SELF.
  if [ -s "$TGT/boot/vmlinuz" ] && stamped_skip "$WORK/kernel.stamp" "$SELF"; then
    echo "kernel: already built, skipping"; return
  fi
  echo "==> kernel $KREL"
  local KT KD
  KT=$(fetch "https://cdn.kernel.org/pub/linux/kernel/$KPATH/linux-$KREL.tar.xz")
  KD=$(unpack "$KT")

# Pin the compiler here, not just in CI: gcc 15 turns this kernel's ACPI signature initializer into a
# -Werror failure thousands of lines from the change. KERNEL_CC overrides; empty forces the system default.
  local KCC="${KERNEL_CC-gcc-13}"
  local kcc=()
  if [ -n "$KCC" ]; then
    command -v "$KCC" >/dev/null 2>&1 || {
      echo "kernel: KERNEL_CC=$KCC but there is no such compiler." >&2
      echo "        Install it, or set KERNEL_CC= to use the default." >&2
      exit 1; }
    kcc=(CC="$KCC" HOSTCC="$KCC")
    echo "    compiler: $("$KCC" --version | head -1)"
  else
    echo "    compiler: system default ($(gcc --version | head -1))"
  fi

  pushd "$KD" >/dev/null
    make "${kcc[@]}" defconfig
    scripts/config --disable MODULES \
      --enable ISO9660_FS --enable OVERLAY_FS --enable TMPFS \
      --enable FUSE_FS \
      --enable DEVTMPFS --enable DEVTMPFS_MOUNT \
      --enable UNIX98_PTYS --enable LEGACY_PTYS \
      --enable VIRTIO_PCI --enable VIRTIO_BLK --enable VIRTIO_NET \
      --enable E1000 --enable E1000E \
      --enable VMXNET3 --enable VMWARE_VMXNET3 \
      --enable ATA --enable ATA_PIIX --enable SATA_AHCI \
      --enable BLK_DEV_SD --enable BLK_DEV_NVME \
      --enable SCSI --enable SCSI_LOWLEVEL \
      --enable SCSI_MPT3SAS --enable VMWARE_PVSCSI --enable SCSI_VIRTIO \
      --enable SCSI_SYM53C8XX_2 --enable MEGARAID_SAS \
      --enable EXT4_FS --enable PACKET --enable UNIX --enable VT \
      --enable VGA_CONSOLE --enable INPUT \
      --enable SWAP --enable ZSMALLOC --enable ZRAM \
      --enable DRM --enable DRM_FBDEV_EMULATION \
      --enable DRM_BOCHS --enable DRM_SIMPLEDRM \
      --enable DRM_VMWGFX --enable DRM_VIRTIO_GPU \
      --enable DRM_QXL --enable DRM_VBOXVIDEO \
      --enable DRM_I915 \
      --enable FB --enable FB_VESA --enable FB_EFI \
      --enable FRAMEBUFFER_CONSOLE --enable FONT_8x16 \
      --enable SOUND --enable SND --enable SND_PCM --enable SND_TIMER \
      --enable SND_HWDEP --enable SND_HDA --enable SND_HDA_INTEL \
      --enable SND_HDA_GENERIC --enable SND_HDA_CODEC_SIGMATEL \
      --enable SND_HDA_CODEC_REALTEK --enable SND_HDA_CODEC_ANALOG \
      --enable SND_HDA_CODEC_HDMI \
      --enable SND_ENS1370 --enable SND_ENS1371 --enable SND_AC97_CODEC \
      --enable SND_USB_AUDIO
    # vmxnet3 was renamed at some point around 6.12; asking for both names
    # costs nothing, since kconfig drops whichever one doesn't exist.
    #
    # The framebuffer, and why there is more than one driver in this list.
    #
    # The first version of this enabled DRM_BOCHS alone, and that was a real
    # mistake rather than a misunderstanding of what the symbol does.
    #
    # DRM_BOCHS binds to exactly one device: QEMU's Bochs VGA adapter, PCI
    # 1234:1111. It is not "the QEMU display driver" and it is not a generic
    # framebuffer. Enable it and you have a kernel that can drive precisely one
    # graphics device out of all of them.
    #
    # Every measurement behind that change -- the desktop drawing, the text
    # console, the handover, all seventeen pixel assertions -- was taken under
    # QEMU with `-vga std`, which is that one adapter. So the work looked
    # finished, and shipped, and booted to a shell:
    #
    #     copper: no /dev/fb0, starting the shell
    #
    # Under VMware the guest gets a different display device entirely, nothing
    # in the kernel binds to it, /dev/fb0 never appears, and copper-init does
    # the correct thing with the situation it was given and starts a shell. The
    # fallback worked exactly as designed. That is what made it so easy to miss:
    # the failure was indistinguishable from a machine with no graphics at all,
    # and nothing in the log said "no driver for your display".
    #
    # So the list is deliberately broad. A live image has to bring up whatever
    # machine it is put on, and the cost of a driver nobody has is a few hundred
    # kilobytes against the cost of a desktop that never appears:
    #
    #   DRM_BOCHS      QEMU std VGA (1234:1111)
    #   DRM_VMWGFX     VMware SVGA -- vmware-svga
    #                  (the symbol is DRM_VMWGFX, not DRM_VMWARE. Asking for
    #                   DRM_VMWARE is accepted by scripts/config and then dropped
    #                   without a word, which is the failure this whole comment
    #                   exists to prevent -- caught by the assertion below, on
    #                   the one driver that actually mattered.)
    #   DRM_VIRTIO_GPU virtio-gpu, the common paravirtualised default
    #   DRM_QXL        QEMU with a qxl adapter
    #   DRM_VBOXVIDEO  VirtualBox
    #   DRM_I915       Intel integrated graphics
    #   DRM_SIMPLEDRM  the generic fallback: binds to anything with a linear
    #                  framebuffer and no better driver, which is the case that
    #                  would otherwise produce a shell
    #   FB_VESA/FB_EFI legacy BIOS and EFI framebuffers, for the same reason
    #
    # DRM_BOCHS also has to be accompanied by FRAMEBUFFER_CONSOLE, and that part
    # was not a mistake. With the driver alone, tty0 stays registered, accepts
    # writes and discards them: write() returns 0, and a screendump after
    # clearing the screen and printing 80 '@' is indistinguishable from a boot
    # where nothing was written. fbcon is what re-registers tty0 against the new
    # framebuffer, so the desktop and the text console share one device -- which
    # is the whole requirement, since the machine has to ask its first-boot
    # questions as text and then hand the screen to the desktop.
    #
    # What sharing it costs, measured:
    #
    #   * the text console works -- rendering and keystrokes both, verified by
    #     decoding screenshots back into the characters they show and matching
    #     every glyph against the kernel's own font_8x16.
    #   * it becomes 160x50 rather than 80x25, because fbcon lays the whole
    #     surface out as 8x16 cells. Anything that asks the terminal how big it
    #     is will lay itself out differently. The wizard was checked both ways:
    #     the two forms are 12 rows by 66 columns and differ in 0 of 792 cells,
    #     once aligned. Same words, same arrangement, different margins.
    #   * the kernel log is visible during boot unless the entry boots quiet,
    #     which the default entry does.
    #
    # And the limit of all of it: a driver in this list is a claim that it
    # compiles, not a claim that it has ever initialised on that hardware. The
    # only one measured here is DRM_BOCHS. Treat the rest as untested until
    # somebody boots the machine they are for -- which is the whole reason this
    # comment is longer than the flag list.
    make "${kcc[@]}" olddefconfig
    require_kernel_config "$KD/.config"
    make "${kcc[@]}" -j"$JOBS" bzImage
    cp arch/x86/boot/bzImage "$TGT/boot/vmlinuz"
  popd >/dev/null
  [ -s "$TGT/boot/vmlinuz" ] || { echo "kernel build failed"; exit 1; }
  stamp_set "$WORK/kernel.stamp" "$SELF"
}

# ---------------------------------------------------------------
# 2. musl libc (our C library, compiled from source)
# ---------------------------------------------------------------
build_musl() {
# musl-gcc embeds absolute paths, so a restored cache from a renamed repo exists but cannot link;
# compile a throwaway program before trusting it.
  local musl_ok=0
  if [ -x "$SYS/bin/musl-gcc" ]; then
    if printf 'int main(void){return 0;}\n' \
       | "$SYS/bin/musl-gcc" -x c - -o "$WORK/.musl-cc-test" >/dev/null 2>&1; then
      musl_ok=1
    else
      echo "musl: cached toolchain at $SYS is present but cannot link; rebuilding it"
      rm -rf "$SYS"
    fi
  fi
  rm -f "$WORK/.musl-cc-test"

  if [ "$musl_ok" != 1 ]; then
    echo "==> musl"
    local MT MD
    MT=$(fetch "https://musl.libc.org/releases/musl-1.2.5.tar.gz")
    MD=$(unpack "$MT")
    pushd "$MD" >/dev/null
      CC=gcc ./configure --prefix="$SYS" --disable-shared
      make -j"$JOBS"; make install
    popd >/dev/null
    [ -x "$SYS/bin/musl-gcc" ] || { echo "musl build failed"; exit 1; }
    printf 'int main(void){return 0;}\n' \
      | "$SYS/bin/musl-gcc" -x c - -o "$WORK/.musl-cc-test" \
      || { echo "musl: freshly built toolchain at $SYS cannot link"; exit 1; }
    rm -f "$WORK/.musl-cc-test"
  fi
  # everything userland from here on is static musl binaries
  export PATH="$SYS/bin:$PATH"
  export CC=musl-gcc
  export CFLAGS="-static -O2"
  export LDFLAGS="-static"
}

# Use the kernel tree's scripts/config: appending CONFIG_* lines duplicates defconfig defaults, and conf
# rejects the reassignment (or corrupts a kconfig choice) instead of setting the symbol.
set_bb_config() {
  local sym="$1"
  local kcfg="$DL/linux-$KREL/scripts/config"
  if [ -x "$kcfg" ]; then
    "$kcfg" -e "$sym"
  else
    sed -i "s|^# CONFIG_$sym is not set$|CONFIG_$sym=y|" .config
    grep -q "^CONFIG_$sym=y$" .config || echo "CONFIG_$sym=y" >> .config
  fi
}

set_bb_config_off() {
  local sym="$1"
  local kcfg="$DL/linux-$KREL/scripts/config"
  if [ -x "$kcfg" ]; then
    "$kcfg" -d "$sym"
  else
    sed -i "s|^CONFIG_$sym=y$|# CONFIG_$sym is not set|" .config
  fi
}

# Copper runs its init, its shell and its network setup out of this busybox,
# so make sure the applets we lean on really are in there. `make defconfig`
# on busybox means "whatever the Kconfig defaults say", which is easy to
# break by bumping the version.
require_bb_config() {
  local cfg="$1" sym missing=""
  for sym in \
      STATIC ASH ID \
      UDHCPC FEATURE_UDHCPC_ARPING IP IFCONFIG ROUTE PING \
      WGET FEATURE_WGET_HTTPS FEATURE_WGET_OPENSSL NSLOOKUP \
      MOUNT UMOUNT SWITCH_ROOT HOSTNAME \
      BLKID FEATURE_BLKID_TYPE GREP \
      ADDUSER ADDGROUP FEATURE_ADDUSER_TO_GROUP GETTY LOGIN \
      CHPASSWD FEATURE_SHADOWPASSWDS SETFONT CLEAR TTY \
      SED CUT HEAD SLEEP MKSWAP SWAPON SWAPOFF READLINK ; do
    grep -qx "CONFIG_$sym=y" "$cfg" || missing="$missing $sym"
  done
  if [ -n "$missing" ]; then
    echo "busybox: missing applets we depend on:$missing" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------
# 3. busybox — base utilities, ash, adduser, chpasswd, mount, ...
# ---------------------------------------------------------------
build_busybox() {
  if [ -x "$TGT/bin/busybox" ] && stamped_skip "$WORK/busybox.stamp" "$SELF"; then
    echo "busybox: already built, skipping"; return
  fi
  echo "==> busybox"
  local BT BD
  BT=$(fetch "https://busybox.net/downloads/busybox-1.36.1.tar.bz2")
  BD=$(unpack "$BT")
  pushd "$BD" >/dev/null
    make defconfig
    # static, plus the applets the first-boot wizard and init rely on.
    # Applet links stay at the defconfig default (soft links).
    set_bb_config STATIC
    set_bb_config ADDUSER
    set_bb_config CHPASSWD
    set_bb_config PASSWD
    set_bb_config LOGIN
    set_bb_config GETTY
    set_bb_config SU
    set_bb_config MOUNT
    set_bb_config UMOUNT
    set_bb_config HOSTNAME
    # blkid is how /init reads the COPPER label off a disk to find the
    # persistent upper; FEATURE_BLKID_TYPE keeps the TYPE= field it prints
    # useful in the boot log when a disk does not mount. grep guards the
    # scan against a device that is already mounted.
    set_bb_config BLKID
    set_bb_config FEATURE_BLKID_TYPE
    set_bb_config GREP
    set_bb_config FEATURE_ADDUSER_TO_GROUP
    set_bb_config FEATURE_SHADOWPASSWDS
    set_bb_config FEATURE_INSTALLER
    # setfont: copper-init loads the console font with this applet before it
    # spawns the shell. The kernel console has no font fallback, so the default
    # VGA face is the difference between fastfetch's box drawing and a screen
    # of question marks on tty1.
    set_bb_config SETFONT
    # clear: the console shell's `clear` is busybox's applet. It is the first
    # command a lot of people reach for, and the applet is what turns it into
    # the VT's erase sequence.
    set_bb_config CLEAR
    # tty: /etc/profile asks it whether the shell is on a virtual console
    # before it upgrades bash's invented TERM=dumb to the VT's TERM=linux.
    set_bb_config TTY
    # the tc applet needs CBQ traffic-class kernel UAPI (TCA_CBQ_* and
    # struct tc_cbq_*) that newer kernel headers removed, so it fails to
    # compile against the runner's headers. Copper ships no traffic
    # control, so drop it.
    set_bb_config_off TC
    # settle remaining symbols to their defaults. busybox's kconfig has
    # no olddefconfig target; oldconfig works because the kconfig choices
    # stay in the consistent state defconfig wrote (scripts/config only
    # edits single symbols), so oldconfig never prompts and NEW symbols
    # take their defaults on a closed stdin
    make oldconfig
    require_bb_config "$BD/.config"
    make -j"$JOBS"
    make CONFIG_PREFIX="$TGT" install
  popd >/dev/null
  [ -x "$TGT/bin/busybox" ] || { echo "busybox build failed"; exit 1; }
  [ -x "$TGT/sbin/getty" ] && [ -x "$TGT/bin/login" ] || {
    echo "busybox: tty3 recovery needs the getty and login applet links" >&2
    exit 1; }
  stamp_set "$WORK/busybox.stamp" "$SELF"
}

# ---------------------------------------------------------------
# 4. standard command suite, compiled from source against musl
# ---------------------------------------------------------------
build_gnu() {   # build_gnu NAME URL [configure args...]
  local name="$1" url="$2"; shift 2
  echo "  -> $name"
  local t d
  t=$(fetch "$url"); d=$(unpack "$t")
  pushd "$d" >/dev/null
    ./configure --host=x86_64-linux-musl --prefix=/usr \
      --disable-shared --enable-static --disable-nls "$@"
    make -j"$JOBS"
    make DESTDIR="$TGT" install
  popd >/dev/null
}

build_tools() {
  if [ -x "$TGT/usr/bin/ls" ] && [ -x "$TGT/usr/bin/grep" ] \
     && stamped_skip "$WORK/tools.stamp" "$SELF"; then
    echo "tools: already built, skipping"; return
  fi
  echo "==> standard command suite"
  build_gnu coreutils   "https://mirrors.kernel.org/gnu/coreutils/coreutils-9.5.tar.xz"
  build_gnu grep        "https://mirrors.kernel.org/gnu/grep/grep-3.11.tar.xz"
  build_gnu sed         "https://mirrors.kernel.org/gnu/sed/sed-4.9.tar.xz"
  build_gnu findutils   "https://mirrors.kernel.org/gnu/findutils/findutils-4.9.0.tar.xz"
  build_gnu diffutils   "https://mirrors.kernel.org/gnu/diffutils/diffutils-3.10.tar.xz"
  build_gnu tar         "https://mirrors.kernel.org/gnu/tar/tar-1.35.tar.xz"
  build_gnu gzip        "https://mirrors.kernel.org/gnu/gzip/gzip-1.13.tar.xz"
  build_gnu xz          "https://github.com/tukaani-project/xz/releases/download/v5.4.6/xz-5.4.6.tar.xz"
  stamp_set "$WORK/tools.stamp" "$SELF"
}

# Point power commands at the tools THIS TREE's PID 1 understands, in both /sbin and /usr/sbin:
# /usr/sbin comes first on PATH, and a systemd-sysv link there wins so `sudo reboot` answers "System has
# not been booted with systemd" (bug 29). One image boots either init, so all four names are Copper's
# wrapper: it reads /proc/1/comm and uses `systemctl --no-block` (a blocking client is SIGTERMed by the
# shutdown it started, cancels its own job, and hands the prompt back) or the busybox applet. Re-run after
# every stage that copies packages, or the systemd ISO fails its read-back gate. A bare `sudo shutdown`
# once looked like it did nothing, so shutdown is the wrapper as a real file too.
power_links() {          # power_links <staged-root>
  local root=$1 cmd
  mkdir -p "$root/sbin" "$root/usr/sbin"
# All four names are the wrapper on both init flavours: the wrapper reads the RUNNING PID 1 (/proc/1/comm)
# and dispatches at call time. tests/shutdown-gate.sh binds a fake comm file to check both halves.
  for cmd in reboot poweroff halt; do
    ln -sf /sbin/shutdown "$root/sbin/$cmd"
    ln -sf /sbin/shutdown "$root/usr/sbin/$cmd"
  done
  # shutdown: the wrapper, on both flavours, as a real file. rm first so a
  # leftover systemctl/busybox link from an earlier run is replaced rather than
  # left as a link that answers a different question (install copies over it,
  # but the explicit removal is what the read-back gate expects to read).
  rm -f "$root/sbin/shutdown" "$root/usr/sbin/shutdown"
  install -m 0755 "$ROOT/shutdown.sh" "$root/sbin/shutdown"
  ln -sf /sbin/shutdown "$root/usr/sbin/shutdown"
}

# Ask sbin/init, not a variable: the cached tree outlives any one build.sh run. Use readlink, not -e,
# because the absolute target does not exist on the build host and -e would call a good tree broken.
init_flavour() {         # init_flavour <staged-root> -> busybox|systemd|unknown
  case "$(readlink "$1/sbin/init" 2>/dev/null)" in
    /usr/bin/copper-init)  echo busybox ;;
    /lib/systemd/systemd)  echo systemd ;;
    *)                     echo unknown ;;
  esac
}

# The systemd deb puts PID 1 at /usr/lib/systemd/systemd; Copper's /lib is real, so the stage bridges
# lib/systemd -> ../usr/lib/systemd. A cached tree can carry that symlink into a package copy and
# `cp: cannot overwrite non-directory '.../rootfs/./lib/systemd' with` stops the build. Stages take the bridge off for
# copies and restore it only for a systemd tree; build_systemd keeps its own bridge so its gate still
# tests the code that actually runs.
merged_usr_bridge() {    # merged_usr_bridge <staged-root> -> true if the bridge is in place
  [ -L "$1/lib/systemd" ] && [ "$(readlink "$1/lib/systemd")" = "../usr/lib/systemd" ]
}

drop_merged_usr_bridge() {   # drop_merged_usr_bridge <staged-root>
  if merged_usr_bridge "$1"; then
    rm -f "$1/lib/systemd"
    echo "  lib/systemd: merged-usr bridge taken off for the package copy"
  fi
}

make_merged_usr_bridge() {   # make_merged_usr_bridge <staged-root>
  [ -x "$1/usr/lib/systemd/systemd" ] || return 0
  if merged_usr_bridge "$1"; then return 0; fi
  # A real directory squats on the name. build_systemd's bridge normalises
  # it the same way: a tree with a lib/systemd/systemd of its own is a
  # merged-usr rootfs and is left exactly as it is.
  if [ -d "$1/lib/systemd" ] && [ -e "$1/lib/systemd/systemd" ]; then
    return 0
  fi
  rm -rf "$1/lib/systemd"
  mkdir -p "$1/lib"
  ln -sfn ../usr/lib/systemd "$1/lib/systemd"
  echo "  lib/systemd: merged-usr bridge back in place"
}

# Copy a staged package tree into the staged rootfs.
#
# The bridge has to come off for the copy (see above) and goes back on if
# this tree is the systemd flavour's. Everything else is cp's ordinary
# -n behaviour: a file the tree already has wins over the package's.
copy_stage_in() {        # copy_stage_in <stage> <target>
  local stage=$1 tgt=$2
  drop_merged_usr_bridge "$tgt"
  cp -a -n "$stage"/. "$tgt"/
  if [ "$(init_flavour "$tgt")" = systemd ]; then
    make_merged_usr_bridge "$tgt"
  fi
}

# Return a cached tree to the default flavour (copper-init, busybox power tools, no bridge); idempotent,
# and only the DEFAULT flavour's chains call it, never `iso` or `systemd`.
default_flavour() {
  if [ "$(init_flavour "$TGT")" = systemd ]; then
    ln -sf /usr/bin/copper-init "$TGT/sbin/init"
# Replace a stale systemctl link with the real shutdown wrapper before power_links: busybox ships no
# shutdown applet, and the ISO read-back gate checks that what is left is a regular file.
    rm -f "$TGT/sbin/shutdown"
    install -m 0755 "$ROOT/shutdown.sh" "$TGT/sbin/shutdown"
    echo "  sbin/init: systemd -> copper-init (the tree came in systemd-flavoured)"
  fi
  power_links "$TGT"
  drop_merged_usr_bridge "$TGT"
}

# ---------------------------------------------------------------
# 5. Copper's own pieces: shell, init (PID 1), first-boot wizard
# ---------------------------------------------------------------

# build_copper needs $CC/$CFLAGS from build_musl; a stage that skips it dies on an unbound variable that
# says nothing about the missing prerequisite. Turn that mistake into a sentence here.
require_toolchain() {
  if [ -z "${CC:-}" ] || [ -z "${CFLAGS:-}" ]; then
    echo "build: no toolchain in this shell (CC/CFLAGS unset)." >&2
    echo "       This stage compiles Copper's own binaries, so it must run" >&2
    echo "       build_musl first -- add it to the stage's dispatch line." >&2
    exit 1
  fi
}

build_copper() {
local SRC="$ROOT/../src"
  require_toolchain
  # This input list and the one stamp_set hashes at the end of the function
  # must name the same files in the same order: the stamp is a hash of their
  # concatenation, so one file out of place makes it never match and the
  # stage rebuild on every run. startniri.sh was missing here.
  if [ -x "$TGT/usr/bin/copper-sh" ] && [ -x "$TGT/usr/bin/copper-init" ] \
     && [ -x "$TGT/usr/bin/copper-firstboot" ] \
     && [ -x "$TGT/usr/bin/xprobe" ] && [ -x "$TGT/sbin/shutdown" ] \
     && stamped_skip "$WORK/copper.stamp" "$SELF" "$SRC"/*.c "$SRC"/*.h \
        "$ROOT/src-init/copper-init.c" "$ROOT/firstboot/copper-firstboot.c" \
        "$ROOT/startxfce.sh" "$ROOT/startniri.sh" \
        "$ROOT/x11/probe/xprobe.c" "$ROOT/shutdown.sh" \
        "$ROOT/copper.sh"
  then
    echo "copper: already built, skipping"; return
  fi
  echo "==> copper built-ins"
  $CC $CFLAGS -std=c11 -o "$TGT/usr/bin/copper-sh" \
     "$SRC/main.c" "$SRC/builtins.c" -I "$SRC"
  $CC $CFLAGS -std=c11 -o "$TGT/usr/bin/copper-init" \
     "$ROOT/src-init/copper-init.c"
  $CC $CFLAGS -std=c11 -o "$TGT/usr/bin/copper-firstboot" \
     "$ROOT/firstboot/copper-firstboot.c"
# xprobe checks X liveness before startxfce trusts a socket; without it a stale :0 from the persistence
# disk survives the server that made it and the next boot reuses a dead display.
  $CC $CFLAGS -std=c11 -o "$TGT/usr/bin/xprobe" \
     "$ROOT/x11/probe/xprobe.c"
  ln -sf /usr/bin/copper-init "$TGT/sbin/init"   # our PID 1

  install -m 0755 "$ROOT/copper.sh" "$TGT/usr/bin/copper"

  # The XFCE launcher. It ships now, before XFCE does, because what it is for
  # today is failing informatively: it names the missing piece and returns a
  # distinct code, which is a more useful thing to have in the image than a
  # command-not-found from copper-sh.
  install -m 0755 "$ROOT/startxfce.sh" "$TGT/usr/bin/startxfce"

  # The niri launcher: the same contract style, same seeding/exit-code
  # discipline as startxfce.
  install -m 0755 "$ROOT/startniri.sh" "$TGT/usr/bin/startniri"

  # Hyprland is no longer baked into the image. Its launcher, compositor,
  # config tree and runtime libraries all arrive with `ingot install hyprland`;
  # keeping the source here is what builds that payload. A fresh ISO therefore
  # has no starthyprland until the payload is installed.

  # shutdown: busybox has no such applet, so `sudo shutdown now` had nothing
  # to run. The wrapper maps its flags onto the busybox halt/poweroff/reboot
  # applets, which signal PID 1; see on_power_signal() in copper-init.c.
  install -m 0755 "$ROOT/shutdown.sh" "$TGT/sbin/shutdown"

  # reboot/poweroff/halt: the glibc packages ship systemd-flavoured versions
  # that try to talk to PID 1 over D-Bus. PID 1 here is busybox init, so they
  # fail with "System has not been booted with systemd". Point them at the
  # busybox applets instead, which signal PID 1 the way copper-init expects.
  # Both sbin/ and usr/sbin/: PATH searches usr/sbin first (bug 29).
  power_links "$TGT"

  # switch_root is going to need all of these, and a staged tree missing one
  # of them is a black screen on a machine with no shell to debug it from.
  # Say it here, where it costs a second. (The udhcpc lease script is checked
  # in build_rootfs instead — this stage runs before the overlay is copied.)
  local f
  for f in usr/bin/copper-init usr/bin/copper-sh usr/bin/copper-firstboot \
           usr/bin/startxfce usr/bin/startniri \
           usr/bin/xprobe sbin/shutdown \
           usr/bin/copper; do
    if [ ! -x "$TGT/$f" ]; then
      echo "copper: $f is missing from the staged rootfs" >&2
      exit 1
    fi
  done
# Test sbin/init with readlink, not -e: its absolute target is absent on the build host, so -e reports
# a perfectly good staged tree as broken.
  if [ "$(readlink "$TGT/sbin/init")" != "/usr/bin/copper-init" ]; then
    echo "copper: sbin/init should be a symlink to /usr/bin/copper-init" >&2
    exit 1
  fi

  stamp_set "$WORK/copper.stamp" "$SELF" "$SRC"/*.c "$SRC"/*.h \
    "$ROOT/src-init/copper-init.c" "$ROOT/firstboot/copper-firstboot.c" \
    "$ROOT/startxfce.sh" "$ROOT/startniri.sh" "$ROOT/x11/probe/xprobe.c" "$ROOT/shutdown.sh" \
    "$ROOT/copper.sh"
}

# ---------------------------------------------------------------
# 6. rootfs config + timezone data
# ---------------------------------------------------------------
build_rootfs() {
  echo "==> rootfs config"
  cp -a "$ROOT/rootfs-overlay/." "$TGT/"
  mkdir -p "$TGT/usr/share/zoneinfo" "$TGT/etc/skel" \
           "$TGT/usr/local/bin" "$TGT/usr/local/sbin"
  chmod 0755 "$TGT/usr/local" "$TGT/usr/local/bin" "$TGT/usr/local/sbin"
  cp -a /usr/share/zoneinfo/. "$TGT/usr/share/zoneinfo/" 2>/dev/null \
    || echo "  (no host zoneinfo to copy — timezone data will be missing)"
  # udhcpc execs this the moment a lease lands, and git does not reliably
  # carry the exec bit across platforms, so set it here.
  chmod 0755 "$TGT/usr/share/udhcpc/default.script"
  [ -x "$TGT/usr/share/udhcpc/default.script" ] || {
    echo "rootfs: udhcpc lease script is not executable"; exit 1; }

  # ingot is Copper's package manager; the live user runs `ingot ...` from a
  # shell prompt, so it must be executable too. Same git-exec-bit caveat.
  chmod 0755 "$TGT/usr/bin/ingot"
  [ -x "$TGT/usr/bin/ingot" ] || {
    echo "rootfs: ingot is not executable"; exit 1; }

  # copper-audio is what the launchers call after starting the server, and what
  # a user types when the machine is quiet. Same caveat again.
  chmod 0755 "$TGT/usr/bin/copper-audio"
  [ -x "$TGT/usr/bin/copper-audio" ] || {
    echo "rootfs: copper-audio is not executable"; exit 1; }

  for f in etc/profile etc/bash.bashrc etc/skel/.bashrc; do
    if [ ! -f "$TGT/$f" ]; then
      echo "rootfs: missing Bash startup file /$f" >&2
      exit 1
    fi
  done

  # A CR anywhere in this file makes busybox ash fail every line of it, and
  # the machine has no shell to fix that with. Cheap to prove here.
  if LC_ALL=C grep -q $'\r' "$TGT/usr/share/udhcpc/default.script"; then
    echo "rootfs: udhcpc lease script has CRLF line endings" >&2
    exit 1
  fi
  if LC_ALL=C grep -q $'\r' "$TGT/usr/bin/ingot"; then
    echo "rootfs: ingot has CRLF line endings" >&2
    exit 1
  fi

# The overlay is copied onto a cached $TGT and cp only adds: compare the manifest against the overlay,
# not $TGT, to drop files the overlay no longer claims instead of baking them into the next ISO.
  local old="$WORK/overlay.manifest" new="$WORK/overlay.manifest.new" rel
  ( cd "$ROOT/rootfs-overlay" && find . \( -type f -o -type l \) | sed 's|^\./||' ) \
    | LC_ALL=C sort > "$new"
  if [ -s "$old" ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      # Paths other stages own. Deleting one of these would break the build
      # in a much more confusing way than the bug this fixes.
      case "$rel" in usr/bin/*|usr/sbin/*|bin/*|sbin/*|usr/lib/*|lib/*|boot/*) continue ;; esac
      rm -f "$TGT/$rel"
      rmdir -p "$TGT/$(dirname "$rel")" 2>/dev/null || true
    done < <(comm -23 "$old" "$new")
  fi
  mv -f "$new" "$old"

# Delete removed wifi binaries and firmware every run: a build cache only adds, and build_iso refuses
# to write a disc that still carries them.
  local stale
  for stale in \
      usr/bin/copper-wifi \
      usr/sbin/wpa_supplicant usr/sbin/wpa_cli usr/sbin/wpa_passphrase \
      sbin/wpa_supplicant sbin/wpa_cli sbin/wpa_passphrase \
      etc/wpa_supplicant \
      usr/share/doc/linux-firmware usr/share/doc/wireless-regdb \
      usr/lib/systemd/system/wpa_supplicant.service \
      usr/lib/systemd/system/wpa_supplicant@.service \
      lib/systemd/system/wpa_supplicant.service \
      lib/systemd/system/wpa_supplicant@.service ; do
    rm -rf "$TGT/$stale"
  done
  local fw
  for fw in "$TGT/lib/firmware" "$TGT/usr/lib/firmware"; do
    [ -d "$fw" ] || continue
    rm -rf "$fw/ath9k_htc" "$fw/ath10k" "$fw/ath11k" "$fw/ath12k" \
           "$fw/rtlwifi" "$fw/rtw88" "$fw/rtw89" "$fw/brcm" \
           "$fw/mediatek" "$fw/mrvl" "$fw/zd1211" "$fw/intel/iwlwifi"
    ( cd "$fw" && rm -f iwlwifi-*.ucode.zst iwlwifi-*.pnvm.zst \
        rt2561.bin* rt2561s.bin* rt2661.bin* rt2860.bin* rt2870.bin* \
        rt3070.bin* rt3071.bin* rt3090.bin* rt3290.bin* rt73.bin* \
        mt7601u.bin* ar5523.bin* carl9170-1.fw* atmel_at76c50*.bin* \
        regulatory.db regulatory.db.p7s ) 2>/dev/null || true
  done
  # The man pages and the old front end's completion if a package brought one.
  rm -rf "$TGT/usr/share/man/man8/wpa_supplicant.8.gz" \
         "$TGT/usr/share/man/man5/wpa_supplicant.conf.5.gz" \
         "$TGT/usr/share/bash-completion/completions/copper-wifi" 2>/dev/null || true

# Prune the zero-byte legacy mime icons map a cache could hold from before gui/niri pruned it, so the
# empty-file gate sees the tree the stages are trying to produce.
  if [ -f "$TGT/usr/share/mime/icons" ] && [ ! -s "$TGT/usr/share/mime/icons" ]; then
    rm -f "$TGT/usr/share/mime/icons"
  fi

# Drop empty files left by cached later stages before rootfs's gate runs, and find from inside $TGT so
# the './etc/motd' exemptions match. Bug 26 was a sweep that missed the vendored skeleton's deliberately
# empty Lua include stubs and shipped a broken home; keep the niri exemption for future re-pins.
  ( cd "$TGT" && find . -type f -size 0 \
      ! -path './etc/motd' \
      ! -path './etc/timezone' \
      ! -path './usr/share/copper/niri-skel/*' \
      ! -name 'mach_kernel' \
      -delete ) 2>/dev/null || true

  assert_no_empty_files
  assert_commands_reachable
  assert_shell_scripts_parse
}

# An empty executable is found by execve and then refused as "command not found". `find -type f` ignores
# symlinks, so only real files are checked; inspect loops with mount/bsdtar, never p7zip, which writes
# some links as zero-byte files. Exemptions are separate `! ...` terms: a `#` inside a backslash-continued
# command ends it and silently disables the rest (bug 26). niri-skel is a vendored data tree with
# meaningful empty markers; mach_kernel is vestigial.
assert_no_empty_files() {
  local empties
  empties=$( cd "$TGT" && find . -type f -size 0 \
    ! -path './etc/motd' \
    ! -path './etc/timezone' \
    ! -path './var/log/*' \
    ! -name '*.uuid' \
    ! -path './usr/share/copper/niri-skel/*' \
    ! -name 'mach_kernel' \
    -print 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort )

  if [ -z "$empties" ]; then
    echo "rootfs: no empty regular files in the staged tree"
    return 0
  fi

  local n
  n=$(printf '%s\n' "$empties" | wc -l)
  {
    echo "rootfs: $n empty regular file(s) in the staged tree."
    echo "If any of these is meant to be executable, the shell will answer"
    echo "'command not found' for it, because execve() cannot run an empty file."
    echo
    printf '%s\n' "$empties" | head -25
    [ "$n" -gt 25 ] && echo "  ... and $((n - 25)) more"
    echo
    echo "Usual cause: a symlink was overwritten without --remove-destination,"
    echo "so the copy wrote through the link and produced an empty file."
  } >&2
  exit 1
}

# The old failure was not a missing file: ip/ifconfig were in busybox but sbin was not on PID 1's PATH,
# so execvp never found them. Resolve each name through copper-init's PATH, in order, and keep the list
# in step with its setenv().
assert_commands_reachable() {
  # Must match setenv("PATH", ...) in copper-init.c. Keeping the two in step
  # by hand is exactly the kind of thing that drifts, so if this fires, check
  # that line first.
  local copper_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  local applet d found target cand missing=""
  for applet in \
      sh ls cat cp mv rm mkdir touch chmod chown \
      grep sed awk cut tr sort uniq wc head tail \
      date sleep env printf echo test true false \
      ln mktemp find xargs basename dirname which \
      id hostname uname ps kill df du \
      adduser addgroup chpasswd \
      ip ifconfig route ping wget nslookup \
      mount umount switch_root \
      copper startxfce startniri \
      vi ; do

    found=""
    # Walk PATH in the real order, first hit wins, exactly like execvp.
    local oldifs="$IFS"
    IFS=:
    for d in $copper_path; do
      IFS="$oldifs"
      if [ "$d" = "/" ]; then cand="$TGT$applet"; else cand="$TGT$d/$applet"; fi
      # -L first: a busybox applet link resolves relative to its own directory,
      # so -e alone reports "missing" for a perfectly good link.
      if [ -L "$cand" ] || [ -e "$cand" ]; then found="$cand"; break; fi
      IFS=:
    done
    IFS="$oldifs"

    if [ -z "$found" ]; then
      missing="$missing $applet"
      continue
    fi

    target="$found"
    [ -L "$found" ] && target=$(readlink -f "$found" 2>/dev/null || echo "$found")
    if [ ! -e "$target" ]; then
      echo "rootfs: '$applet' is a symlink to nowhere: $found -> $(readlink "$found")" >&2
      echo "       execve() cannot follow it, so the shell reports 'command not found'" >&2
      exit 1
    fi
    if [ -f "$target" ] && [ ! -s "$target" ]; then
      echo "rootfs: '$applet' resolves to an EMPTY file: $target" >&2
      echo "       execve() cannot run an empty file" >&2
      exit 1
    fi
  done

  if [ -n "$missing" ]; then
    {
      echo "rootfs: these commands would answer 'command not found' on a live shell."
      echo "        They are not on PATH=$copper_path"
      echo
      for a in $missing; do echo "          $a" >&2; done
      echo
      echo "        Either the applet is genuinely missing from the image, or"
      echo "        copper-init's setenv("PATH", ...) no longer matches the list"
      echo "        checked here. Those two must stay identical."
    } >&2
    exit 1
  fi
  echo "rootfs: every required command is reachable by name on PATH"
}

# A quoting mistake in a shell script can still parse and then execute the wrong command; check every
# tracked *.sh so it is caught at build time, not on a boot.
assert_shell_scripts_parse() {
  local f bad=0

# Use bash -n for build.sh (process substitution is valid), and run git ls-files from $REPO or tests/
# never gets checked.
  local n_bash=0
  for f in $(cd "$REPO" && git ls-files '*.sh' 2>/dev/null); do
    [ -f "$REPO/$f" ] || { echo "build: $f is listed by git but not on disk" >&2; bad=1; continue; }
    n_bash=$((n_bash + 1))
    if ! out=$(bash -n "$REPO/$f" 2>&1); then
      echo "build: $f does not parse:" >&2
      echo "$out" | sed 's/^/       /' >&2
      bad=1
    fi
  done
  [ "$bad" -eq 0 ] || exit 1

# The live tools run under busybox ash, so check them with a POSIX shell too: arrays or `function` would
# fail only on the target. dash -n still accepts `[[ ... ]]` as a command, so tests/ingot-gate.sh executes
# it rather than merely parsing it.
  local posix=""
  for c in dash ash busybox; do
    command -v "$c" >/dev/null 2>&1 && { posix="$c"; break; }
  done

  if [ -n "$posix" ]; then
    local n_posix=0 posix_files posix_want
    # One list, and the count taken from it. The previous version carried the
    # list and the expected count separately, and adding copper-audio turned
    # that into "the POSIX check covered 9 of 8 busybox tools" -- a build that
    # dies on the bookkeeping rather than on the code. So: one list, no
    # number to remember.
    posix_files="iso/copper.sh
             iso/rootfs-overlay/usr/bin/ingot
             iso/rootfs-overlay/usr/bin/copper-audio
             iso/systemd/copper-tty-clear iso/systemd/copper-dhcp
             iso/systemd/copper-zram iso/systemd/copper-zram-stop
             iso/systemd/copper-splash-show iso/systemd/copper-splash-quit"
    posix_want=$(printf '%s\n' $posix_files | wc -w)
    for f in $posix_files; do
      [ -f "$REPO/$f" ] || {
        echo "build: $f is missing, so the POSIX check cannot run on it" >&2
        bad=1; continue; }
      n_posix=$((n_posix + 1))
      if ! out=$("$posix" -n "$REPO/$f" 2>&1); then
        echo "build: $f is not POSIX sh, and it runs under busybox ash:" >&2
        echo "$out" | sed 's/^/       /' >&2
        bad=1
      fi
    done
    [ "$bad" -eq 0 ] || exit 1
    # A check that looked at nothing and reported success is worse than no
    # check at all, because it reads like the busybox tools were verified.
    # This loop was skipping every one of them over a wrong path, and
    # `[ -f ] || continue` is precisely the construct that hides that.
    [ "$n_posix" -eq "$posix_want" ] || {
      echo "build: the POSIX check covered $n_posix of $posix_want busybox tools" >&2; exit 1; }
    echo "build: $n_bash shell scripts parse, and $n_posix busybox tools are POSIX sh"
  else
    echo "build: $n_bash shell scripts parse (no POSIX shell here for the busybox tools)"
  fi
  [ "$n_bash" -gt 0 ] || { echo "build: no shell scripts were found to check" >&2; exit 1; }
}

# build_gui's package copy makes base-files' os-release etc say Ubuntu, and nothing in the build reads
# them. Restore Copper's copies from the overlay and assert both /etc and /usr/lib agree, including on
# a cached gui skip.
copper_identity() {
  local rel id pkg_manager pkg_home
  for rel in etc/os-release etc/legal; do
    if [ ! -f "$ROOT/rootfs-overlay/$rel" ]; then
      echo "gui: iso/rootfs-overlay/$rel is missing; without it the image" >&2
      echo "     identifies itself as something else to every tool that asks" >&2
      exit 1
    fi
    install -D -m 0644 "$ROOT/rootfs-overlay/$rel" "$TGT/$rel"
  done
  # ensure /usr/lib/os-release exists as a copy for tools that look there
  install -D -m 0644 "$ROOT/rootfs-overlay/etc/os-release" "$TGT/usr/lib/os-release"
  # lsb-release, issue, issue.net and motd are generated from that one file.
  # Ubuntu's update-motd.d and /etc/debian_version are removed here too, on
  # cached gui skips as well as fresh copies.
  bash "$ROOT/identity.sh" "$ROOT/rootfs-overlay/etc" "$TGT"

  # The pulseaudio package owns /etc/pulse/default.pa and its copy loads the
  # udev-only detector. The default Copper init has no udev, so that config
  # hands every client the null sink: cava's bars move, firefox is silent and
  # Discord has no microphone. Put Copper's detector back after the packages
  # land, and assert it so a warm cached tree cannot quietly undo it.
  install -D -m 0644 "$ROOT/rootfs-overlay/etc/pulse/default.pa" \
    "$TGT/etc/pulse/default.pa"
  if ! grep -q '^load-module module-detect$' "$TGT/etc/pulse/default.pa"; then
    echo "gui: /etc/pulse/default.pa is not Copper's; the image would be silent" >&2
    exit 1
  fi

  id=$(sed -n 's/^ID=//p' "$TGT/etc/os-release" | head -n1)
  if [ "$id" != copper ]; then
    echo "gui: /etc/os-release does not say ID=copper (it says '${id:-nothing}')" >&2
    echo "     base-files' copy won again; see copper_identity above" >&2
    exit 1
  fi
  pkg_manager=$(sed -n 's/^PKG_MANAGER="\{0,1\}\([^"[:space:]]*\)"\{0,1\}$/\1/p' "$TGT/etc/os-release" | head -n1)
  pkg_home=$(sed -n 's|^PKG_MANAGER_HOME_URL="\{0,1\}\([^"[:space:]]*\)"\{0,1\}$|\1|p' "$TGT/etc/os-release" | head -n1)
  if [ "$pkg_manager" != Ingot ] || [ "$pkg_home" != https://github.com/12hrformat/copper-ingot-repo ]; then
    echo "gui: /etc/os-release does not identify Ingot as Copper's package manager" >&2
    exit 1
  fi
  if ! cmp -s "$TGT/etc/os-release" "$TGT/usr/lib/os-release"; then
    echo "gui: /etc/os-release and /usr/lib/os-release disagree" >&2
    exit 1
  fi
  local ver pretty relfile
  ver=$(sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$TGT/etc/os-release" | head -n1)
  pretty=$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$TGT/etc/os-release" | head -n1)
  for relfile in etc/lsb-release etc/issue etc/issue.net etc/motd; do
    if [ ! -s "$TGT/$relfile" ]; then
      echo "gui: /$relfile is empty or missing; identity is generated from os-release" >&2
      exit 1
    fi
  done
  if ! grep -qx "DISTRIB_RELEASE=$ver" "$TGT/etc/lsb-release" ||
     ! grep -qF "$pretty" "$TGT/etc/issue" ||
     ! grep -qF "$pretty" "$TGT/etc/motd"; then
    echo "gui: the generated identity files disagree with os-release" >&2
    exit 1
  fi
  if [ -e "$TGT/etc/update-motd.d" ] || [ -e "$TGT/etc/debian_version" ]; then
    echo "gui: Ubuntu MOTD scripts or /etc/debian_version survived the identity pass" >&2
    exit 1
  fi
  echo "  identity: $pretty ($ver), generated everywhere"
}

# "Already staged" is not the same question as "the packages are there": XFCE sits on GTK/glibc and dozens
# of packages, so apt fetches .debs at BUILD time; the image itself never asks the network. An empty dpkg
# status forces the full closure; dpkg-deb -x runs no maintainer scripts, so caches are absent afterwards.
build_gui() {
# The _seatd group, zsh and PipeWire are stage guarantees, not just package files: `build.sh iso` re-runs
# rootfs and can erase the group, so a stamp-only guard would skip the repair. Include them in "already staged".
  if [ -e "$TGT/usr/bin/Xorg" ] && [ -e "$TGT/usr/bin/startxfce4" ] \
     && [ -r "$TGT/usr/share/themes/Blacklight/index.theme" ] \
     && [ -r "$TGT/usr/share/copper/wallpapers/backlight-final.png" ] \
     && [ -x "$TGT/usr/bin/zsh" ] \
     && [ -x "$TGT/usr/bin/pipewire" ] \
     && [ -x "$TGT/usr/bin/wireplumber" ] \
     && [ -x "$TGT/usr/bin/amixer" ] \
     && grep -q '^_seatd:' "$TGT/etc/group" \
     && stamped_skip "$WORK/gui.stamp" "$SELF"; then
    echo "gui: already staged, skipping"
    # Skipping the packages must not skip their repair: a cached tree written
    # before this existed still calls itself something else. Cheap and idempotent.
    copper_identity
    return
  fi
  echo "==> display stack (Xorg + XFCE)"
  local DG="$DL/gui" status="$WORK/gui-status" STAGE="$WORK/gui-root" deb n
  mkdir -p "$DG/partial"
  : > "$status"

  # Package lists, refreshed when something is about to be downloaded
  # anyway. A cold runner has none; a warm one re-reads them in seconds.
  apt-get update -qq

# Probe for an installable Candidate, not a name apt merely recognizes: firefox-esr on ubuntu is
# Replaces-only and firefox on Kali is a dropped transitional.
  gui_carries() {
    apt-cache policy "$1" 2>/dev/null | grep -q '^ *Candidate: [^ (]'
  }

  # The pixbuf cache generator ships in a separate package from the library,
  # and only as a recommendation -- so --no-install-recommends would drop it
  # and the session would have loaders with nothing to find them from, which
  # draws no images. Its name changed between releases, so ask the host which
  # one it carries rather than naming one and hoping.
  local pixbuf="" p
  for p in libgdk-pixbuf2.0-bin libgdk-pixbuf-2.0-bin; do
    if gui_carries "$p"; then pixbuf=$p; break; fi
  done
# xfce4-terminal is not pulled in by the metapackage under --no-install-recommends; alsa is probed by
# name because noble turned libasound2 into a virtual package over libasound2t64.
  local alsa="" p
  for p in libasound2t64 libasound2; do
    if gui_carries "$p"; then alsa=$p; break; fi
  done
  local pulseaudio="" p
  for p in pulseaudio; do
    if gui_carries "$p"; then pulseaudio=$p; break; fi
  done
# alsa-utils is the mixer: a muted HDA codec can leave every log healthy but no sound, and copper-audio
# drives amixer/alsactl to unmute it.
  local alsa_utils="" p
  for p in alsa-utils; do
    if gui_carries "$p"; then alsa_utils=$p; break; fi
  done
  if [ -z "$alsa_utils" ]; then
    echo "gui: no installable alsa-utils; the image would have no mixer and" >&2
    echo "gui: no way to unmute a card that comes up silent" >&2
    exit 1
  fi
# open-vm-tools makes the console follow the VMware window via resolutionKMS; vmwgfx alone never learns
# the window resized, which is the "loses quality when fullscreen" symptom.
  local vmtools="" p
  for p in open-vm-tools; do
    if gui_carries "$p"; then vmtools=$p; break; fi
  done
# Both shells and both audio servers have to ship because /etc/copper.conf switches them at boot;
# pipewire-pulse and wireplumber are named explicitly, not assumed as dependencies.
  local zsh="" pipewire="" pipewire_pulse="" wireplumber="" pmiss="" p
  for p in zsh; do
    if gui_carries "$p"; then zsh=$p; break; fi
  done
  for p in pipewire; do
    if gui_carries "$p"; then pipewire=$p; break; fi
  done
  for p in pipewire-pulse; do
    if gui_carries "$p"; then pipewire_pulse=$p; break; fi
  done
  for p in wireplumber; do
    if gui_carries "$p"; then wireplumber=$p; break; fi
  done
  for p in zsh pipewire pipewire-pulse wireplumber; do
    case "$p" in
      zsh)            [ -n "$zsh" ]            || pmiss="$pmiss zsh" ;;
      pipewire)       [ -n "$pipewire" ]       || pmiss="$pmiss pipewire" ;;
      pipewire-pulse) [ -n "$pipewire_pulse" ] || pmiss="$pmiss pipewire-pulse" ;;
      wireplumber)    [ -n "$wireplumber" ]    || pmiss="$pmiss wireplumber" ;;
    esac
  done
  if [ -n "$pmiss" ]; then
    echo "gui: no installable package for:$pmiss" >&2
    echo "gui: both shells and both audio servers have to ship, because" >&2
    echo "gui: /etc/copper.conf offers them as a one-line switch" >&2
    exit 1
  fi
# pactl is what unmutes the default sink for cava and mpv; it speaks to PulseAudio and pipewire-pulse,
# so one binary covers both /etc/copper.conf choices.
  local pulseutils="" p
  for p in pulseaudio-utils; do
    if gui_carries "$p"; then pulseutils=$p; break; fi
  done
  if [ -z "$pulseutils" ]; then
    echo "gui: no installable pulseaudio-utils; copper-audio could not unmute" >&2
    echo "gui: the server's sink, and a fresh boot would be silent" >&2
    exit 1
  fi
  # pavucontrol: the desktop's mixer shortcut execs this binary. Without it the
  # first place a user looks when a video is silent or a call has no microphone
  # just reports "pavucontrol not found". It is a small GTK program in universe;
  # named and asserted here for the same reason pactl is.
  local pavucontrol="" p
  for p in pavucontrol; do
    if gui_carries "$p"; then pavucontrol=$p; break; fi
  done
  if [ -z "$pavucontrol" ]; then
    echo "gui: no installable pavucontrol; the mixer shortcut would fail" >&2
    exit 1
  fi
  # FUSE for AppImages. The file is a squashfs image with its own runtime; that
  # runtime dlopens libfuse.so.2 and execs fusermount to hand the mount to the
  # kernel. noble renamed libfuse2 to libfuse2t64 for the time_t transition, so
  # probe both. `fuse` owns fusermount and is setuid in the package itself --
  # dpkg-deb -x keeps that mode, which matters because the user running an
  # AppImage is not root. Without either half the file only reports "Fuse not
  # installed", and without FUSE_FS in the kernel there is no /dev/fuse to use.
  local fuselib="" fusetools="" p
  for p in libfuse2t64 libfuse2; do
    if gui_carries "$p"; then fuselib=$p; break; fi
  done
  for p in fuse; do
    if gui_carries "$p"; then fusetools=$p; break; fi
  done
  if [ -z "$fuselib" ] || [ -z "$fusetools" ]; then
    echo "gui: AppImage support needs libfuse.so.2 and fusermount; missing:" >&2
    [ -n "$fuselib" ]   || echo "  libfuse2t64 / libfuse2" >&2
    [ -n "$fusetools" ] || echo "  fuse" >&2
    exit 1
  fi
# Ask apt for a browser Candidate: ubuntu knows firefox-esr only through Replaces, Kali carries it and
# knows `firefox` only as a dropped transitional. The wrong probe shipped an image with no browser.
  local browser="" p
  for p in firefox-esr firefox; do
    if gui_carries "$p"; then browser=$p; break; fi
  done
  [ -z "$browser" ] && echo "gui: no firefox package on this host" \
    "(tried firefox-esr, firefox); the image will have no browser" >&2
# openssl and ca-certificates are needed because busybox wget's TLS helper forks `openssl s_client` and
# hangs on GitHub CDNs without it. e2fsprogs brings the real mkfs.ext4: busybox mke2fs makes ext2 with no
# xattrs, which overlayfs rejects. Fonts cover the glyphs terminal tools draw, fontconfig supplies
# fc-cache, and libc-bin carries C.utf8 plus ldd/ldconfig.
  set -- xserver-xorg-core xserver-xorg-input-evdev xkb-data x11-xkb-utils \
         dbus dbus-x11 xfce4 xfce4-terminal hicolor-icon-theme \
         adwaita-icon-theme dmz-cursor-theme librsvg2-common openssl ca-certificates e2fsprogs \
         libc-bin make nano bash ncurses-base \
         fonts-dejavu-core fonts-noto-core fonts-noto-mono \
         fonts-noto-color-emoji fonts-symbola fonts-powerline fonts-font-awesome \
         fonts-hack fonts-jetbrains-mono fonts-firacode fonts-liberation \
         fontconfig
  [ -n "$alsa" ] && set -- "$@" "$alsa"
  [ -n "$pixbuf" ] && set -- "$@" "$pixbuf"
  [ -n "$browser" ] && set -- "$@" "$browser"
# PulseAudio's daemon is the missing half of the audio stack: without it every client reports "no pulse
# audio" even though the client libraries are staged.
  [ -n "$pulseaudio" ] && set -- "$@" "$pulseaudio"
  set -- "$@" "$alsa_utils" "$pulseutils" "$pavucontrol"
  [ -n "$vmtools" ] && set -- "$@" "$vmtools"
  set -- "$@" "$zsh" "$pipewire" "$pipewire_pulse" "$wireplumber"
  set -- "$@" "$fuselib" "$fusetools"
  apt-get \
    -o Dir::State::status="$status" \
    -o Dir::Cache::archives="$DG" \
    -o APT::Sandbox::User=root \
    --download-only --no-install-recommends -y install "$@"

# Unpack each .deb on its own before merging: base-files' merged-usr links would collide with Copper's
# real /bin, /sbin and /lib. Drop those links so the real directories survive the package merge.
  local d="$WORK/gui-deb"
  rm -rf "$STAGE" "$d"; mkdir -p "$STAGE" "$d"
  for deb in "$DG"/*.deb; do
    rm -rf "$d"; mkdir -p "$d"
    dpkg-deb -x "$deb" "$d"
    local link
    for link in bin sbin lib lib64; do
      [ -L "$d/$link" ] && rm -f "$d/$link"
    done
    cp -a -n "$d"/. "$STAGE"/
  done
  rm -rf "$d"
  n=$(ls "$DG"/*.deb | wc -l)
  echo "  $n packages unpacked ($(du -sh "$STAGE" | cut -f1))"

  copy_stage_in "$STAGE" "$TGT"

# zsh's postinst makes /usr/bin/zsh -> /bin/zsh; no maintainer script runs here and Copper is not
# merged-usr, so make the link ourselves. Use the relative ../../bin/zsh target: an absolute one resolves
# against the build host, not the image.
  if [ ! -e "$TGT/usr/bin/zsh" ] && [ ! -L "$TGT/usr/bin/zsh" ]; then
    if [ -x "$TGT/bin/zsh" ]; then
      ln -s ../../bin/zsh "$TGT/usr/bin/zsh"
      echo "  zsh: /usr/bin/zsh -> ../../bin/zsh (the link its postinst makes)"
    else
      echo "gui: the zsh package unpacked no /bin/zsh, so the login shell the" >&2
      echo "     wizard writes (/usr/bin/zsh) cannot be created" >&2
      exit 1
    fi
  fi

  # AppImages' bundled AppRun scripts commonly start with #!/bin/bash. Copper is not
  # merged-usr, so the deb lands only /usr/bin/bash; without this link the runtime mounts
  # the image and then execve fails with ENOENT, printed as "execv error".
  if [ ! -e "$TGT/bin/bash" ] && [ ! -L "$TGT/bin/bash" ]; then
    ln -s ../usr/bin/bash "$TGT/bin/bash"
    echo "  AppImage: /bin/bash -> ../usr/bin/bash"
  fi

  # The Wayland session's fallback keymap and XFCE's pointer both depend on data files,
  # not just their shared libraries. Catch a missing package payload here so
  # the booted desktop cannot silently have no keymap or an invisible cursor.
  for f in usr/bin/bash bin/bash \
           usr/share/X11/xkb/rules/evdev \
           usr/share/icons/DMZ-White/cursors/left_ptr; do
    if [ ! -r "$TGT/$f" ]; then
      echo "gui: required keyboard/cursor data is missing: /$f" >&2
      exit 1
    fi
  done

  # When the host carries a real browser it has to actually land in the tree:
  # a name that resolved but unpacked to nothing would ship a desktop with no
  # browser and no complaint. ubuntu's firefox is the snap-transition stub and
  # legitimately unpacks no binary, so only the real package is checked.
  if [ "$browser" = firefox-esr ] &&
     [ ! -x "$TGT/usr/lib/firefox-esr/firefox-esr" ]; then
    echo "gui: firefox-esr resolved, but no browser landed in the tree" >&2
    exit 1
  fi

  # Every glibc ELF names /lib64/ld-linux-x86-64.so.2 as its interpreter, and
  # the kernel resolves that exact path before a single instruction of the
  # program runs. The loader itself did arrive -- it sits under
  # /usr/lib/x86_64-linux-gnu -- but the base image is musl-built, so it never
  # had a /lib64 of its own. base-files would expose one as a merged-usr
  # symlink, and that link is stripped above so it cannot replace Copper's
  # layout. Without the file exactly there, execve fails with ENOENT and the
  # shell blames the program instead of the loader: "not found", for a binary
  # sitting right there under /usr. Copy it to the one path the kernel will
  # look at.
  if [ ! -e "$TGT/lib64/ld-linux-x86-64.so.2" ]; then
    if [ -L "$TGT/lib64" ]; then rm -f "$TGT/lib64"; fi
    mkdir -p "$TGT/lib64"
    cp -L "$TGT/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" \
         "$TGT/lib64/ld-linux-x86-64.so.2"
  fi

  # Packages ship some files that are empty by nature -- X11 Compose tables,
  # module markers -- and the rootfs stage asserts on every later build over
  # this tree that no file in the image is zero bytes. Prune exactly the
  # empties the packages brought, matched against the staging tree so that
  # an empty file the base image has a name for is left where it is.
  find "$STAGE" -type f -size 0 -printf '%P\n' > "$WORK/gui-empties"
  while IFS= read -r rel; do
    rm -f "$TGT/$rel"
  done < "$WORK/gui-empties"
  echo "  $(wc -l < "$WORK/gui-empties") empty package files pruned"

# No postinst runs, so mirror ca-certificates' one useful step: concatenate the mozilla roots into
# /etc/ssl/certs/ca-certificates.crt so busybox wget can verify TLS.
  mkdir -p "$TGT/etc/ssl/certs"
  if ls "$STAGE"/usr/share/ca-certificates/mozilla/*.crt >/dev/null 2>&1; then
    cat "$STAGE"/usr/share/ca-certificates/mozilla/*.crt \
      > "$TGT/etc/ssl/certs/ca-certificates.crt"
    echo "  CA bundle written ($(wc -c <"$TGT/etc/ssl/certs/ca-certificates.crt") bytes)"
  else
    echo "gui: ca-certificates did not arrive from the packages" >&2
    exit 1
  fi

  # The session bus wants a machine identity even on a live system, and with
  # no maintainer script running here, nothing else is going to make one.
  if [ ! -s "$TGT/etc/machine-id" ]; then
    head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n' > "$TGT/etc/machine-id"
  fi

  # Two directories Xorg writes into at runtime, whose absence is reported
  # only after the server has already started drawing.
  mkdir -p "$TGT/var/lib/xkb" "$TGT/usr/share/X11/xkb/compiled"

# gdk-pixbuf needs loaders.cache or GTK aborts each XFCE component and the session crash-loops; no
# postinst runs here. Mirror the query in a chroot, with the trailing /* on the loader path (find -path
# matches whole paths) or the stage dies with "no loader modules" for a tree full of them.
  local ql="" m0="" cache="" mods="" m=""
  ql=$(find "$TGT/usr" -path '*gdk-pixbuf*' -name gdk-pixbuf-query-loaders \
       -print -quit 2>/dev/null)
  if [ -z "$ql" ]; then
    echo "gui: gdk-pixbuf-query-loaders did not arrive from the packages" >&2
    exit 1
  fi
  # The trailing /* is load-bearing: -path matches the WHOLE path, so without
  # it the pattern only ever matches the loaders directory itself, which the
  # -name *.so guard then rejects, and the stage dies with "no loader
  # modules" for a tree that is full of them. Measured, not guessed.
  m0=$(find "$TGT/usr/lib" -path '*gdk-pixbuf*/2.10.0/loaders/*' \
       -name '*.so' -type f -print -quit 2>/dev/null)
  if [ -z "$m0" ]; then
    echo "gui: no gdk-pixbuf loader modules arrived; nothing to register" >&2
    exit 1
  fi
  for m in $(find "$TGT/usr/lib" -path '*gdk-pixbuf*/2.10.0/loaders/*' \
             -name '*.so' -type f 2>/dev/null | LC_ALL=C sort); do
    mods="$mods ${m#"$TGT"}"
  done
  cache="$(dirname "$m0")/../loaders.cache"
  if ! chroot "$TGT" "${ql#"$TGT"}" $mods \
      >"$cache" 2>"$WORK/gui-pixbuf.log"; then
    echo "  pixbuf-query-loaders exited nonzero; its stderr follows" >&2
    cat "$WORK/gui-pixbuf.log" >&2 2>/dev/null || :
  fi
  if [ ! -s "$cache" ]; then
    echo "gui: loaders.cache is empty after generation" >&2
    exit 1
  fi
  echo "  pixbuf loaders.cache written ($(wc -l <"$cache") entries)"

# Check the SVG entry in loaders.cache: Adwaita's panel icons are SVG and a failed librsvg dlopen leaves
# icons silently NULL.
  if ! grep -q 'image/svg+xml' "$cache"; then
    echo "gui: loaders.cache has no SVG entry (librsvg module did not load)" >&2
    exit 1
  fi

# Mirror update-mime-database's postinst in the chroot; without mime.cache g_content_type_guess cannot
# identify images by content type.
  if [ ! -x "$TGT/usr/bin/update-mime-database" ]; then
    echo "gui: update-mime-database did not arrive from the packages" >&2
    exit 1
  fi
  if ! chroot "$TGT" /usr/bin/update-mime-database /usr/share/mime \
      >"$WORK/gui-mime.log" 2>&1; then
    echo "gui: update-mime-database failed inside the stage:" >&2
    cat "$WORK/gui-mime.log" >&2 2>/dev/null || :
    exit 1
  fi
  if [ ! -s "$TGT/usr/share/mime/mime.cache" ]; then
    echo "gui: update-mime-database produced no mime.cache" >&2
    exit 1
  fi
  echo "  mime database compiled ($(wc -c <"$TGT/usr/share/mime/mime.cache") bytes)"

# Prune the zero-byte legacy mime icons map update-mime-database emits; a later whole-tree empty-file
# gate would fail on it.
  if [ -f "$TGT/usr/share/mime/icons" ] && [ ! -s "$TGT/usr/share/mime/icons" ]; then
    rm -f "$TGT/usr/share/mime/icons"
    echo "  pruned empty mime icons map (no icon mappings in the database)"
  fi

  # Icon-theme directory caches (icon-theme.cache) are another postinst
  # artifact; GTK can scan without them, but Adwaita's per-size icon aliases
  # resolve far more reliably with the cache present. gtk-update-icon-cache
  # rode in the closure (51.9 kB package, verified in the CI download log);
  # run it over every staged theme, mirroring the icon-theme postinst.
  local tdir="" themedir=""
  if [ ! -x "$TGT/usr/bin/gtk-update-icon-cache" ]; then
    echo "gui: gtk-update-icon-cache did not arrive from the packages" >&2
    exit 1
  fi
  for tdir in "$TGT"/usr/share/icons/*/index.theme; do
    [ -f "$tdir" ] || continue
    themedir=$(dirname "$tdir")
    if chroot "$TGT" /usr/bin/gtk-update-icon-cache -f -t \
        "${themedir#"$TGT"}" >"$WORK/gui-icontheme.log" 2>&1; then
      echo "  icon theme cached: ${themedir#"$TGT"}"
    else
      echo "gui: gtk-update-icon-cache failed for ${themedir#"$TGT"}:" >&2
      cat "$WORK/gui-icontheme.log" >&2 2>/dev/null || :
      exit 1
    fi
  done

  # Every one of these missing means the session cannot start, and each is
  # far clearer here than as a failed exec at the end of a boot.
  local f
  for f in usr/bin/Xorg usr/bin/startxfce4 usr/bin/xkbcomp \
           usr/bin/dbus-daemon usr/bin/dbus-launch \
           usr/bin/zsh usr/bin/pipewire usr/bin/pipewire-pulse \
           usr/bin/wireplumber \
           usr/bin/amixer usr/sbin/alsactl usr/bin/speaker-test \
           usr/bin/pactl usr/bin/pavucontrol bin/fusermount \
           etc/pulse/default.pa \
           usr/share/dbus-1/system.conf \
           lib64/ld-linux-x86-64.so.2 \
           usr/bin/openssl etc/ssl/certs/ca-certificates.crt; do
    if [ ! -e "$TGT/$f" ]; then
      echo "gui: $f did not arrive from the packages" >&2
      exit 1
    fi
  done
  # AppImages call fusermount as the logged-in (non-root) user. The kernel only
  # permits that when the helper is root-owned and setuid. The fuse package
  # ships it at /bin/fusermount (Copper's tree is deliberately not merged-usr),
  # and its deb ships mode 0755 -- a normal install sets the bit in postinst,
  # which never runs here. Set it ourselves. Link the /usr/bin spelling too:
  # AppImage runtimes differ on which path they try, and both must reach the
  # same setuid helper.
  if [ -e "$TGT/bin/fusermount" ]; then
    chown 0:0 "$TGT/bin/fusermount"
    chmod 4755 "$TGT/bin/fusermount"
    if [ ! -e "$TGT/usr/bin/fusermount" ] && [ ! -L "$TGT/usr/bin/fusermount" ]; then
      ln -s ../../bin/fusermount "$TGT/usr/bin/fusermount"
    fi
    echo "  AppImage: /bin/fusermount is root:root 4755"
  fi

  for f in usr/share/themes/Blacklight/index.theme \
           usr/share/themes/Blacklight/gtk-3.0/gtk.css \
           usr/share/themes/Blacklight/xfwm4/themerc \
           usr/share/copper/wallpapers/backlight-final.png; do
    if [ ! -r "$TGT/$f" ]; then
      echo "gui: required Backlight theme asset is missing: /$f" >&2
      exit 1
    fi
  done
  # The input driver specifically: without it the server starts, draws, and
  # has no keyboard and no mouse, which is a machine nobody can use.
  # -print -quit stops after the first hit: grep -q closes the pipe on its
  # first match, and a second write from find would arrive as SIGPIPE, which
  # under pipefail reads as "not found" no matter what was found.
  if ! find "$TGT/usr" -name evdev_drv.so -print -quit 2>/dev/null | grep -q .; then
    echo "gui: evdev_drv.so is missing; the server would have no input" >&2
    exit 1
  fi

  # Persistence formats the disk the user picks with the real mkfs.ext4, and
  # /init then mounts the result as the overlay upper. The busybox mke2fs applet
  # cannot stand in: it makes ext2 only and leaves the xattr feature bit clear,
  # which overlayfs refuses. So the tool has to be in the image, and a missing
  # one must fail the build here rather than turn into "persistence silently
  # never works" on a real machine. Locate it by search, not by a fixed path:
  # it moves between /sbin and /usr/sbin depending on the host's usrmerge state.
  if ! find "$TGT/sbin" "$TGT/usr/sbin" -maxdepth 1 -name mkfs.ext4 \
       -print -quit 2>/dev/null | grep -q .; then
    echo "gui: mkfs.ext4 did not arrive from the packages; the wizard" >&2
    echo "     could not format a disk for persistence" >&2
    exit 1
  fi

  # Re-point the power commands at whatever THIS TREE's PID 1 understands: the
  # gui stage just copied systemd/sysvinit-utils versions that cannot talk to
  # busybox init -- in /sbin and in /usr/sbin, which PATH (and sudo's
  # secure_path) searches first (bug 29; the /usr/sbin half is what the
  # 2026-10-17 fix missed). power_links() asks the tree which init it carries,
  # so on a systemd-flavoured tree it points them at systemctl instead.
  power_links "$TGT"

  # Last, so nothing copied in after it can undo it: whose distribution this is.
  copper_identity

  echo "  display stack staged ($(du -sh "$TGT" | cut -f1)) rootfs total"
  stamp_set "$WORK/gui.stamp" "$SELF"
}

# ---------------------------------------------------------------
# 6f. the niri session: the compositor from the praksharma PPA, the vendored niri configuration
# ---------------------------------------------------------------
# noble has no niri binary and upstream ships source only, so the PPA's noble/glibc-2.39 build is the
# runnable source; its closure is staged like build_gui's. The config is vendored and copied, never
# symlinked, so the image stays self-contained when iso/work is cached without the repo.
build_niri() {
# A cached tree can lose zero-byte skel files or the _seatd group while niri's stamp still matches;
# include them in "already staged" so the stage re-runs and the compositor can take the DRM master.
  if [ -e "$TGT/usr/bin/niri" ] \
     && [ -e "$TGT/usr/share/copper/niri-skel/.config/niri/config.kdl" ] \
     && [ -e "$TGT/usr/share/copper/niri-skel/.config/waybar/config.jsonc" ] \
     && [ -e "$TGT/usr/share/copper/niri-skel/.config/waybar/scripts/workspaces.sh" ] \
     && [ -e "$TGT/usr/share/copper/wallpapers/copper-default.png" ] \
     && [ -n "$(find "$TGT/usr" -name seatd -type f -print -quit 2>/dev/null)" ] \
     && grep -q '^_seatd:' "$TGT/etc/group" \
     && stamped_skip "$WORK/niri.stamp" "$SELF" \
        "$ROOT/rootfs-overlay/etc/copper/niri-apps" \
        "$ROOT/rootfs-overlay/usr/share/copper/wallpapers/copper-default.png" \
        "$ROOT/rootfs-overlay/usr/share/copper/niri-overlay/.config/niri/copper-tweaks.kdl" \
        "$ROOT"/rootfs-overlay/usr/share/copper/niri-skel/.config/niri/config.kdl \
        "$ROOT"/rootfs-overlay/usr/share/copper/niri-skel/.config/waybar/config.jsonc \
        "$ROOT"/rootfs-overlay/usr/share/copper/niri-skel/.config/waybar/style.css \
        "$ROOT"/rootfs-overlay/usr/share/copper/niri-skel/.config/waybar/scripts/window.sh \
        "$ROOT"/rootfs-overlay/usr/share/copper/niri-skel/.config/waybar/scripts/workspaces.sh \
        "$ROOT"/rootfs-overlay/usr/share/copper/niri-skel/.config/kitty/kitty.conf; then
    echo "niri: already staged, skipping"; return
  fi
  echo "==> niri session"
  local DH="$DL/niri" STAGE="$WORK/niri-root" deb n
  local HA="$WORK/niri-apt" status="$WORK/niri-status"
  local KEYRING="$HA/etc/apt/keyrings/praksharma-ubuntu-niri.gpg"
  mkdir -p "$DH/partial"
  : > "$status"

  # ---- the archive key, by fingerprint ----------------------------------
  # Fetched, not trusted blind: the key the keyserver returns must carry the
  # fingerprint launchpad publishes for the archive, or the build stops. gpg is
  # expected on the build host -- it is the same host that runs apt -- and if it
  # is not there, say so rather than fall back to something unsigned.
  command -v gpg >/dev/null 2>&1 \
    || { echo "niri: gpg is needed to verify the PPA archive key" >&2; exit 1; }
  rm -rf "$HA"
  mkdir -p "$HA/etc/apt/sources.list.d" "$HA/etc/apt/keyrings"
  local asc="$WORK/praksharma-ubuntu-niri.asc" fpr
# keyserver.ubuntu.com blips for minutes while apt still reaches other hosts; retry the key fetch with
# spacing instead of failing on wget's back-to-back retries.
  local try=0
  until wget -q -t 3 -T 15 -O "$asc" \
         "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$NIRI_PPA_FPR"; do
    try=$((try + 1))
    [ "$try" -ge 6 ] \
      && { echo "niri: could not fetch the PPA archive key from the keyserver" >&2; exit 1; }
    echo "niri: keyserver attempt $try failed; retrying in 20s" >&2
    sleep 20
  done
  fpr=$(gpg --show-keys --with-colons "$asc" 2>/dev/null \
        | awk -F: '/^fpr:/{print $10; exit}')
  if [ "$fpr" != "$NIRI_PPA_FPR" ]; then
    echo "niri: the PPA key's fingerprint is '$fpr', expected '$NIRI_PPA_FPR'" >&2
    exit 1
  fi
  gpg --dearmor < "$asc" > "$KEYRING"
  [ -s "$KEYRING" ] || { echo "niri: the PPA keyring came out empty" >&2; exit 1; }
  echo "  archive key verified ($NIRI_PPA_FPR)"

# Use a private sourceparts dir (host sources plus the PPA) so apt never writes /etc/apt and later
# stages cannot see the PPA and resolve differently.
  if [ -d /etc/apt/sources.list.d ]; then
    cp -a /etc/apt/sources.list.d/. "$HA/etc/apt/sources.list.d/" 2>/dev/null || :
  fi
  # If the host had nothing to copy (an unusual image), fall back to noble's
  # own archive so the non-PPA half of the list still resolves.
  if [ -z "$(ls -A "$HA/etc/apt/sources.list.d" 2>/dev/null)" ]; then
    echo "deb http://archive.ubuntu.com/ubuntu noble main universe" \
      > "$HA/etc/apt/sources.list.d/noble.list"
  fi
  echo "deb [signed-by=$KEYRING] $NIRI_PPA_URL noble main" \
    > "$HA/etc/apt/sources.list.d/praksharma-ubuntu-niri.list"

  # ---- the closure ------------------------------------------------------
  # Dir::State::status empty: every dependency counts as missing, the same
  # guarantee build_gui relies on. The default lists directory is kept, so a
  # warm runner re-reads its cached indexes instead of refetching them; the PPA
  # is simply one more source for apt-get update to fetch once.
  local -a AOPT=(
    -o Dir::Etc::sourceparts="$HA/etc/apt/sources.list.d"
    -o Dir::State::status="$status"
    -o Dir::Cache::archives="$DH"
    -o APT::Sandbox::User=root
    # no translation indexes: this apt tree is a throwaway downloader and
    # nothing reads them, while the PPA's Release file can list a
    # Translation-en the archive then 404s -- a file nobody uses killing
    # the stage (seen 2026-11-11).
    -o Acquire::Languages=none
    # Launchpad flaps between 503 and 200 from one request to the next; let
    # apt retry each index fetch on its own before the outer loop steps in.
    -o Acquire::Retries=5
  )
  apt_update_for niri "$WORK/niri-update.log" "${AOPT[@]}" \
    || { echo "niri: the PPA never became reachable; cannot stage the session" >&2
         exit 1; }

# Stage only what the session needs with no network: pinned niri and noble-pinned waybar (the PPA waybar
# needs a newer Layer Shell than noble's library), bar, launcher, terminal, seat, polkit, portals, keyring
# and GL stack. Everything heavier is an Ingot package named in the manifest.
  set -- niri=25.11ppa4 waybar=0.9.24-1build3 swaybg sway-notification-center fuzzel kitty \
         seatd brightnessctl playerctl wl-clipboard cliphist jq \
         policykit-1-gnome polkitd pkexec \
         xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-gnome \
         gnome-keyring libsecret-1-0 libnotify-bin \
         xdg-user-dirs gvfs-backends udisks2 power-profiles-daemon \
         bibata-cursor-theme \
         libgl1-mesa-dri libegl-mesa0 libgbm1 libglx-mesa0 \
         libxkbcommon0 libinput10 libgtk-layer-shell0
  # The pinned compositor's .deb comes from the same flapping PPA. A failed
  # fetch here used to end the stage even with good indexes; retry, and let
  # apt skip the debs it already downloaded on the second attempt.
  local dltry ok=0
  for dltry in 1 2 3; do
    if apt-get "${AOPT[@]}" --download-only --no-install-recommends -y install "$@" \
       >"$WORK/niri-apt.log" 2>&1; then ok=1; break; fi
    [ "$dltry" -ge 3 ] && break
    echo "niri: download attempt $dltry failed; retrying in 15s" >&2
    sleep 15
  done
  [ "$ok" -eq 1 ] \
    || { echo "niri: apt could not resolve the session closure:" >&2
         tail -n 30 "$WORK/niri-apt.log" >&2 2>/dev/null || :
         exit 1; }

  rm -rf "$STAGE"; mkdir -p "$STAGE"
  for deb in "$DH"/*.deb; do
    dpkg-deb -x "$deb" "$STAGE"
  done
  n=$(ls "$DH"/*.deb | wc -l)
  echo "  $n packages unpacked ($(du -sh "$STAGE" | cut -f1))"

  # A cached build tree keeps the files an earlier run staged, and this stage's
  # copy does not overwrite what is already there, so a bar or compositor that a
  # later run re-resolved would keep the previous run's bytes. Drop this stage's
  # own files before copying, so the pinned ones land.
  rm -f "$TGT/usr/bin/niri" "$TGT/usr/bin/waybar" "$TGT/usr/bin/fuzzel" \
        "$TGT/usr/bin/swaybg" "$TGT/usr/bin/swaync" "$TGT/usr/bin/kitty"
  copy_stage_in "$STAGE" "$TGT"

# Mirror polkitd's postinst: setuid helper and polkitd-owned state dirs. Without the bit the agent reads
# no shadow database and every prompt answers "wrong password"; the iso stage re-asserts it after the
# ownership sweep.
  if [ -e "$TGT/usr/lib/polkit-1/polkit-agent-helper-1" ]; then
    chown 0:0 "$TGT/usr/lib/polkit-1/polkit-agent-helper-1"
    chmod 4755 "$TGT/usr/lib/polkit-1/polkit-agent-helper-1"
  fi
  local polkit_gid d
  polkit_gid=$(awk -F: '$1 == "polkitd" { print $3 }' "$TGT/etc/group" 2>/dev/null | head -n1)
  if [ -n "$polkit_gid" ]; then
    for d in etc/polkit-1/rules.d var/lib/polkit-1; do
      [ -d "$TGT/$d" ] || continue
      chown "0:$polkit_gid" "$TGT/$d"
      chmod 0750 "$TGT/$d"
    done
  fi

# Shared libraries are the one package copy allowed to replace an earlier stage's: cp -a -n would keep an
# older base copy and leave niri unable to start. Stage the Layer Shell library by name too, or the bar
# dies with undefined gtk_layer_try_force_commit.
  rm -rf "$WORK/niri-layer"; mkdir -p "$WORK/niri-layer"
  ( cd "$WORK/niri-layer" && apt-get -o APT::Sandbox::User=root download libgtk-layer-shell0 ) \
    >"$WORK/niri-layer.log" 2>&1 \
    || { echo "niri: could not fetch the Wayland Layer Shell library" >&2; cat "$WORK/niri-layer.log" >&2 2>/dev/null; exit 1; }
  for deb in "$WORK/niri-layer"/*.deb; do
    dpkg-deb -x "$deb" "$STAGE"
  done
  echo "  $(ls "$WORK/niri-layer"/*.deb 2>/dev/null | wc -l) layer-shell packages unpacked"

  while IFS= read -r so; do
    rel=${so#"$STAGE"/}
    mkdir -p "$TGT/$(dirname "$rel")"
    # -L dereferences symlinks to real files; -f forces the overwrite, so the
    # PPA's newer library always wins over an older base-stage copy even when
    # the base shipped a regular file under the same name.
    cp -a -f "$so" "$TGT/$rel"
  done < <(find "$STAGE" \( -type f -o -type l \) \( -name '*.so' -o -name '*.so.*' \))
  echo "  shared libraries from the stage take precedence over earlier packages"

  # The loader, defensively: the gui stage creates it, and every glibc ELF
  # needs it at exactly /lib64/ld-linux-x86-64.so.2 before a single instruction
  # runs. build_niri always runs after build_gui, so this only fires on a tree
  # someone assembled by hand -- and then it makes the chroot gate below fail
  # for the right reason instead of a bare ENOENT.
  if [ ! -e "$TGT/lib64/ld-linux-x86-64.so.2" ]; then
    mkdir -p "$TGT/lib64"
    cp -L "$TGT/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" \
         "$TGT/lib64/ld-linux-x86-64.so.2"
  fi

  # Packages ship some files that are empty by nature, and the rootfs stage
  # asserts on every later build over this tree that no file is zero bytes.
  # Prune exactly the empties the packages brought, matched against the staging
  # tree so an empty file the base image has a name for is left alone.
  find "$STAGE" -type f -size 0 -printf '%P\n' > "$WORK/niri-empties"
  while IFS= read -r rel; do
    rm -f "$TGT/$rel"
  done < "$WORK/niri-empties"
  echo "  $(wc -l < "$WORK/niri-empties") empty package files pruned"

  # The generated caches the package postinsts would have made and this image
  # never runs. Best-effort: a stale cache costs a scan, not a session, so a
  # missing tool is reported and stepped over rather than failing the build.
  if [ -x "$TGT/usr/bin/update-mime-database" ]; then
    chroot "$TGT" /usr/bin/update-mime-database /usr/share/mime \
      >"$WORK/niri-mime.log" 2>&1 \
      || echo "  (update-mime-database failed; new mime types will not resolve)"
# update-mime-database recreates the zero-byte mime icons map gui pruned; prune it again or the whole-tree
# empty-file gate fails later (earlier, in rootfs, on a cache restore).
    if [ -f "$TGT/usr/share/mime/icons" ] && [ ! -s "$TGT/usr/share/mime/icons" ]; then
      rm -f "$TGT/usr/share/mime/icons"
      echo "  pruned empty mime icons map (no icon mappings in the database)"
    fi
  fi
  if [ -x "$TGT/usr/bin/gtk-update-icon-cache" ]; then
    for tdir in "$TGT"/usr/share/icons/*/index.theme; do
      [ -f "$tdir" ] || continue
      themedir=$(dirname "$tdir")
      chroot "$TGT" /usr/bin/gtk-update-icon-cache -f -t "${themedir#"$TGT"}" \
        >"$WORK/niri-icontheme.log" 2>&1 \
        || echo "  (icon cache failed for ${themedir#"$TGT"})"
    done
  fi
  if [ -x "$TGT/usr/bin/update-desktop-database" ]; then
    chroot "$TGT" /usr/bin/update-desktop-database /usr/share/applications \
      >"$WORK/niri-desktop.log" 2>&1 \
      || echo "  (update-desktop-database failed; menu cache will be stale)"
  else
    echo "  (no update-desktop-database in the image; menu cache left unbuilt)"
  fi

# The config is now vendored, not fetched; the SHA constants only record provenance. Copy it, never
# symlink it, so a cached build tree stays self-contained; the stamp notices edits.
  local skel_src="$ROOT/rootfs-overlay/usr/share/copper/niri-skel"
  if [ ! -d "$skel_src/.config/niri" ]; then
    echo "niri: the vendored configuration tree is missing at $skel_src" >&2
    exit 1
  fi
  rm -rf "$TGT/usr/share/copper/niri-skel"
  mkdir -p "$TGT/usr/share/copper/niri-skel"
  cp -a "$skel_src/." "$TGT/usr/share/copper/niri-skel/"
  if [ ! -e "$TGT/usr/share/copper/niri-skel/.config/niri/config.kdl" ]; then
    echo "niri: the vendored config has no niri/config.kdl" >&2
    exit 1
  fi
  echo "  configuration tree staged from the repository ($NIRI_CFG_SHA)"

  # git does not carry the exec bit across platforms, so the tree can arrive
  # with every script mode 0644. The bar runs its helper scripts by path, and a
  # bare path is execve: without +x they fail with "permission denied" and the
  # bar comes up with no workspace chips. Anything that starts with a shebang
  # is meant to run, so restore exactly that set.
  n=0
  while IFS= read -r -d '' f; do
    if [ "$(head -c 2 "$f" 2>/dev/null)" = '#!' ]; then
      chmod 0755 "$f"; n=$((n + 1))
    fi
  done < <(find "$TGT/usr/share/copper/niri-skel" -type f -print0)
  echo "  $n scripts in the config tree marked executable"

  # A CR in any of those files fails on the target and the target has no editor
  # to fix it with; the tree is checked in with LF, and this proves it
  # held for the artifact that actually arrived.
  if grep -rIl $'\r' "$TGT/usr/share/copper/niri-skel" 2>/dev/null \
       | head -n 1 | grep -q .; then
    echo "niri: the configuration tree contains CR bytes; the session would fail" >&2
    grep -rIl $'\r' "$TGT/usr/share/copper/niri-skel" 2>/dev/null | head -n 5 >&2
    exit 1
  fi

# Copper's tweaks are a separate kdl included last: includes are positional, so we can tune the session
# without editing or re-pinning the vendored config.
  local overlay="$ROOT/rootfs-overlay/usr/share/copper/niri-overlay"
  if [ -r "$overlay/.config/niri/copper-tweaks.kdl" ]; then
    mkdir -p "$TGT/usr/share/copper/niri-skel/.config/niri"
    cp -a "$overlay/.config/niri/copper-tweaks.kdl" \
          "$TGT/usr/share/copper/niri-skel/.config/niri/copper-tweaks.kdl"
    printf '\n// Copper Linux session tweaks: animations and translucency.\ninclude "copper-tweaks.kdl"\n' \
      >> "$TGT/usr/share/copper/niri-skel/.config/niri/config.kdl"
    echo "  copper tweaks included into the niri config"
  else
    echo "  (no copper-tweaks.kdl found; shipping the pinned config unchanged)"
  fi

  # ---- the seat group ---------------------------------------------------
  # seatd's package postinst would create _seatd, and no postinst runs here.
  # copper-init starts seatd -g _seatd and the first-boot wizard puts the user
  # in it; without the group, seatd cannot start and there is no seat, which is
  # no compositor.
  if ! grep -q '^_seatd:' "$TGT/etc/group"; then
    local gid=999
    while grep -q ":$gid:" "$TGT/etc/group"; do gid=$((gid - 1)); done
    printf '_seatd:x:%s:\n' "$gid" >> "$TGT/etc/group"
    echo "  created the _seatd group (gid $gid) for seatd"
  fi

  # ---- gates ------------------------------------------------------------
  # Every one of these missing means the session cannot start -- or starts and
  # looks like it didn't -- and each is far clearer here than as a failed exec
  # on a live tty.
  local seatd_bin=""
  for f in usr/bin/niri usr/bin/waybar usr/bin/fuzzel usr/bin/swaybg \
           usr/bin/swaync usr/bin/kitty \
           usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1 \
           usr/lib/polkit-1/polkitd \
           usr/lib/polkit-1/polkit-agent-helper-1 \
           usr/share/dbus-1/system-services/org.freedesktop.PolicyKit1.service \
           usr/share/dbus-1/system.d/org.freedesktop.PolicyKit1.conf \
           usr/share/xdg-desktop-portal/niri-portals.conf \
           etc/polkit-1/rules.d/10-copper-wheel.rules \
           usr/share/copper/wallpapers/copper-default.png \
           etc/copper/niri-apps \
           usr/share/copper/niri-skel/.config/niri/config.kdl \
           usr/share/copper/niri-skel/.config/waybar/config.jsonc \
           usr/share/copper/niri-skel/.config/waybar/scripts/workspaces.sh; do
    if [ ! -e "$TGT/$f" ]; then
      echo "niri: $f did not arrive from the packages" >&2
      exit 1
    fi
  done
  # The config spawns these by absolute path. A file that exists but is not
  # executable is a session that silently skips it, which is how a portal's real
  # path went unnoticed on the desktop side until a boot. Check what runs.
  for f in usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1 \
           usr/share/copper/niri-skel/.config/waybar/scripts/workspaces.sh \
           usr/share/copper/niri-skel/.config/waybar/scripts/window.sh; do
    if [ ! -x "$TGT/$f" ]; then
      echo "niri: $f is not executable; the session would silently skip it" >&2
      exit 1
    fi
  done
  # The helper is only useful setuid. Check the bit, not the file: the mode
  # is what the agent's password check needs, and a cache restore is the
  # easiest way to lose it.
  if [ "$(stat -c '%a' "$TGT/usr/lib/polkit-1/polkit-agent-helper-1" 2>/dev/null)" != "4755" ]; then
    echo "niri: polkit-agent-helper-1 is mode $(stat -c '%a' "$TGT/usr/lib/polkit-1/polkit-agent-helper-1" 2>/dev/null || echo missing), not 4755; polkit authentication would fail" >&2
    exit 1
  fi

  # The component manifest has to agree with the tree. Every "image" probe is a
  # file startniri expects to be present; if the package that supplies it
  # renames a binary, the launcher reports a broken image on every start instead
  # of a boot failure here. "ingot" probes are absent on purpose, so skip those.
  while read -r cname cprobe corigin; do
    case "$cname" in ''|\#*) continue ;; esac
    [ -n "$cprobe" ] || continue
    [ "$corigin" = image ] || continue
    if [ ! -e "$TGT/$cprobe" ]; then
      echo "niri: manifest lists '$cname' as image but $cprobe is missing" >&2
      exit 1
    fi
  done < "$TGT/etc/copper/niri-apps"

  # seatd has lived in both /usr/bin and /usr/sbin across releases, so find it
  # rather than name a directory. -print -quit: grep -q closes the pipe on its
  # first match and a second write would arrive as SIGPIPE, which under pipefail
  # reads as "not found" no matter what was found.
  seatd_bin=$(find "$TGT/usr" -name seatd -type f -print -quit 2>/dev/null)
  if [ -z "$seatd_bin" ]; then
    echo "niri: seatd did not arrive from the packages; the session would have no seat" >&2
    exit 1
  fi

# Chroot niri validate: it parses the shipped config with the exact compositor that will read it, with no
# display or seat. A KDL error here costs a build; found on a boot it costs a machine nobody can type on.
  if ! chroot "$TGT" /usr/bin/niri validate \
       -c /usr/share/copper/niri-skel/.config/niri/config.kdl \
       >"$WORK/niri-validate.log" 2>&1; then
    echo "niri: the shipped config did not validate inside the staged rootfs:" >&2
    cat "$WORK/niri-validate.log" >&2 2>/dev/null || :
    exit 1
  fi
  echo "  $(head -n 1 "$WORK/niri-validate.log" 2>/dev/null)"
  if ! chroot "$TGT" /usr/bin/niri --version \
       >"$WORK/niri-version.log" 2>&1; then
    echo "niri: niri --version failed inside the staged rootfs:" >&2
    cat "$WORK/niri-version.log" >&2 2>/dev/null || :
    exit 1
  fi
  if ! chroot "$TGT" /usr/bin/waybar --version \
       >"$WORK/niri-waybar.log" 2>&1; then
    echo "niri: waybar --version failed inside the staged rootfs:" >&2
    cat "$WORK/niri-waybar.log" >&2 2>/dev/null || :
    exit 1
  fi

# The niri closure can pull in systemd-sysv's power links; re-run power_links so it answers from the
# tree's PID 1 and cannot undo the systemd flavour on a tree already swapped.
  power_links "$TGT"

  echo "  niri session staged ($(du -sh "$TGT" | cut -f1)) rootfs total"
  stamp_set "$WORK/niri.stamp" "$SELF" \
    "$ROOT/rootfs-overlay/etc/copper/niri-apps" \
    "$ROOT/rootfs-overlay/usr/share/copper/wallpapers/copper-default.png" \
    "$ROOT/rootfs-overlay/usr/share/copper/niri-overlay/.config/niri/copper-tweaks.kdl" \
    "$ROOT"/rootfs-overlay/usr/share/copper/niri-skel/.config/niri/config.kdl \
    "$ROOT"/rootfs-overlay/usr/share/copper/niri-skel/.config/waybar/config.jsonc \
    "$ROOT"/rootfs-overlay/usr/share/copper/niri-skel/.config/waybar/style.css \
    "$ROOT"/rootfs-overlay/usr/share/copper/niri-skel/.config/waybar/scripts/window.sh \
    "$ROOT"/rootfs-overlay/usr/share/copper/niri-skel/.config/waybar/scripts/workspaces.sh \
    "$ROOT"/rootfs-overlay/usr/share/copper/niri-skel/.config/kitty/kitty.conf
}


# ---------------------------------------------------------------
# 6g. the boot splash: Plymouth, staged the way the desktop is
# ---------------------------------------------------------------
# Plymouth is packaged upstream, not built here: the no-udev build is broken in 24.004.60 and enabling
# udev would need a daemon this image has no. The kernel switches plymouth.ignore-udev and
# plymouth.ignore-serial-consoles (grub.cfg passes both) steer it to DRM/fb and off ttyS0, which otherwise
# draws no frame. Copy only the daemon, client, libs, plugins and renderers.
build_plymouth() {
  if [ -e "$TGT/usr/sbin/plymouthd" ] \
     && stamped_skip "$WORK/plymouth.stamp" "$SELF" \
        "$ROOT/plymouth/copper/copper.plymouth" \
        "$ROOT/plymouth/copper/copper.script" \
        "$ROOT/plymouth/copper/frames/"*.png; then
    echo "plymouth: already staged, skipping"; return
  fi
  echo "==> boot splash (Plymouth)"
  local DP="$DL/plymouth" STAGE="$WORK/plymouth-root" deb dest n png="" p
  rm -rf "$DP"; mkdir -p "$DP"

  apt-get update -qq

  # noble renamed the PNG library for the 64-bit time_t transition
  # (libpng16-16 became libpng16-16t64); ask the host which name it carries,
  # the same way the gui stage asks for alsa.
  for p in libpng16-16t64 libpng16-16; do
    if apt-cache show "$p" >/dev/null 2>&1; then png=$p; break; fi
  done

  # plymouth and libplymouth5 are the splash; the rest are libraries their
  # binaries and renderers link against. Most already arrive through the gui
  # closure, but naming them keeps this stage self-contained. apt-get download
  # resolves no dependencies, which is what is wanted: an install would pull
  # systemd and udev in as packaging dependencies.
  local pkgs="plymouth libplymouth5 libdrm2 libudev1 libevdev2 libxkbcommon0"
  [ -n "$png" ] && pkgs="$pkgs $png"
  ( cd "$DP" && apt-get -o APT::Sandbox::User=root download $pkgs )

  rm -rf "$STAGE"; mkdir -p "$STAGE"
  for deb in "$DP"/*.deb; do
    dpkg-deb -x "$deb" "$STAGE"
  done
  n=$(ls "$DP"/*.deb | wc -l)
  echo "  $n packages unpacked"

  # Daemon and control client.
  install -D -m 0755 "$STAGE/usr/sbin/plymouthd" "$TGT/usr/sbin/plymouthd"
  install -D -m 0755 "$STAGE/usr/bin/plymouth" "$TGT/usr/bin/plymouth"

  # Plugins and renderers. `script` is the engine the theme uses; `text` is a
  # fallback for machines where no pixel display comes up.
  mkdir -p "$TGT/usr/lib/x86_64-linux-gnu/plymouth/renderers"
  cp -a "$STAGE/usr/lib/x86_64-linux-gnu/plymouth/." \
        "$TGT/usr/lib/x86_64-linux-gnu/plymouth/"

  # The libply libraries and everything the plugins link against. A library the
  # gui closure already staged is left alone -- it may be newer -- so the
  # destination is tested before copying. (cp -n says the same thing, but it
  # warns about portability on every file.)
  for deb in "$STAGE"/usr/lib/x86_64-linux-gnu/*; do
    case "${deb##*/}" in
      libply*.so*|libdrm.so*|libpng16.so*|libudev.so*|libevdev.so*|libxkbcommon.so*) ;;
      *) continue ;;
    esac
    dest="$TGT/usr/lib/x86_64-linux-gnu/${deb##*/}"
    [ -e "$dest" ] || [ -L "$dest" ] || cp -a "$deb" "$TGT/usr/lib/x86_64-linux-gnu/"
  done

  # The theme: the owner's frames and the script that steps through them. It is
  # data, so it is copied whole rather than installed piecemeal.
  rm -rf "$TGT/usr/share/plymouth/themes/copper"
  mkdir -p "$TGT/usr/share/plymouth/themes/copper"
  cp -a "$ROOT/plymouth/copper/." "$TGT/usr/share/plymouth/themes/copper/"

  # Which theme to load. plymouthd reads the [Daemon] Theme key from here (or
  # the plymouth.splash= switch on the kernel command line). The package ships
  # no config of its own, so without this it falls back to a compiled-in
  # default theme that is not ours.
  mkdir -p "$TGT/etc/plymouth" "$TGT/var/lib/plymouth"
  cat > "$TGT/etc/plymouth/plymouthd.conf" <<'CONF'
[Daemon]
Theme=copper
CONF

  local f
  for f in usr/sbin/plymouthd usr/bin/plymouth \
           usr/lib/x86_64-linux-gnu/plymouth/script.so \
           usr/lib/x86_64-linux-gnu/plymouth/renderers/drm.so \
           usr/lib/x86_64-linux-gnu/plymouth/renderers/frame-buffer.so \
           usr/lib/x86_64-linux-gnu/libply-splash-core.so.5 \
           usr/share/plymouth/themes/copper/copper.plymouth \
           usr/share/plymouth/themes/copper/copper.script \
           usr/share/plymouth/themes/copper/frames/1.png \
           usr/share/plymouth/themes/copper/frames/150.png \
           etc/plymouth/plymouthd.conf; do
    if [ ! -e "$TGT/$f" ]; then
      echo "plymouth: $f did not arrive from the packages" >&2
      exit 1
    fi
  done

  # And that they run in the target root, not merely exist. --help runs the
  # dynamic loader over every NEEDED library and exits; a missing libudev,
  # libevdev or libpng fails the build here instead of turning into a splash
  # that silently never appears on a machine nobody can log in to.
  if ! chroot "$TGT" /usr/sbin/plymouthd --help >/dev/null 2>&1; then
    echo "plymouth: plymouthd does not run inside the staged rootfs" >&2
    exit 1
  fi
  if ! chroot "$TGT" /usr/bin/plymouth --help >/dev/null 2>&1; then
    echo "plymouth: the plymouth client does not run inside the staged rootfs" >&2
    exit 1
  fi

  n=$(find "$TGT/usr/share/plymouth/themes/copper/frames" -name '*.png' | wc -l)
  echo "  splash staged: $n frames, $(du -sh "$TGT/usr/share/plymouth/themes/copper" | cut -f1)"
  stamp_set "$WORK/plymouth.stamp" "$SELF" \
    "$ROOT/plymouth/copper/copper.plymouth" \
    "$ROOT/plymouth/copper/copper.script" \
    "$ROOT/plymouth/copper/frames/"*.png
}

# sudo is a glibc binary and the base is musl, so build it on the host and stage it whole; wheel/ingot
# install depends on it. The URL and flags are the ones proven in sudo-dev.sh.
build_sudo() {
  if [ -e "$TGT/usr/bin/sudo" ] \
     && stamped_skip "$WORK/sudo.stamp" "$SELF" "$ROOT/sudo/sudoers"; then
    echo "sudo: already staged, skipping"; return
  fi
  echo "==> sudo"
  local SD SDD
  SD=$(fetch "https://www.sudo.ws/dist/sudo-1.9.15p5.tar.gz")
  SDD=$(unpack "$SD")
  if [ ! -x "$TGT/usr/bin/sudo" ]; then
    pushd "$SDD" >/dev/null
      # Dynamic against the host glibc (the gui closure ships the matching
      # runtime), no PAM (the image has no pam stack), plugins under
      # /usr/lib/sudo where RUNPATH points, and a secure default PATH.
      ./configure --prefix=/usr --sysconfdir=/etc \
        --libexecdir=/usr/lib/sudo --docdir=/usr/share/doc/sudo \
        --without-pam --with-secure-path \
        CFLAGS="-O2 -Wno-error=incompatible-pointer-types"
      make -j"$JOBS"; make DESTDIR="$TGT" install
    popd >/dev/null
  fi
# Install our sudoers last so the byte-for-byte gate sees ours, and pin root:root: a cache restore can
# bring the tree back as uid 1000, making setuid elevate to that user instead of root.
  chown 0:0 "$TGT/usr/bin/sudo"
  chmod 4755 "$TGT/usr/bin/sudo"
  mkdir -p "$TGT/run/sudo" "$TGT/etc/sudoers.d"
  install -m 0440 "$ROOT/sudo/sudoers" "$TGT/etc/sudoers"

  # ---- gates -------------------------------------------------------------
  # The chroot gate is the honest test: the loader resolves, the glibc
  # closure supplies libc, and libsudo_util.so.0 comes from the RUNPATH
  # /usr/lib/sudo that configure baked in. No LD_LIBRARY_PATH, exactly like
  # the booted image.
  if ! chroot "$TGT" /usr/bin/sudo -V 2>&1 | grep -q "Sudo version"; then
    echo "sudo: 'sudo -V' failed inside the staged rootfs" >&2
    exit 1
  fi
  # Setuid is the elevation mechanism; without the bit sudo runs, but as the
  # caller, which is nothing.
  if [ ! -u "$TGT/usr/bin/sudo" ]; then
    echo "sudo: /usr/bin/sudo is not setuid root" >&2
    exit 1
  fi
  # The shipped sudoers is the contract the wheels rely on; silently serving
  # a stale one would grant or deny rights nobody has agreed to.
  if ! cmp -s "$ROOT/sudo/sudoers" "$TGT/etc/sudoers"; then
    echo "sudo: staged sudoers does not match iso/sudo/sudoers" >&2
    exit 1
  fi

  echo "  sudo staged, setuid, sudoers verified"
  stamp_set "$WORK/sudo.stamp" "$SELF" "$ROOT/sudo/sudoers"
}

# ---------------------------------------------------------------
# 6i. systemd as PID 1 -- the migration, opt-in
# ---------------------------------------------------------------
# Opt-in only (`bash iso/build.sh systemd`): SYSTEMD-MIGRATION.md says a half swap is unbootable, and this
# image has never been booted.
# Swap /sbin/init, not the kernel command line, so /init still builds the overlay; keep copper-init as
# copper-console.service and keep seatd rather than logind, so one change at a time.
build_systemd() {
# Unit files and their four helper scripts are this stage's inputs: a helper left out of sdin lets a
# cached ISO ship the PREVIOUS helper under a matching stamp -- a stale artifact with a green light.
# Include the drop-in and zram-stop too, since both change how the machine shuts down.
  local sdin=("$SELF" "$ROOT/systemd"/*.service "$ROOT/systemd"/*.target)
  for p in "$ROOT/systemd"/*.conf "$ROOT/systemd"/*.network \
           "$ROOT/systemd/copper-tty-clear" "$ROOT/systemd/copper-dhcp" \
           "$ROOT/systemd/copper-zram" "$ROOT/systemd/copper-zram-stop" \
           "$ROOT/systemd/system.conf.d"/*.conf \
           "$ROOT/systemd/copper-splash-show" \
           "$ROOT/systemd/copper-splash-quit"; do
    [ -e "$p" ] && sdin+=("$p")
  done
  if [ -e "$TGT/lib/systemd/systemd" ] \
     && [ "$(init_flavour "$TGT")" = systemd ] \
     && stamped_skip "$WORK/systemd.stamp" "${sdin[@]}"; then
    echo "systemd: already staged, skipping"; return
  fi
  echo "==> systemd as PID 1 (migration, opt-in)"
  local DS="$DL/systemd" STAGE="$WORK/systemd-root" deb p ndeb

  # The gui/niri closures bring their own os-release with them; the
  # systemd stage inherits that tree, so re-assert Copper's identity as the
  # other stages do before anything reads it.
  copper_identity

  mkdir -p "$DS/partial"; rm -f "$DS"/*.deb
  apt-get update -qq

# An empty dpkg status fetches systemd's full dependency closure without installing a distro;
# --no-install-recommends keeps it to what systemd links. systemd-sysv is named explicitly because
# power_links normally removes its links and this stage wants them back.
  local status="$WORK/systemd-status"
  : > "$status"
  apt-get \
    -o Dir::State::status="$status" \
    -o Dir::Cache::archives="$DS" \
    -o APT::Sandbox::User=root \
    --download-only --no-install-recommends -y install systemd udev systemd-sysv

  rm -rf "$STAGE"; mkdir -p "$STAGE"
  for deb in "$DS"/*.deb; do
    dpkg-deb -x "$deb" "$STAGE"
  done
  # `ls ... | wc -l` reads well and is a pipefail landmine: if the glob matches
  # nothing, ls exits non-zero and `set -e` kills the stage with no message
  # about why. Count in the shell instead, where an empty list is just zero.
  local ndeb=0
  for deb in "$DS"/*.deb; do [ -e "$deb" ] && ndeb=$((ndeb + 1)); done
  echo "  $ndeb packages unpacked ($(du -sh "$STAGE" | cut -f1))"
  if [ "$ndeb" -eq 0 ]; then
    echo "systemd: apt-get downloaded no packages; check the mirrors and the host's apt sources" >&2
    exit 1
  fi

  # -n: a library the gui closure already staged wins. It was chosen by the
  # desktop's own dependency resolver and may well be newer than the copy
  # systemd would bring; overwriting it to satisfy the init would be trading a
  # working desktop for a boot detail.
  cp -a -n "$STAGE"/. "$TGT"/

  # ---- merged-usr, for the systemd subtree only -----------------------------
  # The systemd deb this image stages ships PID 1 at /usr/lib/systemd/systemd,
  # because the tree these debs are built in is merged-usr: /lib IS /usr/lib,
  # spelled as a symlink at the top level. Copper's tree is NOT merged-usr --
  # /lib here is a real directory holding the musl loader and busybox -- so
  # the deb's files land at $TGT/usr/lib/systemd/... and NOTHING lands at
  # $TGT/lib/systemd/... . That is what the second real CI run found: 39
  # packages unpacked (58M), and then `/lib/systemd/systemd did not arrive`,
  # because the gate at the end of this stage looks at the path the KERNEL and
  # /sbin/init use, and the packages never wrote it.
  #
  # It was green locally for a bad reason: the gate's mock payload put its fake
  # PID 1 at payload/lib/systemd/systemd, a layout no noble deb produces, so
  # the stage's own check was satisfied by the fixture rather than by the
  # package. The fixture is merged-usr-shaped now, which is the whole point --
  # a test that models the input wrongly certifies the wrong code.
  #
  # The fix is the merge, scoped to the one subtree that needs it. systemd was
  # compiled with SYSTEMD_UTIL_DIR=/usr/lib/systemd, so it reads its units and
  # helpers from /usr/lib/systemd natively and is happy; the only path that must
  # ALSO answer at /lib is PID 1 itself, which the kernel execs by the name in
  # /sbin/init. A symlink makes one directory answer at both names, exactly as
  # a merged-usr system does, and leaves the rest of Copper's /lib untouched.
  #
  # Keyed off the FILE, not the directory. An earlier version asked only
  # "is usr/lib/systemd a directory, and is lib/systemd absent?" and that
  # question has a wrong answer whenever something has already put a lib/systemd
  # in the tree: the bridge then skipped itself, nothing linked PID 1 into
  # place, and the stage died three lines later with
  #
  #     systemd: /lib/systemd/systemd did not arrive from the packages
  #
  # which is a true sentence that names the wrong culprit -- the packages did
  # arrive, and the bridge that was supposed to expose them declined to run.
  # (The gui closure, which runs first, is known to leave 454 paths under
  # usr/lib/systemd -- verified by unpacking it -- so usr/lib/systemd is always
  # a real directory by the time this runs; and the CI cache is saved on failure,
  # so a tree from a run that died here is restored by the next one.) So: work
  # out where PID 1 actually landed and make /lib answer for it, from whatever
  # state the tree is in.
  if [ -x "$TGT/usr/lib/systemd/systemd" ]; then
    if [ -L "$TGT/lib/systemd" ]; then
      # Already bridged (idempotent re-run). Nothing to do but say so.
      echo "  lib/systemd is already a symlink; merged-usr bridge in place"
    elif [ -d "$TGT/lib/systemd" ]; then
      # A real directory squats on the name. Normalise it to the symlink the
      # rest of the tree expects, after proving it holds no PID 1 of its own
      # (a tree with its own lib/systemd/systemd is a merged-usr rootfs and is
      # left exactly as it is).
      if [ ! -e "$TGT/lib/systemd/systemd" ]; then
        rm -rf "$TGT/lib/systemd"
        ln -sfn ../usr/lib/systemd "$TGT/lib/systemd"
        echo "  lib/systemd (real dir) -> usr/lib/systemd (merged-usr bridge)"
      else
        echo "  lib/systemd/systemd exists in the tree; left as it is"
      fi
    else
      mkdir -p "$TGT/lib"
      ln -sfn ../usr/lib/systemd "$TGT/lib/systemd"
      echo "  lib/systemd -> usr/lib/systemd (merged-usr bridge; the tree is not merged)"
    fi
  else
    # Say what the tree actually looks like, so the gate below is not the only
    # place this shows up.
    echo "  note: usr/lib/systemd/systemd is not present; bridge not needed"
  fi

  # systemd needs the glibc loader at the path the kernel hard-codes, the same
  # way every other glibc ELF in this image does. build_gui creates it; this
  # stage can run against a tree that was never through build_gui (or through
  # a cached one that predates the line), and without it PID 1 is ENOENT and
  # the machine does not boot at all. Cheap to re-assert.
  if [ ! -e "$TGT/lib64/ld-linux-x86-64.so.2" ]; then
    if [ -L "$TGT/lib64" ]; then rm -f "$TGT/lib64"; fi
    mkdir -p "$TGT/lib64"
    cp -L "$TGT/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" \
         "$TGT/lib64/ld-linux-x86-64.so.2"
  fi

  # Packages ship files that are empty by nature, and the rootfs stage asserts
  # on every later build over this tree that nothing in the image is zero
  # bytes. Prune exactly what the packages brought, matched against the
  # staging tree (same discipline as build_gui).
  if [ -d "$STAGE" ]; then
    find "$STAGE" -type f -size 0 -printf '%P\n' > "$WORK/systemd-empties"
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      rm -f "$TGT/$rel"
    done < "$WORK/systemd-empties"
    echo "  $(wc -l < "$WORK/systemd-empties") empty package files pruned"
  fi

# Copper's units are installed by hand: `systemctl enable` against a staged tree would need a chroot
# and running dbus, and only creates the same symlinks anyway.
  mkdir -p "$TGT/etc/systemd/system/multi-user.target.wants" \
           "$TGT/etc/systemd/system/sysinit.target.wants" \
           "$TGT/etc/systemd/system/copper.target.wants" \
           "$TGT/etc/systemd/network"
# Use install -m 0644 (Windows git can hand units 0777) and guard globs: a bare *.network expands to the
# literal pattern and killed the first run. The guard lets a future .network file just work.
  install -m 0644 "$ROOT/systemd"/*.service "$TGT/etc/systemd/system/"
  install -m 0644 "$ROOT/systemd"/*.target  "$TGT/etc/systemd/system/"
  # The splash now has units of its own, and an owner: daemon during sysinit,
  # quit hand-back before anything that draws on the console. The splash used
  # to have no unit at all under systemd, which is exactly why it never drew.
  ln -sf /etc/systemd/system/copper-plymouth.service \
         "$TGT/etc/systemd/system/sysinit.target.wants/copper-plymouth.service"
  # The helpers are SCRIPTS, not units, and they are the files in this
  # directory that have to be executable and to live on PATH (their units run
  # them as /usr/bin/copper-tty-clear, /usr/bin/copper-dhcp, /usr/bin/copper-zram
  # and the two splash helpers). 0755 here, not 0644 like the units: a unit
  # systemd reads is data, a program systemd execs is not.
  install -D -m 0755 "$ROOT/systemd/copper-tty-clear" \
          "$TGT/usr/bin/copper-tty-clear"
  install -D -m 0755 "$ROOT/systemd/copper-dhcp" \
          "$TGT/usr/bin/copper-dhcp"
  install -D -m 0755 "$ROOT/systemd/copper-zram" \
          "$TGT/usr/bin/copper-zram"
  install -D -m 0755 "$ROOT/systemd/copper-zram-stop" \
          "$TGT/usr/bin/copper-zram-stop"
  install -D -m 0755 "$ROOT/systemd/copper-splash-show" \
          "$TGT/usr/bin/copper-splash-show"
  install -D -m 0755 "$ROOT/systemd/copper-splash-quit" \
          "$TGT/usr/bin/copper-splash-quit"
  for f in "$ROOT/systemd"/*.conf; do
    [ -e "$f" ] || continue
    install -m 0644 "$f" "$TGT/etc/systemd/"
  done
  for f in "$ROOT/systemd"/*.network; do
    [ -e "$f" ] || continue
    install -m 0644 "$f" "$TGT/etc/systemd/network/"
  done
# system.conf.d is a manager drop-in, not a file for /etc/systemd; install -D makes the directory so the
# image does not depend on the systemd package having created it.
  for f in "$ROOT/systemd/system.conf.d"/*.conf; do
    [ -e "$f" ] || continue
    install -D -m 0644 "$f" "$TGT/etc/systemd/system.conf.d/$(basename "$f")"
  done

  local u
  for u in copper-tty-clear.service copper-firstboot.service copper-console.service; do
    ln -sf "/etc/systemd/system/$u" \
           "$TGT/etc/systemd/system/copper.target.wants/$u"
  done
  ln -sf /etc/systemd/system/copper.target \
         "$TGT/etc/systemd/system/multi-user.target.wants/copper.target"
  for u in copper-seatd.service copper-network.service copper-plymouth-quit.service copper-vmtools.service; do
    ln -sf "/etc/systemd/system/$u" \
           "$TGT/etc/systemd/system/copper.target.wants/$u"
  done
  ln -sf /etc/systemd/system/systemd-udevd.service \
         "$TGT/etc/systemd/system/sysinit.target.wants/systemd-udevd.service"
  # Compressed swap has to be up before the desktop allocates, so it is pulled
  # into sysinit rather than copper.target. The unit itself carries
  # DefaultDependencies=no and Before=sysinit.target (see its header).
  ln -sf /etc/systemd/system/copper-zram.service \
         "$TGT/etc/systemd/system/sysinit.target.wants/copper-zram.service"

  # The netconf is read by systemd-udevd's built-in naming scheme. Copper
  # names its NICs the kernel's way (eth0, not ens33), because the DHCP client
  # and the console's own documentation both talk about eth0.
  ln -sf /dev/null "$TGT/etc/systemd/network/99-default.link"

  # ---- PID 1 and the power commands ---------------------------------------
  # The swap itself. One symlink, and everything about boot ordering follows
  # from it.
  ln -sf /lib/systemd/systemd "$TGT/sbin/init"

  # Healthy D-Bus and udev state at first boot. systemd normally gets these
  # from the packages' tmpfiles data at install time; nothing here unpacks a
  # package's postinst, so make the directories the machine assumes exist.
  mkdir -p "$TGT/run/dbus" "$TGT/run/systemd/system" "$TGT/run/systemd/ask-password" \
           "$TGT/var/lib/systemd" "$TGT/etc/systemd/system/getty.target.wants"

# power_links reads the tree's PID 1, which is systemd after the swap, so desktop stages re-run over a
# cached tree cannot silently undo this. /usr/sbin is searched before /sbin, and /usr/sbin/shutdown is
# the wrapper link, not systemd-sysv's bare "power off in one minute" compatibility default.
  power_links "$TGT"

# Enable getty@ttyN for the spare VTs: copper-console owns tty1 but nothing enabled the others, leaving
# blinking unusable consoles. Linking template instances is the same operation systemctl enable performs.
  local vt
# getty units exec /sbin/agetty, but Debian installs /usr/sbin/agetty and Copper is not merged-usr;
# without the link every getty restarts forever with no login prompt. Find the binary, link /sbin/agetty
# to it, or fail the stage rather than shipping a machine with no console login.
  local agetty=""
  for c in usr/sbin/agetty usr/bin/agetty sbin/agetty bin/agetty; do
    if [ -f "$TGT/$c" ] && [ -x "$TGT/$c" ]; then agetty=$c; break; fi
  done
  if [ -z "$agetty" ]; then
    echo "systemd: no agetty anywhere in the tree; every getty unit would" >&2
    echo "          restart forever (getty@.service execs /sbin/agetty)." >&2
    echo "          util-linux is what ships it; make sure the closure has it." >&2
    exit 1
  fi
  # A merged-usr tree has /sbin as a symlink to usr/sbin, so the name already
  # resolves and writing a link there would try to replace the binary with a
  # link to itself. Copper is not merged-usr today (only /lib/systemd is
  # bridged), but the check costs nothing and the failure would be confusing.
  if [ "$agetty" != sbin/agetty ] && [ ! -L "$TGT/sbin" ]; then
    ln -sf "/$agetty" "$TGT/sbin/agetty"
    if [ "$(readlink "$TGT/sbin/agetty")" != "/$agetty" ]; then
      echo "systemd: could not point /sbin/agetty at /$agetty" >&2
      exit 1
    fi
  fi

  for vt in tty2 tty3 tty4 tty5 tty6; do
    ln -sf /lib/systemd/system/getty@.service \
           "$TGT/etc/systemd/system/getty.target.wants/getty@$vt.service"
  done

# Mask ldconfig.service with /dev/null in /etc: this image has no ldconfig, so the unit failed every boot
# and showed in `systemctl --failed`. /etc shadows the vendor unit and an administrator can rm the mask.
  ln -sf /dev/null "$TGT/etc/systemd/system/ldconfig.service"

  # ---- gates --------------------------------------------------------------
  if [ ! -x "$TGT/lib/systemd/systemd" ]; then
    echo "systemd: /lib/systemd/systemd did not arrive from the packages" >&2
    echo "  lib/systemd:     $(ls -ld "$TGT/lib/systemd" 2>&1)" >&2
    echo "  usr/lib/systemd: $(ls -ld "$TGT/usr/lib/systemd" 2>&1)" >&2
    echo "  usr/lib/systemd/systemd: $(ls -l "$TGT/usr/lib/systemd/systemd" 2>&1)" >&2
    exit 1
  fi
  if [ "$(init_flavour "$TGT")" != systemd ]; then
    echo "systemd: sbin/init does not point at /lib/systemd/systemd" >&2
    exit 1
  fi
# Prove PID 1's absolute interpreter exists in the tree. Avoid `readelf | sed | head`: head closes the
# pipe, sed takes SIGPIPE, and `set -o pipefail` aborts the stage; use one anchored sed and take its
# first line instead.
  local interp=""
  interp=$(readelf -l "$TGT/lib/systemd/systemd" 2>/dev/null \
           | sed -n 's/.*interpreter: \(.*\)\]$/\1/p' | sed -n '1p' || true)
  if [ -n "$interp" ] && [ ! -e "$TGT$interp" ]; then
    echo "systemd: $interp (PID 1's interpreter) is missing from the staged rootfs" >&2
    exit 1
  fi
  # The units are the migration. A unit that failed to install is a service
  # that silently never starts, which on a booted machine looks exactly like
  # the feature not existing.
  local want uf
  for uf in copper.target copper-tty-clear.service copper-firstboot.service \
            copper-console.service copper-seatd.service copper-network.service \
            copper-plymouth.service copper-plymouth-quit.service; do
    if [ ! -f "$TGT/etc/systemd/system/$uf" ]; then
      echo "systemd: unit $uf did not install" >&2
      exit 1
    fi
  done
  for want in copper.target.wants/copper-tty-clear.service \
              copper.target.wants/copper-firstboot.service \
              copper.target.wants/copper-console.service \
              copper.target.wants/copper-seatd.service \
              copper.target.wants/copper-network.service \
              copper.target.wants/copper-plymouth-quit.service \
              sysinit.target.wants/copper-plymouth.service \
              multi-user.target.wants/copper.target; do
    if [ ! -L "$TGT/etc/systemd/system/$want" ]; then
      echo "systemd: $want is not a symlink; the unit would not start" >&2
      exit 1
    fi
  done
  # The clear helper is exec'd by the unit above. A unit with an ExecStart that
  # does not exist is the seatd failure all over again, one unit over -- so it is
  # asserted executable at the exact path the unit names. The two splash
  # helpers get the same treatment: copper-plymouth.service and
  # copper-plymouth-quit.service exec them by absolute path.
  for h in copper-tty-clear copper-splash-show copper-splash-quit copper-zram-stop; do
    if [ ! -x "$TGT/usr/bin/$h" ]; then
      echo "systemd: /usr/bin/$h is missing or not executable;" >&2
      echo "          a unit would exec a path that does not exist" >&2
      exit 1
    fi
  done
# The seat is part of the migration: copper-seatd.service is wanted by copper.target and fails silently if
# seatd sits at the other path or _seatd is missing. A boot found both wrong, so both are asserted here.
  if [ ! -x "$TGT/usr/bin/seatd" ] && [ ! -x "$TGT/usr/sbin/seatd" ]; then
    echo "systemd: no seatd binary at /usr/bin/seatd or /usr/sbin/seatd;" >&2
    echo "          copper-seatd.service would exec a path that does not exist" >&2
    exit 1
  fi
  if ! grep -q '^_seatd:' "$TGT/etc/group"; then
    echo "systemd: /etc/group has no _seatd group; seatd -g _seatd would exit" >&2
    echo "          before binding /run/seatd.sock (the wizard's addgroup line did not survive)" >&2
    exit 1
  fi
  # The mask, read back the way systemd resolves it: the name in /etc must be a
  # symlink to /dev/null. A mask that silently failed to install is the failure
  # this whole block is about, so it is asserted rather than assumed.
  if [ "$(readlink "$TGT/etc/systemd/system/ldconfig.service" 2>/dev/null)" != /dev/null ]; then
    echo "systemd: ldconfig.service is not masked; the image has no ldconfig and" >&2
    echo "          the unit would fail on every boot (it did, on the first boot)" >&2
    exit 1
  fi
# No ExecStart-path sweep: units legitimately use shell expressions and runtime paths, so a naive parser
# rejects correct units. The explicit assertions above check what the boot actually proved.

  # The mode too, not just the presence. A unit that installed 0777 is a unit
  # systemd reads with a warning, and the source tree is 777 on Windows, so
  # this is the check that catches a cp that should have been install -m.
  for uf in "$TGT/etc/systemd/system"/copper*.service \
            "$TGT/etc/systemd/system/copper.target"; do
    if [ "$(stat -c '%a' "$uf" 2>/dev/null)" != 644 ]; then
      echo "systemd: $(basename "$uf") installed as mode $(stat -c '%a' "$uf" 2>/dev/null), expected 644" >&2
      exit 1
    fi
  done

# ---- the shutdown bounds ------------------------------------------------
# DefaultDependencies=no removes stop edges, so zram and plymouth need explicit Conflicts/Before=
# shutdown.target or their ExecStop never runs and systemd-shutdown's unbounded swapoff waits ten
# minutes. Check the system.conf.d 10 s cap and the console's 5 s KillMode=mixed bound.
  if [ ! -f "$TGT/etc/systemd/system.conf.d/copper-shutdown.conf" ]; then
    echo "systemd: the system.conf.d drop-in did not install; every stop falls" >&2
    echo "          back to the 90 s default it exists to replace" >&2
    exit 1
  fi
  if [ "$(stat -c '%a' "$TGT/etc/systemd/system.conf.d/copper-shutdown.conf" 2>/dev/null)" != 644 ]; then
    echo "systemd: the system.conf.d drop-in is not mode 644" >&2
    exit 1
  fi
  if ! grep -qx 'DefaultTimeoutStopSec=10s' \
          "$TGT/etc/systemd/system.conf.d/copper-shutdown.conf"; then
    echo "systemd: the system.conf.d drop-in has no DefaultTimeoutStopSec=10s" >&2
    exit 1
  fi
  for uf in copper-zram.service copper-plymouth.service; do
    if ! grep -qx 'Conflicts=shutdown.target' "$TGT/etc/systemd/system/$uf"; then
      echo "systemd: $uf has DefaultDependencies=no but no" >&2
      echo "          Conflicts=shutdown.target; it would have no stop job" >&2
      exit 1
    fi
    if ! grep -qx 'Before=shutdown.target' "$TGT/etc/systemd/system/$uf"; then
      echo "systemd: $uf has no Before=shutdown.target; its stop would not be" >&2
      echo "          ordered into the shutdown transaction" >&2
      exit 1
    fi
  done
  if ! grep -qx 'ExecStop=-/usr/bin/copper-zram-stop' \
          "$TGT/etc/systemd/system/copper-zram.service"; then
    echo "systemd: copper-zram.service does not stop its swap through the" >&2
    echo "          helper; systemd-shutdown's unbounded swapoff would run" >&2
    exit 1
  fi
  if ! grep -qx 'KillMode=mixed' "$TGT/etc/systemd/system/copper-console.service" \
     || ! grep -qx 'TimeoutStopSec=5s' "$TGT/etc/systemd/system/copper-console.service"; then
    echo "systemd: copper-console.service has no bounded stop; the desktop's" >&2
    echo "          cgroup holds the shutdown for the 90 s default" >&2
    exit 1
  fi

  # copper-init still has to exist: the console service runs the --console half
  # of it. A migration that deleted it here would leave the machine with no
  # wizard and no shell.
  if [ ! -x "$TGT/usr/bin/copper-init" ]; then
    echo "systemd: /usr/bin/copper-init is missing; copper-console.service needs it" >&2
    exit 1
  fi
# Assert every command the Copper units name (copper-dhcp, udhcpc, /bin/sh, zram-stop, plymouth): unit
# verify runs chrooted but filters "Command X is not executable" as host noise, so a binary missing from
# the image would never be reported.
  for cmd in usr/bin/copper-dhcp sbin/udhcpc bin/sh usr/sbin/plymouthd usr/bin/plymouth usr/bin/copper-zram usr/bin/copper-zram-stop; do
    if [ ! -x "$TGT/$cmd" ]; then
      echo "systemd: $cmd is missing or not executable; a Copper unit names it" >&2
      echo "          and that unit would fail to start on every boot" >&2
      exit 1
    fi
  done

  # systemd-analyze is the parser that will read these units on the booted
  # machine, so let it read them. It must run INSIDE a chroot into $TGT: run
  # from the build host it resolves ExecStart against the HOST, which has none
  # of Copper's binaries, and it reports every unit as "Command /usr/bin/
  # copper-init is not executable: No such file or directory" -- a failure
  # that looks exactly like a real one and is not. Chrooted, that same check
  # becomes the real thing: it proves each command the units name is present
  # and executable in the tree that will boot.
  #
  # The host's systemd-analyze is a convenience, not the image's systemd: a
  # newer host accepts a directive the image's 255 does not, so the units stay
  # on directives that predate 255. And two classes of message are about the
  # host rather than the units, filtered here rather than tolerated by eye:
  #
  #   - "Can't show udhcpc(1)" and man(1)'s exit status: Documentations=
  #     names man pages that exist in the image, not on the build host.
  #   - messages about /usr/lib/systemd/system/*: the base units pulled in as
  #     dependencies, some of which want libseccomp the build host lacks.
  #
  # Anything else about a Copper unit fails the build.
  #
  # systemd-analyze is a build-time tool, not part of the image (nothing here
  # installs it), so it is copied into the staged tree for the check and every
  # file that copy added is removed again. The two things this has to get right:
  #
  #   - the tool needs its own shared libraries, and the staged tree has a
  #     different libc from the build host (this is a musl-base image with a
  #     glibc userland bolted on; the host is neither). libm.so.6 in particular
  #     is not in the image until systemd's own closure puts it there, and the
  #     FIRST version of this check copied the binary alone and died with
  #     "libm.so.6: cannot open shared object file" -- a hard build failure
  #     caused entirely by the check. So: copy the tool with its ldd closure.
  #
  #   - the tree must come back exactly as it was. The added paths are recorded
  #     as they are created and removed at the end, on both the success and the
  #     failure path, so a rejection here does not leave the build host's libc
  #     in the ISO either.
  #
  # If the tool still cannot run inside the chroot, the check SKIPS with a
  # note. It is a convenience over the gates above it (which already prove the
  # units installed, are wired and are mode 644); it must never be the reason a
  # build fails.
  if command -v systemd-analyze >/dev/null 2>&1; then
    local sa="/usr/bin/systemd-analyze" added="$WORK/systemd-added" f lib
    : > "$added"
    mkdir -p "$TGT/usr/bin"
    if [ ! -e "$TGT$sa" ]; then
      cp -L "$(command -v systemd-analyze)" "$TGT$sa"
      chmod 0755 "$TGT$sa"
      printf '%s\n' "$sa" >> "$added"
    fi
    # Its library closure, at the paths ldd names. Anything already in the tree
    # is left alone and not recorded, so nothing the image needs is removed.
    while IFS= read -r lib; do
      [ -n "$lib" ] || continue
      if [ ! -e "$TGT$lib" ] && [ -e "$lib" ]; then
        mkdir -p "$TGT$(dirname "$lib")"
        cp -L "$lib" "$TGT$lib" 2>/dev/null && printf '%s\n' "$lib" >> "$added"
      fi
    done < <(ldd "$(command -v systemd-analyze)" 2>/dev/null \
             | grep -oE '/[^ ]+\.so[^ ]*' | sort -u)

    local ul out left canrun=1
    if ! chroot "$TGT" "$sa" --version >/dev/null 2>&1; then
      canrun=0
      echo "  (systemd-analyze does not run in the staged tree; unit verify skipped)"
    fi
    if [ "$canrun" = 1 ]; then
# Verify all units in ONE transaction: systemd's own udevd unit carries `Before=sysinit.target`;
# copper-tty-clear's `After=sysinit.target` and `Before=systemd-udevd.service` then close the loop:
# the initial transaction fails outright, not a degraded boot.
      local vlist=""
      for ul in copper-console.service copper-firstboot.service \
                copper-network.service copper-seatd.service \
                copper-tty-clear.service copper.target copper-zram.service \
                copper-plymouth.service copper-plymouth-quit.service; do
        vlist="$vlist /etc/systemd/system/$ul"
      done
      out=$(chroot "$TGT" "$sa" verify $vlist 2>&1 || true)
      if printf '%s\n' "$out" | grep -qiE 'ordering cycle|cyclic ordering|order is cyclic|break cycle'; then
        echo "systemd: the units form an ordering cycle; the boot would fail" >&2
        echo "          (a cycle on sysinit.target fails the initial transaction)" >&2
        printf '%s\n' "$out" | grep -iE 'cycle|cyclic' | sed 's/^/     /' >&2
        while IFS= read -r f; do [ -n "$f" ] && rm -f "$TGT$f"; done < "$added"
        exit 1
      fi

      # The pattern is named ONCE, so there is exactly one place where it can
      # be wrong -- and the gate can point at that place instead of at a
      # string it happens to find somewhere in the file.
      notexec="is not executable"
      for ul in copper-console.service copper-firstboot.service \
                copper-network.service copper-seatd.service \
                copper-tty-clear.service copper-plymouth.service \
                copper-plymouth-quit.service copper-zram.service; do
        out=$(chroot "$TGT" "$sa" verify "/etc/systemd/system/$ul" 2>&1 || true)
# Only parse/directive errors about THIS unit fail the build; host dependency noise is filtered out. Use
# an allow-list, not a blacklist: systemd 255 says "Unknown key name" and 256+ drops "name", so a
# deny-list went red on one runner and green on another.
        left=$(printf '%s\n' "$out" \
          | grep -E "Unknown (key|lvalue|section)|Failed to parse|Empty (ExecStart|section)|not a valid" \
          | grep -F "$ul" \
          | grep -c . || true)
        if [ "$left" != 0 ]; then
          echo "systemd: systemd-analyze rejected $ul:" >&2
          printf '%s\n' "$out" | sed 's/^/     /' >&2
          while IFS= read -r f; do [ -n "$f" ] && rm -f "$TGT$f"; done < "$added"
          exit 1
        fi
# In the chroot the tree IS the machine: "Command X is not executable" means a real missing binary there,
# while the same shape is host noise on the build host, so the chroot gets its own narrower rule.
        gone=$(printf '%s\n' "$out" \
          | grep -E "$notexec" \
          | grep -F "$ul" \
          | grep -c . || true)
        if [ "$gone" != 0 ]; then
          echo "systemd: $ul names a command the image does not have:" >&2
          printf '%s\n' "$out" | grep -F "$ul" | grep -E "$notexec" \
            | sed 's/^/     /' >&2
          while IFS= read -r f; do [ -n "$f" ] && rm -f "$TGT$f"; done < "$added"
          exit 1
        fi
      done
      echo "  units verified by systemd-analyze (chrooted; ExecStart resolves)"
    fi
    # Remove exactly what was added, deepest path first so directories empty out.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rm -f "$TGT$f"
    done < "$added"
    rm -f "$added"
  fi

  echo "  systemd staged as PID 1 ($(du -sh "$TGT/lib/systemd" | cut -f1));"
  echo "  copper-init kept as copper-console.service"
  stamp_set "$WORK/systemd.stamp" "${sdin[@]}"
}

# ---------------------------------------------------------------
# 6j. the unified image: systemd's payload, copper-init's default
# ---------------------------------------------------------------
# One ISO ships both inits; the "systemd init" menu entry or saved /etc/copper-init picks at boot. Keep the
# payload and the /lib bridge (default_flavour would drop it), but point /sbin/init back at copper-init
build_unified() {
  build_systemd

  # The default boot. /sbin/init is the path /init execs when the answer is
  # busybox; the systemd branch execs /lib/systemd/systemd directly.
  if [ "$(readlink "$TGT/sbin/init")" != "/usr/bin/copper-init" ]; then
    ln -sf /usr/bin/copper-init "$TGT/sbin/init"
    echo "  sbin/init: systemd -> copper-init (the unified image's default)"
  fi
  make_merged_usr_bridge "$TGT"
  # Every power name is the runtime wrapper on both inits, so this is the same
  # link set on every tree; re-run it anyway, because build_systemd just copied
  # systemd-sysv in and a link it left behind must not survive to the disc.
  power_links "$TGT"

  # ---- gates --------------------------------------------------------------
  # Both halves have to be present and reachable, or the menu entry is a
  # promise the image cannot keep.
  if [ "$(readlink "$TGT/sbin/init")" != "/usr/bin/copper-init" ]; then
    echo "unified: sbin/init does not point at copper-init (the default boot)" >&2
    exit 1
  fi
  if [ ! -x "$TGT/usr/bin/copper-init" ]; then
    echo "unified: /usr/bin/copper-init is missing; the default boot would fail" >&2
    exit 1
  fi
  if [ ! -x "$TGT/lib/systemd/systemd" ]; then
    echo "unified: /lib/systemd/systemd is not reachable; the GRUB systemd" >&2
    echo "         entry would fall back to copper-init (or fail)" >&2
    exit 1
  fi
  if ! merged_usr_bridge "$TGT"; then
    echo "unified: /lib/systemd is not the merged-usr bridge; the systemd boot" >&2
    echo "         would not find PID 1 at the path /init execs" >&2
    exit 1
  fi
  # systemd's boot has to end at the same wizard as the busybox one, or the
  # "both inits work" claim is only half true.
  if [ ! -f "$TGT/etc/systemd/system/copper-console.service" ]; then
    echo "unified: copper-console.service did not install; systemd would boot" >&2
    echo "         to a machine with no console shell or wizard" >&2
    exit 1
  fi
  for f in etc/copper.conf etc/copper-init; do
    if [ ! -s "$TGT/$f" ]; then
      echo "unified: /$f is missing; the boot-time choice has no default" >&2
      exit 1
    fi
  done
  # The menu entry is the interface a user sees. Every provider renders it from
  # the shared entry list, so a missing switch here is a missing switch on the
  # disc whatever bootloader packaged it.
  if ! grep -q 'copper\.init=systemd' "$ROOT/boot/entries"; then
    echo "unified: the boot entry list has no entry passing copper.init=systemd" >&2
    echo "         the image would carry systemd but offer no way to boot it" >&2
    exit 1
  fi
  echo "  unified: copper-init is the default, systemd is the GRUB entry"
}

# ---------------------------------------------------------------
# 7. live initramfs (busybox + our /init, drivers built into kernel)
# ---------------------------------------------------------------
build_initramfs() {
  local INITRD="$WORK/initramfs"
  if [ -s "$TGT/boot/initrd.img" ] \
     && stamped_skip "$WORK/initramfs.stamp" "$SELF" "$ROOT/live/init"; then
    echo "initramfs: already built, skipping"; return
  fi
  echo "==> initramfs"
  # Start from nothing every time. $INITRD lives in the cached work tree, and
  # mkdir -p only ever adds: a staging directory left over from an earlier
  # version of the init script gets packed into the cpio again, which is how a
  # removed mnt/upper/upper kept turning up in the image.
  rm -rf "$INITRD"
  # Only the mount points themselves. upper/ and work/ are deliberately NOT
  # created here: /init has to make them after it mounts the tmpfs on
  # /mnt/upper, because a tmpfs mounted over a directory hides what was
  # already in it, and the overlay then fails on a missing upperdir.
  mkdir -p "$INITRD"/{bin,sbin,proc,sys,dev,mnt/root,mnt/upper,mnt/merged,run}
  cp "$TGT/bin/busybox" "$INITRD/bin/busybox"
  install -m 0755 "$ROOT/live/init" "$INITRD/init"
  ( cd "$INITRD" && find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9 ) \
    > "$TGT/boot/initrd.img"
  [ -s "$TGT/boot/initrd.img" ] || { echo "initramfs build failed"; exit 1; }
  stamp_set "$WORK/initramfs.stamp" "$SELF" "$ROOT/live/init"
}

# ---------------------------------------------------------------
# 8. boot media (a pluggable provider turns the staged tree into an ISO)
# ---------------------------------------------------------------
build_iso() {
  # Stamped on the whole staged tree, not on the menu alone: the ISO is a copy
  # of all of it, so a change to the overlay, the initrd or the kernel all have
  # to be able to invalidate it. The provider writes the menu first so it is
  # part of the tree that gets hashed, which is the tree that gets packaged.
  bootloader_configure "$TGT"
  # The live init identifies its own medium by this marker, not by the name of
  # one particular bootloader's config. A provider that replaces GRUB still
  # gets a disc that mounts.
  printf 'copper live media\n' > "$TGT/boot/copper-media"
  # The unified tree carries the systemd payload under usr/lib/systemd with
  # /sbin/init pointing at copper-init. The /lib bridge is what makes
  # /lib/systemd/systemd reachable inside the merged root, and a stage that
  # ran again between build_unified and here (build_gui re-runs when
  # build_rootfs clobbers /etc/group) copies packages in through
  # copy_stage_in, which takes the bridge off. Put it back before the tree
  # hash, so what is packaged has it. No-op on a tree with no systemd payload.
  make_merged_usr_bridge "$TGT"
# Pin ownership and modes before the tree hash so packaging hygiene is part of the stamped tree.
# actions/cache restores iso/work as uid 1000; use chown -h so links are not followed off the tree, and
# touch only non-root entries so setuid bits survive.
  find "$TGT" \( ! -uid 0 -o ! -gid 0 \) -exec chown -h 0:0 {} +
  # The live image had /usr and friends owned by uid 1000: a directory the
  # desktop user can write is a directory that user can replace with a root-run
  # binary. Assert the whole system tree is root-owned and not group/world
  # writable, not just sudo and shadow. Group ownership of polkit's state dirs
  # (etc/polkit-1, var/lib/polkit-1) is intentional and outside these trees.
  for d in usr usr/bin usr/lib usr/share usr/local usr/local/bin usr/local/sbin \
           bin sbin lib lib64; do
    [ -e "$TGT/$d" ] || continue
    own=$(stat -c '%u:%g' "$TGT/$d" 2>/dev/null || echo missing)
    mode=$(stat -c '%a' "$TGT/$d" 2>/dev/null || echo missing)
    if [ "$own" != 0:0 ]; then
      echo "iso: /$d is owned by $own, not 0:0" >&2
      exit 1
    fi
    case "$mode" in
      *[!0-7]*)
        echo "iso: /$d has an unreadable mode '$mode'" >&2
        exit 1
        ;;
    esac
    if [ $(( 8#$mode & 022 )) -ne 0 ]; then
      echo "iso: /$d is $own mode $mode; system directories must be root:root without group/other write" >&2
      exit 1
    fi
  done
  local bad_dirs own mode gshadow_gid gsgid gm go
  bad_dirs=$(find "$TGT/usr" "$TGT/bin" "$TGT/sbin" "$TGT/lib" \
      -type d \( ! -uid 0 -o -perm /022 \) -print 2>/dev/null | head -n 20)
  if [ -n "$bad_dirs" ]; then
    echo "iso: system directories are writable or not root-owned:" >&2
    printf '%s\n' "$bad_dirs" | sed 's|.*/iso/work/rootfs|/|' >&2
    exit 1
  fi
  # chown clears setuid/setgid on regular files even when the owner does not
  # change (measured). The find above only touches non-root entries, so sudo is
  # not among them -- but re-assert it anyway: build_sudo set this bit earlier
  # and a silent drop here is exactly the failure this function exists to stop.
  chmod 4755 "$TGT/usr/bin/sudo"
# su needs 4755 to change uid; its PAM common-* includes come from the overlay, or pam_start aborts
# before a password is read.
  if [ -e "$TGT/usr/bin/su" ]; then
    chown 0:0 "$TGT/usr/bin/su"
    chmod 4755 "$TGT/usr/bin/su"
  else
    echo "iso: no /usr/bin/su in the tree; 'su' would fall through to a busybox applet" >&2
    exit 1
  fi
  for pf in common-auth common-account common-session common-password; do
    if [ ! -s "$TGT/etc/pam.d/$pf" ]; then
      echo "iso: /etc/pam.d/$pf is missing or empty; su would abort at pam_start" >&2
      exit 1
    fi
  done
  if ! chroot "$TGT" /usr/bin/su -c /bin/true </dev/null >/dev/null 2>&1; then
    echo "iso: /usr/bin/su cannot run in the staged tree; its PAM stack does not load" >&2
    exit 1
  fi
  # polkit's authentication helper, for exactly the same reason. build_niri
  # sets its bit too, but a cache restore can strip it and the niri stage can
  # then skip on its stamp. Re-assert here, before the tree hash, then read it
  # back off the disc below.
  if [ -e "$TGT/usr/lib/polkit-1/polkit-agent-helper-1" ]; then
    chown 0:0 "$TGT/usr/lib/polkit-1/polkit-agent-helper-1"
    chmod 4755 "$TGT/usr/lib/polkit-1/polkit-agent-helper-1"
  fi
  #
  # /etc/shadow ships 0644 in git and is copied with cp -a, so it was readable
  # by everyone even before this change. Root reads it directly (setuid sudo
  # and its PAM stack run as root), nothing else here authenticates, so
  # root-only is right. /etc/gshadow is different: root:shadow at 0640, using
  # the shadow group declared in our staged /etc/group.
  chmod 0600 "$TGT/etc/shadow"
  if [ -e "$TGT/etc/gshadow" ]; then
    # Root:shadow, 0640: the packaging error reported against the live image
    # was 0000 root:root. Use the staged group's numeric gid: chown on the
    # build host resolves names from the host, not from the staged /etc/group.
    gshadow_gid=$(awk -F: '$1 == "shadow" { print $3; exit }' "$TGT/etc/group" 2>/dev/null)
    if [ -n "$gshadow_gid" ]; then
      chown "0:$gshadow_gid" "$TGT/etc/gshadow"
      chmod 0640 "$TGT/etc/gshadow"
    else
      chown 0:0 "$TGT/etc/gshadow"
      chmod 0600 "$TGT/etc/gshadow"
    fi
  fi
  #
  # /tmp: a live session writes there -- Xorg's lock file and socket
  # (/tmp/.X0-lock, /tmp/.X11-unix) and startxfce's log among them -- and a
  # non-root Xorg dies on an unwritable /tmp before it paints. It is on the
  # overlay, not its own tmpfs, so this mode is the one the session gets.
  mkdir -p "$TGT/tmp"
  chmod 1777 "$TGT/tmp"

# No dpkg triggers run, so compile the 46 staged schemas with the host glib-compile-schemas into
# gschemas.compiled. Without it Firefox aborts with "No GSettings schemas are installed on the system",
# the portal and gvfs SIGTRAP, and xfsettingsd never hands out XSETTINGS. The cache format is stable.
  local gcs gsc
  gcs=$(command -v glib-compile-schemas) || {
    echo "iso: glib-compile-schemas is not on the build host" >&2
    echo "iso: on Debian/Ubuntu it is in libglib2.0-dev-bin; CI installs it in the workflow" >&2
    exit 1
  }
  if ! "$gcs" "$TGT/usr/share/glib-2.0/schemas" >"$WORK/gcs.log" 2>&1; then
    echo "iso: glib-compile-schemas rejected the staged schemas:" >&2
    sed 's/^/iso:   /' "$WORK/gcs.log" >&2
    exit 1
  fi
  gsc="$TGT/usr/share/glib-2.0/schemas/gschemas.compiled"
  if [ ! -s "$gsc" ]; then
    echo "iso: compiling the staged schemas produced no gschemas.compiled" >&2
    exit 1
  fi
  # The cache is a serialised GVariant and the schema ids are plain strings
  # inside it, so a byte-grep proves the desktop schemas really landed in
  # the file rather than it merely being non-empty.
  if ! grep -aqF 'org.gnome.desktop.background' "$gsc"; then
    echo "iso: gschemas.compiled does not carry org.gnome.desktop.background" >&2
    exit 1
  fi
  # The find above has already run, so the two files this block creates pin
  # their own ownership -- on a warm cache the runner owns the tree, and -R
  # would carry that to the disc.
  chown 0:0 "$gsc"; chmod 0644 "$gsc"

# Debian's dmz-cursor-theme postinst makes /usr/share/icons/default/index.theme an alternatives symlink;
# none runs here, so GTK's fallback to "default" found an empty dir and Firefox logged "Unable to load
# pointer from the cursor theme". Copy DMZ-White's cursor.theme as a real file with the same bytes.
  if [ ! -f "$TGT/usr/share/icons/DMZ-White/cursor.theme" ]; then
    echo "iso: DMZ-White/cursor.theme is not staged; the default cursor theme cannot inherit it" >&2
    exit 1
  fi
  mkdir -p "$TGT/usr/share/icons/default"
  cp "$TGT/usr/share/icons/DMZ-White/cursor.theme" \
     "$TGT/usr/share/icons/default/index.theme"
  chown 0:0 "$TGT/usr/share/icons/default/index.theme"
  chmod 0644 "$TGT/usr/share/icons/default/index.theme"

# GTK reads /etc/gtk-3.0/settings.ini before an XSETTINGS manager answers. The
# deb stage drops Yaru defaults there, but no Yaru theme or icon set is staged;
# Electron then starts with a theme it cannot resolve (one of the renderer
# SIGSEGV paths). Copper's overlay names themes that are actually on the disc.
# Check the names against the tree, not against a hardcoded list, so a theme
# replacement only has to change the settings file and the package list.
  local gtk_theme gtk_icons gtk_cursor
  gtk_theme=$(sed -n 's/^gtk-theme-name[[:space:]]*=[[:space:]]*//p' \
      "$TGT/etc/gtk-3.0/settings.ini" 2>/dev/null | head -n1)
  gtk_icons=$(sed -n 's/^gtk-icon-theme-name[[:space:]]*=[[:space:]]*//p' \
      "$TGT/etc/gtk-3.0/settings.ini" 2>/dev/null | head -n1)
  gtk_cursor=$(sed -n 's/^gtk-cursor-theme-name[[:space:]]*=[[:space:]]*//p' \
      "$TGT/etc/gtk-3.0/settings.ini" 2>/dev/null | head -n1)
  if [ -z "$gtk_theme" ] || [ -z "$gtk_icons" ] || [ -z "$gtk_cursor" ]; then
    echo "iso: /etc/gtk-3.0/settings.ini has no theme/icon/cursor fallback" >&2
    echo "iso: Electron can segfault before XFCE's xsettings answer" >&2
    exit 1
  fi
  for pair in "themes:$gtk_theme" "icons:$gtk_icons" "icons:$gtk_cursor"; do
    local kind=${pair%%:*} name=${pair#*:}
    if [ ! -d "$TGT/usr/share/$kind/$name" ]; then
      echo "iso: GTK fallback names /usr/share/$kind/$name, which is not staged" >&2
      exit 1
    fi
  done
  echo "  iso: GTK fallback uses $gtk_theme / $gtk_icons / $gtk_cursor"

  # Whose distribution is about to be written to the disc. build_gui repairs
  # this after it copies base-files in (see copper_identity), and this is the
  # last look before the ISO is produced, so a stage that runs after gui and
  # brings its own os-release with it -- the niri PPA closure is the
  # candidate -- cannot ship a Copper ISO that calls itself something else.
  local osid; osid=$(sed -n 's/^ID=//p' "$TGT/etc/os-release" 2>/dev/null | head -n1)
  if [ "$osid" != copper ]; then
    echo "iso: the staged tree's /etc/os-release says ID='${osid:-nothing}', not copper" >&2
    echo "iso: something after the gui stage overwrote the image's identity" >&2
    exit 1
  fi
  echo "  iso: the image identifies itself as $(sed -n 's/^PRETTY_NAME=//p' "$TGT/etc/os-release" | head -n1)"

  # This image has no wireless stack: no copper-wifi, no wpa_supplicant, no
  # radio firmware. build_rootfs deletes what a pre-revert cache restored; this
  # is the last chance to notice the deletion missed something, before a disc
  # that says "no wifi" ships with it anyway. Checked by path and by name
  # because the package layout differs between /lib and usr/lib.
  local wrelic
  wrelic=$( cd "$TGT" && find . \
      \( -name 'copper-wifi' -o -name 'wpa_supplicant*' -o -name 'wpa_cli' \
         -o -name 'wpa_passphrase' -o -name 'iwlwifi-*' \
         -o -name 'regulatory.db*' -o -name 'rt2561*' -o -name 'rt2561s*' \
         -o -name 'rt2661*' -o -name 'rt2860*' -o -name 'rt2870*' \
         -o -name 'rt3070*' -o -name 'rt3071*' -o -name 'rt3090*' \
         -o -name 'rt3290*' -o -name 'rt73.bin*' -o -name 'mt7601u*' \
         -o -name 'ar5523*' -o -name 'carl9170-1.fw*' \
         -o -name 'atmel_at76c50*' \) -print 2>/dev/null | head -n 20 )
  if [ -n "$wrelic" ]; then
    echo "iso: this image is not supposed to carry a wireless stack, but the" >&2
    echo "iso: staged tree still has:" >&2
    printf '%s\n' "$wrelic" | sed 's/^/iso:   /' >&2
    echo "iso: build_rootfs should have deleted these; a cache restore or a" >&2
    echo "iso: package that brought them back is the likely cause" >&2
    exit 1
  fi
  for wrelic in etc/wpa_supplicant lib/firmware/ath9k_htc lib/firmware/ath10k \
                lib/firmware/ath11k lib/firmware/ath12k lib/firmware/rtlwifi \
                lib/firmware/rtw88 lib/firmware/rtw89 lib/firmware/brcm \
                lib/firmware/mediatek lib/firmware/mrvl lib/firmware/zd1211 \
                lib/firmware/intel/iwlwifi \
                usr/share/doc/linux-firmware usr/share/doc/wireless-regdb ; do
    if [ -e "$TGT/$wrelic" ]; then
      echo "iso: the image still carries $wrelic; it must not" >&2
      exit 1
    fi
  done

  # Fold this script, the shared entry list and the selected provider into the
  # stamp as well as the tree. Without them a change to any of the three
  # against an unchanged tree would skip the rebuild and ship the previous ISO.
  local want
  want=$( { cat "$SELF" "$ROOT/boot/entries" "$BOOTLOADER_DIR/provider.sh" \
                 "$ROOT/identity.sh"; tree_hash "$TGT"; } \
          | sha256sum | cut -d' ' -f1 )
  if [ -s "$OUT/copper.iso" ] && [ -s "$WORK/iso.stamp" ] \
     && [ "$(cat "$WORK/iso.stamp")" = "$want" ]; then
    echo "iso: already built, skipping"; return
  fi

  # How the image is made is the provider's business, not this stage's. The
  # read-back gates below inspect the artifact, so a different provider cannot
  # quietly ship a disc that lost sudo's setuid bit or the shadow mode.
  bootloader_make_iso "$TGT" "$OUT/copper.iso" "$WORK"

  # Check the mode in the artifact, not in the tree it came from: the tree was
  # already verified by build_sudo, and the whole point here is that the ISO
  # layer between them used to drop the bit. Read it back out with xorriso so
  # the gate needs no loop device.
  local ex="$WORK/iso-extract"
  rm -rf "$ex"; mkdir -p "$ex"
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /usr/bin/sudo "$ex/sudo" >/dev/null 2>&1 || true
  if [ "$(stat -c '%a' "$ex/sudo" 2>/dev/null)" != "4755" ]; then
    echo "iso: /usr/bin/sudo in the ISO is mode $(stat -c '%a' "$ex/sudo" 2>/dev/null || echo 'missing'), not 4755" >&2
    echo "iso: the booted image would not be able to elevate" >&2
    exit 1
  fi
  # Same for the two things -R exposes that -r used to hide: ownership and the
  # shadow mode. Checked on the disc because that is what /etc/init mounts.
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /etc/shadow "$ex/shadow" >/dev/null 2>&1 || true
  sm=$(stat -c '%a' "$ex/shadow" 2>/dev/null || echo missing)
  if [ "$sm" != "600" ]; then
    echo "iso: /etc/shadow in the ISO is mode $sm, not 600" >&2
    exit 1
  fi
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /etc/gshadow "$ex/gshadow" >/dev/null 2>&1 || true
  gm=$(stat -c '%a' "$ex/gshadow" 2>/dev/null || echo missing)
  go=$(stat -c '%u:%g' "$ex/gshadow" 2>/dev/null || echo missing)
  gsgid=$(awk -F: '$1 == "shadow" { print $3; exit }' "$TGT/etc/group" 2>/dev/null)
  if [ -n "$gsgid" ]; then
    if [ "$gm" != "640" ] || [ "$go" != "0:$gsgid" ]; then
      echo "iso: /etc/gshadow in the ISO is $go mode $gm, not 0:$gsgid mode 640" >&2
      exit 1
    fi
  elif [ "$gm" != "600" ] || [ "$go" != "0:0" ]; then
    echo "iso: /etc/gshadow in the ISO is $go mode $gm, not 0:0 mode 600" >&2
    exit 1
  fi
  # Ownership too: the other half of what -R exposed. osirrox restores the
  # stored uid/gid, and that is what caught the stale 1000:1000 files.
  if [ "$(stat -c '%u:%g' "$ex/sudo" 2>/dev/null)" != "0:0" ]; then
    echo "iso: /usr/bin/sudo in the ISO is owned by $(stat -c '%u:%g' "$ex/sudo" 2>/dev/null || echo 'missing'), not 0:0" >&2
    exit 1
  fi
  # kill me: every check from here down reads the DISC, not the tree that made
  # it. That is on purpose. The tree can be right and the disc wrong (the
  # packaging drops a mode, a link resolves elsewhere), and the only witness
  # that cannot be wrong about what ships is the thing that ships.
  echo "  iso: /usr/bin/sudo is 4755 root:root; shadow 0600 and gshadow 0640, on the disc"

  # su, read back off the disc for the same reason: it needs 4755 root:root to
  # change uid, and the common-* includes its PAM config names have to be there
  # too or pam_start() aborts before the password prompt (the reported
  # "su: Critical error - immediate abort"). Missing either half is a broken su.
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /usr/bin/su "$ex/su" >/dev/null 2>&1 || true
  if [ "$(stat -c '%a' "$ex/su" 2>/dev/null)" != "4755" ]; then
    echo "iso: /usr/bin/su in the ISO is mode $(stat -c '%a' "$ex/su" 2>/dev/null || echo 'missing'), not 4755" >&2
    echo "iso: su could not change uid, so 'su' would fail for a normal user" >&2
    exit 1
  fi
  if [ "$(stat -c '%u:%g' "$ex/su" 2>/dev/null)" != "0:0" ]; then
    echo "iso: /usr/bin/su in the ISO is owned by $(stat -c '%u:%g' "$ex/su" 2>/dev/null || echo 'missing'), not 0:0" >&2
    exit 1
  fi
  for pf in common-auth common-account common-session common-password; do
    rm -f "$ex/pam-$pf"
    xorriso -osirrox on -indev "$OUT/copper.iso" \
        -extract "/etc/pam.d/$pf" "$ex/pam-$pf" >/dev/null 2>&1 || true
    if [ ! -s "$ex/pam-$pf" ]; then
      echo "iso: /etc/pam.d/$pf is missing from the disc; su would abort at pam_start" >&2
      exit 1
    fi
  done
  echo "  iso: /usr/bin/su is 4755 root:root and its PAM includes are on the disc"

  # polkit's helper, same readback discipline. Missing is allowed only when the
  # image has no polkitd at all; present-but-not-setuid is the failure that
  # turns every authentication prompt into "wrong password".
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /usr/lib/polkit-1/polkit-agent-helper-1 "$ex/polkit-helper" \
      >/dev/null 2>&1 || true
  if [ -e "$ex/polkit-helper" ]; then
    pm=$(stat -c '%a' "$ex/polkit-helper" 2>/dev/null || echo missing)
    if [ "$pm" != "4755" ]; then
      echo "iso: /usr/lib/polkit-1/polkit-agent-helper-1 in the ISO is mode $pm, not 4755" >&2
      echo "iso: polkit could not verify any password; every prompt would fail" >&2
      exit 1
    fi
    if [ "$(stat -c '%u:%g' "$ex/polkit-helper" 2>/dev/null)" != "0:0" ]; then
      echo "iso: polkit-agent-helper-1 in the ISO is owned by $(stat -c '%u:%g' "$ex/polkit-helper" 2>/dev/null), not 0:0" >&2
      exit 1
    fi
    echo "  iso: polkit-agent-helper-1 is 4755 root:root, on the disc"
  fi

  # The GSettings cache, read back off the disc. This is the file whose
  # absence took Firefox down ("No GSettings schemas are installed") and
  # SIGTRAPped the portal and gvfs' volume monitor, so what ships is
  # checked, not what the staging tree says it wrote -- extraction is the
  # only witness that cannot be wrong about the disc.
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /usr/share/glib-2.0/schemas/gschemas.compiled \
      "$ex/gschemas.compiled" >/dev/null 2>&1 || true
  if [ ! -s "$ex/gschemas.compiled" ]; then
    echo "iso: the ISO has no gschemas.compiled under /usr/share/glib-2.0/schemas" >&2
    echo "iso: every GSettings user (firefox, the portal, gvfs, xfsettingsd) would abort on it" >&2
    exit 1
  fi
  if ! grep -aqF 'org.gnome.desktop.background' "$ex/gschemas.compiled"; then
    echo "iso: the disc's gschemas.compiled does not carry the desktop schemas" >&2
    exit 1
  fi
  # The default cursor theme, same readback discipline. Its absence is the
  # "Unable to load pointer from the cursor theme" flood.
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /usr/share/icons/default/index.theme "$ex/index.theme" \
      >/dev/null 2>&1 || true
  if ! grep -q '^Inherits=DMZ-White$' "$ex/index.theme" 2>/dev/null; then
    echo "iso: /usr/share/icons/default/index.theme on the disc does not select DMZ-White" >&2
    echo "iso: GTK would fall back to a cursor theme that does not exist" >&2
    exit 1
  fi
  # Same witness for GTK's fallback settings: the values were checked against
  # the staged tree above, now read them back from the image that ships.
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /etc/gtk-3.0/settings.ini "$ex/gtk-settings.ini" \
      >/dev/null 2>&1 || true
  if [ ! -s "$ex/gtk-settings.ini" ]; then
    echo "iso: the ISO has no /etc/gtk-3.0/settings.ini GTK fallback" >&2
    exit 1
  fi
  local disc_theme disc_icons disc_cursor
  disc_theme=$(sed -n 's/^gtk-theme-name[[:space:]]*=[[:space:]]*//p' \
      "$ex/gtk-settings.ini" 2>/dev/null | head -n1)
  disc_icons=$(sed -n 's/^gtk-icon-theme-name[[:space:]]*=[[:space:]]*//p' \
      "$ex/gtk-settings.ini" 2>/dev/null | head -n1)
  disc_cursor=$(sed -n 's/^gtk-cursor-theme-name[[:space:]]*=[[:space:]]*//p' \
      "$ex/gtk-settings.ini" 2>/dev/null | head -n1)
  if [ "$disc_theme" != "$gtk_theme" ] || [ "$disc_icons" != "$gtk_icons" ] ||
     [ "$disc_cursor" != "$gtk_cursor" ]; then
    echo "iso: the disc's GTK fallback differs from the validated tree" >&2
    exit 1
  fi
  echo "  iso: gschemas.compiled, the default cursor and GTK fallback are on the disc"

# Read power links off the disc: /usr/sbin is searched first, so a leftover ../bin/systemctl there beats
# /sbin's busybox link and `sudo reboot` answers "System has not been booted with systemd" (bug 29).
# Both halves use the wrapper, which reads /proc/1/comm; a blocking systemctl would be SIGTERMed by its
# own shutdown, cancel its own job, and hand the prompt back. tests/shutdown-gate.sh covers both branches.
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /sbin "$ex/sbin" >/dev/null 2>&1 || true
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /usr/sbin "$ex/usr-sbin" >/dev/null 2>&1 || true
  local pbad="" pt flavour
  case "$(readlink "$ex/sbin/init" 2>/dev/null)" in
    /usr/bin/copper-init) flavour=busybox ;;
    /lib/systemd/systemd) flavour=systemd ;;
    *)                    flavour=unknown ;;
  esac
  if [ "$flavour" = unknown ]; then
    echo "iso: /sbin/init in the ISO points nowhere recognisable:" >&2
    echo "iso: $(readlink "$ex/sbin/init" 2>/dev/null || echo 'not a symlink')" >&2
    exit 1
  fi
  # The unified disc boots either init, so the wrapper must ask the RUNNING
  # PID 1, not a build-time link or a directory baked into /run. The branch
  # checks below only see that both dispatch strings survived; this one sees
  # that the decision itself is made from the kernel's comm for PID 1.
  if [ -f "$ex/sbin/shutdown" ] && ! grep -qF '/proc/1/comm' "$ex/sbin/shutdown"; then
    echo "iso: the power wrapper does not read /proc/1/comm to find the running init" >&2
    echo "iso: a baked /run/systemd/system would make a busybox boot call systemctl" >&2
    exit 1
  fi
  if [ "$flavour" = systemd ]; then
    for cmd in reboot poweroff halt; do
      for d in "$ex/sbin" "$ex/usr-sbin"; do
        pt=$(readlink "$d/$cmd" 2>/dev/null || echo missing)
        [ "$pt" = "/sbin/shutdown" ] || pbad="$pbad ${d#"$ex"/}/$cmd -> $pt"
      done
    done
    # shutdown is Copper's wrapper on the systemd image too, and NOT systemd's
    # compatibility link: a bare `shutdown` there means "power off in one
    # minute", which reads as "the command did nothing". The wrapper is a real
    # file at /sbin/shutdown and /usr/sbin/shutdown points at it.
    pt=$(readlink "$ex/usr-sbin/shutdown" 2>/dev/null || echo missing)
    [ "$pt" = "/sbin/shutdown" ] || pbad="$pbad usr-sbin/shutdown -> $pt"
    if [ ! -f "$ex/sbin/shutdown" ] || [ -L "$ex/sbin/shutdown" ]; then
      pbad="$pbad sbin/shutdown (not the wrapper file)"
    elif ! grep -q 'systemctl --no-block' "$ex/sbin/shutdown"; then
      # The wrapper must hand the request to PID 1 and return. A blocking
      # systemctl is SIGTERMed by the shutdown it started and cancels its own
      # job, which is the failure this release is fixing, so check the text
      # that makes it non-blocking on the disc itself.
      pbad="$pbad sbin/shutdown (does not use systemctl --no-block)"
    fi
    # agetty: getty@.service and serial-getty@.service exec /sbin/agetty, and
    # Copper is not merged-usr -- /sbin is a real directory, so the Debian
    # /usr/sbin/agetty is not reachable under that name unless the stage made
    # the link. Without it every VT restart-forever'd with no login prompt.
    pt=$(readlink "$ex/sbin/agetty" 2>/dev/null || echo missing)
    case "$pt" in
      /usr/sbin/agetty)
        [ -f "$ex/usr-sbin/agetty" ] || pbad="$pbad (sbin/agetty target missing)" ;;
      /sbin/agetty)
        [ -f "$ex/sbin/agetty" ] || pbad="$pbad (sbin/agetty target missing)" ;;
      *) pbad="$pbad sbin/agetty -> $pt" ;;
    esac
    if [ -n "$pbad" ]; then
      echo "iso: the ISO boots systemd but its power/login commands are wrong:$pbad" >&2
      echo "iso: expected the Copper shutdown wrapper for reboot/poweroff/halt" >&2
      echo "iso: (it runs systemctl --no-block), and an agetty the getty units" >&2
      echo "iso: can exec by name" >&2
      exit 1
    fi
    echo "  iso: systemd is PID 1, power commands are right, and agetty is on the disc"
  else
# On the busybox half every power name is still the wrapper in both dirs; a direct /bin/busybox link is
# the old single-flavour shape and signals a PID 1 convention systemd does not read.
    for cmd in reboot poweroff halt; do
      for d in "$ex/sbin" "$ex/usr-sbin"; do
        pt=$(readlink "$d/$cmd" 2>/dev/null || echo missing)
        [ "$pt" = "/sbin/shutdown" ] || pbad="$pbad ${d#"$ex"/}/$cmd -> $pt"
      done
    done
    pt=$(readlink "$ex/usr-sbin/shutdown" 2>/dev/null || echo missing)
    [ "$pt" = "/sbin/shutdown" ] || pbad="$pbad usr-sbin/shutdown -> $pt"
    if [ ! -f "$ex/sbin/shutdown" ] || [ -L "$ex/sbin/shutdown" ]; then
      pbad="$pbad sbin/shutdown (not the wrapper file)"
    elif ! grep -qF 'exec /bin/busybox "$mode"' "$ex/sbin/shutdown"; then
      # On this flavour the wrapper has to reach the busybox applet: those
      # applets signal PID 1, and copper-init's on_power_signal() is what
      # performs the orderly shutdown. A wrapper that only knew systemctl
      # would leave `sudo reboot` on the console doing nothing.
      pbad="$pbad sbin/shutdown (does not hand over to the busybox applet)"
    fi
    if [ -n "$pbad" ]; then
      echo "iso: power commands in the ISO are wrong:$pbad" >&2
      echo "iso: /usr/sbin is searched before /sbin, so 'sudo reboot' would not reboot" >&2
      exit 1
    fi
    echo "  iso: power commands point at the Copper wrapper in sbin and usr/sbin, on the disc"
  fi

  # The provider gets the last word on its own menu, read back off the disc.
  # GRUB checks the splash flags and console order; another provider may check
  # a different file or nothing at all.
  if [ "$BOOTLOADER_HAS_CHECK" = 1 ]; then
    bootloader_check "$OUT/copper.iso" "$ex"
  fi

# Read the niri skeleton off the disc: bug 26 shipped a config tree missing files its own config required
# after an absolute-path empty-file sweep and a matching stamp skipped the fix. A re-pin can move files,
# so name what the session reads.
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /usr/share/copper/niri-skel/.config \
      "$ex/niri-config" >/dev/null 2>&1 || true
  for f in niri/config.kdl waybar/config.jsonc waybar/style.css \
           waybar/scripts/workspaces.sh waybar/scripts/window.sh; do
    if [ ! -f "$ex/niri-config/$f" ]; then
      echo "iso: the niri skeleton in the ISO has no $f" >&2
      echo "iso: the session config must be present on the ISO; do not defer it to Ingot" >&2
      exit 1
    fi
  done
  if [ ! -s "$ex/niri-config/niri/config.kdl" ]; then
    echo "iso: the niri skeleton's session config is empty" >&2
    exit 1
  fi
  echo "  iso: niri's session configuration is on the disc"

  echo "$want" > "$WORK/iso.stamp"
  ls -lh "$OUT/copper.iso"
  sha256sum "$OUT/copper.iso"
}

# ---------------------------------------------------------------
# stage dispatch
# ---------------------------------------------------------------
full() {
  build_kernel
  build_musl
  build_busybox
  build_tools
  build_copper
  build_rootfs
  build_gui
  build_niri
  build_plymouth
  build_sudo
  build_initramfs
  build_iso
}

# Default chains normalise a cached systemd tree back to copper-init; `iso` deliberately does not (the
# tree's own state says which flavour to package), while `systemd` does so build_copper's init assertion
# and the swap itself both start from a known default tree.
case "$STAGE" in
  rootfs|gui|niri|plymouth|sudo|initramfs|copper|systemd|unified|all|"")
    default_flavour ;;
esac

case "$STAGE" in
  kernel)     build_kernel ;;
  base)       build_musl; build_busybox ;;
  tools)      build_musl; build_tools ;;
  copper)     build_musl; build_copper ;;
  rootfs)     build_rootfs ;;
  gui)        build_rootfs; build_gui ;;
  niri)       build_rootfs; build_gui; build_niri ;;
  plymouth)   build_rootfs; build_gui; build_niri; build_plymouth ;;
  sudo)       build_rootfs; build_gui; build_niri; build_plymouth; build_sudo ;;
# build_musl must precede any stage that compiles Copper's own binaries: without it CC was unset and
# `bash iso/build.sh systemd` died at `line 638: CC: unbound variable`.
  systemd)    build_musl; build_busybox; build_rootfs; build_gui; build_niri; build_plymouth; build_sudo; build_copper; build_systemd ;;
  # One image, both inits. build_systemd stages the systemd payload and makes
  # it PID 1; build_unified then takes the DEFAULT back to copper-init and
  # keeps the bridge, so the disc boots busybox unless a boot entry asks for
  # systemd. Everything the old systemd chain ran is still needed here.
  unified)    build_musl; build_busybox; build_rootfs; build_gui; build_niri; build_plymouth; build_sudo; build_copper; build_systemd; build_unified ;;
  initramfs)  build_musl; build_busybox; build_rootfs; build_gui; build_niri; build_plymouth; build_sudo; build_initramfs ;;
  iso)        build_musl; build_busybox; build_rootfs; build_gui; build_niri; build_plymouth; build_sudo; build_initramfs; build_iso ;;
  all|"")     full ;;
  *)          echo "unknown stage: $STAGE (kernel|base|tools|copper|rootfs|gui|niri|plymouth|sudo|systemd|unified|initramfs|iso|all)"; exit 2 ;;
esac
echo "==> done"
