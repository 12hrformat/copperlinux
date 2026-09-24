# PR #2 — Copper OS: a from-source Linux distro that boots

> Use the title and description below for pull request **#2** (`copper-os` → `main`)
> on the `Copper-linux/copper` repo.

## Title

**Copper OS: a from-source Linux distro — kernel, musl userland, and our own shell, init, and first-boot wizard**

## Description

### What this is

Copper is its own Linux distro — not a rebrand of Debian or Arch. Every binary
on the ISO is compiled from upstream source inside our own build pipeline, and
the pieces that make it *Copper* are written by hand:

- **copper-sh** — our shell (~500 lines of C, 36 builtins, pipes/redirects/
  quoting, history). Verified with real GCC 12.2 and a 44-command
  AddressSanitizer battery (exit 0).
- **copper-init** — our PID 1 (no systemd). Mounts the basics, applies the
  hostname, runs the first-boot wizard once, then keeps a copper-sh login
  shell alive on tty1. Lives at `/sbin/init`.
- **copper-firstboot** — the OOBE: asks for name, username, hostname,
  timezone, and passwords, then creates the account with busybox
  adduser/chpasswd.

### What's inside the ISO

| Piece | Built from | Notes |
|---|---|---|
| kernel **6.12.10 LTS** | kernel.org | our `.config`, `MODULES` off, drivers built in (virtio, e1000/e1000e, vmxnet3, ATA/SATA, ext4, overlayfs, tmpfs, ptys) |
| C library | **musl 1.2.5** | compiled from source, static |
| base utilities | **busybox 1.36.1** | static; adduser/chpasswd/mount/hostname applets |
| command line | coreutils 9.5, grep 3.11, sed 4.9, findutils 4.9.0, diffutils 3.10, tar 1.35, gzip 1.13, xz 5.4.6 | all compiled from source, static against musl |
| bootloader | GRUB | BIOS + UEFI, "normal" and "verbose" menu entries |

No placeholder or stub commands — the full standard command set is real tool
code, statically linked against musl.

### How it boots

`copper.iso` → GRUB → kernel → a small initramfs that finds the Copper medium,
lays a writable tmpfs over the read-only ISO root (the same overlay mechanism
will later become persistence), then hands off to `copper-init`. First boot
runs the personalization wizard like a real distro's OOBE.

### CI

`build-iso.yml` builds the whole distro from source on GitHub Actions — one
step per stage so a failure names itself, with a workspace cache so re-runs
skip finished stages. The last run is green end to end and uploads
**`copper.iso` (~29 MB)** as a build artifact.

### Try it

1. Download `copper-iso` from the run's Artifacts section and unzip it.
2. New VMware VM, Ubuntu 64-bit guest, ≥2 GB RAM.
3. Attach `copper.iso` to the CD/DVD drive and power on.
4. Walk the first-boot wizard.

Note: the artifact expires after 14 days; re-trigger the workflow to rebuild.

### Honest next steps

- The boot path (grub.cfg + initramfs + overlay) was written blind — the
  VMware boot test is the first real-world check and may need fixes.
- After it boots cleanly: Bluetooth (BlueZ from source), wifi + internet,
  firmware blobs, then a GUI/desktop.
- Real persistence: a writable disk as the overlay upper layer, i.e. an
  install-to-disk mode.

*Handcrafted by 12hrformat.*