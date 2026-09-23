#!/usr/bin/env bash
# build.sh — assemble Copper Linux, a from-source Linux distro, into a
# bootable live ISO. No Debian/Arch packages: every shipped binary is built
# from upstream source in this script (kernel, musl, busybox, coreutils and
# friends) plus Copper's own pieces (copper-sh, copper-init, first-boot
# wizard).
#
# Usage:
#   sudo bash iso/build.sh               # everything, in order
#   sudo bash iso/build.sh <stage>       # one stage only
#
# Stages: kernel | base | tools | copper | rootfs | initramfs | iso
#
# Stages share iso/work/, so CI can run them one step at a time and each
# step skips straight past whatever is already built.

set -euo pipefail

cd "$(dirname "$0")"
ROOT=$(pwd)
WORK="$ROOT/work"; OUT="$ROOT/out"; DL="$WORK/downloads"
SYS="$WORK/sys"            # our toolchain prefix (musl + musl-gcc)
TGT="$WORK/rootfs"         # copper rootfs staging tree
JOBS=${JOBS:-$(nproc)}
export MAKEFLAGS="-j$JOBS"

# Kernel version to build. Pinned LTS on purpose — distro builds should be
# reproducible, not "latest at build time". Bump this when we want a newer
# LTS; override with KREL=6.6.x if you need a different series.
KREL=${KREL:-6.12.10}
KPATH="v${KREL%%.*}.x"

STAGE=${1:-all}

[ "$(id -u)" = 0 ] || { echo "build.sh: run with sudo/root"; exit 1; }
command -v curl >/dev/null || { echo "build.sh: need curl"; exit 1; }

mkdir -p "$DL" "$OUT" "$SYS"/{bin,lib} \
  "$TGT"/{bin,sbin,usr/bin,usr/sbin,usr/share,etc,dev,proc,sys,run,tmp,home,root,var/log,mnt,boot}

fetch() {                   # fetch url -> prints tarball path (stdout only)
  local url="$1"
  local f="$DL/${1##*/}"
  [ -s "$f" ] && { echo "$f"; return; }
  echo "  < $url" >&2
  curl -fL --retry 3 --retry-delay 2 -o "$f" "$url"
  [ -s "$f" ] || { echo "fetch failed: $url" >&2; exit 1; }
  echo "$f"
}

unpack() {                  # unpack tarball -> prints its dir
  local f="$1"
  local d="${f%.tar.*}"
  [ -d "$d" ] || tar -xf "$f" -C "$DL"
  echo "$d"
}

# ---------------------------------------------------------------
# 1. Linux kernel, from kernel.org, with Copper's .config subset
# ---------------------------------------------------------------
build_kernel() {
  [ -s "$TGT/boot/vmlinuz" ] && { echo "kernel: already built, skipping"; return; }
  echo "==> kernel $KREL"
  local KT KD
  KT=$(fetch "https://cdn.kernel.org/pub/linux/kernel/$KPATH/linux-$KREL.tar.xz")
  KD=$(unpack "$KT")
  pushd "$KD" >/dev/null
    make defconfig
    scripts/config --disable MODULES \
      --enable ISO9660_FS --enable OVERLAY_FS --enable TMPFS \
      --enable DEVTMPFS --enable DEVTMPFS_MOUNT \
      --enable UNIX98_PTYS --enable LEGACY_PTYS \
      --enable VIRTIO_PCI --enable VIRTIO_BLK --enable VIRTIO_NET \
      --enable E1000 --enable E1000E --enable VMXNET3 \
      --enable ATA --enable ATA_PIIX --enable BLK_DEV_SD \
      --enable EXT4_FS --enable PACKET --enable UNIX --enable VT --enable INPUT
    make olddefconfig
    make -j"$JOBS" bzImage
    cp arch/x86/boot/bzImage "$TGT/boot/vmlinuz"
  popd >/dev/null
  [ -s "$TGT/boot/vmlinuz" ] || { echo "kernel build failed"; exit 1; }
}

# ---------------------------------------------------------------
# 2. musl libc (our C library, compiled from source)
# ---------------------------------------------------------------
build_musl() {
  if [ ! -x "$SYS/bin/musl-gcc" ]; then
    echo "==> musl"
    local MT MD
    MT=$(fetch "https://musl.libc.org/releases/musl-1.2.5.tar.gz")
    MD=$(unpack "$MT")
    pushd "$MD" >/dev/null
      CC=gcc ./configure --prefix="$SYS" --disable-shared
      make -j"$JOBS"; make install
    popd >/dev/null
    [ -x "$SYS/bin/musl-gcc" ] || { echo "musl build failed"; exit 1; }
  fi
  # everything userland from here on is static musl binaries
  export PATH="$SYS/bin:$PATH"
  export CC=musl-gcc
  export CFLAGS="-static -O2"
  export LDFLAGS="-static"
}

