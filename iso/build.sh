#!/usr/bin/env bash
# Copper Linux — handcrafted by 12hrformat
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

# Every stage below stamps itself with a hash of this script, because that is
# where the kernel version and the config flags live. $0 is whatever was
# typed on the command line — CI runs `sudo bash iso/build.sh kernel`, so it
# is the relative "iso/build.sh" — and the cd on the next line stops it
# resolving. Pin it down first.
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
cd "$(dirname "$0")"
ROOT=$(pwd)
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
  for s in "$ROOT/live/init" "$ROOT/rootfs-overlay/usr/share/udhcpc/default.script"; do
    sh -n "$s" || { echo "build.sh: syntax error in $s"; exit 1; }
  done
  echo "scripts: live/init and the udhcpc lease script parse clean"
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

  # The half of the graphical desktop that is easy to get backwards.
  #
  # FRAMEBUFFER_CONSOLE routes the VGA text console through the framebuffer
  # instead of the legacy text buffer. That changes how the boot art is rendered,
  # and the drawing is the one thing in this image nobody is allowed to change, so
  # it stays off and the artwork keeps the path it has always had.
  #
  # Asserted rather than merely requested, because the failure mode is silent: a
  # kernel bump, or a graphics driver that selects it, would switch the console
  # over without anybody asking, the build would still succeed, and the symptom
  # would be subtly different artwork that still looked roughly right.
  #
  # Note the symbol is simply absent from the config today, because CONFIG_FB is
  # not set either -- see build_kernel for why there is no framebuffer here yet.
  if grep -q '^CONFIG_FRAMEBUFFER_CONSOLE=y' "$cfg"; then
    echo "kernel: CONFIG_FRAMEBUFFER_CONSOLE came back on; that would change" >&2
    echo "        how the boot art is rendered. It must stay off." >&2
    exit 1
  fi

  echo "kernel: config looks fit to boot and to reach the network"
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
  pushd "$KD" >/dev/null
    make defconfig
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
      --disable FRAMEBUFFER_CONSOLE
    # vmxnet3 was renamed at some point around 6.12; asking for both names
    # costs nothing, since kconfig drops whichever one doesn't exist.
    #
    # DRM_BOCHS is deliberately NOT enabled here. It was, and the consequence was
    # measured rather than assumed:
    #
    #     bochs-drm 0000:00:02.0: vgaarb: deactivate vga console
    #     Console: switching to colour dummy device 80x25
    #
    # at about 1.7 seconds, during kernel bring-up -- long before anything in the
    # image draws anything. bochs-drm takes exclusive ownership of the VGA
    # hardware, and with CONFIG_FRAMEBUFFER_CONSOLE off nothing ever takes it
    # back, because fbcon is precisely the thing that re-registers tty0 against
    # the new framebuffer. tty0 is then left registered, accepts writes, and
    # discards them: writing to /dev/tty0 returns 0, and a screendump taken after
    # clearing the screen and printing 80 '@' onto it is indistinguishable from
    # one taken from a boot where nothing was written at all.
    #
    # The image would still build, still boot, still bring up a desktop
    # afterwards, and would never once display the boot art. That is a worse
    # trade than having no desktop, so the flag is off and the boot art is left
    # exactly as it was.
    #
    # Having both needs fbcon enabled with the classic VGA font pinned, so that
    # the artwork is rasterised by the same glyphs the text plane used. Whether
    # that output is genuinely identical is a question about pixels, to be
    # measured against the current rendering, and it is a decision about the
    # artwork. It does not belong in a kernel config line, which is why this
    # comment exists: so the next person to solve the framebuffer by adding
    # DRM_BOCHS finds out what it costs before shipping it.
    #
    # The desktop therefore comes up only where a framebuffer already exists, and
    # this kernel does not provide one: CONFIG_FB is not set and DRM_BOCHS is not
    # set, so /dev/fb0 does not exist and copper-gui never starts. On the ISO that
    # is today is a shell, exactly as it was before any of this. copper-gui exits
    # 1 with a clear message when /dev/fb0 is absent, and copper-init falls
    # straight through to the shell in that case, so nothing regresses -- but the
    # desktop is wired in and waiting, not running, and the commit message says
    # so rather than leaving it to be discovered on a first boot.
    make olddefconfig
    require_kernel_config "$KD/.config"
    make -j"$JOBS" bzImage
    cp arch/x86/boot/bzImage "$TGT/boot/vmlinuz"
  popd >/dev/null
  [ -s "$TGT/boot/vmlinuz" ] || { echo "kernel build failed"; exit 1; }
  stamp_set "$WORK/kernel.stamp" "$SELF"
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
      STATIC ASH \
      UDHCPC FEATURE_UDHCPC_ARPING IP IFCONFIG ROUTE PING \
      WGET FEATURE_WGET_HTTPS NSLOOKUP \
      MOUNT SWITCH_ROOT HOSTNAME \
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
  build_gnu coreutils   "https://ftp.gnu.org/gnu/coreutils/coreutils-9.5.tar.xz"
  build_gnu grep        "https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz"
  build_gnu sed         "https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz"
  build_gnu findutils   "https://ftp.gnu.org/gnu/findutils/findutils-4.9.0.tar.xz"
  build_gnu diffutils   "https://ftp.gnu.org/gnu/diffutils/diffutils-3.10.tar.xz"
  build_gnu tar         "https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz"
  build_gnu gzip        "https://ftp.gnu.org/gnu/gzip/gzip-1.13.tar.xz"
  build_gnu xz          "https://github.com/tukaani-project/xz/releases/download/v5.4.6/xz-5.4.6.tar.xz"
  stamp_set "$WORK/tools.stamp" "$SELF"
}

