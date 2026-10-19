# Copper Linux — Handoff

> please note that SOME things in here are outdated and because this is a thousand lines of text, I cannot keep it all up to date. The most recent and accurate information is in the `BUGS.md` file, which is the source of truth for what is verified and what is not. If you are reading this file, please also read `BUGS.md` to see what is still unverified or broken. thank you
>
> PLEASE dont write bugs or random commecnt in README.md, dont write where things actually stand and stuff like that i like to keep it short
>
> Read this first, then `iso/README.md` for the build internals.
> Written by whoever had the machine last. Everything in it is either verified
> or explicitly marked as unverified — there is no third category.
> **All bug history, traps, and config gotchas live in `BUGS.md` now.**
> This file is only live status and current work.
> if youre contributing or changing anything, im not against the use of ai tools or anything but please make sure you read the code and understand it before you commit it. if you dont understand it, ask someone who does. if you dont know who to ask, ask me. if you dont know who i am, ask the team. if you dont know the who the team is ask yourself why youre here.

## What Copper actually is

This is our own Linux distro, built from source. Not a Debian or Arch rebrand,
and not a respin of either one: the kernel is upstream, but the `.config` is
ours, the userland is built through our own pipeline against musl, and the bits
that make it *Copper* are written by hand.

- real **Linux kernel** (6.12.10 LTS, from kernel.org) with **our `.config`**
- userland **built from source**: musl, busybox, coreutils and friends
- **our own** shell (`copper-sh`), **our own** PID 1 (`copper-init`), **our own**
  first-boot wizard, and **XFCE** as the desktop — launched by `startxfce`,
  which ships whether or not XFCE is installed yet
- **all the standard Linux commands**, real tools — no stubs, no placeholders
- **nine display drivers** built in, so a live image can bring up whatever
  machine it is put on
- boots as an **ISO** in VMware / VirtualBox / QEMU
- first boot personalizes like a real distro OOBE
- speaks to **drivers** (wifi, bluetooth, firmware) and reaches the **internet**

The desktop is done: XFCE is packaged into the ISO and paints a desktop under
QEMU and on real VMware (2026-10-11), with ingot as the package manager. The
session user is done and boot-verified. Persistence (bug 20) and the two-boot
`/tmp` case (bug 24) are boot-verified as well (2026-10-19).
A second, optional desktop — **Hyprland** — is now built into the image and
gated, but not yet booted; see *starthyprland* under "The desktop".

Upstream projects are reference material. Nothing gets packaged as-is, and
nothing gets stamped as Copper without being checked.

---

# Which branch is real

**Work is on `main`. That is the whole answer.** The `gui` branch was the
interim home of the display work; everything on it landed on `main` and then
the branch was **deleted from the remote** — `git ls-remote origin` answers
`main` and `untested`, nothing else. Any doc that still talks about `gui` as a
live branch is stale.

Remotes:

```
origin    https://github.com/12hrformat/copperlinux.git   (push works)
dragon    https://github.com/12hrformat/copperlinux.git   (same remote, a second name for it)
fork      https://github.com/farcrowx/copper.git          (never pushed to, do not start)
```

`untested` still exists out there. Treat anything on it as work that never
made it in.

---

# Where things actually stand

**The box boots, gets on the network, and runs the first-boot wizard.** A
VMware guest, 2 GB, NAT, booting the ISO, produced this:

```
copper: initramfs up, medium is /dev/sr0
copper: handing over to copper-init
copper: eth0 is up, asking DHCP for an address
copper-net: eth0 leased 192.168.127.132/24
copper-net: default route via 192.168.127.2
copper-net: nameserver 192.168.127.2

===================================================
          Welcome to Copper Linux
===================================================
Your name: dragon
Username [letters, digits, - _]: dragon
Hostname [copper]: copper
Password (root):
...
```

That whole line — kernel, initramfs, overlay, `switch_root`, our PID 1, DHCP,
netmask conversion, default route, resolver, the wizard — verified on hardware,
from artifacts that were taken apart and read before being trusted.

**What has actually been executed:**

- **The boot path, end to end, on a real machine.** Kernel → initramfs →
  overlay → `switch_root` → `copper-init`. The log above is the evidence.
- **DHCP against a real server.** A lease, `/24` derived from a
  `255.255.255.0` netmask, a default route, a resolver.
- **The full first-boot wizard.** All six questions answered, nothing refused,
  `Done — welcome`, no shell prompt afterwards. G1 is closed.
- **XFCE reaching a desktop under QEMU** (`-vga std`): boot → shell →
  `startxfce --check` reports `found the X server: /usr/bin/Xorg` and
  `found XFCE` → `startxfce` → the screen becomes the session, and OCR of the
  screendump read the xfdesktop icons ("Home", "File System"). Input devices
  are seen in `/proc/bus/input/devices`.
- **The VMware mouse fix** — owner-confirmed 2026-10-09, cursor follows the
  pointer on a real boot.
- **The devpts / PTY fix** — owner-confirmed: the XFCE terminal opens a real
  pty and `sudo` allocates ptys without error.
- **The display on real VMware** (2026-10-11): the boot that painted XFCE and
  ran Firefox was a VMware guest, so `vmwgfx` drives the panel there. Bug 21
  closed.
