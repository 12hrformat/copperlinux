# Copper OS — Mission Handoff

> This file is the checkpoint for whoever picks this up next. It records what
> was decided, what is DONE and verified, what files exist, and the exact next
> steps. Read this first, then `iso/README.md` for the build internals.

## The goal (in the builder's own words)

Copper is **not** a rebranded Debian/Arch. It's **our own Linux distro**:

- the real **Linux kernel** (torvalds/linux / kernel.org) — we use it, we don't
  rewrite it — with **our own `.config`**
- userland **built from source** in our own build (musl, busybox, coreutils…)
- **our own** shell (`copper-sh`), **our own** init (`copper-init`), **our own**
  first-boot wizard
- ships **all the standard Linux commands** (no stubs — real tools, real work)
- boots as an **ISO** in VMware / VirtualBox / QEMU
- first boot asks to personalize like a real distro / Windows OOBE
- speaks to **drivers** (bluetooth via BlueZ, wifi, firmware) and has a
  **working internet connection**

Reference material (NOT to be packaged as-is): torvalds/linux, Arch, Debian.

## What is DONE and verified ✅

### copper-sh shell — complete & verified
- ~500 lines C, `src/` on the **`copper-sh` branch** (PR branch):
  `12hrformat/copper:copper-sh`
- 36 builtins + pipes `|`, redirects `<` `>` `>>`, quoting, `#` comments,
  history, external PATH programs (fork+exec)
- **Verified by real execution**: compiled with real GCC 12.2
  (`-std=c11 -O2 -Wall -Wextra` → 0 errors, 0 warnings), ran a 44-command
  battery under **AddressSanitizer** → exit 0, no leaks/overruns
- Bugs fixed during testing: argv heap off-by-one (ASan), lost output from
  `_exit()` skipping stdio flush, history storing tokenized (compact) lines,
  children reading stale buffered stdin, `ls -l file` error, `ls` one-per-line
  to non-TTY (so `ls | grep` filters like real ls)
- PR link (shell vs upstream, optional — re-openable anytime by pushing the
  branch back, history lives inside `copper-os`):
  `https://github.com/Copper-linux/copper/compare/main...12hrformat:copper-sh`
- Remote compile/run harness (no local compiler; WSL broken on this machine):
  `%LOCALAPPDATA%\Temp\opencode\ce-compile.mjs` and `ce-run.mjs`
  (Compiler Explorer API, compiler `cg122` = x86-64 gcc 12.2 C mode)

### Started for the OS (WIP, **NOT yet built/verified**)
Branch **`copper-os`** (off `copper-sh`). From-source distro build:
- `iso/build.sh` — builds kernel (dynamic stable version from kernel.org,
  our .config subset: overlayfs, tmpfs, devtmpfs, virtio/e1000/vmxnet3,
  ATA/SATA, ext4, pty), musl 1.2.5, busybox 1.36.1 (static, adduser/chpasswd/
  mount applets), coreutils 9.5 + grep 3.11 + sed 4.9 + findutils 4.9.0 +
  diffutils 3.10 + tar 1.35 + gzip 1.13 + xz 5.4.6 all **static against musl**,
  then compiles copper-sh/copper-init/copper-firstboot, assembles initramfs +
  GRUB ISO via grub-mkrescue (BIOS+UEFI)
- `iso/live/init` — initramfs script: mounts proc/sys/dev, finds the Copper
  medium (iso9660), sets up a **writable overlay** on top of the read-only ISO
  (read-only lowerdir + tmpfs upper — this is also how settings persist
  later), switch_root to `/sbin/init`
- `iso/boot/grub.cfg` — GRUB menu, both "normal" and "verbose" entries
- `src/builtins.c` — musl compat fixes (removed `nftw`, real recursive
  `rmtree`; `_GNU_SOURCE` + `_XOPEN_SOURCE 700`)
- `.gitattributes` — force LF eol for .sh/.c/.h/.yml/.service

## What is MISSING (next person's checklist) ⚠️

1. **Write `iso/src-init/copper-init.c`** — our PID 1: open /dev/console,
   mount proc/sys/devtmpfs/run (idempotent), read /etc/hostname + sethostname,
   run `/usr/bin/copper-firstboot` once if `/etc/copper-firstboot.done`
   missing, spawn copper-sh on /dev/tty1, respawn on exit, ignore SIGINT.
   Symlink as `/sbin/init`.
2. **Write `iso/firstboot/copper-firstboot.c`** — wizard: ask name, username
   (validate `[a-z_][a-z0-9_-]*`), hostname (default copper), timezone
   (default UTC, symlink /etc/localtime), root + user passwords. Create user
   via `busybox adduser -h /home/U -s /usr/bin/copper-sh -G users,audio,
   video,dialout U`; set passwords via `busybox chpasswd`; write
   `/etc/copper-firstboot.done`.
3. **Write `iso/rootfs-overlay/etc/…`** — hostname (`copper`), hosts,
   profile (PATH incl. /usr/local/sbin…, PS1), group (root/users/dialout/
   cdrom/audio/video), passwd (root only), shadow (root locked), fstab
   (tmpfs /tmp).
4. **Rewrite `.github/workflows/build-iso.yml`** — currently still has the old
   Debian package list. Must install source-build deps instead:
   `build-essential bison flex bc cpio rsync curl wget texinfo help2man
   autoconf automake libtool pkg-config python3 perl gawk xorriso mtools
   grub-pc-bin grub-efi-amd64-bin xz-utils`, then `sudo bash iso/build.sh`,
   upload `iso/out/copper.iso`.
5. **Write `iso/README.md`** — architecture + how to run in VMware
   (new VM, Ubuntu 64-bit guest, attach ISO, power on).
6. **Run the build on the fork's GitHub Actions** (branch `copper-os` push
   triggers it; if Actions is disabled on the fork, enable it in the repo's
   Actions tab). First run WILL hit errors — iterate. Kernel build is the
   slowest step (~10–20 min).
7. **Phase 3 after boots cleanly**: Bluetooth (BlueZ from source + BT kernel
   config `CONFIG_BT=y`), NetworkManager from source (glib/dbus deps) for wifi
   + internet, linux-firmware blobs, then GUI/desktop is the next frontier.
   Persistence across reboots = mount a writable disk as the overlay upper
   (currently tmpfs = session-only), i.e. real "install or always-save" mode.

## Repo map (this machine)

- Local repo: `C:\Users\jitendra rathore\desktop\copper-terminal`
- Remotes: `origin` = Copper-linux/copper (read-only for us → 403 on push),
  `gh` = `https://github.com/12hrformat/copper.git` (our fork, push works)
- Branches (pushed to fork): **`copper-os` only** — old branches (`main`,
  `copper-sh`, `patch-1`) were deleted; the shell history is preserved inside
  `copper-os`.
- No local compiler; verify C via the Compiler Explorer harness above.

## Rules to keep (user asked)

- Human-sounding commit messages & code — nothing that reads like AI slop.
- Keep Copper's identity; Arch/Debian source is reference only.
- Verification > vibes: compile clean, run the battery under ASan before
  claiming a command works. Never ship a fake/placeholder command.