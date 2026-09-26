# Copper OS

> handcrafted by THE GOAT FARCROW 😘👌👌👌💕💕

Copper is **our own Linux distro** — not a rebranded Debian or Arch. We run the
real Linux kernel with *our* config, build the userland from source (musl,
busybox, coreutils…), and write the pieces that make it *Copper* ourselves:
`copper-sh` (the shell), `copper-init` (our PID 1), and the first-boot wizard.
Arch and Debian source are reference material only.

```
Copper Linux                ──  what this repo builds
├── kernel                  ──  Linux from kernel.org, our .config
├── libc                    ──  musl, compiled from source
├── userland                ──  coreutils, busybox, grep, sed, tar, …
│                              (full standard command set — no stubs)
├── copper-sh               ──  our shell (see below)
├── copper-init             ──  our init, lives at /sbin/init
├── copper-firstboot        ──  first-boot personalization wizard
└── copper.iso              ──  bootable live ISO (VMware/VBox/QEMU)
```

## Status

All work currently lives on the **`copper-os`** branch.

- **copper-sh — done & verified.** Compiled `-std=c11 -O2 -Wall -Wextra`
  with real GCC 12.2 (0 warnings), ran a 44-command battery under
  AddressSanitizer → exit 0.
- **copper-os — in progress.** The from-source distro build — kernel, musl,
  the full userland, our init + wizard, and the bootable ISO. See
  "What's been updated" below.

## What's been updated (copper-os branch)

- **`iso/build.sh`** — the whole from-source pipeline, stage-able
  (`kernel|base|tools|copper|rootfs|initramfs|iso|all`) with per-stage
  skip-if-built so CI re-runs are cheap: builds Linux **6.12.10 LTS** from
  kernel.org with Copper's config subset (ISO9660, overlayfs, tmpfs, devtmpfs,
  virtio/e1000/vmxnet3 NICs, ATA/SATA, ext4, ptys; `MODULES` off — drivers
  built in). Then builds musl 1.2.5, busybox 1.36.1 (static, with
  adduser/chpasswd/mount/hostname applets), and coreutils 9.5 + grep 3.11 +
  sed 4.9 + findutils 4.9.0 + diffutils 3.10 + tar 1.35 + gzip 1.13 +
  xz 5.4.6 — **all compiled from source, static against musl**. Finishes by
  compiling copper-sh/copper-init/copper-firstboot into the rootfs, packing
  the live initramfs, and running `grub-mkrescue` for a BIOS+UEFI bootable
  `copper.iso`.
- **`iso/src-init/copper-init.c`** — **our PID 1** (no systemd): mounts the
  basics, applies the hostname, runs the first-boot wizard once, then keeps
  a copper-sh login shell alive on tty1. Lives at `/sbin/init`.
- **`iso/firstboot/copper-firstboot.c`** — OOBE wizard: name, username,
  hostname, timezone and passwords; creates the user with busybox adduser,
  sets passwords with busybox chpasswd.
- **`iso/rootfs-overlay/etc/…`** — hostname, hosts, profile, group, passwd,
  shadow, fstab, skel.
- **`iso/live/init`** — live initramfs script: mounts proc/sys/dev, finds
  the Copper medium, builds a **writable overlay** (read-only ISO root +
  tmpfs upper), then hands off to `/sbin/init`. This overlay is also how
  persistence will work later.
- **`iso/boot/grub.cfg`** — GRUB menu ("Copper Linux" + verbose entry).
- **`.github/workflows/build-iso.yml`** — from-source build deps only;
  **one CI step per build stage** (a failure names itself via the job API)
  plus an `actions/cache` on `iso/work/` for fast iterations.
- **`src/builtins.c`** — musl compatibility: replaced `nftw` (not in musl)
  with a proper recursive `rmtree`; fixed feature-test macros so the shell
  builds clean against musl.
- **`HANDOFF.md`** — full mission notes + next-person checklist.

Build status: **green.** Every stage — kernel → musl/busybox → the eight GNU
tools → Copper's binaries → rootfs → initramfs → GRUB ISO — completes on CI
and uploads `copper.iso` (~29 MB) as an Actions artifact. Run the pipeline
locally with `sudo bash iso/build.sh` (or watch the Actions logs). Next
milestone: a clean boot in VMware.

---

# copper-sh

The Copper Linux shell — a tiny POSIX shell written in C.

Right now it's mostly builtins so it can do useful things before a full
coreutils is installed on the system. Everything else (`vi`, `top`, ...)
falls through to `execvp` and runs from `$PATH`.

Status: **v0.1.0-dev** — in development.

## Build & run

On a Linux box (or anywhere with a C compiler):

```sh
make
./copper-sh
```

To install it system-wide:

```sh
make install            # installs to /usr/local/bin/copper-sh
```

## Builtin commands

```
help          show this list
exit / quit   leave the shell (ctrl-d also works)
pwd           print working directory
cd            cd, cd ~, cd -, cd ..
ls            ls [-a] [-l] [path]
cat           cat [file...]
echo          echo [-n] [text...]
head          head [-n N] [file...]
tail          tail [-n N] [file...]
wc            wc [-lwc] [file...]
grep          grep [-inv] PATTERN [file...]
tee           tee [-a] FILE...
sleep         sleep SECONDS
true/false    do nothing, exit 0 / exit 1
clear         clear the screen
whoami        your username
id            uid/gid info
hostname      the machine's hostname
uname         system info
date          date and time
basename      strip dirs/suffix from a path
dirname       the directory part of a path
mkdir         make a directory
rmdir         remove an empty directory
touch         create or update a file
rm            rm [-r] [file...]
cp            cp SRC DST
mv            mv SRC DST
ln            ln [-s] TARGET LINK
chmod         chmod OCTAL FILE
history       this session's commands
type          builtin or external?
which         where on PATH?
env           print the environment
```

Also understands `# comments`, single + double quotes, backslash escapes,
pipes (`|`) and redirects (`<`, `>`, `>>`), and `Ctrl-C` won't kill the
shell (only the current command).

## What's next

- networking (`ping`-ish utilities, sockets) — the whole reason this
  project exists is to get Copper online
- `~/.bashrc`-style init file (`~/.copperrc`)
- history persisted to `~/.copper_history`
- real line editing (arrow keys, tab completion)

## Layout

```
src/main.c       shell loop, prompt, tokenizer, process launching
src/builtins.c   builtin commands + the command table helpers
src/builtins.h   the interface between them
iso/build.sh     from-source distro build (kernel, musl, userland, ISO)
iso/live/init    live initramfs (finds medium, sets up overlay)
iso/boot/        GRUB config
iso/src-init/    copper-init (our PID 1)
iso/firstboot/   copper-firstboot wizard
iso/rootfs-overlay/  default /etc config for the rootfs
Makefile
tests/smoke.sh   quick sanity battery
```
