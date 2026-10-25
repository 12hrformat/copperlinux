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
# Stages: kernel | base | tools | copper | rootfs | gui | hypr | plymouth |
#         sudo | systemd | initramfs | iso
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
# ROOT is iso/. The repository is its parent, and several gates below need it:
# they list tracked files with git, and they run scripts from the top of the
# tree rather than from inside iso/.
#
# This line is the reason the ISO built at all until it was missing. The two gate
# functions that use $REPO arrived with their bodies and without this assignment,
# and under `set -u` that is not a warning -- it is "REPO: unbound variable" and
# a build that stops thirteen minutes in with nothing built. main has no $REPO
# anywhere, so nothing there noticed; this branch has both halves.
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

# The Hyprland session's configuration tree is NOT vendored into this repo: it
# lives in 12hrformat/copper-hyprland-configs and is fetched at build time,
# pinned to a commit and checked against a hash (build_hypr does the fetch and
# the check).
HYPR_CFG_SHA=9c2e40f5189859c79187629157c848944e249ecc
HYPR_CFG_URL="https://codeload.github.com/12hrformat/copper-hyprland-configs/tar.gz/$HYPR_CFG_SHA"
HYPR_CFG_SHA256=06e73842f24f23dfeb0d9c9a3df1ea28b52088a4266e805166ec07b2d1e9ce15

# The cppiber/hyprland PPA for noble, with a verified fingerprint.
HYPR_PPA_URL="https://ppa.launchpadcontent.net/cppiber/hyprland/ubuntu"
HYPR_PPA_FPR="A54D23B62FF3FCC76EFF71E8FDBAAA1CF0CCF48E"

STAGE=${1:-all}

[ "$(id -u)" = 0 ] || { echo "build.sh: run with sudo/root"; exit 1; }
command -v curl >/dev/null || { echo "build.sh: need curl"; exit 1; }

mkdir -p "$DL" "$OUT" "$SYS"/{bin,lib} \
  "$TGT"/{bin,sbin,usr/bin,usr/sbin,usr/share,etc,dev,proc,sys,run,tmp,home,root,var/log,mnt,boot}

# The scripts we ship are read by busybox ash on a machine with no shell
# anybody can ssh into, so a typo in one is found the hard way. Parse them
# here, where failing costs a second instead of a boot.
lint_scripts() {
  local s
  for s in "$ROOT/live/init" "$ROOT/rootfs-overlay/usr/share/udhcpc/default.script" \
           "$ROOT/rootfs-overlay/usr/bin/ingot" "$ROOT/startxfce.sh" "$ROOT/starthyprland.sh"; do
    sh -n "$s" || { echo "build.sh: syntax error in $s"; exit 1; }
  done
  echo "scripts: live/init, the udhcpc lease script, ingot, startxfce and starthyprland parse clean"
}
lint_scripts

# ---- stage caching -----------------------------------------------------
# iso/work/ is cached between runs, and the CI cache deliberately falls back
# to the most recent older tree so the expensive kernel build survives an
# unrelated change. That makes a stale stage easy: "does the output file
# exist" is just as true for a tree built from sources that have since
# changed. This build shipped exactly that once — an ISO whose initrd was
# packed from the previous version of iso/live/init, so the overlay
# directories were missing and the first boot died on a valid-looking
# artifact. So every stage stamps its output with a hash of the inputs that
# produced it, and only skips when that still matches. A warm cache buys
# speed now; it can't be wrong.
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

# The ISO is a copy of the entire staged rootfs, so its inputs are the tree
# itself rather than any one file in it. Run from inside the tree so the
# hashed paths are relative — absolute ones carry the checkout directory and
# would make the stamp differ between runners for no reason.
#
# `-type f` alone is wrong here, and the systemd stage is what exposed it. The
# swap to PID 1 is a SYMLINK (/sbin/init -> /lib/systemd/systemd) and so are
# the power commands, and find with `-type f` cannot see either: two trees that
# differ only in what init points at hash the same. The first version of this
# guard was therefore one symlink-only change away from skipping the rebuild
# and shipping the previous flavour's ISO under a stamp that said it was
# current — a stale artifact with a green light. Symlinks are hashed as
# name -> target; regular files by content; every other type (a device node
# under /dev, a fifo) by path and type, which is all that distinguishes them.
# Directory entries need no line of their own: a directory's existence is
# implied by the paths under it, and an EMPTY directory is not something the
# ISO's behaviour depends on in any way this hash is meant to catch.
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
  # Download to the side and rename: an interrupted curl leaves a partial
  # file, and the existence test above would trust that file forever after.
  curl -fL --retry 3 --retry-delay 2 -o "$f.part" "$url"
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

# ---------------------------------------------------------------
# 1. Linux kernel, from kernel.org, with Copper's .config subset
# ---------------------------------------------------------------

# A kernel that boots to a black screen, or that comes up with no NIC able to
# speak DHCP, is miserable to debug from inside a VM — you never see a build
# error, just a dead machine. So the options Copper actually leans on are
# checked after kconfig has had its say, and a missing one fails the build
# here with a readable list instead.
#
# Only symbols that really exist in $KREL belong in this list. 6.12 dropped
# `ETHERNET` (the driver menu is unconditional once NET is on) and moved
# BLK_DEV_NVME to drivers/nvme/host, so grepping the old paths lies.
require_kernel_config() {
  local cfg="$1" sym missing=""
  for sym in \
      DEVTMPFS DEVTMPFS_MOUNT TMPFS OVERLAY_FS ISO9660_FS BLK_DEV_SR \
      VT VGA_CONSOLE UNIX98_PTYS \
      EXT4_FS BLK_DEV_SD ATA ATA_PIIX BLK_DEV_NVME \
      VIRTIO_PCI VIRTIO_BLK \
      NET NETDEVICES INET PACKET UNIX E1000 E1000E VIRTIO_NET ; do
    grep -qx "CONFIG_$sym=y" "$cfg" || missing="$missing $sym"
  done
  if [ -n "$missing" ]; then
    echo "kernel: these options did not survive olddefconfig:$missing" >&2
    exit 1
  fi

  # Every display driver, asserted rather than merely requested.
  #
  # Two separate mistakes are guarded against here, and both produced a machine
  # that booted to a shell.
  #
  # The first is asking for a symbol whose dependencies are unmet. kconfig
  # accepts --enable FB with no complaint, olddefconfig drops it without a word,
  # and the build goes green with a kernel that has neither a framebuffer nor a
  # driver to make one. A flag that vanishes quietly needs a check that fails
  # loudly, so each of these is asserted to be =y in the config after
  # olddefconfig rather than trusted to have been requested.
  #
  # The second is a driver that is present but useless on the machine it is
  # needed on -- DRM_BOCHS on anything that is not QEMU's Bochs VGA adapter,
  # which is most machines. No amount of asserting it is =y catches that, because
  # it genuinely is =y. Asserting every driver here means a machine with no
  # matching driver is a gap in this list rather than a surprise at boot, and
  # that the two failures are told apart: a dropped symbol stops the build, an
  # unbound one shows up as a missing /dev/fb0 in the log.
  #
  # FONT_8x16 is pinned so the console keeps the glyphs it had on the text
  # plane. Left to its own devices kconfig also picks FONT_8x8, and the console
  # renders 160x100 of unreadably small text instead.
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
  #   SCSI            the base any SCSI disk needs (BLK_DEV_SD depends on it)
  #   SCSI_LOWLEVEL   the menu the host-adapter drivers live under
  #   SCSI_MPT3SAS    LSI Logic SAS/SPI/FC -- VMware's default guest controller
  #   VMWARE_PVSCSI   VMware Paravirtual SCSI (not VMWARE_VMXNET3: that is the
  #                   network adapter, a different symbol entirely)
  #   SCSI_VIRTIO     virtio-scsi, the common QEMU/KVM alternative to virtio-blk
  #
  # The same limit applies as to the display list: asserted =y means it compiles,
  # not that it has initialised on that hardware. SCSI_VIRTIO and VMWARE_PVSCSI
  # are untested until somebody boots a machine that uses them; SCSI_MPT3SAS is
  # the one the VMware report is about.
  for sym in SCSI SCSI_LOWLEVEL SCSI_MPT3SAS VMWARE_PVSCSI SCSI_VIRTIO ; do
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

  # The compiler, pinned rather than whatever the machine happens to have.
  #
  # gcc 15 turned -Wunterminated-string-initialization into a warning the kernel
  # builds with -Werror, and this kernel's ACPI signature table trips it:
  #
  #     drivers/acpi/tables.c:410: error: initializer-string for array of 'char'
  #     truncates NUL terminator [-Werror=unterminated-string-initialization]
  #
  # so the build stops in ACPI code, thousands of lines away from anything that
  # was changed. Pinning the compiler is the smaller fix: the alternative is
  # carrying a patch against the kernel's own source that no upstream asked for,
  # and that silently stops being needed the moment the kernel is bumped.
  #
  # The pin lives here rather than in CI config so a local build gets it too.
  # Set KERNEL_CC to override; set it empty to force the system default.
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
      --enable DEVTMPFS --enable DEVTMPFS_MOUNT \
      --enable UNIX98_PTYS --enable LEGACY_PTYS \
      --enable VIRTIO_PCI --enable VIRTIO_BLK --enable VIRTIO_NET \
      --enable E1000 --enable E1000E \
      --enable VMXNET3 --enable VMWARE_VMXNET3 \
      --enable ATA --enable ATA_PIIX --enable BLK_DEV_SD --enable BLK_DEV_NVME \
      --enable SCSI --enable SCSI_LOWLEVEL \
      --enable SCSI_MPT3SAS --enable VMWARE_PVSCSI --enable SCSI_VIRTIO \
      --enable EXT4_FS --enable PACKET --enable UNIX --enable VT \
      --enable VGA_CONSOLE --enable INPUT \
      --enable DRM --enable DRM_FBDEV_EMULATION \
      --enable DRM_BOCHS --enable DRM_SIMPLEDRM \
      --enable DRM_VMWGFX --enable DRM_VIRTIO_GPU \
      --enable DRM_QXL --enable DRM_VBOXVIDEO \
      --enable DRM_I915 \
      --enable FB --enable FB_VESA --enable FB_EFI \
      --enable FRAMEBUFFER_CONSOLE --enable FONT_8x16
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
  # The toolchain is a cache entry as much as a build product, and a cache
  # entry can outlive the path it was built at. musl-gcc is a wrapper that
  # names its specs file, its crt objects and its libc by ABSOLUTE path, and
  # $SYS lives under the workspace, whose directory is named after the
  # repository. Renaming or transferring the repo moves that path, and a
  # restored musl-gcc then exists and cannot link anything: it still points
  # at /home/runner/work/<old-name>/..., which is gone. "the file exists" is
  # not evidence the toolchain works, so compile something with it. This was
  # a real red build -- a cache from when the repo was copper/copper was
  # restored under copperlinux/copperlinux, and coreutils' configure died
  # with "C compiler cannot create executables" while the cache looked fine.
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

# busybox ships no scripts/config (that's a kernel tool), so enable the
# symbols we need via the kernel tree's copy, which edits .config in
# place. Appending CONFIG_* lines instead would duplicate the defaults
# that make defconfig already wrote — conf rejects those as "reassign"
# (first assignment wins, so CONFIG_STATIC=y got silently dropped) and a
# redundant write into a kconfig choice corrupts its state.
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
      ADDUSER ADDGROUP FEATURE_ADDUSER_TO_GROUP \
      CHPASSWD FEATURE_SHADOWPASSWDS SETFONT ; do
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

# Point the power commands at the tools THIS TREE's PID 1 understands -- in
# BOTH directories PATH searches for them. The order is /usr/local/sbin:
# /usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin (assert_commands_reachable above
# keeps it in step with copper-init's setenv, and sudo's secure_path and
# /etc/profile carry the same list), so /usr/sbin comes FIRST: a `reboot` left
# there by systemd-sysv wins the name over a busybox link in /sbin, and `sudo
# reboot` answers "System has not been booted with systemd" (bug 29). The
# 2026-10-17 fix only relinked /sbin; the CI ISO built from it still shipped
# /usr/sbin/reboot|poweroff|halt|shutdown -> ../bin/systemctl, which is how
# this was caught -- by reading the links back off the shipped disc, and
# re-checked there by build_iso's gate.
#
# WHICH tools depends on which init the tree carries, and the tree is not
# remembered in a variable: the staged tree outlives any one build.sh run, so
# init_flavour() reads sbin/init and answers. The two answers are:
#
#   - busybox (the shipped default): the applets, which signal PID 1 the way
#     copper-init reads it. /usr/sbin/shutdown points at our own wrapper,
#     because busybox ships no shutdown applet.
#   - systemd (the migration): systemctl, in both directories. A busybox applet
#     there signals a PID 1 convention systemd does not read at all.
#
# This has to be right on EVERY call, not only the first. The `iso` chain
# re-runs the desktop stages over the tree -- build_rootfs clobbers /etc/group
# and takes the _seatd group with it, and that group is part of what those
# stages' skip guards ask about -- and each of them calls this. A version that
# always wrote busybox quietly undid the systemd flavour's systemctl links on
# the way to the disc, and the systemd ISO failed its own read-back gate:
#
#     iso: the ISO boots systemd but its power commands are wrong:
#          sbin/reboot -> /bin/busybox usr-sbin/reboot -> /bin/busybox ...
#
# Called after every stage that copies packages into $TGT (copper, gui, hypr;
# plymouth only copies its own lib directory), and by the systemd stage right
# after it swaps PID 1.
# updated by farcrowx, bug 29, iso/build.sh (the /sbin-only relink loops)
power_links() {          # power_links <staged-root>
  local root=$1 cmd
  mkdir -p "$root/sbin" "$root/usr/sbin"
  if [ "$(init_flavour "$root")" = systemd ]; then
    # /usr/sbin/shutdown currently points at our own wrapper (/sbin/shutdown),
    # and /sbin/shutdown is about to become a link to systemctl. The chain
    # would still RESOLVE to systemctl, but the ISO's read-back gate reads the
    # link's own target -- and a chain is not what it expects to find there.
    # So remove it and write the link that answers the question directly.
    rm -f "$root/usr/sbin/shutdown"
    for cmd in reboot poweroff halt shutdown; do
      ln -sf /usr/bin/systemctl "$root/sbin/$cmd"
      ln -sf /usr/bin/systemctl "$root/usr/sbin/$cmd"
    done
    return
  fi
  for cmd in reboot poweroff halt; do
    ln -sf /bin/busybox "$root/sbin/$cmd"
    ln -sf /bin/busybox "$root/usr/sbin/$cmd"
  done
  ln -sf /sbin/shutdown "$root/usr/sbin/shutdown"
}

# Which init is staged in this tree? "busybox" (copper-init, the shipped
# default) or "systemd" (the migration, opt-in via the systemd stage).
#
# The answer is read off sbin/init rather than remembered in a variable,
# because the staged tree outlives any one build.sh run: a cached $TGT from
# actions/cache could hold either. Every gate that cares asks this question,
# so there is one definition of "which init is this" and not four.
#
# readlink, not -e: sbin/init is an absolute symlink and -e would follow it
# onto the build host, where neither target exists. The bug that stopped /init
# handing over was this exact trap, one file over (see build_copper).
init_flavour() {         # init_flavour <staged-root> -> busybox|systemd|unknown
  case "$(readlink "$1/sbin/init" 2>/dev/null)" in
    /usr/bin/copper-init)  echo busybox ;;
    /lib/systemd/systemd)  echo systemd ;;
    *)                     echo unknown ;;
  esac
}

