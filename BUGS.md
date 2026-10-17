# BUGS.md

> please note down all the bugs you come across in h1 heading (#) thier name and how they affect things on a scale of 1-10.

> remove any bugs if fixed and please write in this format [bug number [] fixed by [] ] at the bottom of the file so we can track how many bugs were there and who fixed them

Only bugs that are not fixed live here. Fixed ones are removed from the list —
their graves are in the tracker at the bottom of the file.

---

# 15. firefox install dies of ENOSPC — impact 10/10 (see #20)

**How it affects things:** you can't install bigger apps, and the disk you
gave the VM does literally nothing while you watch it happen.

**What happens:** a real boot `ingot install firefox` (2026-10-10) ingot fetched the index file
donwlaoded firefox.tar, but then on the unpacking stage ingot died, saying
'no space left on device' on a 2 GB VM that had a **10 GB disk
attached the whole time**. The disk is never mounted; the read-only ISO and a
RAM tmpfs upper are all there is.

**Root cause:** the overlay's writable upper is a tmpfs capped at 50% of RAM.
firefox needs ~570 MB in the writable layer at once — the ~120 MB payload and
its ~450 MB unpacked tree coexist until unpack finishes.

**Status:** not fixed. Cap on the upper tmpfs is 50% now
(`iso/live/init`, with the `/tmp` entry in `etc/fstab` kept in step), so it
fits on a 2 GB box. Still RAM, still throwaway.

**The real fix is bug 20** (persistence): the upper moves to a disk. That code
is in the tree now but has not booted yet, so the stopgap stands until then.

Also caught in that same log: `mousepad`, `ristretto`, `xfce4-taskmanager`,
`xarchiver` answered `no package named X in the index` — the live index had
only 5 of the 9 packages. Their pages are published now; gone.

---

# 18. `sudo shutdown now` / `sudo reboot` do nothing — impact 4/10

**How it affects things:** there is no clean reboot or shutdown from the
desktop or a shell. The only way off is a forced power-off, which scribbles
the live overlay and can throw work away.

**Two separate causes, both real:**

1. **busybox ships no `shutdown` applet.** `busybox --list` on this image's
   1.36.1 build answers `halt`, `poweroff` and `reboot` but not `shutdown`, so
   `sudo shutdown now` was "command not found". Nothing in the ISO shipped one.
2. **`reboot`/`halt`/`poweroff` without `-f` never call `reboot(2)`.** busybox's
   own help says it: `-f  Force (don't go through init)`. By default they signal
   PID 1 and expect it to do the orderly shutdown — and copper-init ignored
   `SIGUSR1`/`SIGUSR2`/`SIGTERM`, so the request died silently. Only
   `reboot -f` ever worked, and nothing invoked it.

**The fix is in the tree (2026-10-11), but nobody has booted it yet.**

- `copper-init` now answers the power signals busybox init defines — `SIGTERM`
  → reboot, `SIGUSR2` → poweroff, `SIGUSR1`/`SIGPWR` → halt — with `sync()`
  then `reboot(2)`. The mapping lives in its own `power_how()` so a unit test
  can check it without rebooting the machine running the test.
- A new `/sbin/shutdown` wrapper fills the applet busybox does not have: it maps
  `-r`/`-h`/`-H`/`now` onto the busybox `reboot`/`poweroff`/`halt` applets,
  which then signal PID 1. Root only, as before.

**Still open because:** "built" is not "verified". A real boot has to show
`sudo reboot` restarting the machine and `sudo shutdown now` powering it off.
`tests/shutdown-gate.sh` proves the wrapper picks the right applet by replacing
`/sbin` with stubs in a private mount namespace, and `tests/init-session.c`
checks the signal mapping — but nothing in CI boots the image.

---

# 20. persistence isn't built — the writable layer is RAM — impact 10/10

**How it affects things:** every reboot throws your files away, and the disk
you attach to the VM is never written to. This is the root cause behind bug 15.

**The fix is in the tree (2026-10-11), but nobody has booted it yet.** Same
overlay, different `upperdir`: the writable layer goes on a disk.

- `iso/live/init` scans the attached disks for one carrying the ext4 label
  `COPPER` and mounts it where the tmpfs used to go. No label, or a labeled
  disk that will not mount → the 50% tmpfs, so the ISO still boots anywhere.
  A stale overlay `work/` left by an unclean shutdown is cleared first.
- The wizard's last page (`copper-firstboot.c`) lists the spare whole disks,
  makes the user pick one and type `ERASE`, then runs `mkfs.ext4 -q -F -L
  COPPER`. Explicit choice, never "grab the first disk we see": the medium it
  booted from and anything already mounted are never offered, and the page only
  runs on a real Copper boot (`/init` leaves `/var/lib/copper/live-boot`).
- Activates on the next boot, never mid-session. Hot-swapping the upper under a
  live overlay is not the kind of thing we ship.
- `e2fsprogs` is in the gui stage for the real `mkfs.ext4`, and that stage now
  fails the build when the tool does not arrive. busybox's `mke2fs` applet
  cannot stand in: it makes ext2 only and leaves the xattr feature bit clear,
  which is exactly what overlayfs refuses as an upper (see the config facts at
  the bottom).

**Still open because:** "built" is not "verified". The blocker is unchanged —
a fresh CI-built ISO and a real boot: format a disk in the wizard, reboot,
confirm the session comes back and the writable layer is no longer RAM.
`tests/persist.sh` covers the wizard's disk choices against a stub `mkfs.ext4`
(nothing real is ever formatted) and runs in CI, but nothing in CI boots the
image.

---

# 24. a persisted /tmp makes startxfce reuse a dead display — impact 5/10

**How it affects things:** on the machine that has the persistence disk, the
second boot can come back with no desktop. `startxfce` announces
`an X server is already on :0, using it` and hands XFCE a display that nothing
is listening on, so the session hangs against a server that is not there.

**What happens:** `display_live()` treats the very existence of
`/tmp/.X11-unix/X0` as proof that a server is listening. It is not: X does not
remove the socket when it exits, and with persistence the writable layer is a
disk, so `/tmp` comes back with the socket the last boot left behind. The
launcher reuses it instead of starting a real server.

**Root cause:** `startxfce` prefers a liveness probe when the image has one —
`$COPPER_XPROBE`, then `/usr/bin/xprobe`, then `xdpyinfo` — and only falls back
to trusting the bare socket when it has none. `xprobe` is in the repo
(`iso/x11/probe/xprobe.c`, written for exactly this) but `build_copper` never
compiled or installed it, and `x11-utils` (`xdpyinfo`) is not in the image, so
the socket-only fallback was the only path the image ever had. That was
harmless while the writable layer was RAM and every boot began with an empty
`/tmp`; it is not harmless once persistence puts `/tmp` on the disk.

**Fix in the tree (2026-10-11), not booted yet.** `build_copper` now compiles
`iso/x11/probe/xprobe.c` — static musl, like the other in-image binaries — to
`/usr/bin/xprobe`, lists it in the stage's existence loop, and folds it into
both the skip check and the stamp, so a change to the probe cannot be skipped
against an unchanged tree. `startxfce` already prefers it; only the build was
missing.

**Hardened (2026-10-14), still not booted.** Three residual ways the same
symptom could return were closed, each with a regression test:

- **The probe could hang.** `xprobe` set no receive timeout, so a socket that
  accepts a connection and then never answers (a server still starting, or a
  wedged one) blocked it forever — and the launcher with it. It now sets
  `SO_RCVTIMEO`/`SO_SNDTIMEO` (`XPROBE_TIMEOUT`, default 5s) and returns a
  distinct code instead of blocking.
- **The probe said only "alive / not alive".** A timeout, a permission
  failure or a malformed reply all looked like "not alive", and the launcher
  deleted the socket on any negative — including a live server it merely could
  not speak to yet. `xprobe` now exits `0` live, `1` not-live (no socket /
  refused / peer closed), `2` usage, `3` unknown (timeout / permission /
  auth / malformed); `startxfce` only clears the socket on `1` and leaves it
  alone on `3`.
- **A rootfs with no probe at all.** The bare socket-existence fallback *is*
  the bug. With no probe, `startxfce` now consults `/proc/net/unix`
  (busybox-safe, exact pathname match) and treats "bound" as live, "absent"
  as dead, and "cannot read" as unknown — never as live.

Regression tests: `tests/xprobe-gate.sh` drives the real compiled binary
against a synthetic X server (no third-party deps, skips cleanly without a C
compiler) and is wired into `tests/branch-gate.sh` and the ISO workflow;
`tests/startxfce-gate.sh` gained cases 16-21 for the no-probe fallback, live
reuse, the unknown-leaves-the-socket rule, the bounded startup timeout,
`XPROBE_TIMEOUT` passthrough and a probe stuck at "not live".

**Still open because:** "built" is not "verified". Needs a boot with the
persistence disk: start a desktop, reboot, and `startxfce` must start a fresh
server rather than announce the stale one. For this change a full ISO build
and a VM reboot were **not** run; verification stopped at the passing gates.

---

# 25. the boot splash never draws a frame — impact 3/10

**How it affects things:** the Copper boot splash does not appear. A real boot
shows the built-in Plymouth text "details" screen at most, never the 150
frames. Nothing else breaks — the boot, the session and XFCE are all
unaffected — so this is cosmetic, but the feature is 100% absent.

**What happens:** a real boot of the shipped ISO showed no frames (2026-10-14).
Reproduced headlessly in QEMU against the exact built artifact: the display
switches to graphics at ~20 s, then stays essentially blank — ~60 non-blank
samples out of 10 556 over 230+ s, a few hundred pixels of small centred text.
A rendered Copper frame at that resolution would light ~9 400 pixels per
sample. Nothing was ever drawn.

**Root cause:** the command line ends `console=ttyS0,115200 console=tty0`, so
the kernel reports **two** active consoles in
`/sys/class/tty/console/active`. Plymouth's device manager
(`ply-device-manager.c`) sees an active console that is not the local one,
sets `serial_consoles_detected`, `create_devices_from_terminals()` then
succeeds and it **never creates a renderer**. `main.c` sets
`should_force_details`, `plymouth_should_show_default_splash()` returns false,
and Plymouth runs `show_detailed_splash()` — its built-in text splash — so the
`copper` theme and its frames are never loaded. The serial console itself is
deliberate (see the config facts below: the last `console=` owns
`/dev/console`, so `tty0` must stay last), so it cannot simply be removed.

**Diagnosed against the exact packaged build** `plymouth 24.004.60-1ubuntu7.2`
(noble), not assumed: the strings, the flag handling in `main.c`, and the
`IGNORE_SERIAL_CONSOLES` path in `ply-device-manager.c` all match.

**Fix planned (not written):** tell Plymouth the serial console is not the
display. `plymouthd` already supports `--graphical-boot` and
`--ignore-serial-consoles`; `--graphical-boot` also forces the graphical
splash. Either pass the flag from `splash_spawn()` in
`iso/src-init/copper-init.c` (both the attach and non-attach paths), or add
`plymouth.ignore-serial-consoles` to the kernel command line in
`iso/boot/grub.cfg`, or both — `plymouthd` reads
`plymouth.ignore-serial-consoles` as a kernel argument directly.

**Still open because:** the fix is not written or booted yet. Verification is a
QEMU boot of a remastered ISO (or `-kernel`/`-initrd` with the same `-append`),
confirming the non-blank sample count jumps towards a full frame and changes
from frame to frame.

Until a new ISO lands, the splash can be forced by hand at the GRUB menu: edit
the entry and append `plymouth.ignore-serial-consoles` (or
`plymouth.graphical`) before booting.

---

# 27. `ingot update` can delete a package it then fails to reinstall — impact 6/10

**How it affects things:** updating a package whose new payload then fails to
download leaves the package *gone* — files removed, manifest removed, and
`ingot list` no longer knows it was ever there. A dropped transfer on the CDN
(the thing `dl` retries five times for) turns an update into a silent
uninstall.

**What happens:** `update_one` removes the installed package and only *then*
calls `cmd_install`. `cmd_remove` unlinks every recorded file and deletes
`/var/lib/ingot/<name>.installed`; the page fetch, payload download and sha256
check all happen after that. Any failure in that second half — the page pulled
from the repo, a download that exhausts its retries, an unpack error — returns
nonzero with the old install already destroyed.

**Root cause:** the two halves are ordered for convenience, not safety. The one
step that can run before the old install is touched is the fetch-and-verify, and
it is placed last.

**Status:** not fixed. The minimal safe fix is to fetch and verify the new
payload into `/tmp` first and only then remove and install, or to give
`cmd_install` a force path that installs over the old tree and prunes whatever
the old manifest covered and the new one does not — either way `update` must not
be able to delete a working package on a bad transfer. `cmd_reinstall` has the
same window. A regression test needs an installed package whose new payload
404s.

---

# 28. `ingot` packages installed a binary you could not invoke by name — impact 8/10

**How it affects things:** eight already-published packages reported a clean
install and then gave `command not found` when you typed the name that is
bolded right there in the repository's own README table. `bat` gave you
`batcat`, `fd-find` gave you `fdfind`, `vim-tiny` gave you `vim.tiny`,
`netcat-openbsd` gave you `nc.openbsd` only, `figlet` gave you `figlet-figlet`,
`traceroute` gave you `traceroute.db`. `sl` and `john` also landed in
`usr/games` and `usr/sbin`, which the live image's `PATH` may not contain.

**Root cause:** `mkpkg.sh` builds a payload with `dpkg-deb -x`, which unpacks
the `.deb` data tree and runs nothing else. A handful of debian packages do
not put their command name in the data tree at all: it is created by the
`postinst` script through `update-alternatives`, and the `.deb` data tree
never carries it. Nothing in the build ever runs a `postinst`, so by the time
the payload is on the box the name it answers to is not the name the table
promises. (`bat` and `fd-find` are a different mechanism — a deliberate
Debian rename — but the same end result: the name in the table is not the file
on disk.)

Eight payloads were affected in total: `bat`, `fd-find`, `vim-tiny`,
`netcat-openbsd`, `figlet`, `traceroute`, `sl` and `john`.

**Status:** fixed 2026-10-16. Each payload was relinked — a relative symlink
for the command name the deb's `postinst` would have created (and, for
`bat`/`fd-find`, an alias for the renamed binary; for `sl`/`john`, a
`usr/bin` entry onto the real `usr/games`/`usr/sbin` binary) — and
re-uploaded, with the page `sha256`/`size` recomputed, so `ingot update`
notices the new bytes on its own. `README.md` in `copper-ingot-repo` now has
a table of the affected names under "The payload", and "Adding a package"
tells the next builder to grep the tarball for `bin/` and add the missing
symlink before uploading.

