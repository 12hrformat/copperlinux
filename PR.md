# PR #2 — Copper OS: a from-source Linux distro that boots and gets online

> Use the title and description below for pull request **#2** (`copper-os` → `main`)
> on the `Copper-linux/copper` repo.

## Title

**Copper OS: a from-source Linux distro — kernel, musl userland, our own shell, init, and first-boot wizard**

## Description

### What this is

Copper is its own Linux distro — not a rebrand of Debian or Arch. Every binary
on the ISO is compiled from upstream source inside our own build pipeline, and
the pieces that make it *Copper* are written by hand:

- **copper-sh** — our shell (~500 lines of C, 36 builtins, pipes/redirects/
  quoting, history). Verified with real GCC 12.2 and a 44-command
  AddressSanitizer battery (exit 0).
- **copper-init** — our PID 1 (no systemd). Mounts the basics, applies the
  hostname, **brings the network up**, runs the first-boot wizard once, then
  keeps a copper-sh login shell alive on tty1. Lives at `/sbin/init`.
- **copper-firstboot** — the OOBE: asks for name, username, hostname,
  timezone, and passwords, then creates the account with busybox
  adduser/chpasswd.

### What's inside the ISO

| Piece | Built from | Notes |
|---|---|---|
| kernel **6.12.10 LTS** | kernel.org | our `.config`, `MODULES` off, drivers built in (virtio, e1000/e1000e, vmxnet3, ATA/SATA, NVMe, ext4, overlayfs, tmpfs, ptys) |
| C library | **musl 1.2.5** | compiled from source, static |
| base utilities | **busybox 1.36.1** | static; adduser/chpasswd/mount/hostname, plus `ip`/`ifconfig`/`udhcpc`/`ping`/`wget`/`nslookup` |
| command line | coreutils 9.5, grep 3.11, sed 4.9, findutils 4.9.0, diffutils 3.10, tar 1.35, gzip 1.13, xz 5.4.6 | all compiled from source, static against musl |
| bootloader | GRUB | BIOS + UEFI, "normal" and "verbose" menu entries |

No placeholder or stub commands — the full standard command set is real tool
code, statically linked against musl.

### How it boots

`copper.iso` → GRUB → kernel → a small initramfs that finds the Copper medium,
lays a writable tmpfs over the read-only ISO root (the same overlay mechanism
will later become persistence), then hands off to `copper-init`. First boot
runs the personalization wizard like a real distro's OOBE.

### Getting online

The box is on the network before anyone logs in. `copper-init` picks the first
non-loopback interface, raises it with a `SIOCSIFFLAGS` ioctl (no subprocess,
no dependency on where busybox's applet links landed), and hands off to
`udhcpc -b`, which keeps asking in the background and never blocks the boot.
The wizard runs concurrently, so DHCP negotiates while the user is still
typing their name.

`udhcpc` calls our own lease script
(`usr/share/udhcpc/default.script`, written for Copper rather than lifted from
busybox's example) on every lease change: it assigns the address, installs the
default route, and writes `/etc/resolv.conf` from the nameservers the server
offered. A lease that turns up without any leaves the fallback resolver we
ship alone, rather than replacing it with nothing.

Check it from the shell with `ip a`, `ping 1.1.1.1`, and
`wget https://example.com`. Note that `wget`'s TLS is busybox's internal
implementation: it encrypts the connection but does not verify certificates.

### Failing loudly at build time

A kernel that boots to a black screen, or that comes up with no NIC able to
speak DHCP, is miserable to debug from inside a VM — you get a dead machine
and no error message. So the build checks its own work:

- `sh -n` over the shipped shell scripts (the initramfs `init` and the DHCP
  lease script), since a typo in either costs a whole boot.
- `require_kernel_config` / `require_bb_config` read the `.config` files back
  after kconfig has had its say and fail the build with a readable list if an
  option Copper depends on didn't survive.

### CI

`build-iso.yml` builds the whole distro from source on GitHub Actions — one
step per stage so a failure names itself, with a workspace cache so re-runs
skip finished stages. The last run is green end to end and uploads
**`copper.iso` (~29 MB)** as a build artifact.

### Try it

1. Download `copper-iso` from the run's Artifacts section and unzip it.
2. New VMware VM, Ubuntu 64-bit guest, ≥2 GB RAM, **NAT or bridged networking**.
3. Attach `copper.iso` to the CD/DVD drive and power on.
4. Walk the first-boot wizard, then try `ping 1.1.1.1`.

Note: the artifact expires after 14 days; re-trigger the workflow to rebuild.

### Honest next steps

- The boot path (grub.cfg + initramfs + overlay) and the DHCP path were both
  written without a VM to test in — the VMware boot test is the first
  real-world check and may need fixes.
- After it boots cleanly: WiFi (`CFG80211` + a wireless driver built in,
  wpa_supplicant from source, firmware blobs), then Bluetooth (BlueZ from
  source), then a GUI/desktop.
- Real persistence: a writable disk as the overlay upper layer, i.e. an
  install-to-disk mode.

*Handcrafted by 12hrformat.*
