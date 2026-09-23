#!/usr/bin/env bash
# build.sh — assemble Copper Linux, a from-source Linux distro, into a
# bootable live ISO. No Debian/Arch packages: every shipped binary is built
# from upstream source in this script (kernel, musl, busybox, coreutils and
# friends) plus Copper's own pieces (copper-sh, copper-init, first-boot
# wizard).
#
# Requires root. Run: sudo bash iso/build.sh

set -euo pipefail

cd "$(dirname "$0")"
ROOT=$(pwd)
WORK="$ROOT/work"; OUT="$ROOT/out"; DL="$WORK/downloads"
SYS="$WORK/sys"            # our toolchain prefix (musl + musl-gcc)
TGT="$WORK/rootfs"         # copper rootfs staging tree
JOBS=${JOBS:-$(nproc)}
export MAKEFLAGS="-j$JOBS"

[ "$(id -u)" = 0 ] || { echo "build.sh: run with sudo/root"; exit 1; }
command -v wget >/dev/null || { echo "need wget"; exit 1; }

rm -rf "$WORK" "$OUT"
mkdir -p "$DL" "$OUT" "$SYS"/{bin,lib} \
  "$TGT"/{bin,sbin,usr/bin,usr/sbin,usr/share,etc,dev,proc,sys,run,tmp,home,root,var/log,mnt,boot}

fetch() {                   # fetch url -> prints tarball path
  local url="$1" f="$DL/${1##*/}"
  [ -s "$f" ] || wget -q "$url" -O "$f"
  echo "$f"
}

unpack() {                  # unpack tarball -> prints its dir
  local f="$1" d="${f%.tar.*}"
  [ -d "$d" ] || { mkdir -p "$DL"; tar -xf "$f" -C "$DL"; }
  echo "$d"
}

# ---------------------------------------------------------------
# 1. Linux kernel, from kernel.org, with Copper's .config subset
# ---------------------------------------------------------------
echo "==> kernel"
KREL=${KREL:-$(curl -s https://www.kernel.org/releases.json |
  python3 -c "import json,sys;d=json.load(sys.stdin);print([r['version'] for r in d['releases'] if r.get('moniker')=='stable'][0])")}
KPATH="v${KREL%%.*}.x"
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

# ---------------------------------------------------------------
# 2. musl libc (our C library, built from source)
# ---------------------------------------------------------------
echo "==> musl"
MT=$(fetch "https://musl.libc.org/releases/musl-1.2.5.tar.gz")
MD=$(unpack "$MT")
pushd "$MD" >/dev/null
  ./configure --prefix="$SYS" --disable-shared
  make -j"$JOBS"; make install
popd >/dev/null
[ -x "$SYS/bin/musl-gcc" ] || { echo "musl build failed"; exit 1; }
export PATH="$SYS/bin:$PATH"
export CC=musl-gcc
export CFLAGS="-static -O2"
export LDFLAGS="-static"

# ---------------------------------------------------------------
# 3. busybox — base utilities, ash, adduser, chpasswd, mount, ...
# ---------------------------------------------------------------
echo "==> busybox"
BT=$(fetch "https://busybox.net/downloads/busybox-1.36.1.tar.bz2")
BD=$(unpack "$BT")
pushd "$BD" >/dev/null
  make defconfig
  scripts/config -e STATIC -e ADDUSER -e CHPASSWD -e PASSWD -e LOGIN -e SU \
                 -e MOUNT -e UMOUNT -e HOSTNAME -e FEATURE_ADDUSER_TO_GROUP
  echo "CONFIG_PREFIX=\"$TGT\"" >> .config
  make oldconfig
  make -j"$JOBS"
  make install
popd >/dev/null
[ -x "$TGT/bin/busybox" ] || { echo "busybox build failed"; exit 1; }

# ---------------------------------------------------------------
# 4. standard command suite, compiled from source against musl
# ---------------------------------------------------------------
build_gnu() {   # build_gnu NAME URL [configure args...]
  local name="$1" url="$2"; shift 2
  echo "==> $name"
  local t d
  t=$(fetch "$url"); d=$(unpack "$t")
  pushd "$d" >/dev/null
    ./configure --host=x86_64-linux-musl --prefix=/usr \
      --disable-shared --enable-static --disable-nls "$@"
    make -j"$JOBS"
    make DESTDIR="$TGT" install
  popd >/dev/null
}

build_gnu coreutils "https://ftp.gnu.org/gnu/coreutils/coreutils-9.5.tar.xz"
build_gnu grep      "https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz"
build_gnu sed       "https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz"
build_gnu findutils "https://ftp.gnu.org/gnu/findutils/findutils-4.9.0.tar.xz"
build_gnu diffutils "https://ftp.gnu.org/gnu/diffutils/diffutils-3.10.tar.xz"
build_gnu tar       "https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz"
build_gnu gzip      "https://ftp.gnu.org/gnu/gzip/gzip-1.13.tar.xz"
build_gnu xz        "https://github.com/tukaani-project/xz/releases/download/v5.4.6/xz-5.4.6.tar.xz"

# ---------------------------------------------------------------
# 5. Copper's own pieces: shell, init (PID 1), first-boot wizard
# ---------------------------------------------------------------
echo "==> copper built-ins"
$CC $CFLAGS -std=c11 -o "$TGT/usr/bin/copper-sh" \
   "$ROOT/../src/main.c" "$ROOT/../src/builtins.c" -I "$ROOT/../src"
$CC $CFLAGS -std=c11 -o "$TGT/usr/bin/copper-init" "$ROOT/src-init/copper-init.c"
$CC $CFLAGS -std=c11 -o "$TGT/usr/bin/copper-firstboot" "$ROOT/firstboot/copper-firstboot.c"
ln -sf /usr/bin/copper-init "$TGT/sbin/init"

# ---------------------------------------------------------------
# 6. rootfs config + timezone data
# ---------------------------------------------------------------
echo "==> rootfs config"
cp -a "$ROOT/rootfs-overlay/." "$TGT/"
mkdir -p "$TGT/usr/share/zoneinfo"
cp -a /usr/share/zoneinfo/. "$TGT/usr/share/zoneinfo/" 2>/dev/null || true

# ---------------------------------------------------------------
# 7. live initramfs (busybox + our /init, all drivers built into kernel)
# ---------------------------------------------------------------
echo "==> initramfs"
INITRD="$WORK/initramfs"
mkdir -p "$INITRD"/{bin,sbin,proc,sys,dev,mnt/root,mnt/upper/upper,mnt/upper/work,mnt/merged,run}
cp "$TGT/bin/busybox" "$INITRD/bin/busybox"
install -m 0755 "$ROOT/live/init" "$INITRD/init"
( cd "$INITRD" && find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9 ) \
  > "$TGT/boot/initrd.img"

# ---------------------------------------------------------------
# 8. boot media (grub makes a BIOS+UEFI bootable ISO)
# ---------------------------------------------------------------
echo "==> grub-mkrescue"
mkdir -p "$TGT/boot/grub"
cp "$ROOT/boot/grub.cfg" "$TGT/boot/grub/grub.cfg"
grub-mkrescue -o "$OUT/copper.iso" "$TGT"

ls -lh "$OUT/copper.iso"
sha256sum "$OUT/copper.iso"