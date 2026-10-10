# Copper Linux — Handoff

> Read this first, then `iso/README.md` for the build internals.
> Written by whoever had the machine last. Everything in it is either verified
> or explicitly marked as unverified — there is no third category.

## What Copper is

Our own Linux distro, built from source. Not a rebrand of Debian or Arch, and
not a respin of them: the kernel is upstream but the `.config` is ours, the
userland is compiled in our own pipeline against musl, and the pieces that
make it *Copper* are written by hand.

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

XFCE is packaged into the ISO and paints a desktop under QEMU; the VMware case
has one open bug. See "Working in parallel" below for the current status;
"XFCE" is the history of how it got here.

Upstream projects are reference material. Nothing gets packaged as-is.

---

# Read this part: the branch, and why it isn't on upstream

**Current work is on `gui`, and `gui` is pushed.**

```
origin    https://github.com/12hrformat/copper.git     (push works - this is where gui lives)
dragon    https://github.com/12hrformat/copper.git      (no gui branch)
fork      https://github.com/farcrowx/copper.git        (never pushed to, do not start)
```

`git ls-remote origin refs/heads/gui` answers `3d27857`, which is the tip of
this branch. Earlier notes saying `origin` answers `push=False` are out of date.

`gui` is 12 commits ahead of `origin/main`:

```
3d27857 remove copper-gui: it drew a picture of a desktop, it was not one
9fcb04c gui: stop the pointer being dragged back to the centre
71fbf64 tests: fix the startxfce gate, which was testing the wrong paths
2c57c83 gui: boot to a shell, and add the startxfce command
24bf586 iso: define REPO, so the build gates that use it can run at all
187829b tests: restore the two test files this branch never had, and make them executable
6939a1e docs: record the display driver matrix, and what it does not prove
e64ee94 kernel: add the display drivers the desktop actually needs
98bbc04 tests: make account-gate.sh executable, so CI can run it
fdeb329 iso: turn the framebuffer on, so the desktop actually boots
7278290 gui: wire the desktop into the boot, and find out what it costs
86ec08a gui: a desktop that draws straight into /dev/fb0
```

The first four of those are cherry-picks of work from `untested`, onto `main`'s
tree — which had **diverged** from `untested`, so `iso/build.sh` and
`iso/src-init/copper-init.c` both needed real merges rather than a clean apply.
Two things about that cherry-pick, because they will confuse a re-run:

- **`7ff1879` ("firstboot: remove the boot art") was skipped, correctly.**
  `main` never had the art files — `iso/firstboot/boot-art.h`,
  `tools/gen-boot-art.py` and `tests/art-gate.sh` were all verified absent on
  `origin/main` — so the commit had nothing to remove. Not a compromise.
- **`main`'s firstboot wizard is the old 240-line version**, with no
  questions table, no terminal sizing and no splash. `untested` has a 1033-line
  one. So `gui` has the simpler wizard, and that was accepted rather than
  re-landing six commits to get the other one.

The older work is still on `untested` (14 commits ahead of the old `main`), and
PR #10 (`untested` → `main`) is still open.

To pick up the work:

```sh
git fetch origin
git checkout -B gui origin/gui
```

`origin/gui` already carries everything above, so there is nothing to
cherry-pick. The conflict advice below still applies if `main` moves first:

Expect conflicts in `iso/build.sh`, `iso/src-init/copper-init.c`,
`iso/firstboot/copper-firstboot.c`, `HANDOFF.md`, `README.md` and
`.github/workflows/build-iso.yml`. Resolve by keeping `main`'s layout
(`local SRC="$ROOT/../src"`, no `$REPO` variable) and taking the GUI additions
on top of it.

---

# Where things actually stand

**The box boots, gets onto the network, and runs the first-boot wizard.** A
VMware guest, 2 GB, NAT, booting the ISO, has produced this:

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

That is kernel, initramfs, overlay, `switch_root`, our PID 1, DHCP, netmask
conversion, default route, resolver, and the wizard — verified on hardware,
from artifacts that were taken apart and read before being trusted.

## What has never run

1. **`copper charge` on a booted system.** The logic is verified end to end
   off-ISO (see below) but has never run against a live root.
2. **Real internet traffic.** We have an address, a prefix, a default route
   and a nameserver. Nothing has yet proved that a name resolves or that a TCP
   connection completes. `ping 1.1.1.1` and a `wget` are still unrun.
3. **A boot of the real ISO on VMware.** Everything measured is QEMU with a
   direct `-kernel` boot. GRUB, the VGA BIOS, and real hardware have all been
   bypassed.
4. **Xorg running inside Copper.** It builds and links; it has not been booted
   against Copper's kernel. See "XFCE" below.

The first-boot wizard is no longer on this list. A full run was verified on the
framebuffer kernel: all six questions answered, nothing refused, no shell prompt
afterwards, and 17 of 17 exact pixel assertions on the resulting desktop.

---

# The desktop, and the bug that hid in it

## What happened

`iso/gui/copper-gui.c` was written, wired into the boot, and verified — 17 of 17
exact colour assertions at fixed coordinates, including four corner markers,
plus a text console that renders and accepts keystrokes with every glyph matched
against the kernel's own `font_8x16`.

It has since been **deleted**, and the deletion is deliberate. Every string it
drew was a constant — eight rows of `readme.txt`, a taskbar wired to nothing —
and `compute_layout()` ran once, with no window manager behind it. It rendered
pixels of a desktop rather than being one. `iso/gui/` is gone, along with the
build stage that compiled it and the `gui=1` boot path. XFCE is the desktop.

What remains worth keeping from that work is the kernel half. Then, it booted
to a shell:

```
copper: no /dev/fb0, starting the shell
```

## Why, which is the part worth keeping

`copper-init` was correct. It looked for `/dev/fb0`, found none, and started a
shell, which is the right thing to hand a machine with no framebuffer.

The kernel had exactly **one** display driver: `DRM_BOCHS`. It binds to exactly
one PCI device, `1234:1111` — QEMU's Bochs VGA. It is not "the QEMU display
driver" and it is not a generic framebuffer.

Every measurement behind that change was taken under QEMU `-vga std`, which *is*
that one adapter. So the work looked finished, and was, for the one machine it
had been tested on.

Under VMware the guest gets a different display device, nothing binds,
`/dev/fb0` never appears, and the fallback runs. **The failure was
indistinguishable from a machine with no graphics at all**, and nothing in the
log said "no driver for your display". That is what made it easy to miss, and it
is the general lesson: a correct fallback can hide a missing capability perfectly,
because a correct fallback is indistinguishable from a machine that does not
have the thing.

## What was changed

Nine display options are now requested **and asserted** in
`require_kernel_config`, and the kernel was built and booted once per emulated
device to see which drivers actually claim hardware:

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

### Three limits on that table, none of them hidden

- **VMware is unproven and cannot be proven here.** `vmwgfx` probes the adapter
  correctly — it reads the FIFO, the VRAM and the SVGA version — and then
  prints:

  ```
  vmwgfx 0000:00:03.0: [drm] *ERROR* vmwgfx seems to be running on an unsupported hypervisor.
  ```

  It checks the hypervisor vendor and QEMU is not VMware. So the driver is the
  right one and it works right up to the check that requires real VMware
  hardware. Only booting the ISO on the user's machine settles it.
- **VirtualBox cannot be tested at all.** This QEMU has no VirtualBox display
  device: `-device vboxvga` is rejected as an invalid model name. There is
  nothing to run it against.
- **`FB_VESA` and `FB_EFI` were never exercised.** The probe boots with
  `-kernel`, so no BIOS runs and there is no VGA BIOS to take a mode from. Only
  a real boot through GRUB reaches those two.

