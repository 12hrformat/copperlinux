<img width="1512" height="807" alt="Screenshot 2026-10-10 123948" src="https://github.com/user-attachments/assets/af3e5fea-db73-4694-913a-8b0f190f804f" />

<h1 align="center">Copper Linux</h1>

<p align="center">
  A daily-driving Linux distro, built from source, by a small team.
</p>

<p align="center">
  <a href="https://12hrformat.github.io/copperlinux-site/">Copper Linux website</a>
</p>

---

Copper is our distro. Not a Debian or Arch rebrand — we build the kernel, the
libc, and the userland from source, and we write the bits that make it
*Copper* ourselves: the shell, the init, and the first-boot setup. Arch and
Debian are fine systems, we just wanted to do it our way.

It's for daily driving — for Linux nerds, coders, and students who want
something that feels like theirs.

The source code of Arch Linux and Debian was used for reference, nothing more.

Copper has a twin: **deadlight linux**, a cybersecurity-focused distro by the
same team. Same base, different goal — basically a reskin, but with the useful
tools already on it.

---

## Where things actually stand

| Part | Status |
|---|---|
| `copper-sh` (shell) | Works. Arrow-key line editing, history, pipes, redirects. |
| Networking | Wired works — DHCP on boot, `ping`/`nslookup`/`wget` present. |
| `copper charge` / `copper rollback` | Ship in the ISO. Logic tested end to end off-ISO; not yet run on a booted system. |
| First-boot wizard | Verified end to end: all six questions answered, nothing refused, no shell prompt after — the desktop came up instead. |
| Desktop (XFCE) | **Works under QEMU.** Boot → shell → `startxfce` → the screen becomes the session. VMware display is still unproven (see below). |
| X server (Xorg) | **Builds and boots.** 1.21.1.9 with `modesetting_drv.so` and `libfbdevhw.so`, starts under QEMU. |
| `startxfce` | Ships, names what's missing, and returns a distinct exit code — a missing piece never looks like a broken PATH. |
| Wiring (PTY, input) | PTY fix confirmed on a real boot; VMware mouse fix confirmed by the owner. |
| Install (`ingot`) | Downloads work — progress bar, retry, resume. Installing can still die of ENOSPC because the writable layer is RAM; persistence (G6) puts it on a real disk. |
| Base system (kernel, musl, userland) | Built from source, CI green end to end. |
| Bootable ISO | Builds successfully. Boots in a VM. |
| WiFi | **Not yet.** Wired only, no `wpa_supplicant`. |

### Display drivers, and what's actually proven

The first framebuffer build enabled `DRM_BOCHS` alone. That driver binds to
exactly one device — QEMU's Bochs VGA, PCI `1234:1111` — and every measurement
behind it was taken under QEMU `-vga std`, which is that one adapter. It
booted to a shell on any other machine, because nothing in the kernel matched
its display hardware and `copper-init` correctly fell back.

The kernel now builds in nine display options and asserts every one of them,
so a silently dropped symbol stops the build instead of shipping a shell.
Measured on one kernel, one boot per emulated device:

| Emulated device | Driver that bound | `/dev/fb0` |
|---|---|---|
| `-vga std` | `bochs-drm` | yes |
| `-vga virtio` | `virtio-gpu` | yes |
| `-device qxl-vga` | `qxl` | yes |
| `-device vmware-svga` | `vmwgfx` | **no, on QEMU** |
| `-device cirrus-vga` | *nothing* | no |
| VirtualBox | `vboxvideo` | **untestable** |

Three honest limits on that table:

- **VMware is unproven.** `vmwgfx` probes the adapter correctly and then
  prints `*ERROR* vmwgfx seems to be running on an unsupported hypervisor`
  and stops. It checks the hypervisor vendor, and QEMU is not VMware. The
  driver is the right one; only a real VMware guest can confirm it delivers
  a framebuffer.