---

# 29. `sudo reboot` / `sudo shutdown` do nothing under busybox init — impact 7/10

**How it affects things:** on the booted image, typing `sudo reboot` or
`sudo shutdown now` prints "System has not been booted with systemd as init
system (PID 1). Can't operate." and the machine stays up. The user has to
know to type `busybox reboot` (or find the power button) — and most will not.
This is a real launch blocker for a live ISO: a user who cannot reboot cleanly
will yank the power, which is worse for the overlay and any mounted disks.

**What happens:** `/sbin/reboot` and `/sbin/shutdown` on the image are the
systemd-flavoured ones (pulled in by a dependency that ships them), so they
try to talk to PID 1 over the systemd D-Bus socket. PID 1 is busybox init, so
there is no such socket and the call fails. BusyBox itself has working
`reboot`/`poweroff`/`halt` applets, but they are not what `reboot` resolves to.

**Root cause:** the image mixes glibc binaries from packages that assume
systemd with an init that is not systemd. The package set never re-points the
`reboot`/`shutdown`/`poweroff`/`halt` commands at the busybox applets.

**Status:** not fixed. The minimal fix is a post-install step in `build.sh`
that symlinks `/sbin/reboot`, `/sbin/shutdown`, `/sbin/poweroff` and
`/sbin/halt` to `/bin/busybox` (or installs a tiny wrapper that calls
`busybox reboot`), so the commands the user types work on busybox init.
A regression test should boot the ISO and assert `reboot` exits 0 / the
machine actually reboots. `sudo reboot` must keep working for the `wheel`
user (sudoers already grants it).