`cirrus-vga` genuinely has no driver. It is QEMU's legacy default rather than
anything a current VM hands out, so it is recorded as a gap rather than fixed
with a 15-minute rebuild for a device nobody will boot.

### The assertion earned its place immediately

`require_kernel_config` was inverted to *demand* every driver rather than
request it. On the first run of the new kernel it stopped the build:

```
FAIL: kconfig dropped: DRM_VMWARE
```

**`DRM_VMWARE` is not a symbol.** The real one is `DRM_VMWGFX`. `scripts/config`
accepted the wrong name without complaint, `olddefconfig` dropped it without a
word, and the build would have gone green with no VMware driver in the image —
which is the exact shell this work exists to stop, on the exact machine that
reported it. The check caught it in one minute; nobody would have caught it
otherwise.

## The other half: whatever draws must not log to the screen

fbcon keeps painting `tty0`. If a program's stdout is the framebuffer console,
every line it prints lands on top of whatever was just drawn. That was a real
black band across the title bar, and the rule it established still holds for
the XFCE side: a graphical process routes stdout to `/dev/ttyS0`..`ttyS3` and
failing that to `/dev/null`, never to `/dev/console`. The path that did this for
the old desktop was `start_gui()`, which went with the deletion; `startxfce`
follows the same rule.

---

# XFCE — the requested end state, and what it actually costs

The ask is a real desktop with a start command, `startxfce4`. XFCE is an X
client, so it needs an X server, and that is where the cost is.

## What has been established

- **Xorg 1.21.1.9 builds** against this toolchain, with **both** driver paths
  present in the output: `modesetting_drv.so` and `libfbdevhw.so`. Read back
  from the build tree, not assumed from the switches.
- It links **dynamically against glibc** and needs 21 shared libraries,
  including `libsystemd.so.0` and the loader. That list is the shopping list
  for the rootfs.
- The full X/GTK build dependency chain is installable and verified by
  `pkg-config`: `glib 2.88.3`, `gtk+ 3.24.52`, `cairo 1.18.4`, `pango 1.58.0`,
  `pixman 0.46.4`, `xcb 1.17.0`, `libdrm 2.4.134`, `xfont2`, `epoxy`, `gbm`.

## What has not

**The server has never been booted against Copper's kernel.** A server that
compiles is a server that links. Whether it opens the device, finds a mode it
likes at this resolution, and serves the wire protocol is unmeasured.

The next step is a boot test whose check is **on the wire protocol** — `xdpyinfo`
connecting and being told the screen geometry — because a screenshot cannot
distinguish a healthy server from one that drew something and then died. `xdpyinfo`
fails unless a display genuinely exists and answers.

## The architectural decision, and why it is lower-risk than "switch to glibc"

Copper's userland is **musl-static**. Xorg, glib and GTK3 are not built for
musl-static, so *something* has to give. The chosen approach is **additive, not
replacing**: keep busybox, coreutils and the Copper binaries static-musl, and
add a **dynamic glibc** userspace beside them for Xorg and XFCE, with
`ld-linux-x86-64.so.2` and the needed `.so` files staged into the rootfs.

The reasoning is that the static-musl boot path is the one thing in this project
that is known to work end to end. Replacing it wholesale puts the working shell,
the working init and the working wizard at risk to make room for a guest.
Adding beside them means a failure in the X stack costs a shell, not the machine.

**Nothing physical blocks the size.** The live root is an **overlay on the
read-only ISO** (`lowerdir=/mnt/root`), not the initramfs, and `build_iso` runs
`grub-mkrescue` over the whole staged tree. A few hundred megabytes of userspace
costs ISO size and nothing else. The initramfs stays small.

## `startxfce` — the command, and what it does today

`iso/startxfce.sh` installs as `/usr/bin/startxfce`. It starts the X server if
one is not already listening, then hands `DISPLAY` to `startxfce4` with `exec`,
so when XFCE exits the command exits with the same status.

**It ships before XFCE does**, and that is the point rather than a compromise.
There is no X server and no XFCE in the image, so the only behaviour available
to test is failure. It exits **20** for no X server, **21** for no XFCE, **22**
for a server that never opened a display, **23** for a server that exited while
starting, **24** for a usage error. `startxfce --check` reports what is present
and starts nothing.

Without that, the honest failure was `sh: /usr/bin/startxfce4: not found` and
exit 127 — indistinguishable from a broken PATH, a missing library, or a server
that would not start. Each missing piece now names itself.

### What the launcher got wrong, and where the tests were no help

- **A running X server hid the missing XFCE.** The installation checks were
  inside the branch that starts a server, so the "a server is already running"
  path skipped them and went straight to `exec`. Xorg up and XFCE absent — the
  state of the image the moment anyone starts a server by hand — produced the
  raw `not found` and exit 127. A running server is not a desktop. The checks
  now run first and unconditionally.
- **A stale socket was trusted.** `/tmp/.X11-unix/X0` survives any session that
  did not exit cleanly, and X does not remove it. Checking that the file exists
  means reusing a dead display: XFCE starts, connects to nothing, and hangs with
  nothing to report. It now asks the display with `xdpyinfo` when that exists,
  and falls back to the socket test when it does not.
- **Both of those were found by reading, not by running.** The test suite had
  nothing for them: case 6 reused a live server but also had a session present,
  and no case had a live server with XFCE absent.

### What is verified, precisely

- **`startxfce` with nothing installed: measured.** Exit 20, correct message,
  12 ms. That is the state of the image today.
- **`gui=1` parsing: measured.** Nine command lines through the real parser —
  the default gives a shell, `gui=1` and bare `gui` give the desktop, `nogui`
  and `gui=0` give a shell, and `fpgui=1`, `rogui=1`, `xn--gui=1`, `foo=gui=1bar`
  all give a shell. The last four are why the parser matches whole tokens rather
  than substrings.
- **`copper-init.c`: compiles clean** under `gcc -std=c11 -Wall -Wextra`.
- **The rest of `startxfce-gate.sh`: not yet run to completion.** It has never
  finished a pass. CI will be the first full run, on a runner with no desktop
  for the stubs to disturb.

### Root is not a problem for Xorg

Worth recording because it looks like one. `hw/xfree86/xorg-wrapper.c` gates the
console-user check on `if (getuid() != 0)`, so running as root skips it
entirely. Copper's init is root, so Xorg can start — and root is what it needs
anyway to open `/dev/dri/card*`.

## The honest scale

This is a multi-day project, not a flag. XFCE is one of the heavier desktops to
build from source: roughly 25 modules over a chain that includes glib, GTK3,
pango, cairo, gdk-pixbuf, at-spi2, harfbuzz, the Xcb stack and the X11 client
libraries, each built from upstream tarball into the rootfs.

Minimum set that makes `startxfce4` mean something: `xfconf`, `libxfce4util`,
`libxfce4ui`, `exo`, `garcon`, `xfwm4`, `xfce4-panel`, `xfce4-session`,
`xfce4-settings`, `xfce4-desktop`, `thunar`, `xfce4-appfinder`, `xfce4-terminal`.

**The CI time limit is a real constraint, not a formality.** GitHub Actions
hosted runners cap at six hours, and every one of these builds from source on
every run unless the cache carries it. `restore-keys` is what makes a warm cache
survive an unrelated change — do not "fix" a slow build by removing it. See
bug #2.

---

# Four checks I wrote that reported a cause they had not established

All four were in checks written specifically to avoid inventing causes. They are
recorded because the failure mode repeats and the pattern is the thing to avoid.