# ---------------------------------------------------------------
# The merged-usr bridge: /lib/systemd is a NAME for /usr/lib/systemd
# ---------------------------------------------------------------
# The systemd flavour needs one directory to answer at two names. Ubuntu's
# systemd deb ships PID 1 at /usr/lib/systemd/systemd, because every
# Debian-family tree since bookworm is merged-usr -- /lib IS /usr/lib.
# Copper's tree is NOT merged-usr: /lib here is a real directory holding the
# musl loader and busybox. So the systemd stage makes lib/systemd a symlink
# to ../usr/lib/systemd (build_systemd), and PID 1 is reachable at the name
# the kernel execs.
#
# The bridge is a systemd-flavour ARTEFACT, and the staged tree outlives any
# one build.sh run: the CI saves iso/work AFTER the systemd flavour has run,
# so the next run can restore a tree that carries the bridge. Two things
# then go wrong, and both of them happened for real:
#
#   * cp cannot merge a directory into a symlink, so a package tree that has
#     a real lib/systemd of its own -- the Hyprland closure has one, the gui
#     closure does not -- cannot be copied into the tree at all:
#
#         cp: cannot overwrite non-directory '.../rootfs/./lib/systemd' with
#             directory '.../hypr-root/./lib/systemd'
#
#     and cp stops. That killed the Hyprland stage in CI, on two consecutive
#     runs, on a tree that had been perfectly good a moment before.
#
#   * a tree whose PID 1 is systemd packages a "default" ISO that silently
#     boots systemd -- the half-done swap SYSTEMD-MIGRATION.md warns about,
#     and the reason the two artefacts have to stay unambiguous.
#
# So the stages that copy packages in take the bridge off for the copy and
# put it back afterwards IF this tree is the systemd flavour's. The tree
# then ends where a fresh build of the same flavour ends: the systemd tree
# bridged again (which is exactly what build_systemd's own bridge does to a
# real lib/systemd), the default tree with a real lib/systemd directory, as
# the packages ship it.
#
# build_systemd's own bridge is NOT this code: it is the stage's, it is
# tested by the gate's fixture (which deliberately leaves a real lib/systemd
# squatting on the name), and the sabotage suite proves the gate goes red
# when that block is disabled. Two copies of a rule is a smell, but a gate
# that stops testing the code the stage actually runs is worse.
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

