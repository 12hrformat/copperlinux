# Copper Linux — build internals

Everything under `iso/` contributes to a fully from-source Linux distro:

```
iso/build.sh                the whole pipeline, stage by stage
iso/live/init               live initramfs: find medium, overlay, hand off
iso/boot/grub.cfg           GRUB menu (normal + verbose)
iso/src-init/copper-init.c  our PID 1 (no systemd)
iso/firstboot/copper-firstboot.c   first-boot personalization wizard
iso/rootfs-overlay/         default /etc for the rootfs
```

## How the pieces fit

A Copper ISO is a `grub-mkrescue` image. It boots like this:

1. GRUB loads `vmlinuz` + `initrd.img` (the unpacked live system).
2. `/init` (a busybox ash script) mounts proc/sys/dev, scans the bus for a
   `iso9660` medium that carries `/boot/grub/grub.cfg` (that's us), mounts
   it read-only, then stacks a **writable tmpfs overlay** on top and
   `switch_root`s into the merged tree.
3. `copper-init` (our PID 1) mounts the basics, applies `/etc/hostname`,
   runs the OOBE wizard once (marker: `/etc/copper-firstboot.done`), then
   keeps a `copper-sh` login shell alive on tty1.

The overlay is why the session is writable even though the ISO is
read-only. Right now the upper layer is tmpfs (session-only); making it a
real disk partition is the persistence phase.

## What ships in the ISO (all compiled from source in `build.sh`)

| piece              | version  | source                                        |
|--------------------|----------|-----------------------------------------------|
| Linux kernel       | 6.12.10  | kernel.org (pinned LTS; `KREL` overrides)     |
| musl               | 1.2.5    | musl.libc.org                                 |
| busybox            | 1.36.1   | busybox.net                                   |
| coreutils          | 9.5      | ftp.gnu.org                                   |
| grep               | 3.11     | ftp.gnu.org                                   |
| sed                | 4.9      | ftp.gnu.org                                   |
| findutils          | 4.9.0    | ftp.gnu.org                                   |
| diffutils          | 3.10     | ftp.gnu.org                                   |
| tar                | 1.35     | ftp.gnu.org                                   |
| gzip               | 1.13     | ftp.gnu.org                                   |
| xz                 | 5.4.6    | tukaani-project/xz (GitHub releases)          |
| copper-sh          | —        | `src/` (our shell)                             |
| copper-init        | —        | `iso/src-init/` (our PID 1)                   |
| copper-firstboot   | —        | `iso/firstboot/` (OOBE wizard)                |

Userland is static musl binaries. Kernel config is a curated subset of the
x86_64 defconfig with `MODULES` disabled — the drivers we need are built in.

## Building

Needs a Linux box (or CI) with the source-build toolchain:

```sh
sudo bash iso/build.sh            # everything
sudo bash iso/build.sh kernel     # just one stage (reuses iso/work/)
```

Stages: `kernel | base | tools | copper | rootfs | initramfs | iso`.
Each stage skips work that's already done under `iso/work/`, which is how
CI re-runs stay cheap.

## Running in VMware

1. Download the `copper-iso` artifact from the build, save as `copper.iso`.
2. VMware Workstation / Player → **New Virtual Machine** → *Custom*.
3. Guest OS: **Linux → Ubuntu 64-bit** (just a generic x86_64 baseline).
4. Memory 2 GB, disk 20 GB (not used yet — persistence is later).
5. VM Settings → CD/DVD → *Use ISO image* → `copper.iso`. Set to boot
   from CD (first boot device).
6. Power on. Pick "Copper Linux" in GRUB. The live session boots, the
   wizard asks your name / username / hostname / passwords / timezone, and
   drops you into `copper-sh`.

Tip: the screen blanking timer can make the console look unresponsive —
press Enter when prompted, it's waiting for input.

## Current status

- CI builds the ISO end-to-end from source. The first fully green run is
  the milestone right now (see `HANDOFF.md`).
- Boot order verified by design only — the first real boot test happens
  when you load the artifact in VMware and report what the console says.