**1. A driver probe that read a stub config.** `make O= defconfig` had failed
with *"The source tree is not clean, please run 'make mrproper'"* and left a
746-byte `.config` behind. The symbol check read that stub and concluded kconfig
had dropped `FONT_8x16`. It had dropped nothing. The symptom was real — a font
symbol genuinely absent from a real config would be worth stopping for — and the
cause was invented. Both `defconfig` and `olddefconfig` now check exit status
*and* that they produced a config over 1000 lines before any symbol is read.

**2. A framebuffer check that grepped for a path the kernel never prints.** The
detector looked for the literal string `/dev/fb0`. The kernel prints `fb0`:

```
fbcon: bochs-drmdrmfb (fb0) is primary device
```

So it reported **"fb0: no" for the device whose own log says fb0 is the primary
device**. It was measuring the wording of a log line rather than the existence of
a device, and would have reported a working framebuffer as missing.

**3. Three dependency checks that asked for pkg-config modules that have never
existed.** `libX11`, `libXext`, `libxcb`, `libxau`, `libxdmcp`, `libepoxy`,
`libgbm`, `libXfont2`, `libpciaccess` — the real module names are `x11`, `xext`,
`xcb`, `xau`, `xdmcp`, `epoxy`, `gbm`, `xfont2`, `pciaccess`. Every one of those
libraries was installed the whole time. The check stopped the build three times
on dependencies that were already present. The names were then looked up from
`pkg-config --list-all` instead of assumed.

**4. A meson configure that stopped on options which do not exist.** `-Dfbdev`
and `-Dllvm` are not options in xorg-server 21.1.9. `fbdev` support is not a
switch at all — it is part of the Xorg DDX and comes with `-Dxorg=true` — and
the `llvm` option existed in the autotools build, not the meson one. Guessing
names from the old build system is what produced it. Every option is now checked
against the project's own `meson_options.txt` before meson runs.

The pattern in all four: **grepping for a string I imagine a tool prints, rather
than reading what it printed.** The fix each time was to dump the raw evidence
and look at it.

---

# What was messed up, and what fixed it

Nine commits, and most of them exist because something was quietly wrong in a
way that looked like something else. Worth reading in order — several of these
cost a boot cycle each, and the reasons generalise.

## 1. The overlay directories were created before the tmpfs went over them

`iso/live/init` did `mkdir -p /mnt/upper/upper` and then
`mount -t tmpfs … /mnt/upper`. Mounting hides what was underneath, so the
overlay came up with no `upperdir` and died:

```
overlays: failed to resolve '/mnt/upper/upper': -2
```

Fix: mount the tmpfs **first**, then `mkdir` inside it. The whole staging
order is that one trick. `3ae61c1`.

## 2. CI shipped an ISO built from the *previous* commit

The nastiest one, because **the run was fully green**. `restore-keys:
copper-work-` deliberately restores the previous tree — that is what saves a
7-minute kernel build — but the stage guards were existence-only
(`[ -s "$TGT/boot/initrd.img" ] && skip`). Key changed, old tree restored, file
present, stage skipped. An ISO went out with an initrd packed from the old
`init`.

Fix: `stamped_skip` / `stamp_set` / `tree_hash` in `build.sh`. Every stage
stamps its output with a hash of its own inputs. `d9b1ce1`.

**Do not "fix" this by deleting `restore-keys`.** The fallback is not the bug;
it is what makes a warm cache survive an unrelated change. The stamps are what
make it sound.

## 3. `$0` is not a path you can hash after a `cd`

`SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")` is pinned before the
script `cd`s, because CI runs `sudo bash iso/build.sh kernel` — so `$0` is the
*relative* `iso/build.sh`, and line 20 `cd`s out from under it. `cat "$0"` then
had nothing to open, and under `set -euo pipefail` that killed the script 14
lines after a successful 7-minute kernel build. `307d6b9`.

## 4. My own rescue check was a false negative

Added in fix #1, to turn "switch_root on a root with no init" into something
readable. It read:

```sh
[ -x /mnt/merged/sbin/init ] || rescue "no /sbin/init in the merged root"
```

`/sbin/init` is a symlink to the **absolute** path `/usr/bin/copper-init`.
Before `switch_root` does its chroot, an absolute symlink resolves against the
initramfs root — where there is no `/usr/bin` at all. So the test followed the
link into the initramfs, found nothing, and reported a perfectly good ISO as
broken. It cost a boot cycle to find.

Fix: test the binary, not the link. `switch_root` still gets handed
`/sbin/init`, which resolves correctly after the chroot. `b7facc7`.

## 5. …and the build gate I added to catch #4 made the same mistake

`[ -e "$TGT/sbin/init" ]` — which also *follows* the link, this time to the
**build host's** `/usr/bin/copper-init`, which does not exist. Dangling, so
"missing", so the first CI run of the new gate failed on a staged tree that was
fine. It uses `readlink` now. `0cf3fd9`.

Worth internalising: **`-e` and `-x` follow symlinks. Any check on a
Copper-created link must use `readlink`, or it is testing the build machine.**

## 6. Stale files survived in two staging trees

`build_initramfs` and `build_rootfs` both copy into a `$TGT` that may have come
straight out of the cache, and `cp` only ever adds. A file or directory deleted
from the source came back in the next ISO — and because the ISO stage stamps
the whole tree, it did that while *looking* like a clean rebuild. `rm -rf` the
initramfs staging dir; keep a manifest of what the overlay contained last time
and drop whatever it no longer claims. `0cf3fd9`.

**The manifest has to be built from `iso/rootfs-overlay/`, not from `$TGT`.**
My first version diffed `$TGT` against itself, which is the cached directory
that still holds the stale file, so it could never fire. A test now pins that:
it runs the old logic against the scenario and asserts the file survives, so
the test cannot pass on the broken version.

## 7. The serial console addition made the screen lie

`console=tty0 console=ttyS0,115200` looked obviously right. It is not. **The
last `console=` on the command line is what `/dev/console` points at**, and that
is the only place userspace output goes. On a VM with no serial port, `ttyS0`
never registers, `/dev/console` has no working target, and the screen sits on
GRUB's "Booting up kernel" while the system boots perfectly out of sight. It
looks exactly like a hang. Cost hours. `971b6e5`.

Correct order is `console=ttyS0,115200 console=tty0` — register both, screen
last.

## 8. …which then made the serial log useless

Fixing #7 correctly left the file getting the kernel's half of the boot and
none of ours, and under `quiet` — the entry anyone actually boots — **0 bytes**.
Measured, not assumed.

So `say()` in all three places (initramfs, PID 1, lease script) now writes to
stdout *and* to `/dev/ttyS0`, guarded by `[ -c /dev/ttyS0 ]` so a machine with
no serial port does nothing. `9750dac`.

Practical upshot: **you never have to photograph or transcribe a screen
again.** Point the VM's serial port at a file and paste that.

## 9. DHCP was broadcasting into a tunnel

This is the one that mattered most, and it was hiding in plain sight:

```
copper-net: no lease on sit0 yet, still asking
udhcpc: no lease, forking to background
```

`sit0` is not a network card. It is the IPv6-in-IPv4 tunnel the `sit` module
creates at boot, and with `MODULES=n` every driver is built in, so it exists
before the real NIC finishes probing. `first_nonloop_iface()` took the first
name in `/sys/class/net` that wasn't `lo`, so it got `sit0`, brought it up with
`SIOCSIFFLAGS`, and broadcast DHCP discovers into an interface that cannot
carry them. `eth0` sat there untouched and never even reported link up,
because nothing had asked it to.

