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
- ~500 lines C in `src/` (history preserved inside `copper-os`)
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

### Started for the OS (WIP — most pieces written, build not green yet)
Branch **`copper-os`** (off `copper-sh`). From-source distro build:
- `iso/build.sh` — stage-able pipeline (`kernel|base|tools|copper|rootfs|
  initramfs|iso|all`), each stage skips work already done (CI-friendly):
  pinned Linux kernel **6.12.10 LTS** (reproducible, no live version lookup)
  built from kernel.org with our .config subset (overlayfs, tmpfs, devtmpfs,
  virtio/e1000/vmxnet3, ATA/SATA, ext4, pty; `MODULES` off — drivers built in),
  musl 1.2.5, busybox 1.36.1 (static, adduser/chpasswd/mount/hostname
  applets), coreutils 9.5 + grep 3.11 + sed 4.9 + findutils 4.9.0 + diffutils
  3.10 + tar 1.35 + gzip 1.13 + xz 5.4.6 all **static against musl**, then
  copper's own binaries, initramfs, and a GRUB ISO (BIOS+UEFI)
- `iso/src-init/copper-init.c` — **our PID 1**: console stdio, mounts proc/
  sys/devtmpfs/run, applies /etc/hostname, runs the wizard once (marker file),
  spawns + respawns copper-sh on tty1. Symlinked as `/sbin/init`.
- `iso/firstboot/copper-firstboot.c` — OOBE wizard: name, username
  (validated), hostname (default copper), timezone (default UTC, symlink
  /etc/localtime), root + user passwords. Account via `busybox adduser -h
  /home/U -s /usr/bin/copper-sh -G users,audio,video,dialout,cdrom U`;
  passwords via `busybox chpasswd`; writes `/etc/copper-firstboot.done`.
- `iso/rootfs-overlay/etc/…` — hostname, hosts, profile (full PATH + PS1),
  group (root/users/dialout/cdrom/audio/video), passwd (root+nobody), shadow
  (root locked until wizard), fstab (tmpfs /tmp), skel/.copperrc
- `iso/live/init` — initramfs script: mounts proc/sys/dev, finds the Copper
  medium (iso9660), sets up a **writable overlay** on top of the read-only ISO
  (read-only lowerdir + tmpfs upper — this is also how persistence will work
  later), switch_root to `/sbin/init`
- `iso/boot/grub.cfg` — GRUB menu, both "normal" and "verbose" entries
- `.github/workflows/build-iso.yml` — rebuilds with from-source deps only,
  **per-stage CI steps** (so the anonymous jobs API shows exactly which stage
  failed) + `actions/cache` on `iso/work/` so iterations are fast
- `src/builtins.c` — musl compat fixes (removed `nftw`, real recursive
  `rmtree`; `_GNU_SOURCE` + `_XOPEN_SOURCE 700`)
- `.gitattributes` — force LF eol for .sh/.c/.h/.yml/.service

## What's verified so far

- copper-sh: **verified** (real GCC, ASan battery, see above). 
- copper-init.c / copper-firstboot.c: **written, NOT yet compiled** — the CI
  run is the compiler. First green build is the current goal.
  Local alternative: Compiler Explorer harness (`ce-compile.mjs`) with
  `cg122`, but CE is single-file; these two are single-file so they can be
  checked that way if a quick sanity test is wanted.

## What is MISSING (next person's checklist) ⚠️

1. **Get the CI build green.** Push to `copper-os` triggers the workflow;
   if fork Actions are disabled, enable them in the repo's Actions tab.
   Each stage is its own step, so a failure names itself. Kernel build is
   the slowest step (~10–20 min); the cache makes repeats cheap.
   Known first-run risks: kernel config symbol names, busybox kconfig
   tweaks, coreutils static cross-build details, grub-mkrescue invocation.
2. **Write `iso/README.md`** — architecture + how to run in VMware (new VM,
   Ubuntu 64-bit guest, attach ISO, power on).
3. **Phase 3 after it boots cleanly**: Bluetooth (BlueZ from source + kernel
   `CONFIG_BT=y` etc.), NetworkManager from source (glib/dbus deps) for wifi +
   internet, linux-firmware blobs, then a GUI/desktop.
4. **Persistence** = mount a writable disk as the overlay upper (currently
   tmpfs = session-only), i.e. real "install or always-save" mode.

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