# ---------------------------------------------------------------
# 5. Copper's own pieces: shell, init (PID 1), first-boot wizard
# ---------------------------------------------------------------
build_copper() {
local SRC="$ROOT/../src"
  local GUI="$ROOT/gui"
  if [ -x "$TGT/usr/bin/copper-sh" ] && [ -x "$TGT/usr/bin/copper-init" ] \
     && [ -x "$TGT/usr/bin/copper-firstboot" ] \
     && [ -x "$TGT/usr/bin/copper-gui" ] \
     && stamped_skip "$WORK/copper.stamp" "$SELF" "$SRC"/*.c "$SRC"/*.h \
        "$ROOT/src-init/copper-init.c" "$ROOT/firstboot/copper-firstboot.c" \
        "$GUI/copper-gui.c" "$GUI/fbabi.h" "$GUI/font8x8.h"
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
  # The desktop. -I "$GUI" for font8x8.h, which is compiled in rather than loaded
  # at runtime: there is no font file to find on a machine that is still deciding
  # whether it has a graphics driver, and a desktop that cannot find its own font
  # is a desktop of empty rectangles.
  $CC $CFLAGS -std=c11 -o "$TGT/usr/bin/copper-gui" \
     "$GUI/copper-gui.c" -I "$GUI"
  ln -sf /usr/bin/copper-init "$TGT/sbin/init"   # our PID 1

  # hotfix tools — copper charge and copper rollback
  install -m 0755 "$ROOT/copper-charge.sh" "$TGT/usr/bin/copper-charge"
  install -m 0755 "$ROOT/copper-rollback.sh" "$TGT/usr/bin/copper-rollback"
  install -m 0755 "$ROOT/copper.sh" "$TGT/usr/bin/copper"

  # switch_root is going to need all of these, and a staged tree missing one
  # of them is a black screen on a machine with no shell to debug it from.
  # Say it here, where it costs a second. (The udhcpc lease script is checked
  # in build_rootfs instead — this stage runs before the overlay is copied.)
  local f
  for f in usr/bin/copper-init usr/bin/copper-sh usr/bin/copper-firstboot \
           usr/bin/copper-gui \
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
    "$GUI/copper-gui.c" "$GUI/fbabi.h" "$GUI/font8x8.h" \
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

  # A CR anywhere in this file makes busybox ash fail every line of it, and
  # the machine has no shell to fix that with. Cheap to prove here.
  if LC_ALL=C grep -q $'\r' "$TGT/usr/share/udhcpc/default.script"; then
    echo "rootfs: udhcpc lease script has CRLF line endings" >&2
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
assert_no_empty_files() {
  local empties
  empties=$( cd "$TGT" && find . -type f -size 0 \
    ! -path './etc/motd' \
    ! -path './etc/timezone' \
    ! -path './var/log/*' \
    ! -name '*.uuid' \
    # Vestigial cosmopolitan artifact. It is shipped empty and grub.cfg never
    # boots it -- the menu entries load /boot/vmlinuz and /boot/initrd.img --
    # so an empty mach_kernel costs nothing. Worth knowing it is a no-op file.
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
      copper copper-charge copper-rollback copper-gui \
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
  # matters. So check those against a POSIX shell too, when one is available.
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
    for f in iso/copper.sh iso/copper-charge.sh iso/copper-rollback.sh; do
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
    [ "$n_posix" -eq 3 ] || {
      echo "build: the POSIX check covered $n_posix of 3 busybox tools" >&2; exit 1; }
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
    echo "build: $gate is missing, so the hotfix database was never checked." >&2
    exit 1
  fi
  ( cd "$REPO" && "$gate" ) || {
    echo "build: the hotfix database did not survive the parser." >&2
    echo "       Every entry but the last would be silently ignored on a" >&2
    echo "       live system, with no error and no change." >&2
    exit 1
  }
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
  local want; want=$(tree_hash "$TGT")
  if [ -s "$OUT/copper.iso" ] && [ -s "$WORK/iso.stamp" ] \
     && [ "$(cat "$WORK/iso.stamp")" = "$want" ]; then
    echo "iso: already built, skipping"; return
  fi
  echo "==> grub-mkrescue"
  grub-mkrescue -o "$OUT/copper.iso" "$TGT"
  [ -s "$OUT/copper.iso" ] || { echo "grub-mkrescue failed"; exit 1; }
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