Fix: read `/sys/class/net/<if>/type` (the `ARPHRD_*` value) and only accept
`ARPHRD_ETHER`, or `ARPHRD_IEEE80211_RADIOTAP` when there is no wired one.
That skips `sit0`, `gre0`, `ip6tnl0`, `ipip0`, `teql0`, `tun0` and `ifb0`
without naming any of them, and it no longer depends on directory order.
`2601222`.

The old code carried a comment predicting this exact failure. It was right, and
it was still worth doing properly.

---

# Goals

Ordered by what unblocks the most.

## G1 — Confirm the first-boot wizard ✅ closed

**Done:** verified. A full run on the framebuffer kernel answered all six
questions, refused nothing, and left no shell prompt — the desktop came up
instead. Seventeen of seventeen pixel assertions on the result.

Kept as a closed goal rather than deleted, because "the wizard ran" and "the
wizard ran and the machine then gave you a desktop" are different claims, and
the second is the one that was actually being asked.

## G2 — Prove the internet, not just DHCP

**Done looks like:**

```sh
ping -c 1 1.1.1.1          # raw IP, no DNS
nslookup example.com       # resolver works
wget -O - http://example.com   # HTTP end to end
```

We have a lease, a route and a resolver. None of the three above has run. The
cheap version is to add a reachability probe to the lease script's `bound`
handler so the next log answers it without anyone typing commands; the honest
version is to run the three commands at a `copper-sh` prompt and paste the
output.

## G3 — Static-IP escape hatch

Some networks don't hand out leases, and a DHCP-only box is a box that can't
be used on one.

**Done looks like:** a `/etc/network`-style file (interface, address, netmask
or prefix, gateway, nameservers) that `copper-init` reads and applies instead
of starting `udhcpc`, when the file is present and non-empty. Missing file
means DHCP, as it does today.

## G4 — WiFi

Bigger than ethernet, because `MODULES=off` means the wireless driver and
`CONFIG_CFG80211` have to be compiled into the kernel `.config` directly.

**Done looks like:** the box associates with an access point and gets a lease
without manual fiddling.

Roughly: enable `CFG80211` plus the driver in `build.sh`; build
**wpa_supplicant** from source (static musl) for association; keep busybox
`udhcpc` for the IP afterwards, since it now demonstrably works; and drop the
card's firmware blobs (a `linux-firmware` subset) into the rootfs.
NetworkManager — glib and dbus from source — is the heavy end state for
roaming and a GUI, and is not required to get onto a network.

The interface-selection bug that broke wired DHCP is already handled for wifi:
`first_nonloop_iface()` now asks sysfs for the `ARPHRD_*` type and prefers
`ARPHRD_ETHER` over `ARPHRD_IEEE80211_RADIOTAP`, so a wireless NIC no longer
turns it into a coin flip.

## G5 — Bluetooth

**Done looks like:** `bluetoothctl` or equivalent sees a paired device.

BlueZ built from source, kernel `CONFIG_BT=y` with the relevant protocol
drivers. BlueZ wants a D-Bus daemon; that's the part to budget time for.

## G6 — Persistence

**Done looks like:** a reboot keeps your files.

The overlay's upper layer is currently tmpfs, so the session is throwaway by
design. Move the upper onto a real disk partition the user picks on the
wizard's last page — same overlay mechanism, different `upperdir`.
`iso/live/init` already lays the overlay down, so this is a matter of mounting
a disk where the tmpfs goes and telling the wizard to offer it.

## G7 — Land `patch-1`

See the top of this document. It needs a PR from an account with write access
to `12hrformat/copper`, or someone with that access pushing it.

## G8 — A desktop: XFCE ⚠️ the long end, and now the active request

**Done looks like:** `startxfce4` typed at a `copper-sh` prompt brings up an XFCE
session on the framebuffer, and Ctrl+Alt+F2 or the escape path still gets a
shell.

Ordered, because the order is the whole difficulty:

1. **Boot Xorg on Copper's kernel and prove it over the wire.** `xdpyinfo`
   connecting and reporting the screen geometry. Xorg 1.21.1.9 builds with both
   `modesetting_drv.so` and `libfbdevhw.so` present; it has never been booted.
2. **Add the dynamic glibc userspace beside the static musl one.** Loader plus
   the ~21 libraries Xorg needs, staged into the rootfs. Deliberately additive —
   see "XFCE" above for why replacing the working musl path is the worse risk.
3. **Build the GTK3 and glib chain from source into that rootfs.**
4. **Build the XFCE modules**, minimum set listed above.
5. **Wire it into `copper-init`** with a way back to the shell, and make sure
   that a failure in the X stack costs a shell rather than the machine.

Step 1 is a boot test. Steps 3 and 4 are where the time goes, and CI's six-hour
cap is a real constraint on them.

---

# `copper charge` — what it is and how it got debugged

The hotfix system. `copper charge` pulls `hotfixes.json` and patches the live
system in place; `copper rollback` puts it back. Full user-facing docs are in
`README.md`. This section is the part a next person needs and the README does
not say: **every one of these was found by running the thing, not by reading
it.**

`copper-charge.sh` and `copper-rollback.sh` had never been executed by anyone
before today. Four defects, each of which made the feature completely
non-functional:

1. **`charge` called `curl`, which does not exist on the live system.** The
   rootfs ships busybox applets; there is no `curl` anywhere in the ISO.
   Checked by listing the artifact, not by assuming. Now prefers `curl` if
   present and falls back to `wget`.
2. **`rollback` could never restore anything.** `charge` names a backup by
   `tr '/' '_'`, so `/usr/bin/foo` becomes `usr_bin_foo`. `rollback` undid
   that with `sed 's|__|/|g'` — replacing a *double* underscore, which can
   never appear when `tr` emits one per slash. Every restore died with
   `target file not found`. Now `tr '_' '/'`.
3. **The only hotfix in the database targeted `src/main.c`,** a repo path that
   does not exist on a booted system, so even a successful fetch could only
   ever print `skipping … not found`. Replaced with a demo entry against
   `/etc/copper/demo.txt`, which the ISO ships.
4. **There was no `copper` binary at all.** The tools shipped as
   `copper-charge` and `copper-rollback`, so the command everyone would type,
   `copper charge`, returned `not found`. Added `/usr/bin/copper` as a front
   end, calling the tools by absolute path so a short `PATH` cannot hide them.

## How it is verified

Not by a green CI run — by running both scripts against a fake root in WSL
with the real ISO overlay files, as root, and reading the actual file contents
after each step:

```
copper: applied demo-banner — Demo: proves charge can find, back up and patch a file
copper:   backed up to .../var/backups/copper/etc_copper_demo.txt
copper: charge complete
  -> second run: skipping demo-banner — fail_code not in etc/copper/demo.txt (already fixed?)
  -> rollback:  restored etc_copper_demo.txt → .../etc/copper/demo.txt
```

Apply, backup, idempotent skip, and restore are all confirmed. What is **not**
confirmed is the same cycle on a booted system.

## Testing it offline

The ISO installs `hotfixes.json` at `/etc/copper/hotfixes.json`, and `charge`
prefers that file and never touches the network when it exists. So the hotfix
system can be tested on a VM with no working internet. Delete the file to go
back to fetching from `HOTFIX_URL`.

## A trap worth knowing

`busybox adduser` and `addgroup` write to the real `/etc/passwd` and
`/etc/group` regardless of `HOME`, `PWD`, or anything else. Probing them
inside a WSL shell **modifies WSL**. Back those files up and restore them in
a `trap`, or you will leave junk accounts behind. This happened twice here and
was cleaned up both times.

---

# What is verified, and what is not