# ---------------------------------------------------------------
# 3. busybox — base utilities, ash, adduser, chpasswd, mount, ...
# ---------------------------------------------------------------
build_busybox() {
  [ -x "$TGT/bin/busybox" ] && { echo "busybox: already built, skipping"; return; }
  echo "==> busybox"
  local BT BD
  BT=$(fetch "https://busybox.net/downloads/busybox-1.36.1.tar.bz2")
  BD=$(unpack "$BT")
  pushd "$BD" >/dev/null
    make defconfig
    # busybox has no scripts/config (that's a kernel tool), so set our
    # symbols straight in .config and let oldconfig settle them
    {
      echo 'CONFIG_STATIC=y'
      echo 'CONFIG_ADDUSER=y'
      echo 'CONFIG_CHPASSWD=y'
      echo 'CONFIG_PASSWD=y'
      echo 'CONFIG_LOGIN=y'
      echo 'CONFIG_SU=y'
      echo 'CONFIG_MOUNT=y'
      echo 'CONFIG_UMOUNT=y'
      echo 'CONFIG_HOSTNAME=y'
      echo 'CONFIG_FEATURE_ADDUSER_TO_GROUP=y'
      echo 'CONFIG_FEATURE_SHADOWPASSWDS=y'
      echo 'CONFIG_FEATURE_INSTALLER=y'
      echo 'CONFIG_INSTALL_APPLETS=y'
      echo 'CONFIG_INSTALL_APPLET_SYMLINKS=y'
    } >> .config
    make oldconfig
    make -j"$JOBS"
    make CONFIG_PREFIX="$TGT" install
  popd >/dev/null
  [ -x "$TGT/bin/busybox" ] || { echo "busybox build failed"; exit 1; }
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
  [ -x "$TGT/usr/bin/ls" ] && [ -x "$TGT/usr/bin/grep" ] \
    && { echo "tools: already built, skipping"; return; }
  echo "==> standard command suite"
  build_gnu coreutils   "https://ftp.gnu.org/gnu/coreutils/coreutils-9.5.tar.xz"
  build_gnu grep        "https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz"
  build_gnu sed         "https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz"
  build_gnu findutils   "https://ftp.gnu.org/gnu/findutils/findutils-4.9.0.tar.xz"
  build_gnu diffutils   "https://ftp.gnu.org/gnu/diffutils/diffutils-3.10.tar.xz"
  build_gnu tar         "https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz"
  build_gnu gzip        "https://ftp.gnu.org/gnu/gzip/gzip-1.13.tar.xz"
  build_gnu xz          "https://github.com/tukaani-project/xz/releases/download/v5.4.6/xz-5.4.6.tar.xz"
}

# ---------------------------------------------------------------
# 5. Copper's own pieces: shell, init (PID 1), first-boot wizard
# ---------------------------------------------------------------
build_copper() {
  [ -x "$TGT/usr/bin/copper-sh" ] && [ -x "$TGT/usr/bin/copper-init" ] \
    && [ -x "$TGT/usr/bin/copper-firstboot" ] \
    && { echo "copper: already built, skipping"; return; }
  echo "==> copper built-ins"
  local SRC="$ROOT/../src"
  $CC $CFLAGS -std=c11 -o "$TGT/usr/bin/copper-sh" \
     "$SRC/main.c" "$SRC/builtins.c" -I "$SRC"
  $CC $CFLAGS -std=c11 -o "$TGT/usr/bin/copper-init" \
     "$ROOT/src-init/copper-init.c"
  $CC $CFLAGS -std=c11 -o "$TGT/usr/bin/copper-firstboot" \
     "$ROOT/firstboot/copper-firstboot.c"
  ln -sf /usr/bin/copper-init "$TGT/sbin/init"   # our PID 1
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
}

# ---------------------------------------------------------------
# 7. live initramfs (busybox + our /init, drivers built into kernel)
# ---------------------------------------------------------------
build_initramfs() {
  [ -s "$TGT/boot/initrd.img" ] && { echo "initramfs: already built, skipping"; return; }
  echo "==> initramfs"
  local INITRD="$WORK/initramfs"
  mkdir -p "$INITRD"/{bin,sbin,proc,sys,dev,mnt/root,mnt/upper/upper,mnt/upper/work,mnt/merged,run}
  cp "$TGT/bin/busybox" "$INITRD/bin/busybox"
  install -m 0755 "$ROOT/live/init" "$INITRD/init"
  ( cd "$INITRD" && find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9 ) \
    > "$TGT/boot/initrd.img"
  [ -s "$TGT/boot/initrd.img" ] || { echo "initramfs build failed"; exit 1; }
}

# ---------------------------------------------------------------
# 8. boot media (grub makes a BIOS+UEFI bootable ISO)
# ---------------------------------------------------------------
build_iso() {
  [ -s "$OUT/copper.iso" ] && { echo "iso: already built, skipping"; return; }
  echo "==> grub-mkrescue"
  mkdir -p "$TGT/boot/grub"
  cp "$ROOT/boot/grub.cfg" "$TGT/boot/grub/grub.cfg"
  grub-mkrescue -o "$OUT/copper.iso" "$TGT"
  [ -s "$OUT/copper.iso" ] || { echo "grub-mkrescue failed"; exit 1; }
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
  build_initramfs
  build_iso
}

case "$STAGE" in
  kernel)     build_kernel ;;
  base)       build_musl; build_busybox ;;
  tools)      build_musl; build_tools ;;
  copper)     build_musl; build_copper ;;
  rootfs)     build_rootfs ;;
  initramfs)  build_musl; build_busybox; build_rootfs; build_initramfs ;;
  iso)        build_musl; build_busybox; build_rootfs; build_initramfs; build_iso ;;
  all|"")     full ;;
  *)          echo "unknown stage: $STAGE (kernel|base|tools|copper|rootfs|initramfs|iso|all)"; exit 2 ;;
esac

echo "==> done"