---

# Everything fixed — the details are gone, the lessons stay

Fixed bugs were removed from the list above per the rules. The lessons they
cost are preserved below so they don't have to be learned twice. Their full
records — number, name, who fixed them — are in the tracker at the bottom.

**The desktop as a real user (bugs 19/22/23, boot-verified 2026-10-11).**
Three separate things had to be true before XFCE painted *and* Firefox ran:

- **The session must not be root.** `spawn_tty`'s child drops to the wizard
  user before it runs the shell (PID 1 stays root; `sudo` is the way back up).
  Without it Firefox hit its "running as root in a regular user's session"
  refusal — the browser was never the bug.
- **The ISO cannot rewrite the modes it copies.** `grub-mkrescue` invokes
  xorriso with `-r` (rationalised Rock Ridge), which forces uid/gid 0 and
  **flattens file modes** — that is what silently ate `sudo`'s setuid bit.
  Wrapping `xorriso` to rewrite `-r` into `-R`, plus explicit ownership/mode
  pins for `/usr/bin/sudo`, `/etc/shadow` and `/tmp`, is what keeps them.
- **A non-root X server must not try to grab a VT.** Xorg calls `setsid()`
  first and `VT_ACTIVATE` needs `CAP_SYS_TTY_CONFIG`, so a user-owned Xorg dies
  in `xf86OpenConsole()`. The guard is `if (!xf86Info.ShareVTs)`, so the flag
  that actually skips the grab is **`-sharevts`** — `-novtswitch` is a
  different flag and does not skip it. `-keeptty` keeps the controlling
  terminal the login shell already owns.