- **`copper charge` and `copper rollback` on a booted VM** — apply / backup /
  idempotent-skip / restore all confirmed on the live system (the four
  defects that made it non-functional in the first place are bug 10 in
  BUGS.md's tracker).
- **Ingot downloads on a live boot** (2026-10-10): index fetched, payload
  downloaded through the GitHub release redirect with a progress bar, retry
  and resume working. The install itself died of ENOSPC — that is G6 (below),
  not the downloader.
- **The framebuffer kernel** on the emulated adapters — `bochs-drm` on
  `-vga std`, `virtio-gpu` on `-vga virtio`, `qxl` on `-device qxl-vga` — each
  confirmed from the guest's own dmesg.
- **`copper-sh`** — compiled clean under GCC, run through a 44-command battery
  under AddressSanitizer (exit 0, no leaks). `tests/smoke.sh` (19 assertions)
  is the gate.
- **The whole CI build**, green end to end — kernel, musl, busybox, the GNU
  tools, the Copper binaries, rootfs, initramfs, GRUB ISO.

**What has never actually run:**

- **Real internet traffic, as the G2 trio defines it** — `ping -c 1 1.1.1.1`,
  `nslookup example.com` and a plain `wget` haven't all been run. The ingot
  payload downloads went over the real network and came through fine, but that
  specific three-command checklist is still unpaid.
- **The Hyprland session, on any machine.** The compositor and its config are
  built into the image and the launcher is gated (see *starthyprland* below),
  but no boot has started it: CI has no GPU and the Windows build box cannot run
  a glibc Wayland compositor. Built, not booted.
- **VirtualBox's `vboxvideo`**, which cannot be probed at all: QEMU has no such
  display device. Every other display in the matrix has now been seen, on QEMU
  or on real VMware.
- **Xorg running as the wizard user — closed, boot-verified (2026-10-11).** A
  real boot logs in as the wizard user (`id` answers the user, not root),
  `startxfce` with no `sudo` paints XFCE, and **Firefox and nmap run in the
  session**. That is bugs 19, 22 and 23 together: the uid drop, the ISO mode
  pins, and the `-sharevts` VT flag. See BUGS.md.
- **Anything on real non-VM hardware.** Every measurement in this document is
  a VM.
- ~~**Persistence (G6) end to end.**~~ Done — boot-verified 2026-10-19.

**A note on green CI runs:** a green run does not mean the artifact is
correct. Run `36220249701` was fully green and shipped an ISO built from the
previous commit's `init`. Always take the artifact apart before trusting it.

---

# The desktop

## The display matrix, and what is proven

Nine display options are requested **and asserted** in `require_kernel_config`.
The kernel was built and booted once per emulated device to see which drivers
actually claim hardware:

| Emulated device | Driver that bound | `/dev/fb0` |
|---|---|---|
| `-vga std` | `bochs-drm` | yes |
| `-vga virtio` | `virtio-gpu` | yes |
| `-device qxl-vga` | `qxl` | yes |
| `-device vmware-svga` | `vmwgfx` | **no, on QEMU** |
| `-device cirrus-vga` | *nothing* | no |
| VirtualBox | `vboxvideo` | **untestable** |

`DRM_BOCHS`, `DRM_SIMPLEDRM`, `DRM_VMWGFX`, `DRM_VIRTIO_GPU`, `DRM_QXL`,
`DRM_VBOXVIDEO`, `DRM_I915`, `FB_VESA`, `FB_EFI`.

The three honest limits: VMware is unproven until booted on real VMware;
VirtualBox cannot be tested at all (QEMU has no such display device); and
`FB_VESA`/`FB_EFI` were never exercised because the probe skips the BIOS. The
`DRM_VMWARE`→`DRM_VMWGFX` kconfig typo the assertion caught is the reason the
assertions exist — see BUGS.md.

## The architecture: musl-static base, glibc guest for X

Copper's userland is **musl-static**. Xorg, glib and GTK3 are not built for
musl-static, so the approach is **additive, not replacing**: keep busybox,
coreutils and the Copper binaries static-musl, and add a **dynamic glibc**
userspace beside them for Xorg and XFCE, with `ld-linux-x86-64.so.2` and the
needed `.so` files staged into the rootfs. A failure in the X stack costs a
shell, not the machine.

**Nothing physical blocks the size.** The live root is an **overlay on the
read-only ISO** (`lowerdir=/mnt/root`), not the initramfs, and `build_iso` runs
`grub-mkrescue` over the whole staged tree. A few hundred megabytes of
userspace costs ISO size and nothing else.

## `startxfce` — the command

`iso/startxfce.sh` installs as `/usr/bin/startxfce`. It starts the X server if
one is not already listening, then hands `DISPLAY` to `startxfce4` with `exec`.

Exit codes are a contract: **20** no X server in the image, **21** no XFCE,
**22** server never opened a display, **23** server exited while starting,
**24** usage error, **25** the app-install prompt had no terminal to ask on
without `--yes`/`--no`. `startxfce --check` reports what is present and starts
nothing. Verified: exit 20 path measured (12 ms); happy path measured under
QEMU; gate kept green by CI.

## App install offers (ingot)

`startxfce` offers optional apps from `copper-ingot-repo` before starting the
session. **Packaged:** firefox, mousepad, ristretto, xfce4-taskmanager,
xfce4-screenshooter, xfce4-notifyd, tumbler, xarchiver. **Baked into the image:**
XFCE itself, thunar, xfce4-terminal. The
offered list lives in `iso/rootfs-overlay/etc/copper/xfce-apps`. Default is to
ask first and install what's missing; on no, or if an install fails, the
desktop starts anyway — a component that won't install is a warning, not a
failure to launch.

## starhyprland — the second, optional session

Copper ships XFCE; **Hyprland** is the optional second desktop. The first-boot
wizard now asks which one — a **Desktop** row in the table, `xfce` or
`hyprland`, Enter for `xfce` — and records the answer as `/etc/copper-desktop`.
`copper-init` reads the first line of that file at the next boot: it names the
right launcher in its console hint, and starts `seatd` (when it is present, either
way, so both launchers work from the prompt). Anything unreadable or
unrecognised means XFCE, the desktop that is always present, so a half-written
marker is never a machine with no desktop. The wizard also puts the session user
in the `_seatd` group the seat daemon needs.

The compositor and its ecosystem come from **`ppa:cppiber/hyprland` for noble**
(Hyprland 0.56.2 — the version ML4W 2.17's Lua config requires, and a PPA built
against noble's glibc 2.39, so nothing else in the desktop stage moves), and the
ML4W config tree is fetched at a pinned commit from
`12hrformat/copper-hyprland-configs` and checked against a sha256. Both are the
**`hypr` build stage** (after `gui`): the PPA archive key is fetched by
fingerprint and its fingerprint is checked before it is trusted; the closure is
resolved with `apt-get --download-only` against an empty dpkg status file
exactly the way `build_gui` resolves XFCE's; the config is unpacked to
`/usr/share/copper/hyprland-skel`; and the stage gates itself with
`Hyprland --version` and `waybar --version` inside a chroot before it stamps.

Two things the closure carries only because the config is vendored and promised
unmodified: **`bash`** (every ML4W helper is `#!/usr/bin/env bash`; without it
the keybinds that shell out — `killactive`, `screenshot`, reload, `moveTo`, the
theme toggles — die as `bash: not found`) and **`jq`** (ML4W reads its own
settings with it). Copper's own scripts stay POSIX under busybox `ash`; this is
the one bash, ~1.4 MB, and it exists for the vendored tree alone.

The skel also carries intentional zero-byte files — ML4W's Lua `require()` stubs
(`hyprland-gui.lua`, the `conf/*/default.lua` includes) and markers whose
*presence* is the setting (`waybar-disabled`, `software.sh`) — so the `rootfs`
stage exempts that subtree by path from **both** of its empty-file checks: the
gate *and* the sweep that runs just before it (bug 26, finished as bug 40 — the
sweep's guards were written for `find .` against a tree named by an absolute
path, so nothing was exempt and the skeleton lost its stubs on any rebuild that
re-ran `rootfs` while `hypr`'s stamp still matched). Three things now keep it
whole: the sweep exempts the subtree; `build_hypr` counts a missing
`conf/environments/default.lua` as "not staged" and re-unpacks the skeleton; and
the `iso` stage extracts that stub back off the disc and fails the build if it is
not there. The `hypr` stage also prunes the same legacy zero-byte
`usr/share/mime/icons` map the `gui` stage prunes, because it re-runs
`update-mime-database` and would otherwise re-create it.

`starthyprland` (`iso/starthyprland.sh`, POSIX sh) is the launcher, the twin of
`startxfce`: it seeds the shipped config tree into the user's home, makes
`XDG_RUNTIME_DIR`, brings up a session bus, checks the `seatd` socket, forces
the software renderer on a machine with a DRM node but no render node, then
execs the compositor. Its exit codes are a contract — **20** no Hyprland, **21**
no config, **22** no runtime, **23** died on the way up, **24** usage, **25** a
missing component and no terminal to ask on — and `tests/starthyprland-gate.sh`
asserts every one against a stubbed compositor, alongside the prep ordering and
the environment the compositor is handed.

Seeding is **additive and repeatable**, and that took a second pass to get right
(bug 36). It used to be `cp -a -n "$SKEL"/. "$HOME"/`, and only when
`~/.config/hypr/hyprland.lua` was missing — which meant a home seeded by an
image whose empty-file gate had dropped ML4W's zero-byte Lua `require()` stubs
stayed broken forever: the `hyprland.lua` that was there kept the seeding branch
from running, and busybox's `cp -n` skips an existing **directory** outright, so
even a re-run would have copied nothing. `seed_config()` instead walks the
shipped tree, makes the directories that are missing, and copies only the files
and symlinks that are absent — never overwriting a file that is there — and it
runs as a repair pass on every start, saying nothing unless it added something.

When the user has no session config yet, the launcher asks — on a terminal —
whether to install it from ingot: `would you like your hyprland config files?
(Y/n)`, Enter meaning yes. Yes runs `ingot install hypr-configs`, which refreshes
the skel from `12hrformat/copper-ingot-repo`; no keeps the config the image
baked. Off a terminal, or given `--yes`/`--no`, it picks without asking. All four
paths are in `tests/starthyprland-gate.sh`. The package it drives is real now —
page `iso/copper/pkg/desktop/hypr-configs`, payload
`hypr-configs-9c2e40f.tar.gz` on the `payloads-v1` release — verified against its
sha256 but not boot-tested.

Two deliberate limits, both recorded rather than left to be found on a machine:

- **Quickshell is not built.** ML4W 2.12+ uses it for the bar, but its pinned
  commit requires Qt 6.6 (`QT_MIN_VERSION "6.6.0"`) and noble ships Qt 6.4.2, so
  building it means dragging a second Qt into the image — a change of its own.
  **Waybar is the bar here.**
- **No systemd, no logind.** The seat comes from `seatd`, the bus from
  `dbus-launch` by hand, and ML4W's startup path is its own
  `hyprland.lua`/`conf/autostart.lua`, not systemd units — exactly as it is on a
  systemd distro, where ML4W's installer masks its own units anyway. The `uwsm`
  session manager is therefore not used.

**Input needs two things, and only one of them is obvious.** The seat (group +
seatd + the drm node) lets the compositor open the devices; libinput then has to
*accept* each one, and it accepts only devices whose udev record exists —
bug #30 — **and names a device type** — bug #34. That second half is the one
that looks like a working boot when it is missing: the compositor starts, seat
and DRM are fine, and the pointer simply does not move. So
`seed_udev_input_db()` (copper-init.c) does not just write the `I:` line any
more: it reads each device's sysfs capabilities and classifies it exactly the
way udev's `input_id` builtin would — keyboard, mouse, touchpad, joystick and
the rest — writing `ID_INPUT_KEYBOARD=1` and its fellows into the record. PID 1
reports `wrote N record(s), M naming a device type` at boot, and warns loudly
when M is 0; `starthyprland.sh` warns from the user's side. The unit test drives
the classifier with real keyboard/mouse bitmaps (`tests/init-session.c`), but
the whole chain — record → libinput → moving pointer — is still **not
boot-verified**: that is the open half of bug #34, and a boot is not done until
the log shows `M` greater than 0 and the pointer moves.

**Built, not booted.** Nothing here has run on a real machine: CI has no GPU,
and the compositor is a glibc Wayland binary the Windows build box cannot run.
What is proven is the build (the chroot gate) and the launcher (the gate); the
session itself is the boot nobody has done yet.

---

# Goals

Ordered by what unblocks the most.

## G1 — Confirm the first-boot wizard ✅ closed

Verified: a full run on the framebuffer kernel answered all six questions,
refused nothing, and left no shell prompt — the desktop came up instead.

## G2 — Prove the internet, not just DHCP

**Done looks like:**

```sh
ping -c 1 1.1.1.1          # raw IP, no DNS
nslookup example.com       # resolver works
wget -O - http://example.com   # HTTP end to end
```

We have a lease, a route and a resolver. The ingot payload downloads on a real
boot are the closest thing so far to end-to-end internet, but the trio above
has not all been run together. Cheap version: add a reachability probe to the
lease script's `bound` handler so the next log answers it; honest version: run
the three commands at a `copper-sh` prompt and paste the output.

## G3 — Static-IP escape hatch

**Done looks like:** a `/etc/network`-style file (interface, address, netmask
or prefix, gateway, nameservers) that `copper-init` reads and applies instead
of starting `udhcpc`, when present and non-empty. Missing file means DHCP.

## G4 — WiFi

**Done looks like:** the box associates with an AP and gets a lease without
manual fiddling. Roughly: `CFG80211` plus the wireless driver in the kernel
`build.sh`; **wpa_supplicant** from source (static musl); keep busybox
`udhcpc` for the IP afterwards (it demonstrably works); drop the card's
firmware blobs (a `linux-firmware` subset) into the rootfs. NetworkManager is
the heavy end state and not required to get onto a network. The
interface-selection bug that broke wired DHCP is already handled for wifi:
`first_nonloop_iface()` asks sysfs for the `ARPHRD_*` type and prefers
`ARPHRD_ETHER` over `ARPHRD_IEEE80211_RADIOTAP`.

## G5 — Bluetooth

**Done looks like:** `bluetoothctl` sees a paired device. BlueZ built from
source, `CONFIG_BT=y` with the protocol drivers. BlueZ wants a D-Bus daemon;
that's the part to budget time for.

## G6 — Persistence ✅ boot-verified 2026-10-19

**Done looks like:** a reboot keeps your files, and the 10 GB disk you gave
the VM actually gets written to instead of sitting there doing nothing.

The writable top layer of the overlay is a tmpfs, so every session is
throwaway — and that is the same reason `ingot install firefox` died of ENOSPC
on a machine with a 10 GB disk: the upper is pure RAM, and firefox's payload +
unpack tree need ~570 MB of it. Stopgap (landed): cap the upper tmpfs at 50% so
a firefox-sized install fits. Real fix, now in the tree: the upper moves to a
disk.

- **The label is the handshake.** A disk carrying the ext4 label `COPPER` is
  claimed as the overlay upper. `iso/live/init` probes every non-medium disk for
  it and falls back to the tmpfs when there is none, so the ISO still boots
  anywhere. Label-first is the safety: we only ever claim a disk we labelled
  ourselves.
- **The wizard takes the disk, and only asks when asking matters.** Last page of
  `copper-firstboot`. With exactly one spare whole disk that is empty (`blkid`
  finds no filesystem) it is automatic: it prints the disk, counts down 5
  seconds with `press Enter to skip`, then runs `mkfs.ext4 -q -F -L COPPER`.
  Anything else — two candidates, or one that already has files on it — falls
  back to the list, where the disk must be named and `ERASE` typed. The medium
  it booted from, anything mounted, and the disk the marker names as `upper=`
  are never candidates, and the page only runs on a real Copper boot (`/init`
  leaves `/var/lib/copper/live-boot`). The `upper=` check is the belt for bug
  35, where the disk `/init` had already attached still reached the list.
- **It finishes the job itself.** After formatting, the wizard copies the few
  files it wrote (`/etc/passwd`, `shadow`, `group`, hostname/hosts, timezone,
  the done-marker, the desktop answer, `/home`) onto the fresh disk, then
  reboots. So the disk carries the account *and* the done-marker: the next boot
  comes up as a finished machine instead of asking every question a second time.
  Both steps are best effort — if the copy fails the next boot is just the old
  behaviour (wizard runs again).
- **It activates on the next boot, not mid-session.** Hot-swapping the upper
  under a live overlay is the kind of fragile shit we don't ship. The wizard's
  own reboot is how the disk becomes live; every boot after is persistent.
  `COPPER_PERSIST_SECONDS` shortens the countdown and `COPPER_PERSIST_NO_REBOOT`
  suppresses the reboot — both for the test bench, which must not be rebooted
  by a test run, and neither is set on a real boot.
- **Two build facts it rests on:** busybox's `mke2fs` applet only makes ext2 and
  overlayfs refuses that as an upper, so the real `mkfs.ext4` (e2fsprogs, gui
  stage) is mandatory and the gui stage now fails the build without it; and PID
  1 remounts a fresh tmpfs over `/run`, so the marker lives on the overlay
  (`/var/lib/copper/live-boot`), never in `/run`. See BUGS.md config facts.
- **Tested where it can be:** `tests/persist.sh` drives the real wizard against
  stub `mkfs.ext4` and stub `blkid` in a mount namespace — nothing real is
  formatted, and the machine is never rebooted (`COPPER_PERSIST_NO_REBOOT`) —
  and runs in CI via `tests/branch-gate.sh`. It covers the automatic take, the
  countdown being stoppable, a disk that already has files going back to the
  list, two disks listing, a hand-typed unoffered disk being refused, and the
  marker's `upper=` disk never being offered.

**Boot-verified 2026-10-19.** CI run 131's ISO on a VMware guest with a spare
NVMe disk (SCSI would not have worked — no VMware SCSI host driver in the
kernel): boot 1 the wizard formatted the spare, boot 2 `/init` claimed it
(`/var/lib/copper/live-boot` read `upper=/dev/nvme0n1`), `df -h /` showed the
overlay at 20 GB with 19 GB free instead of a ~1 GB tmpfs, and a file written
in that session came back after a further reboot. The two-boot desktop case
came along on the same boots: `startxfce` started a fresh X server rather than
reusing the stale `/tmp` socket — bug 24's test, also closed.

**Automatic take + self-reboot (2026-10-19, needs a boot).** The wizard used to
list the disks and make the first boot pick one and type `ERASE` — too much of a
setup screen for what is meant to be a finished machine. It now takes a single
empty spare disk on its own and reboots into it, carrying the wizard's answers
across so the next boot does not ask again. In the tree and covered by
`tests/persist.sh`; not yet seen on a real boot.

Two findings from that boot, logged in BUGS.md: the wizard re-offered the very
disk /init had mounted (bug 35 — the pick was skipped, nothing formatted; the
marker's `upper=` is now a second, stronger check that cannot miss it), and
`sudo reboot` printed systemd errors and did nothing (bug 18's first real-boot
evidence).

## G7 — Land `patch-1`

It needs a PR from an account with write access to `12hrformat/copperlinux`,
or someone with that access pushing it.

## G8 — A desktop: XFCE ✅ / finishing

**Done looks like:** `startxfce4` brings up an XFCE session on the framebuffer.
Status: **done and boot-verified (2026-10-11).** A real boot of the current ISO
logs in as the wizard user, `startxfce` (no `sudo`) paints XFCE, and **Firefox
and nmap run in the session** — bugs 19, 22 and 23 closed. That boot was a
VMware guest, which also settles the VMware framebuffer — bug 21 closed. What
remains is the edges, not "does it work": ~~a persisted `/tmp` making the second
boot reuse a dead display (bug 24)~~ — the two-boot test passed 2026-10-19 —
and `sudo shutdown`/`sudo reboot` (bug 18, fixed in the tree, still failing on
a real boot: see its 2026-10-19 evidence).

Order of the remaining work — 1–3 are done (boot-verified 2026-10-11):

1. ~~Drop privileges in the session shell.~~ Done — bug 19.
2. ~~Xorg as the wizard user, device nodes and VT flags sorted.~~ Done — bug 23.
3. ~~The VMware framebuffer.~~ Done — bug 21, on the same VMware boot.
4. ~~the persisted `/tmp` two-boot case (bug 24)~~ — boot-verified
   2026-10-19, fresh server on the second boot. `sudo shutdown`/`reboot`
   (bug 18) still owes a working boot: on that same boot `sudo reboot`
   printed systemd errors and did nothing; only `reboot -f` worked.

CI's six-hour cap is a real constraint on the heavy build stages; `restore-keys`
is what makes a warm cache survive an unrelated change (that bug is 2 in BUGS.md's
  tracker).

### The root session, first real casualty: Firefox (verified 2026-10-11)

Running the session as root stopped being a paper problem on a real boot. A
VMware guest given **8 GB of RAM** (still on the RAM overlay — persistence is
not on yet) reached the network, `ingot install firefox` went through, `startxfce`
painted XFCE — and then the browser would not start:

```
dragon@copper:~$ firefox
Running Firefox as root in a regular user's session is not supported.  ($HOME is /home/dragon which is owned by dragon.)
```

Clicking the browser icon fails too, with XFCE's generic **"Input/output
error."** Two different messages, one cause: the process is uid 0 while `$HOME`
is the wizard user's home, `/home/dragon`, owned by `dragon`. Firefox
hard-refuses that combination — this is the uid drop below that was designed and
never built. Neither Firefox nor ingot is at fault.

So the 8 GB bought a *finished install* and an *unusable browser*. Until the
session actually runs as the wizard user, no browser ships working on Copper —
and that makes the privilege drop below a blocker for the desktop, not polish.
`HOME=/root firefox` is the obvious stopgap; it has **not** been boot-tested and
is not a fix (it just moves the profile to `/root`). Recorded, not patched —
until 2026-10-11:

**Fix (2026-10-11), boot-verified.** The drop is built as the
brief below decided, plus the two pieces the brief flagged as the hard part.

- `spawn_tty`'s child now drops to the wizard user
  (`initgroups`/`setgid`/`setuid`) before the `exec`, reading the login name
  from `/etc/copper-firstboot.done`. No marker user — a first boot before the
  wizard, or a stale account — and the child stays root, which is what the
  image did before.
- Xorg runs as that user, so `copper-init` chowns `/dev/input/*`, `/dev/dri/*`,
  `/dev/fb*` and the tty/VT nodes to the session user at boot. There is no
  udev, so those are root-owned and a non-root Xorg comes up with a dead
  pointer and no keyboard otherwise. It also makes `/dev/shm` and
  `/run/user/<uid>` first — `startxfce` used to, but as the user it cannot
  `mkdir` under the root-owned `/dev` or `/run`.
- `startxfce` adds `-keeptty -sharevts -novtswitch` when it is not root. With no
  logind on this image, a non-root Xorg cannot grab or switch the console VT —
  the `VT_ACTIVATE` ioctl needs `CAP_SYS_TTY_CONFIG` — and Xorg calls `setsid()`
  on itself first. `-sharevts` is the flag that actually skips the grab
  (`xf86OpenConsole()` guards it with `if (!xf86Info.ShareVTs)`); `-novtswitch`
  alone does not, and a real boot died on exactly that — bug 23. `-keeptty`
  keeps the controlling terminal the login shell already owns. As root none of
  these are passed; that path is unchanged.

The brief's third worry, the xorg-wrapper console-user gate, turns out not to
exist here: there is no `Xorg.wrap` in the image. `/usr/bin/Xorg` is a 274-byte
`sh` script that `exec`s `/usr/lib/xorg/Xorg` directly, so nothing checks the
console user.

**Now boot-verified** (see the third boot result below): the drop itself,
Xorg-as-non-root opening the device nodes, and the VT flags.
`tests/init-session.sh` covers the in-process drop in CI; the rest is a
real-boot fact.

**First boot result (2026-10-11).** The drop landed — a real boot of the
`711fcb9` ISO printed `id` as the wizard user, so the session is no longer
root. It then exposed bug 22: `sudo` in the image is not setuid (grub-mkrescue
writes the live root as rationalised Rock Ridge and flattens the mode), so
`sudo whoami` failed and `startxfce` could not install its components. Fixed in
`build_iso` (bug 22); the boot test for that is still pending. The same
flattening made `/tmp` `555`, which likely killed the non-root Xorg before it
painted, and reading the rebuilt ISO back out showed the switch to `-R` then
exposed stale ownership (`/etc/*` owned by uid 1000, from the cache restore) and
a `0644` `/etc/shadow`, so `build_iso` now pins ownership `root:root`,
`/etc/shadow` `0600` and `/tmp` `1777` too.

**Second boot result (2026-10-11): `sudo` is fixed; the VT flags are not.** A
real boot of the setuid-fixed ISO installed its components through the `sudo`
password prompt — bug 22's setuid half verified — and got Xorg much further than
before: it opened its own log under `/home/dragon/.local/share/xorg/`, read the
input config and found the keyboard and mouse, then died on `xf86OpenConsole:
Switching VT failed`. That is bug 23: the launcher was passing `-novtswitch`,
which never disables the VT grab; `-sharevts` does. It is in the launch line now
(`-keeptty -sharevts -novtswitch`) and asserted by `tests/startxfce-gate.sh`, not
booted yet. That same boot wrote its input config to `/etc/X11/xorg.conf` —
expected on that artifact, whose `/etc` was still owned by uid 1000; after the
`553528f` ownership pin the non-root session falls back to `/tmp/xorg.conf`,
which the launcher already handles.

**Third boot result (2026-10-11): green.** A real boot of the current ISO (the
`-sharevts` line plus the `553528f` ownership/mode pins) logs in as the wizard
user, `startxfce` with no `sudo` paints XFCE, and **Firefox and nmap run in the
session** — bugs 19, 22 and 23 closed together. That guest is VMware, so the
display half of bug 21 is closed as well. ~~Still unverified on a boot: the
persisted `/tmp` two-boot case (bug 24)~~ — both verified 2026-10-19, on the
persistence boots (`sudo shutdown`/`reboot` / bug 18 remains open: `sudo
reboot` still did nothing there).

### The desktop session runs as root — brief for the implementer

Status 2026-10-10. Decision is made (owner): **the wizard-created user owns
the session; PID 1 keeps root; sudo is the elevator.** Anything marked
*verify* is a real-boot fact to establish, not something this document claims.

**Why the session is root today (verified):** `spawn_tty` (`copper-init.c:220-238`)
`setsid()`, opens `/dev/tty1`, dup2s it onto 0/1/2, `TIOCSCTTY`, then `execl`s
`/usr/bin/copper-sh` — with no `setgid`/`setuid` anywhere, so the child stays
uid 0. The home-directory block (`copper-init.c:331-356`) only `chdir`s to
`/home/<user>` and sets `HOME`/`USER`/`LOGNAME`; identity never changes.

**What must change, in order:**

1. **Drop privileges in the spawned shell child, not in init.** PID 1 stays
   root. The drop belongs in the `spawn_tty` child between `TIOCSCTTY` and the
   `execl`. Read the username from `/etc/copper-firstboot.done` (first line),
   `getpwnam` for uid/gid, `initgroups` (same supplements the wizard uses:
   `{"wheel","users","audio","video","dialout","cdrom"}` —
   `copper-firstboot.c:979`), `setgid`, `setuid`, then exec. Fall back to uid 0
   only when no marker user exists (first boot before the wizard).

2. **Xorg as the wizard user is the hard part.** `startxfce.sh` already
   anticipates a non-root login; Xorg is launched plainly as the current user,
   which is the right call (no Xauthority dance). What fights a non-root Xorg:
   - **Device nodes.** The static xorg.conf pins evdev to `/dev/input/event*`,
     and modesetting needs `/dev/dri/card*`. devtmpfs defaults these
     root-owned (`0660 root:root` typical; *verify perms on the booted image*).
     The baked `/etc/group` has `video` but **no `input` group**, and the
     wizard supplements list has neither. So a non-root session can't open the
     evdev nodes → frozen cursor, no keyboard/mouse. Options: add an `input`
     group, chgrp the nodes at boot, or chmod. First thing to boot-verify.
   - **The xorg-wrapper console-user gate activates.** As root the check is
     skipped; as the wizard user it runs and may fail closed with no logind.
     *Verify:* does a non-root `startxfce` reach a live display? Either a
     setuid Xorg wrapper (X stays root) with `-auth`/`XAUTHORITY`, or handle
     the gate.
   - **X authority.** If X runs as root while XFCE runs as the user, clients
     need `-auth`/`XAUTHORITY`. If X and XFCE share the wizard uid, nothing
     extra is needed. Decide first, then wire.

3. **sudo already ships and should just work.** Setuid-root sudo,
   `%wheel ALL=(ALL:ALL) ALL`, wizard puts the user in `wheel`, and the devpts
   fix means sudo can allocate ptys. `startxfce.sh:60-63` clears `SUDO` when
   `id -u` = 0. *Verify:* `sudo true` from the dropped shell. **[2026-10-11:
   it did not, and not because of sudo's config — the ISO flattened the
   setuid bit on the way onto the disc. That is bug 22; fixed in `build_iso`.
   2026-10-11 boot: `sudo` now prompts and installs, so this half is verified.
   The ownership / `/etc/shadow 0600` / `/tmp 1777` hardening from `553528f`
   still has not booted.]**

**Success check for the implementer:** fresh image through the wizard; console
`id` shows the wizard username, not uid 0; `sudo whoami` answers `root`;
`startxfce` gives a desktop whose pointer and keyboard both work and whose
panel/terminal run as the wizard user. **Status:** implemented 2026-10-11 and
still unverified — see the fix note above. A real boot has since confirmed the
`sudo` half and exposed bug 23 (the VT grab); the `-sharevts` fix is in, not
booted. The xorg-wrapper gate turned out not to exist in this image, so it is
not a variable.

---

# ingot — our package manager

Pacman was removed (2026-10-08, owner's call) and replaced by **ingot**,
distributed through **GitHub Pages**:

1. `ingot install nmap` goes to a GitHub Pages URL like
   `https://<pages>/iso/copper/pkg/hacking/nmap` — one JSON file per package.
2. ingot downloads the JSON to `/tmp`, reads the **real url** where the
   payload lives (Releases/CDN).
3. ingot downloads the payload, checks **sha256** against the JSON (mismatch →
   refuse), installs, and **deletes the JSON from `/tmp`**.

Pages carries only tiny index files; heavy payloads live behind the "real
url". This is the design dragon specified — **write NO other package path
without asking.**

Status: **built, gated, and released.** `iso/rootfs-overlay/usr/bin/ingot` is
the shipped client (POSIX sh, busybox-ash clean), with
install/remove/update/reinstall/inspect/info/search/list. `dl()` retries with
resume (`-C -`) and renders a progress bar on a terminal. `tests/ingot-gate.sh`
(31 assertions) is green in WSL as root and non-root. The live Pages repo
(`copper-ingot-repo`) has the index with all five payload packages; payloads
live on the `payloads-v1` GitHub release and their sha256 digests match the
pages, verified offline.

Carried over from the pacman work, still true:

- The GUI stage's glibc closure gives the rootfs libssl/libcrypto/libz/liblzma/
  libzstd/libbz2 and `/lib64/ld-linux-x86-64.so.2`, so glibc-linked payloads
  run.
- Runtime network is proven; busybox wget takes the openssl helper path on a
  normal image (openssl + ca-certificates ship), which verifies certificates.
  The internal-TLS fallback still exists if the helper's exec fails, and that
  path does not verify — bug 16 in BUGS.md's tracker, and see the wget note
  in Config facts.
- The remaining blocker on a full `ingot install firefox` is space, not
  downloads (G6).

---

# The build gates

- `lint_scripts` — `sh -n` over the initramfs `init` and the lease script.
  Both are read by busybox ash on a machine with no shell to log into.
- `require_kernel_config` / `require_bb_config` — read the `.config` files
  back after kconfig has had its say and refuse to continue, listing what went
  missing.
- `build_copper` — checks the staged tree contains the binaries and lease
  script `switch_root` needs, that `/sbin/shutdown` is installed (bug 18), and
  that `sbin/init` is a symlink to `/usr/bin/copper-init`. Uses `readlink`, not
  `-e` (bug 5 in BUGS.md's tracker).

---

# GUI: the files that matter, and the lines not to cross

**Yours:**

- `iso/startxfce.sh` — the launcher: device detection (207-215), generated
  xorg.conf (204-251), server start (269-273), session exec (355).
- `iso/starthyprland.sh` — the Hyprland launcher, the twin of `startxfce`:
  seed config, runtime dir, bus, seatd check, renderer choice, exec.
- `iso/build.sh` **gui stage only** (~895-995) — apt package list at 916,
  unpack, loader copy, gates.
- `iso/build.sh` **hypr stage only** (~1261-1620) — the cppiber PPA key pin, the
  empty-status closure, the config fetch-and-hash, the `_seatd` group, chroot
  gates.
- `iso/rootfs-overlay/etc/copper/hypr-apps` — what `starthyprland` offers.
- `tests/startxfce-gate.sh` — CI runs it every push; keep it green.
- `tests/starthyprland-gate.sh` — the Hyprland launcher's prep and exit codes,
  against a stubbed compositor; runs via `tests/branch-gate.sh`.
- `tests/xprobe-gate.sh` — drives the real `xprobe` binary against a synthetic
  X server; runs via `tests/branch-gate.sh` and the ISO workflow. Keep it green.

**Not yours — do not restructure:**

- `iso/build.sh` outside the gui and hypr stages: stamp helpers (~89-111),
  kernel/base/tools/copper/rootfs/initramfs/iso, the stage list at the bottom.
- `src/`, `iso/live/init/`, `iso/src-init/`, `iso/firstboot/` — the verified
  boot path (the wizard gained one additive question, the Desktop row, and the
  `_seatd` group; the rest of it is not to be restructured). A regression there
  costs a boot.
- `.github/workflows/build-iso.yml` — shared; touch only to add your own test
  name, in the same commit as the test.
- `iso/out/` — build output, stays untracked.

---

# Repo map

```
iso/build.sh              stage pipeline: kernel|base|tools|copper|rootfs|gui|hypr|plymouth|sudo|initramfs|iso|all
iso/sudo/sudoers          root ALL and %wheel ALL — the elevation contract for ingot
iso/rootfs-overlay/usr/bin/ingot   the package manager (shipped; gated by ingot-gate)
iso/rootfs-overlay/etc/ingot.conf  default Pages repo url, INGOT_REPO overrides
tests/ingot-gate.sh       31 assertions against a fake Pages repo (localhost)
iso/live/init             initramfs: find the ISO, lay a writable overlay, switch_root
iso/boot/grub.cfg         GRUB menu: normal, verbose, debug, initramfs-shell
iso/src-init/copper-init.c    our PID 1
iso/startxfce.sh           the XFCE launcher: probe the display, exec startxfce4
iso/starthyprland.sh       the Hyprland launcher: seat, bus, renderer, exec
iso/rootfs-overlay/etc/copper/hypr-apps   components starthyprland offers
iso/x11/probe/xprobe.c     X server liveness probe, static, raw wire protocol
iso/shutdown.sh            /sbin/shutdown: maps flags onto busybox halt/poweroff/reboot
iso/firstboot/copper-firstboot.c   the OOBE wizard  (full run now verified)
iso/rootfs-overlay/       /etc and friends that land in the rootfs
iso/rootfs-overlay/usr/share/udhcpc/default.script   our DHCP lease script
src/                      copper-sh: main.c, builtins.c, builtins.h
tests/smoke.sh            19-assertion shell smoke test
tests/account-gate.sh     asserts the shipped account/answer path
tests/shutdown-gate.sh    proves /sbin/shutdown maps flags to the right applet
tests/startxfce-gate.sh   21 cases: the launcher's display states and exit codes
tests/starthyprland-gate.sh the Hyprland launcher's prep and exit codes, vs a stub
tests/xprobe-gate.sh      the real xprobe binary vs a synthetic X server
.github/workflows/build-iso.yml   per-stage CI steps + workspace cache
```

---

# Tooling and how to drive a boot

## Getting the ISO

Artifacts download fine now, using the Git Credential Manager token. Capture
the token into a variable and never print it:

```sh
out=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill)
tok=$(printf '%s\n' "$out" | sed -n 's/^password=//p')
curl -sL -H "Authorization: Bearer $tok" \
  https://api.github.com/repos/farcrowx/copper/actions/artifacts/<id>/zip -o iso.zip
```

## The VM

VMware Workstation, guest OS **Linux / Other Linux 6.x kernel 64-bit**, 2 GB,
2 processors, **NAT** networking (bridged may not answer DHCP), and the ISO on
the CD drive with **Connected at power on** ticked.

**Give the guest a spare disk for the G6 persistence test.** ✅ Done
2026-10-19 — but add it as **NVMe**, not SCSI: the kernel has no VMware SCSI
host driver, and a SCSI disk is invisible to the guest (config fact in
BUGS.md). The wizard now takes it on its own (one empty disk, five-second
countdown, then it reboots into the disk), so there is nothing to pick and
nothing to type: the session came back with its files and `/` was the disk, not
RAM. That was the boot that closed bug 20.

Then **Add… → Serial Port**, "This end is connected to" → **Output to file** →
a `.txt` path (VMware insists on `.txt` and will warn the file doesn't exist;
accept it, it creates it) → **Connect at power on**. The `copper:` and
`copper-net:` lines reach the file on every entry, so paste the file rather
than photographing a screen.

## Tooling on the build machine

- **Git for Windows** gives a real POSIX shell at
  `C:\Program Files\Git\bin\bash.exe`. That allows `sh -n` on the shipped
  scripts and — more usefully — unit testing shell logic with a stub binary on
  `PATH`, no VM and no compiler.
- **This box cannot create a symlink at all** — `ln -s` fails regardless of
  privilege, because Windows wants Developer Mode for native symlinks. Tests
  of symlink behaviour have to stub `readlink`; the real thing is CI's to
  prove, and it does.
- No local C toolchain: no gcc/clang/tcc, no WSL, no container runtime. C
  verification goes through Compiler Explorer's API, which is **glibc, not
  musl**, so it cannot validate musl-specific code. CI is the real oracle.
- PowerShell gotchas that cost time: no heredocs (write the message to a file
  and use `git commit -F`); inline `bash -lc` with quotes and `$` gets mangled
  (write a `.sh` and invoke it); `curl.exe` mangles JSON in `--data-raw` (write
  the body to a file, use `--data-binary @file`).

---

# Rules to keep

- No AI slop.
- Keep Copper's identity distinct. Arch and Debian are reference material, not
  packaging material.
- **Verification over vibes.** Compile clean, run the battery under ASan before
  claiming a command works, and never ship a fake or placeholder command. A
  command that exists but doesn't work is worse than a missing one, because it
  lies.
- **Read the artifact, not the CI run.** A green build has shipped a stale ISO
  here. It will again.
- When something is unverified, say so in the commit message and in this file.
  The gap between "it builds" and "it boots" is what this project has been
  living on.
- If you make a file that wasn't already made, write "handcrafted by [ your name ]" and if you update a file that had bugs, please write "updated by [ your name, the bug, the line where the bug was ]".

THANK YOU