Being precise here matters, because it is easy to mistake "it compiles" for
"it works".

## Has actually been executed

- **The boot path, end to end, on a real machine.** Kernel → initramfs →
  overlay → `switch_root` → `copper-init`. The log at the top of this document
  is the evidence.
- **DHCP against a real server.** A lease, `/24` derived from a
  `255.255.255.0` netmask, a default route, and a resolver. `mask_to_prefix`
  had only ever been unit-tested before this; it is now correct in production.
- **`copper-sh`** — compiled with real GCC 12.2
  (`-std=c11 -O2 -Wall -Wextra`, zero warnings) and run through a 44-command
  battery under **AddressSanitizer**: exit 0, no leaks, no overruns. Bugs that
  found and fixed: an argv heap off-by-one, output lost because `_exit()`
  skipped the stdio flush, history storing tokenized instead of the line you
  typed, children reading stale buffered stdin, `ls -l` on a single file, and
  `ls` going one-per-line on a non-TTY so `ls | grep` filters like real `ls`.
- **`tests/smoke.sh`** — 19 assertions over the shell's core behaviours. Run it
  before you touch the shell.
- **The DHCP lease script** — 58 assertions on `mask_to_prefix` (all 33 valid
  netmasks, generated rather than typed, plus non-contiguous and malformed
  input) and 25 more driving the whole script against a stub `ip`.
- **The stage-stamp logic** — 11 assertions including the exact regression
  (output present *and* input moved on must rebuild), and a separate harness
  proving the helpers survive `set -euo pipefail`.
- **The build gates** — overlay-manifest pruning against a simulated warm
  cache, the CRLF gate, and the `readlink` comparison, with a check that the
  *old* manifest logic fails the same scenario.
- **The logging paths** — all three `say()` implementations reach both the
  screen and `ttyS0`, with the `-c` guard proven to skip a non-character
  device.
- **A complete, clean first-boot wizard run** — banner, all six questions
  answered, nothing refused, `Done — welcome`, and no shell prompt afterwards.
  G1 is closed.
- **The framebuffer kernel**, on the emulated adapters — `bochs-drm`
  on `-vga std`, `virtio-gpu` on `-vga virtio`, `qxl` on `-device qxl-vga` —
  each confirmed from the guest's own dmesg showing that driver as fb0's primary
  device. (The 17/17 pixel assertions that sat alongside this went out with
  `copper-gui`.)
- **The whole CI build**, green end to end — kernel, musl, busybox, all eight
  GNU tools, Copper's three binaries, rootfs, initramfs, GRUB ISO.
- **`sh -n`** on all three shipped shell scripts, plus at build time via
  `lint_scripts`.
- **`copper-init.c` and `copper-firstboot.c`** compile clean under GCC 12.2
  with `-Wall -Wextra -Wpedantic -Wshadow -Wwrite-strings`, and in CI against
  musl.

## Has never run

- **The shipped ISO on VMware.** The one thing the whole display-driver work
  exists for is unproven on the hardware it was written for. `vmwgfx` probes
  correctly and refuses on QEMU because QEMU is not VMware.
- **Xorg running against Copper's kernel.** It builds, with both driver paths in
  the binary. Whether it starts is unmeasured.
- **Anything on real hardware.** Every measurement in this document is QEMU with
  a direct `-kernel` boot — no GRUB, no VGA BIOS, no EFI.
- **`copper charge` against a booted system.** Verified off-ISO only.
- **Any real internet traffic.** No `ping`, no `nslookup`, no `wget`. G2.

## A note on green CI runs

**A green run does not mean the artifact is correct.** Run `36220249701` was
fully green and shipped an ISO built from the previous commit's `init`. Always
take the artifact apart: mount it, `gzip -dc` the initrd, decode the cpio, read
`/init` back out, and parse the ISO's Rock Ridge records if you need to know
what a symlink points at. Windows shows 8.3 names because the image has Rock
Ridge and **no Joliet** — `COPPER_I` is `copper-init`, and that is cosmetic,
not a bug.

## The build gates

- `lint_scripts` — `sh -n` over the initramfs `init` and the lease script. Both
  are read by busybox ash on a machine with no shell to log into and fix them
  with.
- `require_kernel_config` / `require_bb_config` — read the `.config` files back
  after kconfig has had its say and refuse to continue, listing what went
  missing.
- `build_copper` — checks the staged tree actually contains the binaries and
  lease script `switch_root` needs, and that `sbin/init` is a symlink to
  `/usr/bin/copper-init`. Uses `readlink`, not `-e`; see bug #5.

---

# Traps that will cost you a day

**Backgrounded test stubs inherit your desktop, and will use it.** WSLg runs a
real X server on `:0` and exports `DISPLAY=:0` and `WAYLAND_DISPLAY=wayland-0`.
A backgrounded process that inherits those makes WSLg start a notification
daemon, which is a popup on the desktop of whoever is running the test — and it
cost two interruptions and a `pkill` before it was identified. Any test that
backgrounds something must unset `DISPLAY`, `WAYLAND_DISPLAY`, `XDG_SESSION_TYPE`,
`XDG_SESSION_DESKTOP`, `XDG_CURRENT_DESKTOP`, `XDG_RUNTIME_DIR` and
`DBUS_SESSION_BUS_ADDRESS` first, and should use its own scratch directory so it
never touches the real `/tmp/.X11-unix`.

**A `trap` does not fire when the tool call is killed outright.** An interrupted
run left a live instance behind, which then collided with the next run on the
same scratch directory; both were found blocked for eight minutes with no
children. One scratch directory per run (`mktemp -d`), a lock so a second copy
refuses rather than races, and a cleanup step you can run by hand.

**Two tests sharing one scratch directory will corrupt each other.** Each case
above deletes and recreates the directory, so two copies are always racing on
whatever the other is halfway through.

**Never write an inline `wsl ... bash -c "..."` with pipes, `||`, `$(...)` or
`$?`.** PowerShell parses them first and mangles them — `||` is not a statement
separator, `head` and `wc` are not PowerShell commands, and `> /tmp/file`
redirects to `C:\tmp\file`, which does not exist. **Write a `.sh` file and invoke
it.** Every one of these cost a round trip today, and the failures look like
bugs in the script rather than in the shell that ate it.

**`nohup … &` inside `wsl` is not detached.** `wsl` tears the session down when
the calling command returns and takes the child with it. An `apt-get install`
launched that way wrote no log at all and installed nothing, while appearing to
have started. Run long jobs as a background task from the harness instead, and
verify by asking `pkg-config` whether the library arrived — not by whether
`apt-get` returned 0.

**`bzImage` is compressed, so `strings` on it lies.** It reports every display
driver absent, including ones known to be present. The only trustworthy evidence
about which driver bound is the **guest's own dmesg**. An earlier probe was
discarded for this reason.

**The kernel's framebuffer message is `fb0`, not `/dev/fb0`.** See the second
false check above. A grep for the path reports a working framebuffer as missing.

**`make O=… defconfig` fails on a dirty source tree and leaves a stub `.config`
behind.** The message is *"The source tree is not clean, please run 'make
mrproper'"*, and the leftover file is a few hundred bytes. Anything that reads
symbols out of it will confidently report nonsense. `mrproper` first, and check
the config is over 1000 lines.

**pkg-config module names are not library file names.** `x11` not `libX11`,
`epoxy` not `libepoxy`, `xfont2` not `libXfont2`, `pciaccess` not
`libpciaccess`. Look them up with `pkg-config --list-all` instead of guessing;
guessing stopped three builds on libraries that were already installed.