**The VMware display (bug 21, boot-verified 2026-10-11).** The
`*ERROR* vmwgfx seems to be running on an unsupported hypervisor` seen under
QEMU was QEMU failing VMware's own vendor check, not a driver problem: `vmwgfx`
is the right driver and it drives the panel on real VMware, where XFCE paints
and Firefox runs. QEMU can prove a driver *probes*; only the hypervisor the
driver was written for can prove it *paints*. VirtualBox's `vboxvideo` is still
untestable here — QEMU has no such display device.

**Why the kconfig assertions exist (a win, kept on purpose):**
`require_kernel_config` was inverted to *demand* every display driver rather
than request it. The first run of the new kernel stopped the build with
`FAIL: kconfig dropped: DRM_VMWARE`. **`DRM_VMWARE` is not a symbol** — the
real one is `DRM_VMWGFX`. `scripts/config` accepted the wrong name without
complain, `olddefconfig` dropped it without a word, and the build would have
gone green with no VMware driver in the image. The check caught a real typo
in one minute. That is the whole reason the assertions exist.

## Traps that will cost you a day

**Backgrounded test stubs inherit your desktop, and will use it.** WSLg runs
a real X server on `:0` and exports `DISPLAY=:0` and
`WAYLAND_DISPLAY=wayland-0`. A backgrounded process that inherits those makes
WSLg start a notification daemon, which is a popup on the desktop of whoever
is running the test — it cost two interruptions and a `pkill` before it was
identified. Any test that backgrounds something must unset `DISPLAY`,
`WAYLAND_DISPLAY`, `XDG_SESSION_TYPE`, `XDG_SESSION_DESKTOP`,
`XDG_CURRENT_DESKTOP`, `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`
first, and should use its own scratch directory so it never touches the real
`/tmp/.X11-unix`.

**A `trap` does not fire when the tool call is killed outright.** An
interrupted run left a live instance behind, which then collided with the
next run on the same scratch directory; both were found blocked for eight
minutes with no children. One scratch directory per run (`mktemp -d`), a lock
so a second copy refuses rather than races, and a cleanup step you can run by
hand.

**Two tests sharing one scratch directory will corrupt each other.** Each
case deletes and recreates the directory, so two copies are always racing on
whatever the other is halfway through.