# Take the staged tree back to the default flavour: PID 1 is copper-init
# again, the power commands are busybox's again, and the bridge is off.
# Idempotent -- a tree that is already the default flavour is left as it is.
#
# This is called by the DEFAULT flavour's chains only. The `iso` chain is not
# one of them: the CI builds the default ISO and the systemd ISO with the
# same command, and the tree's own state is what says which flavour is being
# packaged. The `systemd` chain is not one either: that stage is what puts
# the swap in place.
default_flavour() {
  if [ "$(init_flavour "$TGT")" = systemd ]; then
    ln -sf /usr/bin/copper-init "$TGT/sbin/init"
    # The systemd flavour replaced Copper's own /sbin/shutdown wrapper with a
    # link to systemctl. Put the wrapper back before power_links points
    # /usr/sbin/shutdown at it: busybox ships no shutdown applet, so the
    # wrapper IS the shutdown command on a default tree, and a default tree
    # whose /sbin/shutdown is systemctl's link ships a `sudo shutdown` that
    # talks to a PID 1 that is not there. rm first, so what is left is a
    # regular file and not a link -- install replaces a symlink with the file
    # it copies, but removing it outright says so rather than leaving it to
    # the install implementation.
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

# build_musl is what exports $CC, $CFLAGS and the musl PATH -- and it is not
# obvious from inside build_copper that it needs any of that, because in the
# default `full()` path build_musl has always run first. A stage that reaches
# build_copper without it does not get a compiler that is merely missing: it
# gets `set -u` aborting on `line 638: CC: unbound variable`, a message about a
# shell variable that says nothing about the one-line cause. That happened for
# real when the `systemd` stage was added without build_musl in its dispatch
# line, and CI is what found it. This guard turns the same mistake into a
# sentence that names the missing stage.
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
  if [ -x "$TGT/usr/bin/copper-sh" ] && [ -x "$TGT/usr/bin/copper-init" ] \
     && [ -x "$TGT/usr/bin/copper-firstboot" ] \
     && [ -x "$TGT/usr/bin/xprobe" ] && [ -x "$TGT/sbin/shutdown" ] \
     && stamped_skip "$WORK/copper.stamp" "$SELF" "$SRC"/*.c "$SRC"/*.h \
        "$ROOT/src-init/copper-init.c" "$ROOT/firstboot/copper-firstboot.c" \
        "$ROOT/startxfce.sh" "$ROOT/x11/probe/xprobe.c" "$ROOT/shutdown.sh" \
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
  # xprobe: the X server liveness probe startxfce uses before it trusts an
  # existing display. Static musl like the rest, so it needs nothing from the
  # display stack and is safe to run before X exists. Without it startxfce
  # falls back to believing a bare socket file, and on a machine with the
  # persistence disk the socket outlives the server that made it -- the next
  # boot then reuses a dead :0 instead of starting one.
  $CC $CFLAGS -std=c11 -o "$TGT/usr/bin/xprobe" \
     "$ROOT/x11/probe/xprobe.c"
  ln -sf /usr/bin/copper-init "$TGT/sbin/init"   # our PID 1

  install -m 0755 "$ROOT/copper.sh" "$TGT/usr/bin/copper"

  # The XFCE launcher. It ships now, before XFCE does, because what it is for
  # today is failing informatively: it names the missing piece and returns a
  # distinct code, which is a more useful thing to have in the image than a
  # command-not-found from copper-sh.
  install -m 0755 "$ROOT/startxfce.sh" "$TGT/usr/bin/startxfce"

  # The Hyprland launcher: the same contract style, same seeding/exit-code
  # discipline as startxfce.
  install -m 0755 "$ROOT/starthyprland.sh" "$TGT/usr/bin/starthyprland"

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
           usr/bin/startxfce usr/bin/starthyprland usr/bin/xprobe sbin/shutdown \
           usr/bin/copper; do
    if [ ! -x "$TGT/$f" ]; then
      echo "copper: $f is missing from the staged rootfs" >&2
      exit 1
    fi
  done
  # sbin/init is a symlink, so -e is the wrong test for it: -e follows the
  # link, the target is absolute, and it therefore gets looked up on the build
  # host, where there is no /usr/bin/copper-init — the link reads as dangling
  # and a perfectly good staged tree gets reported as broken. That is the same
  # trap that stopped /init handing over, one file over. readlink does not
  # follow, which is exactly what is wanted here.
  if [ "$(readlink "$TGT/sbin/init")" != "/usr/bin/copper-init" ]; then
    echo "copper: sbin/init should be a symlink to /usr/bin/copper-init" >&2
    exit 1
  fi

  stamp_set "$WORK/copper.stamp" "$SELF" "$SRC"/*.c "$SRC"/*.h \
    "$ROOT/src-init/copper-init.c" "$ROOT/firstboot/copper-firstboot.c" \
    "$ROOT/startxfce.sh" "$ROOT/starthyprland.sh" "$ROOT/x11/probe/xprobe.c" "$ROOT/shutdown.sh" \
    "$ROOT/copper.sh"
}

# ---------------------------------------------------------------
# 6. rootfs config + timezone data
# ---------------------------------------------------------------
build_rootfs() {
  echo "==> rootfs config"
  cp -a "$ROOT/rootfs-overlay/." "$TGT/"
  mkdir -p "$TGT/usr/share/zoneinfo" "$TGT/etc/skel"
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

  # The overlay is copied onto a $TGT that may have come straight out of the
  # build cache, still holding files from an earlier revision. mkdir -p and cp
  # only ever add, so a file deleted from iso/rootfs-overlay/ would survive
  # forever and be baked into the next ISO. Record what the overlay contained
  # last time and drop whatever it no longer claims.
  #
  # The list has to come from iso/rootfs-overlay/, not from $TGT: $TGT is the
  # cached directory that still has the stale file in it, so diffing $TGT
  # against itself would never notice.
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

  # usr/share/mime/icons is a zero-byte legacy mapping that update-mime-database
  # emits, and the gui and hypr stages each prune it after they run. A cache
  # restore can still hold one from a build before those prunes existed, and the
  # gate below would then fail here, in rootfs, before either stage can run.
  # Drop the same empty mapping the stages drop, so the gate sees the tree the
  # stages are trying to produce rather than one a previous build left behind.
  if [ -f "$TGT/usr/share/mime/icons" ] && [ ! -s "$TGT/usr/share/mime/icons" ]; then
    rm -f "$TGT/usr/share/mime/icons"
  fi

  # A cache restore can leave empty files behind from a previous build's later
  # stages (kitty/python __init__.py, sensors.d/.placeholder, ...). Those
  # stages prune their own empties during their run, but rootfs runs first and
  # the gate below would otherwise fail on the stale copies. Drop every empty
  # regular file now, except the ones the gate already exempts by name, so the
  # gate sees the tree the stages are trying to produce.
  #
  # Run it from inside the tree. The guards say './etc/motd', which is the
  # shape find prints for `find .`; the first version of this sweep was
  # `find "$TGT"` beside them, and $TGT is absolute, so they matched nothing
  # and the exemption the gate below carries never applied here. That went
  # unnoticed for motd and timezone -- neither is empty in this image -- but
  # not for the Hyprland skeleton: its Lua configuration require()s files that
  # are DELIBERATELY empty, a stub like conf/environments/default.lua existing
  # only to be required, and those are precisely the zero-byte files. Rootfs is
  # stage 6 and hypr is stage 8, so the skeleton is unpacked after this sweep
  # on a cold build and survives -- but any rebuild that re-ran rootfs (any
  # edit under iso/rootfs-overlay/) swept the skel already sitting in the
  # cached tree, and hypr's stamp still matched, so nothing put the stubs back.
  # The ISO shipped a skeleton missing the files its own config requires
  # (bug 26), and every home seeded from it failed to start.
  ( cd "$TGT" && find . -type f -size 0 \
      ! -path './etc/motd' \
      ! -path './etc/timezone' \
      ! -path './usr/share/copper/hyprland-skel/*' \
      ! -name 'mach_kernel' \
      -delete ) 2>/dev/null || true

  assert_no_empty_files
  assert_commands_reachable
  assert_shell_scripts_parse
  # assert_hotfix_db_readable  # removed
}

# ---------------------------------------------------------------
# 6b. no command in the image may be an empty REGULAR file
# ---------------------------------------------------------------
# Narrow on purpose, and deliberately not about symlinks.
#
# A zero-byte regular file that is supposed to be an executable is fatal:
# execve() finds it, refuses it, and the shell reports "command not found"
# for a command that is plainly listed. An empty *symlink* is not a thing --
# a symlink has no size of its own; it has a target.
#
# `find -type f` does not match symlinks (find defaults to -P, no follow), so
# this ignores every one of the 600-odd applet links and looks only at real
# files. That distinction matters: an earlier version of this gate was aimed
# at "310 empty files" which turned out to be a measurement error. p7zip
# reports those entries correctly as symlinks -- Mode = lr-xr-xr-x,
# Symbolic Link = ../bin/busybox -- but silently writes some of them to disk as
# 0-byte regular files on extraction. Inspect the image with `mount -o loop`
# or bsdtar, never with p7zip, or you will chase this ghost again.
#
# A few files are legitimately empty, so they are named rather than allowing a
# blanket exemption.
#
# updated by dragon, bug 26: the Hyprland config skel is the one exception, and
# it is exempted as a whole subtree rather than file by file. It is a vendored,
# sha256-pinned DATA tree (the hypr stage checks the tarball hash before it
# unpacks it), not a set of commands -- which is the only thing this gate is
# for. ML4W ships zero-byte Lua include stubs that `require()` loads (empty is
# valid Lua, and deleting them would break the config) and marker files whose
# *presence* is the setting (`waybar-disabled`, `software.sh`). Naming the eight
# files would only break again on the next re-pin, when upstream's next release
# moves them; the subtree is the stable unit.
#
# mach_kernel is the vestigial cosmopolitan artifact: shipped empty, and
# grub.cfg never boots it (the menu loads /boot/vmlinuz and /boot/initrd.img),
# so an empty one costs nothing. Worth knowing it is a no-op file.
#
# Every exemption is a `! ...` term inside the one find below. Keep it that way:
# a `#` comment inside a backslash-continued command ends the command at the
# comment, so every term after it silently stops applying -- which is exactly
# how bug 26's first fix went red, with the skel term skipped and the gate still
# naming the files it was meant to exempt.
assert_no_empty_files() {
  local empties
  empties=$( cd "$TGT" && find . -type f -size 0 \
    ! -path './etc/motd' \
    ! -path './etc/timezone' \
    ! -path './var/log/*' \
    ! -name '*.uuid' \
    ! -path './usr/share/copper/hyprland-skel/*' \
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

# ---------------------------------------------------------------
# 6c. the commands people actually type must be reachable BY NAME
# ---------------------------------------------------------------
# This tests the thing that actually broke, which is not "is the file there".
#
# `ip` and `ifconfig` were present, compiled into the shipped busybox, and
# correctly symlinked the entire time, and still answered "command not found".
# They live in sbin. PID 1 started with no PATH in its environment, so execvp
# fell back to the kernel's compiled-in default -- /bin:/usr/bin -- and sbin
# was never searched. Every existence-style check passes on that failure,
# which is how it survived several builds and several boots.
#
# So: resolve each name the way the live shell will, through the PATH
# copper-init sets, in that order, with no fallback and no confstr. If the two
# ever drift apart, the build says so instead of a user finding out.
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
      copper startxfce starthyprland \
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

# ---------------------------------------------------------------
# 6c. no shell script in the repo may fail to parse
# ---------------------------------------------------------------
# A quoting mistake in a shell script does not stop it from running: the shell
# starts executing whatever the broken quoting handed it. One real example --
# an apostrophe inside a comment within a single-quoted awk program closed the
# quote, and the remainder of the awk was executed as shell, failing as
# "buf[depth]: not found" with nothing pointing at the real cause.
assert_shell_scripts_parse() {
  local f bad=0

  # bash -n, not sh -n. build.sh uses process substitution and is run with
  # bash, so checking it with a POSIX shell reports a syntax error in code
  # that runs perfectly well every day.
  # `git ls-files` prints paths relative to the directory you run it in, so
  # this has to be run from the repository root or the paths do not resolve.
  # Run from $ROOT and it silently lists iso/ only -- tests/ never gets checked.
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

  # The three tools that run on a live system declare #!/bin/busybox sh and
  # are executed by busybox ash, not by bash. Grammar the POSIX shell does not
  # have -- array assignment, the `function` keyword, process substitution --
  # would fail on the machine this ISO is for, which is the only place it
  # matters. ingot (usr/bin) runs there too: `#!/bin/sh` on the live image is
  # /bin/busybox, so it gets the same check. So check those against a POSIX
  # shell too, when one is available.
  #
  # What this does NOT catch: bash builtins that happen to be spelled like
  # ordinary commands. dash -n accepts `[[ -n "$1" ]]`, because to its parser
  # that is a command called "[[" with two arguments, and it only fails when it
  # runs. Catching those needs a shell that runs the code, not one that reads
  # it, which is what the charge tests do.
  local posix=""
  for c in dash ash busybox; do
    command -v "$c" >/dev/null 2>&1 && { posix="$c"; break; }
  done

  if [ -n "$posix" ]; then
    local n_posix=0
    for f in iso/copper.sh \
             iso/rootfs-overlay/usr/bin/ingot \
             iso/systemd/copper-tty-clear iso/systemd/copper-dhcp; do
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
    [ "$n_posix" -eq 4 ] || {
      echo "build: the POSIX check covered $n_posix of 4 busybox tools" >&2; exit 1; }
    echo "build: $n_bash shell scripts parse, and $n_posix busybox tools are POSIX sh"
  else
    echo "build: $n_bash shell scripts parse (no POSIX shell here for the busybox tools)"
  fi
  [ "$n_bash" -gt 0 ] || { echo "build: no shell scripts were found to check" >&2; exit 1; }
}

# ---------------------------------------------------------------
# 6d. the hotfix database must survive the parser that reads it
# ---------------------------------------------------------------
# The parser is hand-written awk, because the live system has no python3. It
# once concatenated the whole file into a single line, so every field came
# back as the last entry value and all but the last entry were invisible --
# which worked perfectly, because the database had exactly one entry.
#
# So this does not test a copy of the parser. It runs the real script and
# compares what comes out against what is in the file.
assert_hotfix_db_readable_disabled() {
  # $ROOT is iso/, not the repository root, so "$ROOT/iso/..." is iso/iso/...
  # and the gate died with "no such file" while printing an explanation about
  # the parser. Check the path first and say which of the two it actually is.
  local gate="$REPO/iso/assert-hotfix-db.sh"
  if [ ! -f "$gate" ]; then
    # Reported and skipped rather than failed, and deliberately visible in the
    # build log so it cannot quietly rot.
    #
    # The gate travels with the hotfix feature: it runs the same awk parser the
    # live system uses against hotfixes.json. If this tree ever ships without
    # the feature, the file goes with it, and skipping here is the honest
    # answer -- reported, not passed.
    echo "build: no hotfix gate at $gate -- skipping the database parser check."
    echo "       This tree has no hotfix feature to check. Not the same as passing."
    return 0
  fi
  ( cd "$REPO" && "$gate" ) || {
    echo "build: the hotfix database did not survive the parser." >&2
    echo "       Every entry but the last would be silently ignored on a" >&2
    echo "       live system, with no error and no change." >&2
    exit 1
  }
}

# ---------------------------------------------------------------
# 6d2. whose distribution is this
# ---------------------------------------------------------------
# build_gui copies the display stack out of noble's packages with
# `cp -a "$STAGE/." "$TGT/"` -- no -n, so the packages win over what rootfs
# (stage 6) and the overlay already put there. base-files is in that closure,
# and base-files is what owns /etc/os-release, /etc/lsb-release, /etc/issue and
# /usr/lib/os-release. The moment the packages land, the image stops being
# Copper and becomes "Ubuntu 24.04.5 LTS" with LOGO=ubuntu-logo -- which is
# what fastfetch then draws on a Copper machine (bug 41, the Ubuntu logo).
#
# Nothing in the build reads those files, which is why it stayed invisible.
# Put Copper's back here, still from iso/rootfs-overlay so there is one source
# of truth, and assert the result rather than trusting the copy order to stay
# this way forever. Called at the end of build_gui and on its cached early
# return: a warm tree whose gui stage is skipped must be repaired too, since it
# was written by whatever ran last.
#
# Both /etc/os-release and /usr/lib/os-release are plain files on this image
# (on a normal Debian the first is a symlink to the second), and a reader may
# open either, so both are written and then compared.
copper_identity() {
  local rel id
  for rel in etc/os-release etc/lsb-release etc/issue; do
    if [ ! -f "$ROOT/rootfs-overlay/$rel" ]; then
      echo "gui: iso/rootfs-overlay/$rel is missing; without it the image" >&2
      echo "     identifies itself as Ubuntu to every tool that asks" >&2
      exit 1
    fi
    install -D -m 0644 "$ROOT/rootfs-overlay/$rel" "$TGT/$rel"
  done
  install -D -m 0644 "$ROOT/rootfs-overlay/etc/os-release" "$TGT/usr/lib/os-release"

  id=$(sed -n 's/^ID=//p' "$TGT/etc/os-release" | head -n1)
  if [ "$id" != copper ]; then
    echo "gui: /etc/os-release does not say ID=copper (it says '${id:-nothing}')" >&2
    echo "     base-files' copy won again; see copper_identity above" >&2
    exit 1
  fi
  if ! cmp -s "$TGT/etc/os-release" "$TGT/usr/lib/os-release"; then
    echo "gui: /etc/os-release and /usr/lib/os-release disagree" >&2
    exit 1
  fi
  echo "  identity: $(sed -n 's/^PRETTY_NAME=//p' "$TGT/etc/os-release" | head -n1)"
}

# ---------------------------------------------------------------
# 6e. the display stack: Xorg + XFCE, unpacked from packages
# ---------------------------------------------------------------
# Copper builds its own base system from source, and a desktop is not part of
# that: XFCE is dozens of packages sitting on GTK and glibc, and rebuilding a
# toolchain and a desktop environment here would be a distribution of its own.
# So the display stack arrives the way distributions ship it -- as packages,
# downloaded and unpacked at BUILD time. The image itself never asks the
# network for anything; what this costs is space in the ISO, and that is the
# trade that was made.
#
# The dependency closure is computed by apt against an EMPTY dpkg status
# file: every library the desktop needs counts as missing, including the
# dynamic loader those binaries are linked against, so nothing arrives
# half-installed. --download-only, no recommends: what comes down is a pile
# of .deb files, unpacked with dpkg-deb -x into a staging tree and then
# merged into the rootfs WITHOUT overwriting anything already in it. The
# busybox applet links, the static musl tools and the overlay's /etc come
# first and win; a package that ships the same path loses. That is what keeps
# /bin/sh busybox's and keeps `ls` the musl binary on PATH.
#
# Nothing is configured: maintainer scripts never run, no postinst triggers
# fire, and the caches they would generate (fonts, icons, pixbuf loaders) are
# simply absent until something on the target generates them. A missing
# fontconfig cache costs a slow first font lookup; a missing pixbuf loader
# cache costs image formats, and is the first thing to look at if the
# session comes up drawing boxes instead of icons.
build_gui() {
  # "Already staged" is not the same question as "the packages are there". The
  # _seatd group is created by a line in THIS stage, and a later stage can take
  # it back out: build_rootfs runs again before the ISO is made (`build.sh iso`
  # re-runs the whole chain) and `cp -a "$ROOT/rootfs-overlay/."` overwrites
  # /etc/group with the eight-line skeleton, erasing whatever this stage
  # appended. The stamp still matches, so this guard used to skip and the group
  # never came back -- and the boot paid for it: the systemd image shipped
  # without _seatd, seatd could not start, and its unit restart-looped on the
  # wizard's tty. The group is part of what this stage guarantees, so it is
  # part of "already staged".
  if [ -e "$TGT/usr/bin/Xorg" ] && [ -e "$TGT/usr/bin/startxfce4" ] \
     && grep -q '^_seatd:' "$TGT/etc/group" \
     && stamped_skip "$WORK/gui.stamp" "$SELF"; then
    echo "gui: already staged, skipping"
    # Skipping the packages must not skip their repair: a cached tree written
    # before this existed still calls itself Ubuntu. Cheap and idempotent.
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
  # The pixbuf cache generator ships in a separate package from the library,
  # and only as a recommendation -- so --no-install-recommends would drop it
  # and the session would have loaders with nothing to find them from, which
  # draws no images. Its name changed between releases, so ask the host which
  # one it carries rather than naming one and hoping.
  local pixbuf="" p
  for p in libgdk-pixbuf2.0-bin libgdk-pixbuf-2.0-bin; do
    if apt-cache show "$p" >/dev/null 2>&1; then pixbuf=$p; break; fi
  done
  # xfce4-terminal is named explicitly rather than assumed: the xfce4
  # metapackage does not depend on it (nor recommend it), so under
  # --no-install-recommends the image had a desktop with no terminal
  # emulator in it at all. Clicking "Terminal" then ran exo-open --launch
  # TerminalEmulator, which found no helper and popped the "choose an
  # application" dialog. It brings exo-utils (exo-open) along as a
  # dependency, which is what actually performs the launch.
  #
  # alsa: firefox dlopens libasound for audio, so it has to be in the image
  # for the browser to be able to make sound. noble renamed the package for
  # the 64-bit time_t transition -- libasound2 became a virtual name over
  # libasound2t64 -- and an apt install of a virtual package fails. Ask the
  # host which name it carries, like the pixbuf bin above.
  local alsa="" p
  for p in libasound2t64 libasound2; do
    if apt-cache show "$p" >/dev/null 2>&1; then alsa=$p; break; fi
  done
  # openssl and ca-certificates: busybox wget's openssl helper (the path that
  # verifies certs and works against GitHub release CDNs) forks `openssl
  # s_client`. Without the binary busybox silently falls back to its internal
  # TLS, which cannot verify certificates and hangs on
  # release-assets.githubusercontent.com -- the "downloads don't go through"
  # bug. libssl/libcrypto already arrive through the glibc closure; this brings
  # the tool itself. ca-certificates brings the roots to build the bundle from.
  # e2fsprogs: the first-boot wizard formats the spare disk the user picks with
  # the real mkfs.ext4, and /init mounts the result as the overlay upper. The
  # busybox mke2fs applet cannot stand in: it creates ext2 only, and its
  # superblock leaves EXT2_FEATURE_COMPAT_SUPP at zero, so there is no EXT_ATTR
  # bit and overlayfs refuses that upper outright. A real ext4 carries the
  # xattrs an overlay needs, which is why the glibc tool comes in here.
  #
  # fonts: DejaVu is Latin and little else. The terminal tools draw out of the
  # rest of Unicode -- btop's graphs and fastfetch's separators are braille,
  # block elements and dingbats -- and a font that lacks them is a tofu box in
  # the terminal or a question mark on the console. Noto carries the scripts
  # and symbols, Symbola the monochrome emoji, Noto Color Emoji the coloured
  # ones VTE can draw, Powerline the prompt glyphs, and Font Awesome the set
  # the Hyprland config asks for by name. Hack, JetBrains Mono, Fira Code and
  # Liberation are the terminal faces themselves: they carry box drawing and
  # the powerline-adjacent shapes at one advance width, which is what the
  # desktop's font picker is looking for when it offers "more fonts".
  #
  # fontconfig (the package -- the library arrives with GTK) is the one that
  # ships fc-cache and fc-match. --no-install-recommends drops it, so the font
  # cache step in startxfce/starthyprland found no fc-cache to run, silently
  # skipped, and left the live image rescanning every font directory on every
  # glyph lookup.
  #
  # libc-bin is not desktop, but it owns /usr/lib/locale/C.utf8. The session
  # sets LANG=C.UTF-8 and glibc refuses a locale whose files are absent, so
  # without this every TUI would quietly stay in the C locale and draw one
  # byte at a time. It also brings ldd and ldconfig, which the image otherwise
  # lacks.
  set -- xserver-xorg-core xserver-xorg-input-evdev xkb-data x11-xkb-utils \
         dbus dbus-x11 xfce4 xfce4-terminal hicolor-icon-theme \
         adwaita-icon-theme librsvg2-common openssl ca-certificates e2fsprogs \
         libc-bin curl make nano fastfetch \
         firefox \
         fonts-dejavu-core fonts-noto-core fonts-noto-mono \
         fonts-noto-color-emoji fonts-symbola fonts-powerline fonts-font-awesome \
         fonts-hack fonts-jetbrains-mono fonts-firacode fonts-liberation \
         fontconfig
  [ -n "$alsa" ] && set -- "$@" "$alsa"
  [ -n "$pixbuf" ] && set -- "$@" "$pixbuf"
  apt-get \
    -o Dir::State::status="$status" \
    -o Dir::Cache::archives="$DG" \
    -o APT::Sandbox::User=root \
    --download-only --no-install-recommends -y install "$@"

  rm -rf "$STAGE"; mkdir -p "$STAGE"
  for deb in "$DG"/*.deb; do
    dpkg-deb -x "$deb" "$STAGE"
  done
  n=$(ls "$DG"/*.deb | wc -l)
  echo "  $n packages unpacked ($(du -sh "$STAGE" | cut -f1))"

  copy_stage_in "$STAGE" "$TGT"

  # Every glibc ELF names /lib64/ld-linux-x86-64.so.2 as its interpreter, and
  # the kernel resolves that exact path before a single instruction of the
  # program runs. The loader itself did arrive -- it sits under
  # /usr/lib/x86_64-linux-gnu -- but the symlink that exposes it at /lib64
  # ships in base-files, which nothing in this closure pulls, and the base
  # image is musl-built, so it never had a /lib64 of its own. Without the
  # file exactly there, execve fails with ENOENT and the shell blames the
  # program instead of the loader: "not found", for a binary sitting right
  # there under /usr. Copy it to the one path the kernel will look at.
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

  # The CA bundle, built the way ca-certificates' postinst builds it -- no
  # maintainer script runs on this image (see the block of mirrors elsewhere
  # in this stage), so update-ca-certificates never fires and the default
  # openssl CAfile /etc/ssl/certs/ca-certificates.crt would be missing. That
  # leaves busybox wget's openssl helper able to connect but unable to verify:
  # -verify 100 -verify_return_error fail the handshake on every real site.
  # update-ca-certificates is just "concatenate the mozilla roots", so mirror
  # that one step directly.
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

  # gdk-pixbuf refuses to know any image format without loaders.cache, and on
  # an installed system only the package postinst writes it -- which never
  # runs here. Without it every icon lookup returns NULL, GTK's g_error()
  # ("Bail out!") aborts each XFCE component as it starts, and the session
  # respawns them in an endless crash-loop that never paints a desktop.
  # First seen on VMware: xfdesktop PIDs 268 -> 279 -> 297 -> 304 climbing in
  # /tmp/session.log while the screen stayed dark.
  #
  # Mirror the gdk-pixbuf postinst here. Layout moved between releases: the
  # generator lives beside the library (newer builds) or in /usr/bin (older);
  # in 2.42 it takes the loader modules as arguments instead of scanning, and
  # PNG/JPEG are compiled into the library so they need no entry. So locate
  # the tool in the staged tree, feed it every loader .so under the module
  # dir it arrived with, ordered with LC_ALL=C for a byte-deterministic
  # cache, and take its stdout as loaders.cache next to the module dir. Run
  # it chrooted into the staged rootfs, where the glibc closure and the
  # modules it dlopens both live. PNG and JPEG ship in the library itself;
  # the SVG loader module arrives in librsvg2-common (in the list above).
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

  # Adwaita resolves panel/status icons to scalable SVGs, and the crash log
  # dies exactly there (ensure_surface_for_gicon on .../scalable/status/).
  # If librsvg2-common's loader module failed to dlopen in the chroot it is
  # silently absent from the cache -- the file looks fine but SVG icons go
  # NULL. Verify the entry here, where a missing module is cheap to fix,
  # instead of on a dark screen.
  if ! grep -q 'image/svg+xml' "$cache"; then
    echo "gui: loaders.cache has no SVG entry (librsvg module did not load)" >&2
    exit 1
  fi

  # The same GTK message names the mime database: without /usr/share/mime/
  # mime.cache, g_content_type_guess() cannot identify image files, and
  # gdk-pixbuf's content-type loader selection fails for formats not covered
  # by filename. shared-mime-info ships the generator (verified: /usr/bin/
  # update-mime-database in the file list) but only its postinst ever runs
  # it. Mirror that here, chrooted where its glib/libxml2 live.
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

  # update-mime-database also emits a legacy /usr/share/mime/icons mapping.
  # On the minimal database this image carries there are no icon mappings to
  # write, so the file is zero bytes -- and every later stage re-runs the
  # whole-tree "no empty regular file" check, so it would fail the build two
  # stages after we made it. An empty icons file carries no information, so
  # prune it; keep a non-empty one, which means real mappings landed.
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
           lib64/ld-linux-x86-64.so.2 \
           usr/bin/openssl etc/ssl/certs/ca-certificates.crt; do
    if [ ! -e "$TGT/$f" ]; then
      echo "gui: $f did not arrive from the packages" >&2
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
# 6f. the Hyprland session: the compositor from the cppiber PPA,
#     the configuration from copper-hyprland-configs
# ---------------------------------------------------------------
# Hyprland is the optional second desktop. The first-boot wizard records
# whether it was chosen (/etc/copper-desktop), starthyprland starts it from the
# tty, and this stage is what puts it in the image.
#
# Two things arrive here, from two places, for two reasons.
#
# The compositor and its ecosystem come from ppa:cppiber/hyprland for noble.
# noble packages no Hyprland at all, and this PPA is the source ML4W's own
# Ubuntu setup uses and is built for noble's glibc 2.39, so nothing else in the
# desktop stage has to move. The closure is computed exactly the way build_gui
# computes XFCE's: apt against an EMPTY dpkg status file with --download-only
# --no-install-recommends, so every library counts as missing and nothing
# arrives half-installed, then dpkg-deb -x into a staging tree and cp -a -n
# into the rootfs, where the busybox applets, the musl tools and the overlay's
# /etc already are and win.
#
# The configuration is ML4W OS 2.17, scoped to the Hyprland session (the
# contents of 12hrformat/copper-hyprland-configs, hyprland.md 6). It is NOT
# vendored into this repo; it is fetched from that repo at a pinned commit,
# checked against a hash, and unpacked to /usr/share/copper/hyprland-skel.
# starthyprland seeds it into the user's home the first time it runs, as the
# user, so the files are owned by them (a root copy would leave a config the
# user cannot edit).
#
# The PPA is added in isolation: apt is pointed at a private sourceparts
# directory holding a copy of the host's own sources plus the PPA, so the host's
# /etc/apt is never written to and no later stage can see the PPA and change
# what IT resolves. The archive key is fetched by fingerprint and its
# fingerprint is checked before it is trusted.
#
# Quickshell, which ML4W uses for the bar, is deliberately NOT built here. Its
# pinned commit requires Qt 6.6 (cmake: QT_MIN_VERSION "6.6.0",
# qt_standard_project_setup(REQUIRES 6.6)); noble ships Qt 6.4.2. It cannot be
# built against noble's Qt without dragging a second Qt into the image, which is
# a change of its own. Waybar ships from the PPA and is the bar instead; see
# HANDOFF.md. Nothing here pretends Quickshell is present.
build_hypr() {
  # The skeleton is unpacked here, but a stage that runs earlier can take files
  # back out of it: build_rootfs sweeps every zero-byte file in the tree, and
  # the Lua configuration's include stubs are zero bytes on purpose -- empty is
  # valid Lua and require() loads it. The sweep exempts the skeleton now (bug 40,
  # the half bug 26 left), but a cached tree can already have been swept, and
  # hypr's stamp would still match and skip the stage that puts the files back.
  # So the stub the config require()s is part of "already staged": if it is
  # gone, the skeleton is not whole and the whole stage re-runs to re-unpack it.
  #
  # seatd and the _seatd group are here for the same reason, and the boot found
  # them missing. The gate below ("seatd did not arrive from the packages") is
  # the loud check, but a guard that skips the stage never runs it: the guard
  # asked only about Hyprland, so a tree that HAD Hyprland and had LOST seatd
  # (or the group build_gui appends, which build_rootfs' overlay copy clobbers
  # on the second pass) skipped everything, passed everything, and shipped a
  # seatd unit pointing at a binary that was not there.
  if [ -e "$TGT/usr/bin/Hyprland" ] \
     && [ -e "$TGT/usr/share/copper/hyprland-skel/.config/hypr/hyprland.lua" ] \
     && [ -e "$TGT/usr/share/copper/hyprland-skel/.config/hypr/conf/environments/default.lua" ] \
     && [ -n "$(find "$TGT/usr" -name seatd -type f -print -quit 2>/dev/null)" ] \
     && grep -q '^_seatd:' "$TGT/etc/group" \
     && stamped_skip "$WORK/hypr.stamp" "$SELF"; then
    echo "hypr: already staged, skipping"; return
  fi
  echo "==> Hyprland session"
  local DH="$DL/hypr" STAGE="$WORK/hypr-root" deb n
  local HA="$WORK/hypr-apt" status="$WORK/hypr-status"
  local KEYRING="$HA/etc/apt/keyrings/cppiber-hyprland.gpg"
  mkdir -p "$DH/partial"
  : > "$status"

  # ---- the archive key, by fingerprint ----------------------------------
  # Fetched, not trusted blind: the key the keyserver returns must carry the
  # fingerprint launchpad publishes for the archive, or the build stops. gpg is
  # expected on the build host -- it is the same host that runs apt -- and if it
  # is not there, say so rather than fall back to something unsigned.
  command -v gpg >/dev/null 2>&1 \
    || { echo "hypr: gpg is needed to verify the PPA archive key" >&2; exit 1; }
  rm -rf "$HA"
  mkdir -p "$HA/etc/apt/sources.list.d" "$HA/etc/apt/keyrings"
  local asc="$WORK/cppiber-hyprland.asc" fpr
  if ! curl -fsSL --retry 3 --retry-all-errors \
       "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$HYPR_PPA_FPR" \
       -o "$asc"; then
    echo "hypr: could not fetch the PPA archive key from keyserver.ubuntu.com" >&2
    exit 1
  fi
  fpr=$(gpg --show-keys --with-colons "$asc" 2>/dev/null \
        | awk -F: '/^fpr:/{print $10; exit}')
  if [ "$fpr" != "$HYPR_PPA_FPR" ]; then
    echo "hypr: the PPA key's fingerprint is '$fpr', expected '$HYPR_PPA_FPR'" >&2
    exit 1
  fi
  gpg --dearmor < "$asc" > "$KEYRING"
  [ -s "$KEYRING" ] || { echo "hypr: the PPA keyring came out empty" >&2; exit 1; }
  echo "  archive key verified ($HYPR_PPA_FPR)"

  # ---- sources, isolated ------------------------------------------------
  # A private sourceparts directory: a copy of whatever the host already uses,
  # plus the PPA. apt then reads the host's sources.list (untouched) and this
  # directory instead of /etc/apt/sources.list.d, so the PPA is visible to this
  # stage and to nothing else. The copy is what keeps noble's own mirrors in
  # the mix: seatd, swaync, lua5.4 and the rest are ordinary noble packages.
  if [ -d /etc/apt/sources.list.d ]; then
    cp -a /etc/apt/sources.list.d/. "$HA/etc/apt/sources.list.d/" 2>/dev/null || :
  fi
  # If the host had nothing to copy (an unusual image), fall back to noble's
  # own archive so the non-PPA half of the list still resolves.
  if [ -z "$(ls -A "$HA/etc/apt/sources.list.d" 2>/dev/null)" ]; then
    echo "deb http://archive.ubuntu.com/ubuntu noble main universe" \
      > "$HA/etc/apt/sources.list.d/noble.list"
  fi
  echo "deb [signed-by=$KEYRING] $HYPR_PPA_URL noble main" \
    > "$HA/etc/apt/sources.list.d/cppiber-hyprland.list"

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
  )
  apt-get "${AOPT[@]}" update -qq

  # The list is what has to be in the image for the session to come up with no
  # network at all: the compositor and its ecosystem from the PPA (hyprland.md
  # 3.1), and the ordinary noble pieces the session leans on (3.3, plus what
  # ML4W's own config assumes the distro already has). Everything heavier is an
  # ingot package and is named in the manifest, not here.
  #
  #   hyprland              the compositor
  #   hypridle/lock/paper/picker/sunset   the ecosystem tools ML4W drives
  #   hyprpolkitagent       the authentication agent (no logind, so no
  #                         polkit-gnome autolaunch via systemd)
  #   hyprland-guiutils     the toolkit dialogs ML4W opens
  #   xdg-desktop-portal-hyprland   screencopy and global shortcuts
  #   waybar                the bar (Quickshell is deferred; see above)
  #   fuzzel                the launcher
  #   seatd                 the seat, since there is no logind
  #   sway-notification-center   notifications (the swaync binary)
  #   kitty                 the terminal
  #   lua5.4                ML4W's config is Lua
  #   wl-clipboard cliphist      clipboard and its history
  #   grim slurp            screenshots
  #   brightnessctl         brightness keys
  #   qt6ct                 Qt theming, which ML4W drives
  #   fonts-font-awesome libnotify-bin libsecret-1-0 gnome-keyring
  #   gnome-themes-extra gvfs-backends udisks2   theming and mounting
  #   xdg-desktop-portal-gtk    the GTK portal (FileChooser and friends)
  #   power-profiles-daemon the profile switcher the bar talks to
  #   xdg-user-dirs         the XDG_* directories the config expects
  #   polkitd pkexec        the polkit daemon and the tool hyprpolkitagent
  #                         prompts through
  #   libgl1-mesa-dri libegl-mesa0 libgbm1 libglx-mesa0
  #                         the GL/GBM stack the renderer needs; the gui
  #                         closure may not have brought the DRI drivers
  #   xwayland              X11 apps under the compositor
  #   inotify-tools imagemagick   used by ML4W's own scripts
  #   bash                  every ML4W helper is #!/usr/bin/env bash. Copper's
  #                          own scripts are POSIX on purpose and run under
  #                          busybox ash, but this is a vendored config we
  #                          promised to keep unmodified: without this one
  #                          package the keybinds that shell out (killactive,
  #                          screenshot, reload, moveTo, the theme toggles) all
  #                          die as "bash: not found". It is ~1.4MB. The
  #                          decision is logged in HANDOFF.md, Hyprland.
  #   jq                    ML4W reads its own settings with it; without it
  #                          the statusbar and theme scripts fail halfway.
  set -- hyprland hypridle hyprlock hyprpaper hyprpicker hyprsunset \
         hyprpolkitagent hyprland-guiutils xdg-desktop-portal-hyprland \
         waybar fuzzel \
         seatd sway-notification-center kitty lua5.4 wl-clipboard cliphist \
         grim slurp brightnessctl qt6ct \
         fonts-font-awesome libnotify-bin libsecret-1-0 gnome-keyring \
         gnome-themes-extra gvfs-backends udisks2 xdg-desktop-portal-gtk \
         power-profiles-daemon xdg-user-dirs polkitd pkexec \
         libgl1-mesa-dri libegl-mesa0 libgbm1 libglx-mesa0 xwayland \
         libxkbcommon0 libxkbcommon-x11-0 libinput10 \
         inotify-tools imagemagick \
         bash jq
  apt-get "${AOPT[@]}" --download-only --no-install-recommends -y install "$@" \
    >"$WORK/hypr-apt.log" 2>&1 \
    || { echo "hypr: apt could not resolve the session closure:" >&2
         tail -n 30 "$WORK/hypr-apt.log" >&2 2>/dev/null || :
         exit 1; }

  rm -rf "$STAGE"; mkdir -p "$STAGE"
  for deb in "$DH"/*.deb; do
    dpkg-deb -x "$deb" "$STAGE"
  done
  n=$(ls "$DH"/*.deb | wc -l)
  echo "  $n packages unpacked ($(du -sh "$STAGE" | cut -f1))"

  copy_stage_in "$STAGE" "$TGT"

  # Shared libraries are the one thing copied from a PACKAGE that must be
  # allowed to replace an earlier package's copy. cp -a -n lets the gui stage's
  # version win, which is right for /etc, for the busybox applet links and for
  # the static musl tools -- but wrong here: the PPA carries a NEWER
  # libxkbcommon (and libinput) than noble's, Hyprland links the newer soname,
  # and the version gui already put in /usr/lib would leave the compositor
  # unable to start. Identical version -> the copy is the same bytes and this is
  # a no-op; newer -> the newer library is the one its consumer was built
  # against, and an older one is never what a newer consumer wants.
  while IFS= read -r so; do
    rel=${so#"$STAGE"/}
    mkdir -p "$TGT/$(dirname "$rel")"
    # -L dereferences symlinks to real files; -f forces the overwrite, so the
    # PPA's newer library always wins over an older base-stage copy even when
    # the base shipped a regular file under the same name (cp -a alone would
    # keep the older one).
    cp -a -f "$so" "$TGT/$rel"
  done < <(find "$STAGE" \( -type f -o -type l \) \( -name '*.so' -o -name '*.so.*' \))
  echo "  shared libraries from the stage take precedence over earlier packages"

  # The loader, defensively: the gui stage creates it, and every glibc ELF
  # needs it at exactly /lib64/ld-linux-x86-64.so.2 before a single instruction
  # runs. build_hypr always runs after build_gui, so this only fires on a tree
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
  find "$STAGE" -type f -size 0 -printf '%P\n' > "$WORK/hypr-empties"
  while IFS= read -r rel; do
    rm -f "$TGT/$rel"
  done < "$WORK/hypr-empties"
  echo "  $(wc -l < "$WORK/hypr-empties") empty package files pruned"

  # The generated caches the package postinsts would have made and this image
  # never runs. Best-effort: a stale cache costs a scan, not a session, so a
  # missing tool is reported and stepped over rather than failing the build.
  if [ -x "$TGT/usr/bin/update-mime-database" ]; then
    chroot "$TGT" /usr/bin/update-mime-database /usr/share/mime \
      >"$WORK/hypr-mime.log" 2>&1 \
      || echo "  (update-mime-database failed; new mime types will not resolve)"
    # updated by dragon, bug 26: the same legacy zero-byte icons map the gui
    # stage prunes is re-created here, because this stage re-runs
    # update-mime-database after gui already pruned it. Left alone it fails the
    # whole-tree empty-file gate two stages later -- on a cache restore it fails
    # *earlier*, in the rootfs step that runs before this one. Mirror the gui
    # prune so the hypr stage cannot reintroduce it.
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
        >"$WORK/hypr-icontheme.log" 2>&1 \
        || echo "  (icon cache failed for ${themedir#"$TGT"})"
    done
  fi
  if [ -x "$TGT/usr/bin/update-desktop-database" ]; then
    chroot "$TGT" /usr/bin/update-desktop-database /usr/share/applications \
      >"$WORK/hypr-desktop.log" 2>&1 \
      || echo "  (update-desktop-database failed; menu cache will be stale)"
  else
    echo "  (no update-desktop-database in the image; menu cache left unbuilt)"
  fi

  # ---- the configuration, pinned and hashed -----------------------------
  # The tree lives in its own repo so it can be re-pinned without a kernel
  # build. The fetch is verified against HYPR_CFG_SHA256; a mismatch is a hard
  # stop, because a config tree that is not the one that was reviewed is exactly
  # the thing this pin exists to prevent. Retried once, because a truncated
  # download is a transport failure and not a changed artifact.
  local cfg="$DL/hypr-cfg-$HYPR_CFG_SHA.tar.gz" got try
  for try in 1 2; do
    if [ -s "$cfg" ] \
       && [ "$(sha256sum "$cfg" | cut -d' ' -f1)" = "$HYPR_CFG_SHA256" ]; then
      break
    fi
    rm -f "$cfg"
    echo "  < $HYPR_CFG_URL" >&2
    curl -fsSL --retry 3 --retry-all-errors -o "$cfg.part" "$HYPR_CFG_URL" || {
      rm -f "$cfg.part"; continue; }
    got=$(sha256sum "$cfg.part" | cut -d' ' -f1)
    if [ "$got" != "$HYPR_CFG_SHA256" ]; then
      echo "hypr: configuration tarball sha256 is $got, expected $HYPR_CFG_SHA256" >&2
      rm -f "$cfg.part"
      continue
    fi
    mv "$cfg.part" "$cfg"
    break
  done
  if [ ! -s "$cfg" ] \
     || [ "$(sha256sum "$cfg" | cut -d' ' -f1)" != "$HYPR_CFG_SHA256" ]; then
    echo "hypr: could not fetch the configuration tree at the pinned commit" >&2
    echo "      $HYPR_CFG_URL" >&2
    exit 1
  fi
  echo "  configuration tree verified ($HYPR_CFG_SHA)"

  local cfgd="$WORK/hypr-cfg" top
  rm -rf "$cfgd"; mkdir -p "$cfgd"
  tar -xzf "$cfg" -C "$cfgd"
  top="$cfgd/copper-hyprland-configs-$HYPR_CFG_SHA"
  if [ ! -d "$top/dotfiles" ]; then
    echo "hypr: the configuration tarball has no dotfiles/ tree" >&2
    exit 1
  fi
  rm -rf "$TGT/usr/share/copper/hyprland-skel"
  mkdir -p "$TGT/usr/share/copper/hyprland-skel"
  cp -a "$top/dotfiles/." "$TGT/usr/share/copper/hyprland-skel/"
  if [ ! -e "$TGT/usr/share/copper/hyprland-skel/.config/hypr/hyprland.lua" ]; then
    echo "hypr: the seeded config has no hypr/hyprland.lua" >&2
    exit 1
  fi

  # git does not carry the exec bit across platforms, so the tree arrived with
  # every script mode 0644 (verified: all 438 blobs are 100644). ML4W's config
  # runs several of them by path -- ~/.config/ml4w/scripts/ml4w-autostart,
  # waybar/launch.sh, listeners.sh -- and a bare path is execve: without +x they
  # fail with "permission denied" and the desktop comes up with no bar. Anything
  # that starts with a shebang is meant to run, so restore exactly that set.
  n=0
  while IFS= read -r -d '' f; do
    if [ "$(head -c 2 "$f" 2>/dev/null)" = '#!' ]; then
      chmod 0755 "$f"; n=$((n + 1))
    fi
  done < <(find "$TGT/usr/share/copper/hyprland-skel" -type f -print0)
  echo "  $n scripts in the config tree marked executable"

  # A CR in any of those scripts fails on the target and the target has no
  # editor to fix it with; the config repo states the LF policy, and this proves
  # it held for the artifact that actually arrived.
  if grep -rIl $'\r' "$TGT/usr/share/copper/hyprland-skel" 2>/dev/null \
       | head -n 1 | grep -q .; then
    echo "hypr: the configuration tree contains CR bytes; the session would fail" >&2
    grep -rIl $'\r' "$TGT/usr/share/copper/hyprland-skel" 2>/dev/null | head -n 5 >&2
    exit 1
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
  # Every one of these missing means the session cannot start, and each is far
  # clearer here than as a failed exec on a live tty.
  local seatd_bin=""
  for f in usr/bin/Hyprland usr/bin/hyprctl usr/bin/hyprpaper usr/bin/hypridle \
           usr/bin/hyprlock usr/bin/waybar usr/bin/fuzzel usr/bin/swaync \
           usr/bin/kitty usr/libexec/hyprpolkitagent \
           etc/copper/hypr-apps \
           usr/share/copper/hyprland-skel/.config/hypr/hyprland.lua; do
    if [ ! -e "$TGT/$f" ]; then
      echo "hypr: $f did not arrive from the packages" >&2
      exit 1
    fi
  done
  # seatd has lived in both /usr/bin and /usr/sbin across releases, so find it
  # rather than name a directory. -print -quit: grep -q closes the pipe on its
  # first match and a second write would arrive as SIGPIPE, which under pipefail
  # reads as "not found" no matter what was found.
  seatd_bin=$(find "$TGT/usr" -name seatd -type f -print -quit 2>/dev/null)
  if [ -z "$seatd_bin" ]; then
    echo "hypr: seatd did not arrive from the packages; the session would have no seat" >&2
    exit 1
  fi

  # The chroot is the honest test: the loader resolves and every library
  # Hyprland links is present at the path it names. --version prints and exits
  # without a compositor, so this needs no display and no seat of its own.
  #
  # Because Hyprland --version does not touch every symbol, also check that
  # the staged libxkbcommon actually carries the V_1.11.0 soname-version that
  # Hyprland (from this PPA) was built against. The pre-1.11 versions the
  # compositor would silently take and fail on at boot are rejected here.
  if [ -e "$TGT/usr/lib/x86_64-linux-gnu/libxkbcommon.so.0" ]; then
    echo "  libxkbcommon versions: $(strings "$TGT/usr/lib/x86_64-linux-gnu/libxkbcommon.so.0" 2>/dev/null | sed -n '/^V_/p' | tr '\n' ' ')"
    if ! strings "$TGT/usr/lib/x86_64-linux-gnu/libxkbcommon.so.0" 2>/dev/null | grep -qx 'V_1.11.0'; then
      echo "hypr: staged libxkbcommon does not provide V_1.11.0; Hyprland would refuse to start (see its log at /tmp/hyprland.log on the booted image)" >&2
      exit 1
    fi
  fi
  if ! chroot "$TGT" /usr/bin/Hyprland --version \
       >"$WORK/hypr-version.log" 2>&1; then
    echo "hypr: Hyprland --version failed inside the staged rootfs:" >&2
    cat "$WORK/hypr-version.log" >&2 2>/dev/null || :
    exit 1
  fi
  echo "  $(head -n 1 "$WORK/hypr-version.log" 2>/dev/null)"
  if ! chroot "$TGT" /usr/bin/waybar --version \
       >"$WORK/hypr-waybar.log" 2>&1; then
    echo "hypr: waybar --version failed inside the staged rootfs:" >&2
    cat "$WORK/hypr-waybar.log" >&2 2>/dev/null || :
    exit 1
  fi

  # The Hyprland closure is the one that carries systemd-sysv (an empty dpkg
  # status makes apt keep every Priority: important package systemd ships),
  # and that is where /usr/sbin/reboot|poweroff|halt|shutdown ->
  # ../bin/systemctl came from in the shipped ISO. Re-point them after the
  # copy, or `sudo reboot` resolves to systemctl first (bug 29). power_links()
  # answers from the tree's own PID 1, so this stage cannot undo the systemd
  # flavour's links on a tree that has already been swapped.
  power_links "$TGT"

  echo "  Hyprland session staged ($(du -sh "$TGT" | cut -f1)) rootfs total"
  stamp_set "$WORK/hypr.stamp" "$SELF"
}

# ---------------------------------------------------------------
# 6g. the boot splash: Plymouth, staged the way the desktop is
# ---------------------------------------------------------------
# Plymouth is the boot splash engine: it takes the console over early, draws a
# theme, and hands the console back when it is told to quit. It is the same
# kind of thing as the desktop -- a real project's binary rather than something
# Copper builds -- so it arrives the same way, from packages unpacked at build
# time.
#
# Building it from source is the obvious alternative and was tried first. The
# no-udev build is broken upstream in the version this targets: in 24.004.60
# add_input_devices_to_renderer() is defined inside `#ifdef HAVE_UDEV` but
# called outside it (src/libply-splash-core/ply-device-manager.c:318 defines,
# :1133 calls), so -Dudev=disabled does not compile. It must not be built with
# udev either: that links udev's enumeration path, which finds no device
# without the udev daemon running, and this image runs no udev.
#
# It does not need udev at runtime. plymouthd reads a documented kernel command
# line switch, `plymouth.ignore-udev` -- src/main.c sets
# PLY_DEVICE_MANAGER_FLAGS_IGNORE_UDEV on it -- and skips udev entirely, taking
# its own fallback path: PLY_RENDERER_TYPE_AUTO, which tries DRM and then the
# framebuffer. grub.cfg passes that switch. The libraries still link libudev
# (libply-splash-core.so.5 NEEDs libudev.so.1), so the library is staged, but
# no code path ever calls into the daemon.
#
# A second switch travels the same way. `plymouth.ignore-serial-consoles` maps
# to PLY_DEVICE_MANAGER_FLAGS_IGNORE_SERIAL_CONSOLES, and without it plymouthd
# treats the machine's second console= (ttyS0 in the VM) as a serial console,
# sets serial_consoles_detected in ply-device-manager.c, and returns before it
# ever creates a renderer -- the splash loads, runs its script, and draws no
# frame (bug 25). grub.cfg passes it too; it changes only what plymouth treats
# as the display, not the console= entries themselves.
#
# Only what the live image uses is copied out of the packages: the daemon, the
# control client, the four libply libraries, the script and text plugins and
# the two renderers. The systemd units, the SysV init script and the
# initramfs-tools hooks the package also ships are left behind on purpose.
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

# ---------------------------------------------------------------
# 6b. sudo — real privilege elevation, staged with the glibc closure
# ---------------------------------------------------------------
# sudo is a glibc binary and the base image is musl, so it gets built on the
# build host (which has the same-family glibc the gui closure brings in) and
# staged whole into the rootfs. It is what lets a normal user run
# `ingot install`: copper-firstboot puts the account in the wheel group, the
# overlay's sudoers grants wheel full rights, and sudo (setuid root) is the
# elevation step. fetch/unpack come from the top of this file; the URL and
# flags below are the ones proven on the Kali box in sudo-dev.sh.
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
  # make install drops an example sudoers; ours is authoritative and the
  # gates below compare byte-for-byte, so ours goes in last and wins.
  #
  # The binary may have arrived through actions/cache, which restores the tree
  # owned by the unprivileged runner: sudo would be uid 1000, the setuid bit
  # would then elevate to that user instead of root, and the chroot gate below
  # fails on "effective uid is not 0, is sudo installed setuid root?". build_iso
  # pins the tree back to root:root before packaging, but that runs later -- this
  # gate is the one that decides, so the owner is pinned here too.
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
# This is the first real step of SYSTEMD-MIGRATION.md, and it is deliberately
# a stage that has to be asked for (`bash iso/build.sh systemd`) rather than
# something `full` runs. The migration document says a half-finished swap is
# an unbootable ISO rather than a degraded one, and that is exactly right: the
# image on the other side of this stage has never been booted. Keeping it out
# of the default path means the shippable ISO is never the half-finished one,
# and means this stage can be iterated on without the busybox image paying for
# it.
#
# What it does NOT do, and why:
#
#   - it does not touch iso/live/init. /init builds the overlay out of the
#     persistent disk, mounts it and switch_roots into it; systemd has to
#     start INSIDE that merged tree, not instead of the tree. So switch_root
#     still execs /sbin/init, and this stage re-points that one symlink. An
#     `init=/lib/systemd/systemd` kernel argument (which the migration
#     document originally suggested) would skip the overlay entirely and boot
#     the read-only squashfs: same rootfs, no persistence, and /etc from the
#     medium. That is why the swap is a symlink and not a kernel argument.
#
#   - it does not delete copper-init. It keeps running as a service
#     (copper-console.service, `copper-init --console`), because the wizard
#     and the session shell need a controlling terminal and the account drop
#     that file already does correctly. Under systemd only the PID-1 half of
#     it -- mounts, power signals, hostname, DHCP, seatd, the udev seeder --
#     is retired, because units do those now.
#
#   - it does not enable logind. The seat still comes from seatd, which is
#     what starthyprland looks for and what HANDOFF.md documents. Moving the
#     seat to logind is a later step; doing both at once would mean a Hyprland
#     failure with two possible causes.
build_systemd() {
  # The unit files ARE the inputs this stage is stamped on: touch one and the
  # stage must re-run. Listed with a helper rather than bare globs so a
  # missing pattern (there is no *.network file today) does not hand
  # stamped_skip the literal string "…*.network", which would hash a filename
  # that does not exist and silently change what "already staged" means.
  #
  # The two SCRIPTS in this directory count as unit files for this purpose.
  # copper-tty-clear.service execs copper-tty-clear, and copper-network.service
  # execs copper-dhcp, so editing either of them changes what the image does.
  # They were not in this list, and that was a live bug rather than a
  # theoretical one: the stage skips itself when its inputs still hash the
  # same, so a helper that is not one of the inputs did not invalidate the
  # stamp. Edit the helper, re-run the build, and the stage said "already
  # staged, skipping" and the ISO shipped the PREVIOUS helper -- a stale
  # artifact with a green light, which is the entire failure mode the stamp
  # exists to prevent.
  local sdin=("$SELF" "$ROOT/systemd"/*.service "$ROOT/systemd"/*.target)
  for p in "$ROOT/systemd"/*.conf "$ROOT/systemd"/*.network \
           "$ROOT/systemd/copper-tty-clear" "$ROOT/systemd/copper-dhcp"; do
    [ -e "$p" ] && sdin+=("$p")
  done
  if [ -e "$TGT/lib/systemd/systemd" ] \
     && [ "$(init_flavour "$TGT")" = systemd ] \
     && stamped_skip "$WORK/systemd.stamp" "${sdin[@]}"; then
    echo "systemd: already staged, skipping"; return
  fi
  echo "==> systemd as PID 1 (migration, opt-in)"
  local DS="$DL/systemd" STAGE="$WORK/systemd-root" deb p ndeb

  # The gui/hypr closures call themselves Ubuntu in /etc/os-release; the
  # systemd stage inherits that tree, so re-assert Copper's identity as the
  # other stages do before anything reads it.
  copper_identity

  mkdir -p "$DS/partial"; rm -f "$DS"/*.deb
  apt-get update -qq

  # systemd and udev are named here; everything else is their dependency
  # closure, and --download-only resolves it. The empty dpkg status is the
  # same device the gui and hypr stages use: apt is told nothing is installed,
  # so it fetches the packages AND their dependencies rather than assuming the
  # build host's own copy. --no-install-recommends keeps the closure to what
  # systemd actually links, not the distro's opinion of a complete system.
  #
  # systemd-sysv is what carries /sbin/{reboot,poweroff,halt,shutdown} and the
  # systemctl links. It is named explicitly rather than pulled in as a
  # dependency, because in the busybox image the power_links() calls go out of
  # their way to undo exactly those links, and this stage wants them back.
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
  # Ubuntu's systemd deb ships PID 1 at /usr/lib/systemd/systemd, because every
  # Debian-family tree since bookworm is merged-usr: /lib IS /usr/lib, spelled
  # as a symlink at the top level. Copper's tree is NOT merged-usr -- /lib here
  # is a real directory holding the musl loader and busybox -- so the deb's
  # files land at $TGT/usr/lib/systemd/... and NOTHING lands at
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

  # ---- the Copper units ---------------------------------------------------
  # Everything Copper-specific lives in units we write, not in units the
  # packages ship: the wizard, the console, seatd, the DHCP client. They are
  # installed and wired up by hand rather than by `systemctl enable`, because
  # enabling means running systemctl against a staged tree -- which means a
  # chroot, a running dbus, and a systemd that is not called into that way
  # from a build. `systemctl enable` creates ordinary symlinks; making the
  # same symlinks is the same operation without the ceremony.
  mkdir -p "$TGT/etc/systemd/system/multi-user.target.wants" \
           "$TGT/etc/systemd/system/sysinit.target.wants" \
           "$TGT/etc/systemd/system/copper.target.wants" \
           "$TGT/etc/systemd/network"
  # install -m 0644, not cp: a Windows checkout hands git these files as 0777
  # (see .gitattributes), and a world-writable unit is one systemd reads with
  # a warning and a reviewer reads with suspicion. The mode is set here rather
  # than trusted from the source tree.
  #
  # Each install is guarded rather than globbed bare. A bare glob that matches
  # nothing expands to the literal pattern, and `install -m 0644 *.network`
  # with no .network files fails the whole stage with "cannot stat
  # '...*.network'" -- which is exactly what happened the first time this ran:
  # iso/systemd/ ships no .network files, and the stage died before it
  # installed anything. The guard is also what lets a future .network file be
  # added to the directory and just work.
  install -m 0644 "$ROOT/systemd"/*.service "$TGT/etc/systemd/system/"
  install -m 0644 "$ROOT/systemd"/*.target  "$TGT/etc/systemd/system/"
  # The helpers are SCRIPTS, not units, and they are the files in this
  # directory that have to be executable and to live on PATH (their units run
  # them as /usr/bin/copper-tty-clear and /usr/bin/copper-dhcp). 0755 here,
  # not 0644 like the units: a unit systemd reads is data, a program systemd
  # execs is not.
  install -D -m 0755 "$ROOT/systemd/copper-tty-clear" \
          "$TGT/usr/bin/copper-tty-clear"
  install -D -m 0755 "$ROOT/systemd/copper-dhcp" \
          "$TGT/usr/bin/copper-dhcp"
  for f in "$ROOT/systemd"/*.conf; do
    [ -e "$f" ] || continue
    install -m 0644 "$f" "$TGT/etc/systemd/"
  done
  for f in "$ROOT/systemd"/*.network; do
    [ -e "$f" ] || continue
    install -m 0644 "$f" "$TGT/etc/systemd/network/"
  done

  local u
  for u in copper-tty-clear.service copper-firstboot.service copper-console.service; do
    ln -sf "/etc/systemd/system/$u" \
           "$TGT/etc/systemd/system/copper.target.wants/$u"
  done
  ln -sf /etc/systemd/system/copper.target \
         "$TGT/etc/systemd/system/multi-user.target.wants/copper.target"
  for u in copper-seatd.service copper-network.service; do
    ln -sf "/etc/systemd/system/$u" \
           "$TGT/etc/systemd/system/copper.target.wants/$u"
  done
  ln -sf /etc/systemd/system/systemd-udevd.service \
         "$TGT/etc/systemd/system/sysinit.target.wants/systemd-udevd.service"

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

  # The power commands are systemd's now. After build_copper's power_links()
  # pointed them at busybox, and after the Isle of Man of links the GUI closure
  # dropped in /usr/sbin, put them where a systemd machine expects: /usr/sbin
  # wins PATH, so both directories have to agree.
  #
  # power_links() answers that from the tree's own PID 1, which is systemd as
  # of the line above, so the stage and the stages that re-run over this tree
  # later cannot disagree about what a systemd machine wants. That is the whole
  # point: the stages that re-run over this tree (the `iso` chain runs the
  # desktop stages again) each call power_links(), and a power_links() that
  # always wrote busybox's applets silently undid this stage on the way to the
  # disc.
  #
  # /usr/sbin/shutdown is the one with a history: build_copper installs our own
  # wrapper there and busybox ships no shutdown applet. systemd-sysv does ship
  # one, and on a systemd machine it is the right one to ship -- /usr/bin/
  # systemctl and a D-Bus that answers. power_links removes the wrapper's link
  # first, so the link that is left answers the question directly instead of
  # pointing through /sbin/shutdown.
  power_links "$TGT"

  # ---- ldconfig: mask a unit that cannot succeed here ----------------------
  # systemd ships ldconfig.service as ExecStart=/sbin/ldconfig -X, and this
  # image has no ldconfig at all -- the gui and hypr closures never brought one,
  # and there is no DEB postinst on this build to run it. On the booted ISO it
  # therefore failed every time, and it was one of the two entries in
  # `systemctl --failed`. A live image with no /etc/ld.so.cache and no ldconfig
  # has nothing for the unit to do, so mask it: /dev/null at the unit's name is
  # systemd's own way of saying "this exists and must not run", which is truer
  # than a unit that is enabled and broken. Masking is idempotent.
  #
  # The mask points at systemd's unit directory, and it has to. The name is
  # resolved through /usr/lib/systemd/system (where the deb put ldconfig.service)
  # and through /etc/systemd/system (which wins) -- so the link is made in /etc,
  # where an administrator's own unmask is a rm away, and it shadows the vendor
  # copy without touching it.
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
  # PID 1 is a glibc ELF with an absolute interpreter, and the kernel resolves
  # it before the first instruction runs. Prove the loader is where the ELF
  # says to look, in the tree, without running anything.
  #
  # `readelf | sed | head` is the obvious way to read the interpreter out and it
  # is wrong here: build.sh runs under `set -o pipefail`, readelf can print more
  # than one line matching the pattern, head exits after the first and closes
  # the pipe, and the resulting SIGPIPE on sed makes the whole pipeline
  # non-zero -- which aborts the stage under `set -e`. That was not theoretical:
  # it killed this stage the first time the gate ran it with build.sh's own
  # shell flags, with `local interp` as the last line of the trace. sed alone,
  # with no head and a pattern anchored so it cannot escape, has no pipe to
  # break and no early exit to signal.
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
            copper-console.service copper-seatd.service copper-network.service; do
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
              multi-user.target.wants/copper.target; do
    if [ ! -L "$TGT/etc/systemd/system/$want" ]; then
      echo "systemd: $want is not a symlink; the unit would not start" >&2
      exit 1
    fi
  done
  # The clear helper is exec'd by the unit above. A unit with an ExecStart that
  # does not exist is the seatd failure all over again, one unit over -- so it is
  # asserted executable at the exact path the unit names.
  if [ ! -x "$TGT/usr/bin/copper-tty-clear" ]; then
    echo "systemd: /usr/bin/copper-tty-clear is missing or not executable;" >&2
    echo "          copper-tty-clear.service would exec a path that does not exist" >&2
    exit 1
  fi
  # The seat is part of the migration, not a nicety: copper-seatd.service is
  # wanted by copper.target, and the two ways it can be broken are both silent.
  # The binary must be at a path the unit actually searches -- the unit's own
  # ExecStart lists /usr/bin/seatd and /usr/sbin/seatd -- and the _seatd group
  # must exist, or seatd exits before it binds the socket. A boot found the
  # first of these wrong (the unit named /usr/bin/seatd; noble installs
  # /usr/sbin/seatd) and the second missing (build_rootfs overwrote /etc/group
  # after build_hypr had appended it). Neither was caught here, so both are
  # asserted here now.
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
  # (An ExecStart-path sweep was tried here and removed: the units legitimately
  # name shell expressions -- copper-seatd.service runs
  # `/bin/sh -c '… exec /usr/sbin/seatd; done; …'` -- and runtime paths such as
  # /run/udhcpc.eth0.pid, so a parser that reads "every absolute word after
  # ExecStart" rejects correct units. The assertions just above say what the
  # boot actually proved, without guessing at shell syntax.)

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
  # copper-init still has to exist: the console service runs the --console half
  # of it. A migration that deleted it here would leave the machine with no
  # wizard and no shell.
  if [ ! -x "$TGT/usr/bin/copper-init" ]; then
    echo "systemd: /usr/bin/copper-init is missing; copper-console.service needs it" >&2
    exit 1
  fi
  # Every other command the units name has to be in the tree too, for the same
  # reason. Each of these is an ExecStart, or something an ExecStart runs:
  #
  #   /usr/bin/copper-dhcp   copper-network.service's ExecStart
  #   /sbin/udhcpc           what copper-dhcp execs
  #   /bin/sh                copper-seatd.service's ExecStart (/bin/sh -c '…')
  #
  # The unit verify below cannot see these on its own: it runs chrooted, but
  # its filter treats "Command X is not executable" as host noise, because the
  # SAME expression runs against the build host, where that shape really is
  # noise. In the chroot the tree IS the machine, so the shape is a real
  # defect there -- the image is missing a binary a Copper unit names, and
  # that unit can never start. That is the seatd bug again, one unit over:
  # the unit named a path the image did not have, and nothing here said so.
  for cmd in usr/bin/copper-dhcp sbin/udhcpc bin/sh; do
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
      # ---- one transaction, not one unit at a time -------------------------
      #
      # An ORDERING CYCLE only exists in a transaction: it is a loop between
      # units, so systemd-analyze has to be given all of them at once to see
      # it. Verified one unit at a time, every unit in the loop looks perfect
      # on its own -- which is exactly how copper-tty-clear.service shipped
      # with `After=sysinit.target` AND `Before=systemd-udevd.service` while
      # systemd's own udevd unit carries `Before=sysinit.target`:
      #
      #     sysinit.target -> copper-tty-clear.service -> systemd-udevd.service
      #                    -> sysinit.target
      #
      # That is a cycle, and it is on sysinit.target, so the boot's initial
      # transaction fails outright: not a degraded boot, no boot. The check
      # below is the build-time version of that, and it is deliberately not
      # scoped to a unit name -- systemd decides which job it drops when it
      # breaks a cycle, so the message can name any unit in the loop.
      local vlist=""
      for ul in copper-console.service copper-firstboot.service \
                copper-network.service copper-seatd.service \
                copper-tty-clear.service copper.target; do
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
                copper-tty-clear.service; do
        out=$(chroot "$TGT" "$sa" verify "/etc/systemd/system/$ul" 2>&1 || true)
        # A message counts only if it is ABOUT this unit AND is a real defect.
        #
        # Two independent problems with the obvious "keep lines naming the
        # unit, drop known noise" filter:
        #
        #   - systemd-analyze pulls in every dependency (the base system
        #     units) and reports those too. Lines that name our unit can still
        #     be the host's packaging -- "Command X is not executable" is the
        #     HOST failing to resolve an ExecStart that only exists in the
        #     image once chrooted (the chroot removes most of that, but a
        #     missing dependency unit still reports against the unit that
        #     wanted it).
        #   - a BLACKLIST of known noise is one new wording away from hiding a
        #     real error, and systemd changes its wording between releases:
        #     255 says "Unknown key name 'X' in section 'Service'", 256+ says
        #     "Unknown key 'X'". A deny-list tuned on one version goes red on
        #     the other -- which is exactly what happened: this step passed on
        #     the dev box's systemd 261 and failed the CI runner's 255.
        #
        # So it is an allow-list. Only a key systemd does not know, a key in
        # the wrong section, a parse error, or a missing ExecStart can fail a
        # Copper unit -- all answered by the unit's own text, none of them
        # dependent on what the build host happens to have installed. A
        # message that is not one of those shapes is the host talking about
        # itself, and the gates above already prove the units installed, are
        # wired, and are mode 644.
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
        # In the chroot the tree IS the machine, so "Command X is not
        # executable" is not host noise here: it means the image is missing a
        # binary this unit names, and the unit can never start. The allow-list
        # above is deliberately silent about that shape, because the SAME
        # expression has to run against the build host as well -- that is where
        # the gate's parse check uses it, and there the shape really is noise,
        # because the host has none of Copper's binaries. So the chroot gets
        # its own, narrower rule.
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
# 8. boot media (grub makes a BIOS+UEFI bootable ISO)
# ---------------------------------------------------------------
build_iso() {
  # Stamped on the whole staged tree, not on grub.cfg alone: the ISO is a
  # copy of all of it, so a change to the overlay, the initrd or the kernel
  # all have to be able to invalidate it. The config goes in first so it is
  # part of the tree that gets hashed, which is the tree that gets packaged.
  mkdir -p "$TGT/boot/grub"
  cp "$ROOT/boot/grub.cfg" "$TGT/boot/grub/grub.cfg"
  # Packaging hygiene, pinned here and before the tree hash so it is part of
  # the stamped tree. -r used to force uid/gid 0 and flatten every mode, which
  # hid two things the tree had wrong; -R carries the real values to the disc,
  # so they have to be right here.
  #
  # Ownership: the workflow restores iso/work through actions/cache as the
  # unprivileged runner, so every restored file comes back owned by uid 1000;
  # the stages whose stamps then match are skipped and leave those files that
  # way. It shipped /etc/shadow owned by a normal user. The image has only ever
  # run root-owned -- that is what -r enforced -- so pin it. Only entries that
  # are not already root:root are touched, because chown clears setuid on
  # regular files and sudo (4755, root:root) has to keep its bit.
  #
  # -h because the closure is full of symlinks -- icon themes, the doc and man
  # alternates, firmware -- and this chown runs on the host, not in the chroot.
  # A dangling link fails with "cannot dereference", and an absolute one would
  # chown the matching path on the RUNNER instead of the tree; -h changes the
  # link itself and never leaves $TGT. A failing -exec also makes find exit
  # non-zero, which is how this took the iso stage down on a warm cache.
  find "$TGT" \( ! -uid 0 -o ! -gid 0 \) -exec chown -h 0:0 {} +
  # chown clears setuid/setgid on regular files even when the owner does not
  # change (measured). The find above only touches non-root entries, so sudo is
  # not among them -- but re-assert it anyway: build_sudo set this bit earlier
  # and a silent drop here is exactly the failure this function exists to stop.
  chmod 4755 "$TGT/usr/bin/sudo"
  #
  # /etc/shadow ships 0644 in git and is copied with cp -a, so it was readable
  # by everyone even before this change. Root reads it directly (setuid sudo
  # and its PAM stack run as root), there is no shadow group on this image, and
  # nothing else here authenticates, so root-only is right.
  chmod 0600 "$TGT/etc/shadow"
  if [ -e "$TGT/etc/gshadow" ]; then chmod 0600 "$TGT/etc/gshadow"; fi
  #
  # /tmp: a live session writes there -- Xorg's lock file and socket
  # (/tmp/.X0-lock, /tmp/.X11-unix) and startxfce's log among them -- and a
  # non-root Xorg dies on an unwritable /tmp before it paints. It is on the
  # overlay, not its own tmpfs, so this mode is the one the session gets.
  mkdir -p "$TGT/tmp"
  chmod 1777 "$TGT/tmp"

  # Whose distribution is about to be written to the disc. build_gui repairs
  # this after it copies base-files in (see copper_identity), and this is the
  # last look before the ISO is produced, so a stage that runs after gui and
  # brings its own os-release with it -- the Hyprland PPA closure is the
  # candidate -- cannot ship a Copper ISO that calls itself Ubuntu.
  local osid; osid=$(sed -n 's/^ID=//p' "$TGT/etc/os-release" 2>/dev/null | head -n1)
  if [ "$osid" != copper ]; then
    echo "iso: the staged tree's /etc/os-release says ID='${osid:-nothing}', not copper" >&2
    echo "iso: something after the gui stage overwrote the image's identity" >&2
    exit 1
  fi
  echo "  iso: the image identifies itself as $(sed -n 's/^PRETTY_NAME=//p' "$TGT/etc/os-release" | head -n1)"

  # Fold this script into the stamp as well as the tree. The ISO is produced
  # by grub-mkrescue plus the xorriso filter below; without $SELF here, a
  # change to either of those against an unchanged tree would skip the rebuild
  # and ship the previous ISO. Every other stage folds $SELF in for this
  # reason.
  local want; want=$( { cat "$SELF"; tree_hash "$TGT"; } | sha256sum | cut -d' ' -f1 )
  if [ -s "$OUT/copper.iso" ] && [ -s "$WORK/iso.stamp" ] \
     && [ "$(cat "$WORK/iso.stamp")" = "$want" ]; then
    echo "iso: already built, skipping"; return
  fi

  # grub-mkrescue hardcodes xorriso's -r, "rationalised" Rock Ridge: every
  # mode is flattened to 444 (files) or 555 (executables), uid/gid forced to
  # 0, and setuid/setgid stripped. That is how the live image lost
  # /usr/bin/sudo's setuid bit -- sudo then refused every elevation with
  # "must be owned by uid 0 and have the setuid bit set", so a normal user
  # could not install anything. -R is the same Rock Ridge without the
  # rationalisation, so it keeps the modes and the ownership the staging tree
  # has (corrected just above, and validated by build_sudo).
  #
  # grub-mkrescue offers no option to change this and reaches xorriso through
  # PATH, so a one-job filter sits in front of it and rewrites exactly -r.
  local REAL_XORRISO XW
  REAL_XORRISO=$(command -v xorriso) || { echo "iso: xorriso not found" >&2; exit 1; }
  XW="$WORK/iso-xorriso"
  rm -rf "$XW"; mkdir -p "$XW"
  cat > "$XW/xorriso" <<'WRAP'
#!/bin/sh
# Exec the real xorriso with grub-mkrescue's -r turned into -R. COPPER_REAL_XORRISO
# is set by the caller so this does not recursively find itself on PATH.
real=${COPPER_REAL_XORRISO:?}
n=$#
i=0
while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    a=$1; shift
    [ "$a" = "-r" ] && a="-R"
    set -- "$@" "$a"
done
exec "$real" "$@"
WRAP
  chmod 0755 "$XW/xorriso"
  echo "==> grub-mkrescue"
  PATH="$XW:$PATH" COPPER_REAL_XORRISO="$REAL_XORRISO" \
    grub-mkrescue -o "$OUT/copper.iso" "$TGT"
  [ -s "$OUT/copper.iso" ] || { echo "grub-mkrescue failed"; exit 1; }

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
  echo "  iso: /usr/bin/sudo is 4755 root:root and /etc/shadow is 0600, on the disc"

  # The power commands, read back off the disc -- bug 29 in one check. PATH
  # (copper-init's setenv, /etc/profile) and sudo's secure_path all search
  # /usr/sbin before /sbin, so a `reboot` there pointing at ../bin/systemctl
  # beats the busybox link in /sbin and `sudo reboot` dies with "System has
  # not been booted with systemd". The 2026-10-17 fix relinked /sbin only, and
  # the ISO CI built from it still shipped systemd-sysv's copies in /usr/sbin
  # -- found by inspecting that artifact, so the same inspection is what this
  # gate automates. Same readback discipline as sudo's mode above.
  #
  # Which links are CORRECT depends on which init the disc carries, so read
  # sbin/init off the disc first (an absolute symlink, so readlink, not -e --
  # see init_flavour) and check the power commands against that answer. On the
  # busybox image they must be busybox applets; on a systemd image they must be
  # systemctl, because a busybox halt signals PID 1 the way copper-init reads
  # it and systemd does not read it that way at all.
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
  if [ "$flavour" = systemd ]; then
    for cmd in reboot poweroff halt shutdown; do
      for d in "$ex/sbin" "$ex/usr-sbin"; do
        pt=$(readlink "$d/$cmd" 2>/dev/null || echo missing)
        [ "$pt" = "/usr/bin/systemctl" ] || pbad="$pbad ${d#"$ex"/}/$cmd -> $pt"
      done
    done
    if [ -n "$pbad" ]; then
      echo "iso: the ISO boots systemd but its power commands are wrong:$pbad" >&2
      echo "iso: systemd expects /usr/bin/systemctl there, not a busybox applet" >&2
      exit 1
    fi
    echo "  iso: systemd is PID 1 and the power commands point at systemctl, on the disc"
  else
    for cmd in reboot poweroff halt; do
      for d in "$ex/sbin" "$ex/usr-sbin"; do
        pt=$(readlink "$d/$cmd" 2>/dev/null || echo missing)
        [ "$pt" = "/bin/busybox" ] || pbad="$pbad ${d#"$ex"/}/$cmd -> $pt"
      done
    done
    pt=$(readlink "$ex/usr-sbin/shutdown" 2>/dev/null || echo missing)
    [ "$pt" = "/sbin/shutdown" ] || pbad="$pbad usr-sbin/shutdown -> $pt"
    if [ ! -f "$ex/sbin/shutdown" ] || [ -L "$ex/sbin/shutdown" ]; then
      pbad="$pbad sbin/shutdown (not the wrapper file)"
    fi
    if [ -n "$pbad" ]; then
      echo "iso: power commands in the ISO are wrong:$pbad" >&2
      echo "iso: /usr/sbin is searched before /sbin, so 'sudo reboot' would not reboot" >&2
      exit 1
    fi
    echo "  iso: power commands point at busybox/wrapper in sbin and usr/sbin, on the disc"
  fi

  # The boot command line, read back off the disc (bug 25, and bug 7 with it).
  # grub.cfg is copied from the tree, so what is really being checked is that
  # the file the build ships is the one that carries the splash: with a serial
  # console beside the screen, plymouthd refuses to create a renderer at all
  # and the animation never paints a frame. And tty0 has to be the LAST
  # console= or /dev/console is the serial port and the screen goes quiet.
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /boot/grub/grub.cfg "$ex/grub.cfg" >/dev/null 2>&1 || true
  if [ ! -f "$ex/grub.cfg" ]; then
    echo "iso: no /boot/grub/grub.cfg in the ISO -- nothing would boot" >&2
    exit 1
  fi
  local cl badsw=""
  cl=$(sed -n '/^    linux .*quiet splash/p' "$ex/grub.cfg" | head -n1)
  for sw in splash plymouth.ignore-udev plymouth.ignore-serial-consoles; do
    case " $cl " in
      *" $sw "*) ;;
      *) badsw="$badsw $sw" ;;
    esac
  done
  if [ -z "$cl" ] || [ -n "$badsw" ]; then
    echo "iso: the splash entry's kernel command line is wrong (missing:$badsw):" >&2
    echo "iso:   $cl" >&2
    exit 1
  fi
  if [ "$(printf '%s\n' "$cl" | grep -o 'console=[^ ]*' | tail -n1)" != "console=tty0" ]; then
    echo "iso: the last console= on the splash entry is not tty0:" >&2
    echo "iso:   $cl" >&2
    echo "iso: /dev/console is the LAST one; the screen would go quiet (bug 7)" >&2
    exit 1
  fi
  echo "  iso: splash switches and tty0-last console order on the disc's grub.cfg"

  # The Hyprland skeleton, read back off the disc -- bug 26's second half, in
  # one check. The session config is Lua whose include stubs are DELIBERATELY
  # empty: a stub exists to be require()d and holds nothing. The one tree-wide
  # empty-file sweep, in build_rootfs, used to delete them -- its guards were
  # written for `find .` against a tree named by an absolute path, so they
  # matched nothing, and the skeleton had no guard at all. rootfs runs before
  # hypr, so only a cached tree that re-ran rootfs lost the stubs, and hypr's
  # stamp then reported "already staged" and did not put them back: the ISO
  # shipped a skeleton missing the file its own config requires, and every home
  # seeded from it came up half-loaded. That is what the human hit. Same
  # readback discipline as sudo's mode above -- check the artifact, on the disc.
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /usr/share/copper/hyprland-skel/.config/hypr/conf/environments \
      "$ex/skel-env" >/dev/null 2>&1 || true
  if [ ! -f "$ex/skel-env/default.lua" ]; then
    echo "iso: the Hyprland skeleton in the ISO has no conf/environments/default.lua" >&2
    echo "iso: its Lua config require()s that file; the seeded session would load half" >&2
    exit 1
  fi
  echo "  iso: the Hyprland skeleton's zero-byte Lua include is on the disc"

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
  build_hypr
  build_plymouth
  build_sudo
  build_initramfs
  build_iso
}

# The DEFAULT flavour's chains take the tree back from the systemd flavour
# if that is what they find.
#
# The staged tree outlives any one build.sh run: iso/work is cached between
# runs, and a cached tree can hold either flavour. A default build that
# inherited the systemd flavour's state would ship an image that boots systemd
# while calling itself the default one -- the half-done swap
# SYSTEMD-MIGRATION.md warns about -- and would fail to copy the Hyprland
# packages into the tree at all.
#
# The `iso` chain is deliberately NOT in this list: the CI builds the default
# ISO and the systemd ISO with the same command, and the tree's own state is
# what says which flavour is being packaged.
#
# The `systemd` chain IS in it, and it is the one that has to be: that stage
# is what puts the swap in place, so it has to do the swap from a KNOWN
# default tree rather than from whatever it found. Two reasons, both real:
# build_copper asserts that sbin/init is copper-init, and it runs before
# build_systemd in that chain, so a tree that came in systemd-flavoured would
# stop the stage dead; and the swap itself is supposed to be the ONLY thing
# that makes a tree systemd-flavoured. Normalising first also makes the stage
# re-runnable: running it twice leaves the same tree, not a tree that has been
# swapped twice.
case "$STAGE" in
  rootfs|gui|hypr|plymouth|sudo|initramfs|copper|systemd|all|"")
    default_flavour ;;
esac

case "$STAGE" in
  kernel)     build_kernel ;;
  base)       build_musl; build_busybox ;;
  tools)      build_musl; build_tools ;;
  copper)     build_musl; build_copper ;;
  rootfs)     build_rootfs ;;
  gui)        build_rootfs; build_gui ;;
  hypr)       build_rootfs; build_gui; build_hypr ;;
  plymouth)   build_rootfs; build_gui; build_hypr; build_plymouth ;;
  sudo)       build_rootfs; build_gui; build_hypr; build_plymouth; build_sudo ;;
  # build_musl and build_busybox lead every stage that compiles or links
  # Copper's own binaries, because build_musl is what exports $CC/$CFLAGS/PATH.
  # This line did not, and CI proved the cost: `bash iso/build.sh systemd` on a
  # runner reaches build_copper with CC unset, and `set -u` kills the build at
  # `$CC $CFLAGS ... copper-sh` with "line 638: CC: unbound variable". The
  # default `all`/`full` path never showed it because full() runs build_musl
  # first; the opt-in stage has to say so itself. It is why this stage is
  # spelled like initramfs/iso and not like sudo.
  systemd)    build_musl; build_busybox; build_rootfs; build_gui; build_hypr; build_plymouth; build_sudo; build_copper; build_systemd ;;
  initramfs)  build_musl; build_busybox; build_rootfs; build_gui; build_hypr; build_plymouth; build_sudo; build_initramfs ;;
  iso)        build_musl; build_busybox; build_rootfs; build_gui; build_hypr; build_plymouth; build_sudo; build_initramfs; build_iso ;;
  all|"")     full ;;
  *)          echo "unknown stage: $STAGE (kernel|base|tools|copper|rootfs|gui|hypr|plymouth|sudo|systemd|initramfs|iso|all)"; exit 2 ;;
esac
echo "==> done"