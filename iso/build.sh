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
# Stages: kernel | base | tools | copper | rootfs | gui | hypr | plymouth | sudo | initramfs | iso
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
tree_hash() {      # tree_hash <dir>
  ( cd "$1" && find . -type f -exec sha256sum {} + | LC_ALL=C sort ) \
    | sha256sum | cut -d' ' -f1
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

  echo "kernel: config looks fit to boot, to reach the network, and to draw"
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
      CHPASSWD FEATURE_SHADOWPASSWDS ; do
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

# Point the SysV power commands at busybox -- in BOTH directories PATH
# searches for them. The order is /usr/local/sbin:/usr/local/bin:/usr/sbin:
# /usr/bin:/sbin:/bin (assert_commands_reachable above keeps it in step with
# copper-init's setenv, and sudo's secure_path and /etc/profile carry the same
# list), so /usr/sbin comes FIRST: a `reboot` left there by systemd-sysv wins
# the name over a busybox link in /sbin, and `sudo reboot` answers "System has
# not been booted with systemd" (bug 29). The 2026-10-17 fix only relinked
# /sbin; the CI ISO built from it still shipped
# /usr/sbin/reboot|poweroff|halt|shutdown -> ../bin/systemctl, which is how
# this was caught -- by reading the links back off the shipped disc, and
# re-checked there by build_iso's gate.
# /usr/sbin/shutdown points at our wrapper: busybox ships no shutdown applet.
# Called after every stage that copies packages into $TGT (copper, gui, hypr;
# plymouth only copies its own lib directory).
# updated by farcrowx, bug 29, iso/build.sh (the /sbin-only relink loops)
power_links() {          # power_links <staged-root>
  local root=$1 cmd
  mkdir -p "$root/sbin" "$root/usr/sbin"
  for cmd in reboot poweroff halt; do
    ln -sf /bin/busybox "$root/sbin/$cmd"
    ln -sf /bin/busybox "$root/usr/sbin/$cmd"
  done
  ln -sf /sbin/shutdown "$root/usr/sbin/shutdown"
}

# ---------------------------------------------------------------
# 5. Copper's own pieces: shell, init (PID 1), first-boot wizard
# ---------------------------------------------------------------
build_copper() {
local SRC="$ROOT/../src"
  if [ -x "$TGT/usr/bin/copper-sh" ] && [ -x "$TGT/usr/bin/copper-init" ] \
     && [ -x "$TGT/usr/bin/copper-firstboot" ] \
     && [ -x "$TGT/usr/bin/xprobe" ] && [ -x "$TGT/sbin/shutdown" ] \
     && stamped_skip "$WORK/copper.stamp" "$SELF" "$SRC"/*.c "$SRC"/*.h \
        "$ROOT/src-init/copper-init.c" "$ROOT/firstboot/copper-firstboot.c" \
        "$ROOT/startxfce.sh" "$ROOT/x11/probe/xprobe.c" "$ROOT/shutdown.sh" \
        "$ROOT/copper-charge.sh" "$ROOT/copper-rollback.sh" "$ROOT/copper.sh"
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

  # hotfix tools — copper charge and copper rollback
  install -m 0755 "$ROOT/copper-charge.sh" "$TGT/usr/bin/copper-charge"
  install -m 0755 "$ROOT/copper-rollback.sh" "$TGT/usr/bin/copper-rollback"
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
           usr/bin/copper-charge usr/bin/copper-rollback usr/bin/copper; do
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
    "$ROOT/copper-charge.sh" "$ROOT/copper-rollback.sh" "$ROOT/copper.sh"
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
  # regular file now, except the two the gate already exempts by name, so the
  # gate sees the tree the stages are trying to produce.
  find "$TGT" -type f -size 0 \
    ! -path './etc/motd' ! -path './etc/timezone' ! -name 'mach_kernel' \
    -delete 2>/dev/null || true

assert_no_empty_files
  assert_commands_reachable
  assert_shell_scripts_parse
  assert_hotfix_db_readable
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
      copper copper-charge copper-rollback startxfce starthyprland \
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
    for f in iso/copper.sh iso/copper-charge.sh iso/copper-rollback.sh \
             iso/rootfs-overlay/usr/bin/ingot; do
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
    # This loop was skipping all three over a wrong path, and `[ -f ] ||
    # continue` is precisely the construct that hides that.
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
assert_hotfix_db_readable() {
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
  if [ -e "$TGT/usr/bin/Xorg" ] && [ -e "$TGT/usr/bin/startxfce4" ] \
     && stamped_skip "$WORK/gui.stamp" "$SELF"; then
    echo "gui: already staged, skipping"; return
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
  set -- xserver-xorg-core xserver-xorg-input-evdev xkb-data x11-xkb-utils \
         dbus dbus-x11 xfce4 xfce4-terminal fonts-dejavu-core hicolor-icon-theme \
         adwaita-icon-theme librsvg2-common openssl ca-certificates e2fsprogs
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

  cp -a -n "$STAGE"/. "$TGT"/

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

  # Re-point the power commands at busybox: the gui stage just copied
  # systemd/sysvinit-utils versions that cannot talk to busybox init -- in
  # /sbin and in /usr/sbin, which PATH (and sudo's secure_path) searches first
  # (bug 29; the /usr/sbin half is what the 2026-10-17 fix missed).
  power_links "$TGT"

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
  if [ -e "$TGT/usr/bin/Hyprland" ] \
     && [ -e "$TGT/usr/share/copper/hyprland-skel/.config/hypr/hyprland.lua" ] \
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

  cp -a -n "$STAGE"/. "$TGT"/

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
  # copy, or `sudo reboot` resolves to systemctl first (bug 29).
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
  echo "  iso: /usr/bin/sudo is 4755 root:root and /etc/shadow is 0600, on the disc"

  # The power commands, read back off the disc -- bug 29 in one check. PATH
  # (copper-init's setenv, /etc/profile) and sudo's secure_path all search
  # /usr/sbin before /sbin, so a `reboot` there pointing at ../bin/systemctl
  # beats the busybox link in /sbin and `sudo reboot` dies with "System has
  # not been booted with systemd". The 2026-10-17 fix relinked /sbin only, and
  # the ISO CI built from it still shipped systemd-sysv's copies in /usr/sbin
  # -- found by inspecting that artifact, so the same inspection is what this
  # gate automates. Same readback discipline as sudo's mode above.
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /sbin "$ex/sbin" >/dev/null 2>&1 || true
  xorriso -osirrox on -indev "$OUT/copper.iso" \
      -extract /usr/sbin "$ex/usr-sbin" >/dev/null 2>&1 || true
  local pbad="" pt
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
  initramfs)  build_musl; build_busybox; build_rootfs; build_gui; build_hypr; build_plymouth; build_sudo; build_initramfs ;;
  iso)        build_musl; build_busybox; build_rootfs; build_gui; build_hypr; build_plymouth; build_sudo; build_initramfs; build_iso ;;
  all|"")     full ;;
  *)          echo "unknown stage: $STAGE (kernel|base|tools|copper|rootfs|gui|hypr|plymouth|sudo|initramfs|iso|all)"; exit 2 ;;
esac

echo "==> done"