**Never write an inline `wsl ... bash -c "..."` with pipes, `||`, `$(...)`
or `$?`.** PowerShell parses them first and mangles them — `||` is not a
statement separator, `head` and `wc` are not PowerShell commands, and
`> /tmp/file` redirects to `C:\tmp\file`, which does not exist. **Write a
`.sh` file and invoke it.** Every one of these cost a round trip, and the
failures look like bugs in the script rather than in the shell that ate it.

**`nohup … &` inside `wsl` is not detached.** `wsl` tears the session down
when the calling command returns and takes the child with it. An `apt-get
install` launched that way wrote no log at all and installed nothing, while
appearing to have started. Run long jobs as a background task from the harness
instead, and verify by asking `pkg-config` whether the library arrived — not
by whether `apt-get` returned 0.

**`bzImage` is compressed, so `strings` on it lies.** It reports every
display driver absent, including ones known to be present. The only
trustworthy evidence about which driver bound is the **guest's own dmesg**. An
earlier probe was discarded for this reason.

**The kernel's framebuffer message is `fb0`, not `/dev/fb0`.** A grep for the
path reports a working framebuffer as missing.

**`make O=… defconfig` fails on a dirty source tree and leaves a stub
`.config` behind.** The message is *"The source tree is not clean, please run
'make mrproper'"*, and the leftover file is a few hundred bytes. Anything that
reads symbols out of it will confidently report nonsense. `mrproper` first,
and check the config is over 1000 lines.

**pkg-config module names are not library file names.** `x11` not `libX11`,
`epoxy` not `libepoxy`, `xfont2` not `libXfont2`, `pciaccess` not
`libpciaccess`. Look them up with `pkg-config --list-all` instead of guessing;
guessing stopped three builds on libraries that were already installed.

**meson options must be read from the project's own `meson_options.txt`.**
xorg-server 21.x is meson, not autotools, and the option sets differ —
`-Dfbdev` and `-Dllvm` do not exist, and it is `systemd_logind` with an
underscore.

**`CC=…` is an environment variable, not a `meson setup` argument.** Passed
as a trailing flag, meson reads it as a source directory and reports
`ERROR: Neither source directory 'CC=gcc-13' … contain a build file
meson.build`, which points at the project rather than at the misplaced flag.

**This network cannot download 4.9 MB in five minutes.** `curl --max-time
300` failed partway. Use `-C -` to resume, and gate on `tar tf` rather than
on the transfer appearing to succeed — a truncated tarball extracts halfway
and then reports a build error against the source.

**Any change to a cache-key file forces the heavy stages to re-run.** The CI
cache key hashes `iso/build.sh`, `iso/live/init`, `iso/boot/grub.cfg`,
`iso/rootfs-overlay/**`, `iso/src-init/**`, `iso/firstboot/**`, `src/**` and
`iso/sudo/**`. `restore-keys` still restores the previous `iso/work/` on an
unrelated key, so the key is only a hint — what actually keeps a restored tree
honest is the per-stage stamp. A stage whose inputs moved re-runs even on a
cache hit (the kernel is the expensive one, ~7 min cold), and a warm
source/object tree makes the re-run cheap. Batch changes; don't dribble.

**A stage's skip-check and its stamp must name the identical file list — and
every file the stage installs must be in it.** `stamped_skip` and `stamp_set`
both hash `cat "$@"`, so if their argument lists differ by even one file the
stamp can never match and the stage re-runs on every build.
`build_copper` had exactly that: `stamp_set` hashed three hotfix scripts that
`stamped_skip` did not, so the stage silently never skipped. That mismatch also
hid a second gap — the stage installs `iso/startxfce.sh`
(`install -m 0755 "$ROOT/startxfce.sh" "$TGT/usr/bin/startxfce"`) but *neither*
list hashed it, so the only reason a launcher edit ever reached the ISO was the
always-rerun accident. Both lists now carry `startxfce.sh` and all three hotfix
scripts. When a stamp looks like it is not skipping, diff the two lists first.

**A cached musl toolchain is only usable at the path it was built at.**
`musl-gcc` is a wrapper that names its specs file and its crt/lib objects by
**absolute** path, and `$SYS` is `iso/work/sys` under the workspace, whose
directory is named after the repository. Renaming or transferring the repo
moves `/home/runner/work/<name>/<name>`, so a restored `musl-gcc` still exists
and still points at the old path, and cannot link anything: coreutils'
`configure` then dies with *"C compiler cannot create executables"*, which
blames coreutils rather than the cache. `build_musl` now compiles a one-line
program with the cached toolchain and rebuilds it when that fails, instead of
trusting that the file exists. This was a real red build.

**`xfce4` does not depend on a terminal emulator, and
`--no-install-recommends` does not pull one.** The gui stage names
`xfce4-terminal` explicitly. Without it the image has no `*.desktop` carrying
`Categories=…;TerminalEmulator;`, so clicking "Terminal" runs
`exo-open --launch TerminalEmulator`, finds no helper, and pops the "choose an
application" dialog — "nothing is chosen for terminal". The defaults live in
`iso/rootfs-overlay/etc/xdg/xfce4/helpers.rc` (`TerminalEmulator=xfce4-terminal`,
`WebBrowser=firefox`). exo reads the system-wide file after the user's own
`~/.config/xfce4/helpers.rc`; the system file is the one that works here
because first-boot's skel copy takes only top-level regular files, never a
nested `~/.config/...`.

