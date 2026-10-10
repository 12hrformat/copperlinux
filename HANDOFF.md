# Copper Linux — Handoff

> please note that SOME things in here are outdated and because this is a thousand lines of text, I cannot keep it all up to date. The most recent and accurate information is in the `BUGS.md` file, which is the source of truth for what is verified and what is not. If you are reading this file, please also read `BUGS.md` to see what is still unverified or broken. thank you

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
QEMU, with ingot as the package manager. Remaining work is the session user +
persistence, plus confirming the VMware framebuffer on real hardware.

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
- **The shipped ISO on VMware, to the framebuffer.** `vmwgfx` probes correctly
  and refuses on QEMU because QEMU is not VMware. The mouse is confirmed on
  real VMware; the *display* is the open half. See BUGS.md #21.
- **Xorg running as the wizard user.** The session still runs as root; the uid
  drop is designed and not built.
- **Anything on real non-VM hardware.** Every measurement in this document is
  a VM.
- **Persistence (G6) end to end.** Designed; disk not yet claimed at boot.

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
xarchiver. **Baked into the image:** XFCE itself, thunar, xfce4-terminal. The
offered list lives in `iso/rootfs-overlay/etc/copper/xfce-apps`. Default is to
ask first and install what's missing; on no, or if an install fails, the
desktop starts anyway — a component that won't install is a warning, not a
failure to launch.

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

## G6 — Persistence ⚠️ current work

**Done looks like:** a reboot keeps your files, and the 10 GB disk you gave
the VM actually gets written to instead of sitting there doing nothing.

The writable top layer of the overlay is a tmpfs today, so every session is
throwaway — and that is the same reason `ingot install firefox` died of ENOSPC
on a machine with a 10 GB disk: the upper is pure RAM, and firefox's payload +
unpack tree need ~570 MB of it. Stopgap (landed): cap the upper tmpfs at 50%
so a firefox-sized install fits in the current ISO. Real fix below.

**The plan: same overlay, different `upperdir` — the upper goes on a disk.**

- **The label is the handshake.** We declare a filesystem label, `COPPER`.
  `iso/live/init` scans the disks that aren't the boot medium at boot, and if
  one carries a `COPPER`-labeled ext4 partition it mounts that where the tmpfs
  used to go. No label → tmpfs fallback, ISO still boots anywhere. Label-first
  is the safety: we never touch a random disk with real data on it, because we
  only claim what we labeled ourselves.
- **The wizard picks the disk.** Last page of `copper-firstboot`: list the
  spare disks, the user picks one, we wipe + format ext4 with the `COPPER`
  label, and tell them it takes effect on the next boot. Explicit choice, not
  "grab the first disk we see".
- **It activates on the next boot, not mid-session.** Hot-swapping the upper
  under a live overlay is the kind of fragile shit we don't ship. Turn it on
  at boot, reboot once, and every boot after is persistent.
- **Where it goes:** `iso/live/init` does the detect-and-mount; the wizard's
  last page does the format (`mkfs.ext4 -L COPPER`, so the image needs an ext4
  mkfs); the label contract lives in one place so both halves agree.

**Boot-verification is the blocker.** Everything above is design; confirming it
needs a fresh CI-built ISO and a real boot.

## G7 — Land `patch-1`

It needs a PR from an account with write access to `12hrformat/copperlinux`,
or someone with that access pushing it.

## G8 — A desktop: XFCE ✅ / finishing

**Done looks like:** `startxfce4` brings up an XFCE session on the framebuffer.
Status: **Xorg boots and XFCE paints under QEMU** — measured, with the owner
confirming input and the PTY fix on real boots. What remains is running the
session as the wizard user instead of root, plus confirming the VMware
framebuffer on an actual VMware boot.

Order of the remaining work:

1. **Drop privileges in the session shell.** The uid drop is designed (see the
   brief below); needs building and a boot test.
2. **Xorg as the wizard user**, with device-node, xorg-wrapper, and X
   authority sorted.
3. Boot-test as that user, and confirm the VMware framebuffer on real VMware.

CI's six-hour cap is a real constraint on the heavy build stages; `restore-keys`
is what makes a warm cache survive an unrelated change (that bug is 2 in BUGS.md's
  tracker).

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
   `id -u` = 0. *Verify:* `sudo true` from the dropped shell.

**Success check for the implementer:** fresh image through the wizard; console
`id` shows the wizard username, not uid 0; `sudo whoami` answers `root`;
`startxfce` gives a desktop whose pointer and keyboard both work and whose
panel/terminal run as the wizard user. **Unverified today:** the uid drop,
Xorg-as-non-root device access, and the xorg-wrapper gate.

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
  script `switch_root` needs, and that `sbin/init` is a symlink to
  `/usr/bin/copper-init`. Uses `readlink`, not `-e` (bug 5 in BUGS.md's
  tracker).

---

# GUI: the files that matter, and the lines not to cross

**Yours:**

- `iso/startxfce.sh` — the launcher: device detection (207-215), generated
  xorg.conf (204-251), server start (269-273), session exec (355).
- `iso/build.sh` **gui stage only** (~895-995) — apt package list at 916,
  unpack, loader copy, gates.
- `tests/startxfce-gate.sh` — CI runs it every push; keep it green.

**Not yours — do not restructure:**

- `iso/build.sh` outside the gui stage: stamp helpers (~89-111),
  kernel/base/tools/copper/rootfs/initramfs/iso, the stage list at the bottom.
- `src/`, `iso/live/init/`, `iso/src-init/`, `iso/firstboot/` — the verified
  boot path. A regression there costs a boot.
- `.github/workflows/build-iso.yml` — shared; touch only to add your own test
  name, in the same commit as the test.
- `iso/out/` — build output, stays untracked.

---

# Repo map

```
iso/build.sh              stage pipeline: kernel|base|tools|copper|rootfs|gui|sudo|initramfs|iso|all
iso/sudo/sudoers          root ALL and %wheel ALL — the elevation contract for ingot
iso/rootfs-overlay/usr/bin/ingot   the package manager (shipped; gated by ingot-gate)
iso/rootfs-overlay/etc/ingot.conf  default Pages repo url, INGOT_REPO overrides
tests/ingot-gate.sh       31 assertions against a fake Pages repo (localhost)
iso/live/init             initramfs: find the ISO, lay a writable overlay, switch_root
iso/boot/grub.cfg         GRUB menu: normal, verbose, debug, initramfs-shell
iso/src-init/copper-init.c    our PID 1
iso/startxfce.sh           the XFCE launcher: probe the display, exec startxfce4
iso/x11/probe/xprobe.c     X server liveness probe, static, raw wire protocol
iso/firstboot/copper-firstboot.c   the OOBE wizard  (full run now verified)
iso/rootfs-overlay/       /etc and friends that land in the rootfs
iso/rootfs-overlay/usr/share/udhcpc/default.script   our DHCP lease script
src/                      copper-sh: main.c, builtins.c, builtins.h
tests/smoke.sh            19-assertion shell smoke test
tests/account-gate.sh     asserts the shipped account/answer path
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

**Give the guest a spare disk for the G6 persistence test.** A second virtual
disk (ext4 target, 10 GB is plenty) is what the wizard will offer to claim.

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