**meson options must be read from the project's own `meson_options.txt`.**
xorg-server 21.x is meson, not autotools, and the option sets differ —
`-Dfbdev` and `-Dllvm` do not exist, and it is `systemd_logind` with an
underscore. Guessing from the autotools build is what produced the failures.

**`CC=…` is an environment variable, not a `meson setup` argument.** Passed as a
trailing flag, meson reads it as a source directory and reports
`ERROR: Neither source directory 'CC=gcc-13' … contain a build file meson.build`,
which points at the project rather than at the misplaced flag.

**This network cannot download 4.9 MB in five minutes.** `curl --max-time 300`
failed partway. Use `-C -` to resume, and gate on `tar tf` rather than on the
transfer appearing to succeed — a truncated tarball extracts halfway and then
reports a build error against the source.

**Any change to a cache-key file is a full kernel rebuild.** The CI cache key
hashes `iso/build.sh`, `iso/live/init`, `iso/boot/grub.cfg`,
`iso/rootfs-overlay/**`, `iso/src-init/**`, `iso/firstboot/**` and `src/**`. A
change to *any one* of those throws away the whole `iso/work/` cache. The cache
is saved even on failure (`if: always()`), so a red run still warms the next
one. Batch changes; don't dribble.

**The kernel command line's last `console=` is `/dev/console`.** See bug #7.
This is the single most counter-intuitive thing in the whole boot, it produces
a fake hang, and it cost the most time.

**`console=ttyS0,115200` on a VM with no serial port is not a no-op.** It
takes `/dev/console` away from `tty0`. Add the serial port *and* put `tty0`
last.

**Only add symbols to `require_kernel_config` that you have checked exist.**
A symbol that doesn't exist in 6.12 fails the build immediately and
expensively. `ETHERNET` is the cautionary tale: it was in the list, and 6.12
removed it.

**`MODULES=n` means every `tristate` resolves to `y` or `n`,** never `m`. So a
`--enable`d tristate really is `=y` in the final `.config`.

**`core.autocrlf` was `true` on the build machine** and quietly filled the
working tree with CRLF. A CR is invisible in a diff and it breaks things
quietly: a CR at the end of `PATH` in `/etc/profile` makes every command come up
"not found", CRLF in `passwd`/`hosts` breaks the lookups, and CRLF in a script
busybox ash runs turns every line into "command not found" during boot. It is
`false` now and `.gitattributes` asks for LF everywhere. Leave both alone.

**`git commit -- <paths>` commits the working tree, not the index**, which
leaks `update-index --chmod=+x` changes into a later commit. Use index-only:
`git reset -q; git add -- <files>; git update-index --chmod=+x -- <f>; git commit`.

**`core.fileMode` is off on Windows**, so exec bits need
`git update-index --chmod=+x`. `iso/live/init` and the lease script are mode
100755 and must stay that way.

---

# Config facts worth not rediscovering

Each of these cost a wrong turn once. All were checked against real sources.

- **busybox's `make defconfig` is not a stock config.** busybox patches kconfig
  with `const char conf_defname[] = "/dev/null"`
  (`scripts/kconfig/confdata.c:25`), so "defconfig" means *the Kconfig
  defaults*. There is no `configs/defconfig` in 1.36.1. Per-applet symbols live
  in `//config:config SYMBOL` comments inside the `.c` files and in the
  directory `Config.src` files.
- `CONFIG_STATIC` is `default n`, so it must be set explicitly — and **after**
  `make defconfig`, because reassigning a symbol defconfig already answered is
  silently dropped (first assignment wins). That's what `set_bb_config` is for.
- **6.12 has no `CONFIG_ETHERNET`.** The driver menu is unconditional under
  `NET`/`NETDEVICES`. Those are the real gates.
- In 6.12, `config INET` moved to `net/Kconfig` and `net/ipv4/Makefile` builds
  `tcp.o`/`udp.o` in `obj-y` unconditionally under `INET`. So `CONFIG_INET=y`
  (which `x86_64_defconfig` sets) is enough for IPv4.
- `BLK_DEV_NVME` lives in `drivers/nvme/host/Kconfig` in 6.12. It's `tristate`
  with **no default**, so the explicit `--enable` in `build.sh` turns it on.
- `CONFIG_OVERLAY_FS` is also `tristate` with no default. The entire live-root
  design rests on `build.sh` passing `--enable OVERLAY_FS`.
- vmxnet3's Kconfig path isn't `drivers/net/ethernet/vmware/Kconfig` in 6.12
  and the symbol name couldn't be pinned down. `build.sh` passes **both**
  `--enable VMXNET3` and `--enable VMWARE_VMXNET3`; kconfig drops
  whichever doesn't exist. Deliberately not asserted.
- **In busybox 1.36.1 udhcpc's source is `networking/udhcp/dhcpc.c`,** not
  `networking/udhcp.c` — the client was split into a directory. `ip` is split
  too: address parsing is in `networking/libiproute/`.
- The environment udhcpc exports comes from the DHCP **option** names. The
  consequence that matters: **`$subnet` is the netmask as a dotted quad**, and
  `$mask` is the same mask as a decimal uint32. Neither is a prefix length.
- busybox `ip` *does* accept a dotted mask after the slash: `get_prefix_1`
  (`networking/libiproute/utils.c`) falls back to parsing it as a netmask. We
  convert to a prefix length ourselves rather than depending on that.
- `udhcpc -b` does not exit — after its retries it forks into the background
  and keeps trying forever. So init can fire it and move on; no `-n` needed.
- udhcpc does **not** put `PATH` in the lease script's environment, so init has
  to set it before the exec.
- busybox installs udhcpc at `/sbin/udhcpc`, `ip`/`ifconfig`/`route` in
  `/sbin`, `ping` in `/bin`, `wget`/`nslookup` in `/usr/bin`, `switch_root` in
  `/sbin`. It does **not** install a lease script, which is why we ship one.
- `wget`'s `https://` is busybox's internal TLS. It encrypts but does **not**
  verify certificates. Fine for pulling a tarball, not for a login.

---

# Working in parallel: GUI and the package paths — read the ownership lines before editing

Status written 2026-10-08. Work is on **`main`**. pacman is **gone**; the
queue is now just **GUI polish** (display under QEMU, verified). **sudo** is
built by its own stage and CI-green; **ingot** is shipped, busybox-clean, and
gated by `tests/ingot-gate.sh` (31 assertions, green in WSL) — the release
step (real Pages repo) is what remains. The `gui`-branch narrative at the top
of this file is history — the display commits live on `main` now.

Verified at this tip:

- **XFCE reaches a desktop.** Under QEMU (`-vga std`): boot → shell →
  `startxfce --check` reports `found the X server: /usr/bin/Xorg` and
  `found XFCE` → `startxfce` → the screen becomes the session, and OCR of the
  screendump read the xfdesktop icons ("Home", "File System"). It paints.
- **The guest sees input devices** — `/proc/bus/input/devices` lists the
  keyboard and mouse under QEMU.