**The kernel command line's last `console=` is `/dev/console`.** The single
most counter-intuitive thing in the whole boot; it produces a fake hang and
cost the most time. Correct order is `console=ttyS0,115200 console=tty0` —
register both, screen last.

**`console=ttyS0,115200` on a VM with no serial port is not a no-op.** It
takes `/dev/console` away from `tty0`. Add the serial port *and* put `tty0`
last.

**An active serial console hides Plymouth's graphical splash.** Plymouth reads
`/sys/class/tty/console/active`; when `console=ttyS0,115200 console=tty0`
names two consoles it concludes a serial console is in charge, forces its text
"details" splash and never creates a DRM/framebuffer renderer — so the theme is
never loaded and no frame is ever drawn. `--graphical-boot` /
`--ignore-serial-consoles` (or the `plymouth.ignore-serial-consoles` kernel
argument) is the way out. See bug 25.

**The live image has no `/dev/pts` unless the initramfs mounts devpts.** Two
things break silently: `sudo` dies with `unable to allocate pty`, and nothing
that needs a real PTY works (the XFCE terminal opens and cannot give its
shell a pty — vte's openpty fails on a missing `/dev/pts`). Fixed in
`iso/live/init` (2026-10-10) and owner-confirmed, but nothing in the CI build
catches pty-regressions because the build never boots.

**The writable layer is RAM unless a disk is labelled `COPPER`.** A
firefox-class install needs ~570 MB in the writable layer at once; on a 2 GB VM
the 50% tmpfs cap fits it, but that layer is throwaway. The upper moves to a
disk only when it carries the ext4 label `COPPER` — the label the wizard writes
on its last page — and `iso/live/init` falls back to the tmpfs when there is
none. You'll think "just attach a bigger disk and it fixes itself" — it does
not: a disk with no label does nothing, and the upper stays in RAM. (Built
2026-10-11; the real boot is still bug 20's open question.)

**`busybox adduser` and `addgroup` write to the real `/etc/passwd` and
`/etc/group` regardless of `HOME`, `PWD`, or anything else.** Probing them
inside a WSL shell **modifies WSL**. Back those files up and restore them in
a `trap`, or you will leave junk accounts behind. This happened twice here and
was cleaned up both times.

**Harness / VM facts:**

- copper-sh rejects `2>&1` and `&`: the tokenizer splits them and `parse_line`
  errors with `only one '>' per command`. Plain commands, at most one of
  `< > >>`.
- QEMU's monitor `sendkey` has **no `greater` key** and rejects uppercase
  names (`shift-D` → `invalid parameter: D`). A typed `>` silently never
  arrives — this bought a full debug round of "the serial output is empty".
- The shell runs on tty1; serial carries only init's chatter. Read the guest
  by screendump + tesseract (installed in the WSL box) instead of redirecting
  to `/dev/ttyS0`; `diag2-xfce.sh` is the working pattern.
- **A green CI run does not mean the artifact is correct.** Run
  `36220249701` was fully green and shipped an ISO built from the previous
  commit's `init`. Always take the artifact apart: mount it, `gzip -dc` the
  initrd, decode the cpio, read `/init` back out. Windows shows 8.3 names
  because the image has Rock Ridge and **no Joliet** — `COPPER_I` is
  `copper-init`, and that is cosmetic, not a bug.

## Config facts worth not rediscovering

Each of these cost a wrong turn once. All were checked against real sources.

- **busybox's `make defconfig` is not a stock config.** busybox patches kconfig
  with `const char conf_defname[] = "/dev/null"`
  (`scripts/kconfig/confdata.c:25`), so "defconfig" means *the Kconfig
  defaults*. There is no `configs/defconfig` in 1.36.1. Per-applet symbols
  live in `//config:config SYMBOL` comments inside the `.c` files and in the
  directory `Config.src` files.
- `CONFIG_STATIC` is `default n`, so it must be set explicitly — and **after**
  `make defconfig`, because reassigning a symbol defconfig already answered is
  silently dropped (first assignment wins). That's what `set_bb_config` is
  for.
- **6.12 has no `CONFIG_ETHERNET`.** The driver menu is unconditional under
  `NET`/`NETDEVICES`. Those are the real gates.
- In 6.12, `config INET` moved to `net/Kconfig` and `net/ipv4/Makefile`
  builds `tcp.o`/`udp.o` in `obj-y` unconditionally under `INET`. So
  `CONFIG_INET=y` (which `x86_64_defconfig` sets) is enough for IPv4.
- `BLK_DEV_NVME` lives in `drivers/nvme/host/Kconfig` in 6.12. It's
  `tristate` with **no default**, so the explicit `--enable` in `build.sh`
  turns it on.
- `CONFIG_OVERLAY_FS` is also `tristate` with no default. The entire live-root
  design rests on `build.sh` passing `--enable OVERLAY_FS`.
- vmxnet3's Kconfig path isn't
  `drivers/net/ethernet/vmware/Kconfig` in 6.12 and the symbol name couldn't
  be pinned down. `build.sh` passes **both** `--enable VMXNET3` and
  `--enable VMWARE_VMXNET3`; kconfig drops whichever doesn't exist.
  Deliberately not asserted.
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
- udhcpc does **not** put `PATH` in the lease script's environment, so init
  has to set it before the exec.
- busybox installs udhcpc at `/sbin/udhcpc`, `ip`/`ifconfig`/`route` in
  `/sbin`, `ping` in `/bin`, `wget`/`nslookup` in `/usr/bin`, `switch_root` in
  `/sbin`. It does **not** install a lease script, which is why we ship one.
- `wget`'s `https://` can take **two very different paths** depending on what
  is on the machine, and which one runs decides whether a download succeeds:
  **(a) the openssl helper** (`FEATURE_WGET_OPENSSL`, `default y`): busybox
  forks `openssl s_client` and feeds it the sockets — this path verifies
  certs (unless `--no-check-certificate`) and works against github.com
  releases; **(b) busybox's internal TLS** (`FEATURE_WGET_HTTPS`, `default
  y`): used only when the openssl exec fails or wasn't configured — it prints
  `note: TLS certificate validation not implemented` every time, does **not**
  verify certificates, and on a faithful 1.36.1 build it hangs against
  `release-assets.githubusercontent.com` (the GitHub release redirect) while
  fetching Pages and github.com itself fine. **The ISO ships `openssl` +
  `ca-certificates` now** (gui stage, since 2026-10-10), so a normal image
  takes path (a). If you ever see that note on the machine, the openssl exec
  failed or was dropped, i.e. path (b) — and payload downloads from GitHub
  releases will never complete.
- **busybox's `mke2fs` applet cannot make an overlay upper.** busybox 1.36.1
  creates ext2 only — no `-t`, no journal — and it sets `s_feature_compat` from
  `EXT2_FEATURE_COMPAT_SUPP` (`util-linux/mkfs_ext2.c` ~516,
  `include/bb_e2fs_defs.h:526`), which in this version is **0**. So the
  `EXT2_FEATURE_COMPAT_EXT_ATTR` bit (0x0008) is never set, an ext2 with no
  xattr support is exactly what overlayfs refuses as an upper, and "just use
  the busybox applet" silently produces a disk that cannot hold the writable
  layer. Persistence uses the real `mkfs.ext4` from `e2fsprogs` (gui stage),
  and the gui stage fails the build if it is missing. Read from the 1.36.1
  source, not assumed.
- **busybox `blkid` has no `-s` or `-o`.** It is `blkid [DEVICE]...` and prints
  one tagged line per device: `/dev/sdb: LABEL="COPPER" UUID="..." TYPE="ext4"`
  (the `TYPE=` only because `FEATURE_BLKID_TYPE` defaults on). `/init` matches
  the `LABEL="COPPER"` substring instead of asking for a single field. `findfs
  LABEL=COPPER` exists too, but a per-device `blkid` keeps the boot log honest
  about what was probed and skipped.
- **PID 1 mounts a fresh tmpfs over `/run`, burying anything the initramfs left
  there.** `mount_if_needed("tmpfs", "/run", "tmpfs")` in `copper-init.c` calls
  `mount()` unconditionally and only tolerates `EBUSY` — and a second tmpfs over
  an existing one is a stack, not an error. So markers for later boot stages go
  on the overlay (the wizard's is `/var/lib/copper/live-boot`), never in `/run`.
- **musl ships no kernel UAPI headers.** There is no `linux/`, no `asm/`, no
  `asm-generic/`. Building `libnl` or `wpa_supplicant` static against musl
  therefore fails in `linux/netlink.h` → `asm/types.h` → not found, and adding
  only `asm-generic` just moves the error one file along. The `wifi` stage makes
  a shim directory of symlinks into the host's `linux-libc-dev` (Debian/Ubuntu
  put `asm/` under the multiarch triple) and passes it with **`-idirafter`**,
  which is what puts the kernel headers *after* musl's own on the search path
  instead of in front of them.
- **`wpa_supplicant`'s kconfig does not find libnl on its own.** `CONFIG_LIBNL32=y`
  is resolved through pkg-config, so `PKG_CONFIG_PATH` has to point at the
  prefix libnl was installed into (`$WP/lib/pkgconfig`), and the sources also
  want `-I$WP/include/libnl3`. Miss it and the error is
  `Package 'libnl-3.0' not found`, which reads like libnl is absent when only
  the path is.
- **`CONFIG_TLS` defaults to `openssl`.** A static musl build then fails at
  `openssl/opensslv.h`. wpa_supplicant carries its own implementation:
  `CONFIG_TLS=internal` with `CONFIG_INTERNAL_LIBTOMMATH=y` (its bundled bignum)
  removes the OpenSSL dependency entirely, which is what the image ships.
- **A managed wireless interface reports `ARPHRD_ETHER` (1), exactly like a
  wired NIC.** `/sys/class/net/<if>/type` cannot tell them apart — so the old
  `first_nonloop_iface()` type test would have handed an unassociated `wlan0` to
  `udhcpc`. cfg80211 gives each wireless interface a `wireless` subdirectory
  under its sysfs entry; that directory's presence is the test
  (`is_wireless()` in `copper-init.c`).
- **`BRCMFMAC_PCI` does not exist.** The Broadcom PCIe symbol is
  `BRCMFMAC_PCIE`; requesting the other one is silently dropped, the same trap
  as `DRM_VMWGFX`. Every symbol now asserted =y for wireless was run through
  this kernel's `olddefconfig` first, so the assert list contains only names
  that survived.
- **Ubuntu's `linux-firmware` is zstd-compressed, every file, as `<name>.zst`.**
  A kernel without `CONFIG_FW_LOADER_COMPRESS_ZSTD` requests `<name>`, finds
  nothing, and fails the load with `-ENOENT`. The driver is present, the blob is
  visible in the image, and the radio still comes up dead — which points at the
  driver, the interface or the supplicant, and not at a kconfig symbol. The
  `wifi` stage keeps the compressed names it was shipped with (decompressing on
  the build host would only inflate the ISO) and asserts the option is `=y`.
- **`linux-firmware` is a metapackage on noble, not the files.** The `.deb` apt
  downloads is a 1.8 kB stub that carries no firmware; the blobs arrive as split
  subpackages (`linux-firmware-intel-wireless`, `linux-firmware-realtek`, and
  friends). Unpacking only the package named `linux-firmware` leaves the staging
  tree empty, and the glob that looks right — `linux-firmware_*.deb` — does not
  match the split names, so the build stops at its own "did not unpack" check
  with the download sitting right there. Every `.deb` apt fetched is unpacked.
- **`regulatory.db` is not in `linux-firmware`.** It is its own package,
  `wireless-regdb`, which recommends nothing and is recommended by nothing, so
  asking apt for `linux-firmware` alone gives a radio that loads firmware and
  then has no regdomain. Both are downloaded. It is also the one staged file
  that is *not* compressed — a small detail that makes a `.zst`-only sweep look
  complete while skipping it.

---

# bug tracker

Every bug we ever hit and who killed it. No name = still open.
29 bugs total: 22 fixed, 7 open.

| bug number | fixed by | what was the bug | commit |
| --- | --- | --- | --- |
| bug 1 | farcrowx | overlay dirs were created before the tmpfs hid them | (3ae61c1) |
| bug 2 | farcrowx | CI shipped the previous commit's init — green run, stale ISO | (d9b1ce1) |
| bug 3 | farcrowx | $0 is relative after the script cd's, and the stamps ate it | (307d6b9) |
| bug 4 | farcrowx | rescue check -x followed an absolute symlink into the initramfs | (b7facc7) |
| bug 5 | farcrowx | build gate -e followed the symlink into the build host | (0cf3fd9) |
| bug 6 | farcrowx | stale files survived in the cached staging trees | (0cf3fd9) |
| bug 7 | farcrowx | last console= is /dev/console — serial stole the screen | (971b6e5) |
| bug 8 | farcrowx | serial log got 0 bytes under quiet | (9750dac) |
| bug 9 | farcrowx | DHCP discovered into sit0, eth0 never came up | (2601222) |
| bug 10 | 12hrformat | copper charge/rollback — four defects, each making it dead | (ab6c17f, b811a15) |
| bug 11 | 12hrformat | GdkPixbuf loaders absent → XFCE crash loop | (6ebc11a) |
| bug 12 | 12hrformat | icons still failed: mime database + SVG loaders | (12e7c86, 0770d98) |
| bug 13 | 12hrformat | VMware mouse dead — launcher picked the wrong device | (7df142c, cc1ad9b) |
| bug 14 | 12hrformat | no /dev/pts — sudo and the terminal died | (9d2705c) |
| bug 15 | still open | firefox install dies of ENOSPC | (2026-10-10) |
| bug 16 | 12hrformat | payload downloads hung — busybox internal TLS | (99515d1) |
| bug 17 | 12hrformat | startxfce false-started on a dead server / missing XFCE | (1bf9a4f) |
| bug 18 | still open | `sudo shutdown` / `sudo reboot` do nothing |  |
| bug 19 | 12hrformat | the desktop session runs as root — firefox refused to start | (711fcb9) |
| bug 20 | still open | persistence isn't built — the writable layer is RAM |  |
| bug 21 | 12hrformat | VMware framebuffer unproven — real VMware boot paints XFCE | (boot-verified 2026-10-11) |
| bug 22 | 12hrformat | ISO rationalised Rock Ridge flattened modes — sudo lost setuid | (e934a12, 553528f) |
| bug 23 | 12hrformat | a non-root X server dies grabbing the VT — `-novtswitch` was the wrong flag | (131b86d) |
| bug 24 | still open | startxfce reuses a dead display when /tmp persists |  |
| bug 25 | still open | plymouth never draws a frame — serial console forces the text splash |  |
| bug 26 | dragon | the empty-file gate rejected the Hyprland skel's intentional zero-byte files | (2026-10-16) |
| bug 27 | still open | ingot update deletes a package it then fails to reinstall |  |
| bug 28 | 12hrformat | payloads installed a binary you could not invoke by name | (2026-10-16) |
| bug 29 | still open | `sudo reboot` / `sudo shutdown` do nothing under busybox init |  |