- **VirtualBox cannot be tested at all.** QEMU has no VirtualBox display
  device — `-device vboxvga` is rejected as an invalid model name.
  `DRM_VBOXVIDEO` is a claim that it compiles, nothing more.
- **`FB_VESA` and `FB_EFI` were never exercised.** The test boots with
  `-kernel` directly, so no BIOS runs, and those two need a VGA BIOS. Only a
  real ISO boot through GRUB reaches them.

`cirrus-vga` has no driver and is a real gap. It's QEMU's legacy default
rather than anything a current VM hands out, so it's recorded rather than
fixed.

## Boot, and starting a desktop

First boot asks its questions, then lands on a **`copper-sh` prompt**. That's
the current default and it's deliberate: the X stack is proven under QEMU but
not on every machine, so a failure in it costs a shell rather than the
machine.

| Command | What it does |
|---|---|
| `startxfce` | Starts the X server if one isn't already running, then XFCE on it. |
| `startxfce --check` | Reports what's installed and exits, starting nothing. |

`startxfce` exits **20** if there's no X server in the image, **21** if XFCE is
missing, **22** if the server started but never opened a display, **23** if the
server exited while starting, and **24** on a usage error. That's a contract —
a script can branch on the exit code without parsing a message.

Boot entries in GRUB:

| Entry | What you get |
|---|---|
| Copper Linux | Wizard if needed, then a shell |
| Copper Linux (verbose) | As above, with kernel messages |
| Copper Linux (debug) | Everything logged, panic-on-hang so a wedge reboots and shows its face |
| Copper Linux (initramfs shell) | A shell inside the initramfs, skipping the overlay — splits "kernel/initrd broken" from "our /init broke" in half |

---

## What's in this repo

```
Copper Linux
├── kernel           — Linux from kernel.org, our own .config
├── libc             — musl, built from source
├── userland         — coreutils, busybox, grep, sed, tar, ...
├── copper-sh        — our shell
├── copper-init      — our init, lives at /sbin/init
├── copper-firstboot — first-boot setup wizard
├── copper           — copper charge / rollback front end
├── ingot            — our package manager (GitHub Pages repo)
├── hotfixes.json    — the hotfix database `copper charge` reads
├── copper.iso       — bootable live ISO (VMware / VirtualBox / QEMU)
```

The build pipeline (`iso/build.sh`) is staged — `kernel`, `base`, `tools`,
`copper`, `rootfs`, `gui`, `sudo`, `initramfs`, `iso`, or `all` — and skips a
stage if it's already built, so re-runs on CI are cheap.

**Kernel:** Linux 6.12.10 LTS, with a trimmed config: ISO9660, overlayfs,
tmpfs, devtmpfs, virtio/e1000/vmxnet3 NICs, ATA/SATA, ext4, ptys. Drivers are
built in, no loadable modules.

**Base:** musl 1.2.5, busybox 1.36.1 (static, with adduser, chpasswd, mount,
hostname), coreutils 9.5, grep 3.11, sed 4.9, findutils 4.9.0, diffutils 3.10,
tar 1.35, gzip 1.13, xz 5.4.6 — all compiled from source and linked statically
against musl.

Run it locally with:

```sh
sudo bash iso/build.sh
```

or check the Actions logs for a CI run. A finished build uploads `copper.iso`
(~57 MB) as an Actions artifact.

---

## copper-init

Our own PID 1, not systemd. It mounts the basics, sets the hostname, runs the
first-boot wizard once, then keeps a `copper-sh` login shell alive on tty1.
Lives at `/sbin/init`.

The live initramfs (`iso/live/init`) finds the boot medium and builds a
writable overlay — read-only ISO root, tmpfs on top — before handing off to
`copper-init`. Persistence (G6) is the plan to move that writable layer onto a
real disk partition.

---

## copper-sh

A small POSIX-style shell, written in C. Mostly builtins for now, so it can do
useful things before the rest of the userland is on the system. Anything not
built in falls through to `execvp` and runs from `$PATH`.