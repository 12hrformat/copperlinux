# Copper Linux — build internals

> handcrafted by 12hrformat

Everything under `iso/` contributes to a fully from-source Linux distro:

```
iso/build.sh                the whole pipeline, stage by stage
iso/live/init               live initramfs: find medium, overlay, hand off
iso/boot/grub.cfg           GRUB menu (normal + verbose)
iso/src-init/copper-init.c  our PID 1 (no systemd)
iso/firstboot/copper-firstboot.c   first-boot personalization wizard
iso/rootfs-overlay/         default /etc for the rootfs
iso/rootfs-overlay/usr/share/udhcpc/default.script   the DHCP lease script
```

## How the pieces fit

A Copper ISO is a `grub-mkrescue` image. It boots like this:

1. GRUB loads `vmlinuz` + `initrd.img` (the unpacked live system).
2. `/init` (a busybox ash script) mounts proc/sys/dev, scans the bus for a
   `iso9660` medium that carries `/boot/grub/grub.cfg` (that's us), mounts
   it read-only, then stacks a **writable tmpfs overlay** on top and
   `switch_root`s into the merged tree.
3. `copper-init` (our PID 1) mounts the basics, applies `/etc/hostname`,
   brings the network up, runs the OOBE wizard once (marker:
   `/etc/copper-firstboot.done`), then keeps a `copper-sh` login shell
   alive on tty1.

The overlay is why the session is writable even though the ISO is
read-only. Right now the upper layer is tmpfs (session-only); making it a
real disk partition is the persistence phase.

## Getting online

Nobody has logged in yet, but the machine should already be reachable, so
`copper-init` sorts the network out before the wizard runs:

- finds the first interface in `/sys/class/net` that isn't `lo`, waiting a
  couple of seconds for a cold one to turn up
- raises it with `SIOCSIFFLAGS` directly, so init needs no helper binary
- execs `/sbin/udhcpc -b`, which keeps asking in the background and never
  holds up the boot

`udhcpc` calls `usr/share/udhcpc/default.script` on every lease change; that
script assigns the address, installs the default route, and writes
`/etc/resolv.conf` from the nameservers the server offered. It turns the
netmask DHCP hands over into a prefix length, guessing /24 when a server
leaves it out — installing a /32 instead would push every packet through the
gateway. If a lease turns up without any nameservers, the fallback resolver
we ship in `rootfs-overlay/etc/resolv.conf` is left in place rather than
replaced with nothing.

`wget` speaks `https://` through busybox's built-in TLS, which encrypts the
connection but does **not** verify certificates — fine for pulling down a
kernel tarball, not something to trust with a password.

Worth checking once you're in:

```sh
ip a                      # did DHCP hand us an address?
ping 1.1.1.1              # raw IP
wget https://example.com  # DNS and TLS together
```

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

Two things in the build exist purely to catch trouble early:

- `lint_scripts` runs `sh -n` over `live/init` and the udhcpc lease script.
  Both are read by busybox ash on a machine nobody can log into yet, where a
  typo costs a boot.
- `require_kernel_config` / `require_bb_config` read the `.config` files back
  after kconfig has had its say and fail the build, listing what went
  missing, if an option Copper leans on didn't survive. A kernel with no
  `VGA_CONSOLE` or no `E1000` is a black screen and a dead NIC — much easier
  to catch as a build error.

## Running in VMware

1. Download the `copper-iso` artifact from the build, save as `copper.iso`.
2. VMware Workstation / Player → **New Virtual Machine** → *Custom*.
3. Guest OS: **Linux → Ubuntu 64-bit** (just a generic x86_64 baseline).
4. Memory 2 GB, disk 20 GB (not used yet — persistence is later).
5. VM Settings → Network Adapter: leave it on **NAT** (that has a DHCP server
   behind it). Bridged works too if your network hands out leases.
6. VM Settings → CD/DVD → *Use ISO image* → `copper.iso`. Set to boot
   from CD (first boot device).
7. Power on. Pick "Copper Linux" in GRUB. The live session boots, DHCP gets
   the box online while the wizard asks your name / username / hostname /
   passwords / timezone, and then you land in `copper-sh`.

Tip: the screen blanking timer can make the console look unresponsive —
press Enter when prompted, it's waiting for input.

## Current status

- CI builds the ISO end-to-end from source; that pipeline is green.
- `copper-init.c` compiles clean under GCC 12.2 (`-std=c11 -O2 -Wall
  -Wextra -Wpedantic -Wshadow -Wwrite-strings`, zero warnings).
- The DHCP lease script is tested on its own: every valid netmask, the
  malformed ones, and a full run of each lease state against a stub `ip`.
  `HANDOFF.md` lists what that caught.
- Ethernet + DHCP has never seen a real DHCP server. Neither has the boot
  path — `grub.cfg`, the initramfs `init` and the overlay are all still
  unrun. That's the next thing to try, and `ping 1.1.1.1` in the shell is
  the test.
- WiFi, Bluetooth, persistence and a desktop are still to do.