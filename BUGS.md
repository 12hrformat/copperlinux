# BUGS.md

> please note down all the bugs you come across in h1 heading (#) thier name and how they affect things on a scale of 1-10.

> remove any bugs if fixed and please write in this format [bug number [] fixed by [] ] at the bottom of the file so we can track how many bugs were there and who fixed them

Only bugs that are not fixed live here. Fixed ones are removed from the list —
their graves are in the tracker at the bottom of the file.

---

# 15. firefox install dies of ENOSPC — impact 8/10

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

**Two separate causes:**

1. **busybox has no `shutdown` applet at all.** `busybox --list` on a
   faithful 1.36.1 build shows `shutdown: MIA` while `halt`, `poweroff` and
   `reboot` are all present — so `shutdown` is simply "command not found".
   Nothing in the ISO ships one.
2. **`reboot`/`halt`/`poweroff` without `-f` never call the reboot(2)
   syscall.** They signal PID 1 and expect init to do the work, and
   copper-init ignores `SIGINT`/`SIGTERM`/`SIGHUP` (`copper-init.c:269-271`)
   — so the request silently dies. `reboot -f` would work; nothing invokes
   it.

**Fix candidates:** teach copper-init the power signals (sync + `reboot(2)`
with the right magic), and ship a small `/sbin/shutdown` wrapper since busybox
will never provide the applet.

---

# 19. the desktop session runs as root — impact 7/10

**How it affects things:** every process in the desktop was uid 0. Thunar warns
"you are logged in as root", every bug the desktop hits is a root bug,
anything created in the session is root-owned — and it made the browser
unusable.

**What happened (verified):** `spawn_tty` (`copper-init.c`) did `setsid()`,
opened `/dev/tty1`, dup2'd it onto 0/1/2, `TIOCSCTTY`, then `execl`'d
`/usr/bin/copper-sh` — with no `setgid`/`setuid` anywhere, so the child stayed
uid 0 while `HOME` said `/home/<user>`. Firefox hard-refuses that combination:

    Running Firefox as root in a regular user's session is not supported. ($HOME is /home/dragon which is owned by dragon.)

**Decision (owner, 2026-10-10):** the wizard-created user owns the session;
PID 1 keeps root; sudo is the elevation path.

**The fix is in the tree (2026-10-11), but nobody has booted it yet:**

- `spawn_tty`'s child now resolves the login name from
  `/etc/copper-firstboot.done` and `initgroups`/`setgid`/`setuid`s to it before
  the exec. No marker user (first boot, or a stale account) → the child stays
  root, which is what the image did before.
- Xorg now runs as that user too, so `copper-init` chowns the nodes a non-root
  X server opens — `/dev/input/*`, `/dev/dri/*`, `/dev/fb*`, the tty/VT nodes —
  to the session user at boot. Without udev they are root-owned and the server
  comes up with a dead pointer and no keyboard. It also makes `/dev/shm` and
  `/run/user/<uid>` first, because `startxfce` used to but as the user it
  cannot `mkdir` under the root-owned `/dev` or `/run`.
- `startxfce` passes `-keeptty -novtswitch` when it is not root: with no
  logind, a non-root Xorg cannot grab or switch the console VT, and it
  `setsid()`s itself first. The root path is untouched.
- `tests/init-session.sh` unit-tests the drop (reads the marker, resolves a
  real account, forks and asserts the child lands on it). CI runs it.

**Still open because:** "built" is not "verified". Needs a real boot: `id` on
the console shows the wizard user, `sudo whoami` answers `root`, and
`startxfce` gives a desktop whose pointer and keyboard both work and whose
terminal runs `firefox`.

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

# 21. VMware framebuffer unproven — impact 5/10

**How it affects things:** on real VMware the *display* half of the desktop is
unconfirmed — the mouse is confirmed to track, the screen is not. VirtualBox
cannot be tested at all here.

**What happens:** `vmwgfx` probes the adapter correctly — reads the FIFO, the
VRAM and the SVGA version — then prints:

```
vmwgfx 0000:00:03.0: [drm] *ERROR* vmwgfx seems to be running on an unsupported hypervisor.
```

It checks the hypervisor vendor, and QEMU is not VMware. The driver is the
right one and works right up to its own hardware check. `FB_VESA`/`FB_EFI`
were never exercised (probe boots with `-kernel`, no VGA BIOS), and
`cirrus-vga` has no driver — recorded as a gap, not fixed, because nobody
boots it.

**Status:** only a boot on real VMware settles it.

---

# Everything fixed — the details are gone, the lessons stay

Fixed bugs were removed from the list above per the rules. The lessons they
cost are preserved below so they don't have to be learned twice. Their full
records — number, name, who fixed them — are in the tracker at the bottom.

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

**Any change to a cache-key file is a full kernel rebuild.** The CI cache key
hashes `iso/build.sh`, `iso/live/init`, `iso/boot/grub.cfg`,
`iso/rootfs-overlay/**`, `iso/src-init/**`, `iso/firstboot/**` and `src/**`.
A change to *any one* of those throws away the whole `iso/work/` cache. The
cache is saved even on failure (`if: always()`), so a red run still warms the
next one. Batch changes; don't dribble.

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

---

# bug tracker

Every bug we ever hit and who killed it. No name = still open.
21 bugs total: 16 fixed, 1 stopgapped, 4 open.

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
| bug 19 | still open | the desktop session runs as root |  |
| bug 20 | still open | persistence isn't built — the writable layer is RAM |  |
| bug 21 | still open | VMware framebuffer unproven |  |