**Bug: on VMware, `startxfce` starts X but the screen is blank — ROOT CAUSE
FOUND, fix shipped.** The full `/tmp/session.log` was recovered (via the
owner's screenshot-OCR round trip) and it is conclusive — this was never
VMware's fault:

- The session **starts**: `xfce4-session`, `xfwm4`, `xfsettingsd`,
  `xfce4-panel`, `Thunar`, `xfdesktop` all launch.
- Then every component dies on **missing GdkPixbuf loaders**:
  `Gtk-WARNING: Could not load a pixbuf from icon theme`,
  `could not load a pixbuf from /org/gtk/libgtk/icons/...png. This may
  indicate that pixbuf loaders or the mime database could not be found`,
  then `Wnck:ERROR ... default_icon_at_size: assertion failed: (base)`,
  `Gtk:ERROR ... ensure_surface_for_gicon: assertion failed (error == NULL)`,
  each ending in `Bail out!` (GLib's g_error → abort).
- `xfdesktop` is respawned by the session manager and dies again — PIDs
  climbing in the log (268 -> 279 -> 297 -> 304). The session repeatedly
  aborts before painting anything; X itself is fine.
- **Why no loaders:** `loaders.cache` is only ever written by the gdk-pixbuf
  package's postinst, and this build runs no postinsts (pure `dpkg-deb -x`).
  The boot-time fallback in `startxfce.sh` (`gdk-pixbuf-query-loaders
  --update-cache`) runs, but as a normal user against a read-only squashfs
  `/usr` it cannot write, and the `>/dev/null 2>&1 || :` swallows the failure.
- **Fix (shipped in the gui stage):** `build_gui()` now mirrors the gdk-pixbuf
  postinst at build time: it locates `gdk-pixbuf-query-loaders` in the staged
  tree (the tool moved out of `/usr/bin` into the libdir in gdk-pixbuf 2.42 —
  first attempt hardcoded `/usr/bin` and the build gate caught it), feeds it
  every loader `.so` under the module dir as arguments (PNG/JPEG are compiled
  into the library now and need no entry), and writes its stdout to
  `.../2.10.0/loaders.cache` — all chrooted into `$TGT`, where the glibc
  closure and modules are available. The stage aborts if the cache comes out
  empty. The image now ships the cache; the runtime fallback in `startxfce.sh`
  becomes an inert no-op. CI caught a second bug in the next iteration: the
  loader `find` used `-path '.../2.10.0/loaders'` without a trailing `/*`,
  which matches only the directory and so (with `-name '*.so'`) matched
  nothing — the gate failed with "no loader modules" on a tree full of them.
  Fixed with a trailing `/*` and a comment explaining why. **Final CI for the
  loaders fix: run 37881707295 (commit `6ebc11a`) is green** — the log shows
  `pixbuf loaders.cache written (93 entries)` and the `copper-iso` artifact is
  downloadable.
- **Owner retested 2026-10-09; icons still fail.** Fresh session log with the
  loaders-cache image still shows `Could not load a pixbuf from icon theme.
  This may indicate that pixbuf loaders or the mime database could not be
  found` and the crash loop. Two new leads from that log:
  1. The GTK message explicitly names the **mime database** — `shared-mime-info`
     ships `/usr/bin/update-mime-database` but (like `loaders.cache`) only its
     postinst ever runs it; this build runs no postinsts.
  2. The fatal icon is `Adwaita/scalable/status/*.svg` — an **SVG**, which in
     gdk-pixbuf 2.42 is a *module* in `librsvg2-common` (PNG/JPEG are compiled
     in, SVG is not). If that module failed to dlopen in the chroot, the
     cache can exist with 93 entries and still carry no SVG entry.
  Next build (in flight): `build_gui()` now (a) gates on `image/svg+xml`
  actually appearing in `loaders.cache`, (b) runs `update-mime-database
  /usr/share/mime` chrooted, aborting unless `mime.cache` is produced, and
  (c) runs `gtk-update-icon-cache -f -t` over every staged icon theme.
  Also to confirm with the owner: whether the retest actually booted the
  `6ebc11a` artifact and not the older local `copper.iso`.
- **Owner confirmed 2026-10-09:** the VM has `loaders.cache` (so the fixed ISO
  was booted) and `/usr/share/mime/mime.cache` is **absent** — the missing
  half is exactly the mime database. Commit `12e7c86` added it. CI went red a
  different way: `update-mime-database` emits a legacy `/usr/share/mime/icons`
  map that is zero bytes on this minimal database, and the sudo stage's
  whole-tree empty-file gate tripped (`./usr/share/mime/icons`). The gui stage
  (SVG gate, mime db, icon themes) had all passed. Fix in `0770d98`: prune the
  generated `icons` file when empty (keeping non-empty ones, which carry real
  mappings). Next data point is the `0770d98` artifact (its gui stage already
  proved green on the run before).
- **Unrelated leftover:** plain `startxfce4` by hand dies with
  `exec: line 126: xinit: not found` because the gui list never installs
  `xinit`. Harmless for `startxfce` (it sets DISPLAY, skipping the xinit
  branch) but a papercut for interactive use; consider adding `xinit` later.
- **Bug: on VMware, the mouse cursor is stuck (no input reaches X) — ROOT
  CAUSE FOUND and fixed (commit pending push), the two candidates narrowed to
  one by a blocking-read test on the machine.** Sequence of diagnosis:
  - **Xorg was exonerated first:** `/var/log/Xorg.0.log` shows evdev opened and
    registered both devices — `XINPUT: Adding extended input device
    "Keyboard0" id 6` and `"Pointer0" id 7`, "initialized for relative axes".
    `ps w` shows the single Xorg is ours (`-config /etc/X11/xorg.conf`), so
    there is no stale third-party server holding the devices.
  - **The `od` result was a red herring.** `busybox od -x -N 96` on both mouse
    nodes printed an instant `read error` — not "the node is broken". busybox
    `od` reads nonblocking, so "read error" means "no events available right
    now". It said nothing about VMware or the kernel.
  - **The decisive test was a blocking read:** `busybox dd if=/dev/input/eventX
    of=/dev/null bs=24 count=2`. In the VMware VM on 2026-10-09:
    - `event1` (AT keyboard): **1+0 records in** — delivers events (the user
      types at the console through it).
    - `event2` (ImPS/2 Generic Wheel Mouse): **2+0 records in** — delivers
      relative motion. This is the working mouse.
    - `event3` (VMware Virtual USB Mouse): **hangs forever** — the kernel gets
      zero events from it.
  - **Why event3 is dead:** it is VMware's absolute-pointer/tablet device,
    which is only fed when the guest speaks the vmmouse protocol. The
    `xserver-xorg-input-vmmouse` driver was **retired from Ubuntu in 2018
    (xenial)** and does not exist in noble, so the tablet can never report
    here. VMware feeds the emulated PS/2 mouse relative motion on every Linux
    guest, tools or not — event2 is the pointer.
  - **The bug was the launcher, not the VM:** the matcher in `startxfce.sh`
    picked the *last* `*Mouse*` match in sysfs order, so `VMware Virtual USB
    Mouse` (event3) beat `ImPS/2 Generic Wheel Mouse` (event2) purely by
    sorting later. The fix (in `iso/startxfce.sh`, with gate cases 10 and 11
    in `tests/startxfce-gate.sh`): the PS/2-named device (`*ImPS/2*`,
    `*ImExPS*`, `*Explorer*`, `*PS/2*`) wins the pointer, and a plain
    `*Mouse*` is only the pointer when no PS/2 device exists. The sysfs
    location is now `COPPER_SYSINPUT`-overridable so the gate can fake the
    exact VMware device lineup (`event1` keyboard / `event2` ImPS/2 /
    `event3` tablet) and assert the config writes `/dev/input/event2`.
  - **Next data point:** boot the new artifact in VMware and confirm the
    cursor moves; then the agreed next project is wrapping the `startxfce.sh`
    exec with `dbus-launch --exit-with-session` to silence the session-bus /
    AT-SPI / login1 noise.
- **Owner confirmed 2026-10-09 (input bug CLOSED):** with the `cc1ad9b`
  artifact the cursor follows the mouse in VMware. The launcher change in
  `7df142c` is the fix; gate cases 10/11 and the private-TMP hygiene in
  `cc1ad9b` shipped with it. The remaining session-log noise (D-Bus
  session bus, AT-SPI, system/login1, `pm-is-supported`) is the agreed next
  project.

## Pacman is GONE — Copper grows its own package manager (ingot) instead

Pacman was removed on 2026-10-08 (owner's call): no `iso/pacman/`, no
`build_pacman` stage, no pacman step in the workflow, no Arch stub db. Chasing
Arch's stub-db/readline/ncurses compatibility was the wrong shape of the job —
the image is a musl base, and glibc-closure games buy a fragile hybrid. Replaced
by:

**ingot** — our own package manager, distributed through **GitHub Pages**:

1. `ingot install nmap` goes to a GitHub Pages URL that looks like
   `https://<pages>/iso/copper/pkg/hacking/nmap` — one JSON file per package
   (no binary on Pages at all).
2. ingot downloads that JSON to `/tmp`, reads it, and finds the **real url**
   where the actual package payload lives (Releases/CDN — anywhere that can
   hold big files).
3. ingot downloads the payload from that url, checks its **sha256** against the
   hash stored in the JSON (mismatch → refuse), installs it, and **deletes the
   JSON from `/tmp`**.

Pages carries only tiny index files; heavy payloads live behind the "real url".
This is the design dragon specified — write NO other package path without asking.

Status (2026-10-08): **built and gated, not yet released.** What landed:

- **`iso/rootfs-overlay/usr/bin/ingot`** — the shipped client. POSIX sh,
  busybox-ash clean (`sh -n` + `busybox sh -n` both pass). install/remove/
  update/reinstall/inspect/info/search/list. Reads the one-key-per-line JSON
  shape documented in its own header (index: `{"nmap": "hacking"}` one entry
  per line; package pages: flat string values, `depends` the only array).
  Recursion runs dep installs in a subshell — there is no `local` in POSIX sh,
  so an inline call would let the dep's fetch clobber the outer install's
  `name`/`url`/`want` and silently re-install the dep under the dep's own
  name. The gate test found exactly that.
- **`iso/rootfs-overlay/etc/ingot.conf`** — default Pages url, overridable by
  `INGOT_REPO` (which is how the gate points it at a scratch server).
- **`tests/ingot-gate.sh`** — 31 assertions, green in WSL as root and
  non-root: serves a fake Pages repo over localhost + busybox httpd, proves
  files land, dep installs first, sha256 mismatch refuses, /tmp stays clean
  after every path, remove deletes exactly what the manifest recorded (and
  does not recurse into deps), unknown names fail by name, info/search/list
  behave, inspect shows the installed record, reinstall removes then
  reinstalls, update notices a moved sha256 and reinstalls else reports up to
  date. Wired into `tests/branch-gate.sh` and the workflow test list.
- **`iso/build.sh`** — `build_rootfs` chmods ingot + CRLF-guards it; the
  POSIX parse audit now covers 4 busybox tools (ingot joins copper.sh,
  copper-charge.sh, copper-rollback.sh).
- **`iso/sudo/`** — sudo built by its own stage, CI-green: `ingot install`
  runs as `sudo` from a wheel user (wheel group + `%wheel ALL=(ALL:ALL) ALL`).

Still to do for release: build the real Copper Pages repo, publish payload
hashes, and boot `ingot install nmap` off a screendump.

Carried over from the pacman work, still true and still needed:

- The GUI stage's glibc closure gives the rootfs libssl/libcrypto/libz/liblzma/
  libzstd/libbz2 and `/lib64/ld-linux-x86-64.so.2`, so glibc-linked payloads
  run.
- Runtime network is proven (DHCP + DNS in every serial log); busybox wget's
  TLS encrypts but does not verify certificates — noted in ingot's docs and in
  `futureplans.md`.
- First end-to-end check once the Pages repo exists: boot, `ingot install
  tree`, run `tree`, read it off a screendump.

## GUI: the files that matter, and the lines not to cross

For whoever picks up the display work:

**Yours:**

- `iso/startxfce.sh` — the launcher: device detection (207-215), generated
  xorg.conf (204-251), server start (269-273), session exec (355).
- `iso/build.sh` **gui stage only** (~895-995) — apt package list at 916,
  unpack, loader copy, gates.
- `tests/startxfce-gate.sh` — CI runs it every push; keep it green.

**Not yours — do not restructure:**

- `iso/build.sh` outside the gui stage: stamp helpers (~89-111),
  kernel/base/tools/copper/rootfs/initramfs/iso, the stage list at the bottom.
  The ingot/sudo stages will insert there; two-way edits in one file are how
  merges go wrong.
- `src/`, `iso/live/init/`, `iso/src-init/`, `iso/firstboot/` — the verified
  boot path. The GUI does not need them; a regression there costs a boot.
- `.github/workflows/build-iso.yml` — shared; touch only to add your own test
  name, in the same commit as the test.
- `iso/out/` — build output, stays untracked.

**Harness facts that will otherwise cost you a day** (each verified the hard
way):

- copper-sh rejects `2>&1` and `&`: the tokenizer splits them and `parse_line`
  errors with `only one '>' per command`. Plain commands, at most one of
  `< > >>`.
- QEMU's monitor `sendkey` has **no `greater` key** and rejects uppercase
  names (`shift-D` → `invalid parameter: D`). A typed `>` silently never
  arrives — this bought a full debug round of "the serial output is empty".
- The shell runs on tty1; serial carries only init's chatter. Read the guest
  by screendump + tesseract (installed in the WSL box) instead of redirecting
  to `/dev/ttyS0`; `diag2-xfce.sh` is the working pattern.

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

Artifacts download fine now, using the Git Credential Manager token. Earlier
notes saying this returns 401 are out of date. Capture the token into a
variable and never print it:

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

Then **Add… → Serial Port**, "This end is connected to" → **Output to file** →
`C:\Users\hp\Desktop\copper-boot.txt` (VMware insists on a `.txt` name and will
warn that the file does not exist; accept it, it creates the file) → **Connect
at power on**.

Boot the **verbose** entry while diagnosing. The `copper:` and `copper-net:`
lines now reach the file on *every* entry, so paste that file rather than
photographing a screen.

## Tooling on the build machine

- **Git for Windows** gives a real POSIX shell at
  `C:\Program Files\Git\bin\bash.exe`. That allows `sh -n` on the shipped
  scripts and — more usefully — unit testing shell logic with a stub binary on
  `PATH`, no VM and no compiler. Most of the tests in this branch were written
  that way. Don't assume there's no way to test shell here.
- **This box cannot create a symlink at all** — `ln -s` fails regardless of
  privilege, because Windows wants Developer Mode for native symlinks. So any
  test of symlink *behaviour* has to stub `readlink`; the real thing is CI's to
  prove, and it does.
- No local C toolchain: no gcc/clang/tcc, no WSL, no container runtime. C
  verification goes through Compiler Explorer's API, which is **glibc, not
  musl**, so it cannot validate musl-specific code. CI is the real oracle.
- PowerShell gotchas that cost time: no heredocs (write the message to a file
  and use `git commit -F`); inline `bash -lc` with quotes and `$` gets mangled
  (write a `.sh` and invoke it); `curl.exe` mangles JSON in `--data-raw` (write
  the body to a file, use `--data-binary @file`); nested `$'\r'` through
  `bash -lc` arrives as a literal backslash-r, so CR checks must live in a
  script file.

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
  living on, and bugs #4 through #9 were all invisible to the build.
- If you make a file that wasn't already made, write "handcrafted by [ your name ]" and if you update a file that had bugs, please write "updated by [ your name, the bug, the line where the bug was ]"
----
THANK YOU
