# BUGS.md

> please note down all the bugs you come across in h1 heading (#) thier name and how they affect things on a scale of 1-10.

---

# 15. firefox install dies of ENOSPC — impact 10/10 (root cause is 20)

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

**The real fix is bug 20** (persistence): the upper moves to a disk. That is
boot-verified now (2026-10-19: the writable layer was a 20 GB disk with 19 GB
free), so the ENOSPC ceiling should be gone. The stopgap stands until
`ingot install firefox` is re-run on a persistent boot and passes.

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

**Fix written (2026-10-20):** tell Plymouth the serial console is not the
display, through the kernel argument it already reads for its other switch.
`iso/boot/grub.cfg`'s normal entry now ends

    ... quiet splash plymouth.ignore-udev plymouth.ignore-serial-consoles \
        console=ttyS0,115200 console=tty0

next to `plymouth.ignore-udev`, and `iso/build.sh`'s plymouth-stage comment
records why. It maps to `PLY_DEVICE_MANAGER_FLAGS_IGNORE_SERIAL_CONSOLES` the
same way `plymouth.ignore-udev` maps to its flag in `main.c`, and it changes
only what Plymouth treats as the display — the two `console=` entries are
untouched and the serial log still fills.

**Why the kernel argument and not the `plymouthd` flags.** The earlier plan
named `--graphical-boot`/`--ignore-serial-consoles`, but the noble
`plymouthd(8)` man page (`plymouth 24.004.60-1ubuntu7.2`) documents neither,
and an option the daemon rejects would kill the splash outright rather than
mis-draw it. The kernel argument is the mechanism this build already relies on
for `ignore-udev`, is confirmed by upstream's own console-detection bug reports
(the exact `console=ttyS0 console=tty0` case), and cannot break the daemon if it
is ever unrecognised — it is simply ignored.

**Why this entry stays in the list even though the fix is written.** Unlike
bug 27, this one cannot be closed by a script test: it is a boot-time renderer
decision, and the only proof is a booted ISO drawing frames. It stays here until
a boot says so.

**Still open because:** the fix is not booted yet. Verification is a QEMU boot
of a remastered ISO (or `-kernel`/`-initrd` with the same `-append`),
confirming the non-blank sample count jumps towards a full frame and changes
from frame to frame.

Until a new ISO lands, the splash can be forced by hand at the GRUB menu: edit
the entry and append `plymouth.ignore-serial-consoles` before booting.

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

# 30. Hyprland comes up with no keyboard and no pointer — impact 10/10 [ASSIGNED TO 12HRFORMAT]

**How it affects things:** on a real boot `starthyprland` starts the compositor:
the wallpaper paints, the bar appears, and then nothing. The pointer will not
move, no key types anywhere, no window can be opened. The session looks alive
and cannot be used at all, and without the Ctrl-Alt-Del fix (bug 31) there was
no way out of it either.

**What happens:** Hyprland reads its keyboard and pointer through libinput.
libinput enumerates `/sys/class/input/event*` through libudev and then discards
every device `udev_device_get_is_initialized()` calls false. That flag does not
mean the device is broken — it means a record for the device exists under
`/run/udev/data`, which `systemd-udevd` is what writes. **This image runs no
udev daemon** (no systemd, no udev — "no udev" in HANDOFF.md), so no record is
ever written, libinput finds zero devices, and the compositor starts with no
input.

**Root cause:** a deliberately udev-less image meets a library whose device
enumeration is gated on a udev daemon having run. XFCE never showed the bug
because `startxfce.sh` writes an `/etc/X11/xorg.conf` with `AutoAddDevices
false` and an explicit evdev section per device: Xorg opens those paths
directly and never asks libudev whether they are "initialized".

**Status:** fixed 2026-10-17. `seed_udev_input_db()` in `copper-init.c` writes
the record the daemon would have: for each `/sys/class/input/eventN` it writes
`/run/udev/data/c<major>:<minor>` holding `I:<usec>` and `E:ID_INPUT=1`. It
runs as root before the login shell, so the records are in place before
`starthyprland` can be typed. `starthyprland` now warns if the records are
missing rather than leaving a dead pointer unexplained, and
`tests/init-session.c` asserts the file name and the `I:` line libudev reads.

**Not covered yet:** hotplug. A keyboard plugged in after boot gets no record
until the shell is restarted (PID 1 reruns the seeder each pass). Fine for a VM
whose devices are present from boot; a real udev replacement is the eventual
answer.

---

# 31. Ctrl-Alt-Del does nothing — no way out of a stuck session — impact 7/10 [ASSIGNED TO 12HRFORMAT]

**How it affects things:** when the session wedges — dead input (bug 30), a
compositor that stopped responding, anything — the one escape that every Linux
gives you is Ctrl-Alt-Del, and here it did nothing. There was no way back to a
login except reaching for the VM's power control or the host's reset.

**What happens:** the kernel does not reboot on Ctrl-Alt-Del itself. It sends
SIGINT to PID 1 and lets init decide, and Copper's PID 1 installed `SIG_IGN` on
SIGINT — so the signal was received and thrown away, on purpose, every time.

**Root cause:** the signal table treated Ctrl-Alt-Del as "not a thing this init
should act on", which is a defensible-sounding choice that turns out to be a
trap the moment a session stops responding. sysvinit, busybox init and systemd
all reboot on Ctrl-Alt-Del.

**Status:** fixed 2026-10-17. `copper-init.c` now installs its power handler on
SIGINT, and `power_how(SIGINT)` returns `RB_AUTOBOOT`, so Ctrl-Alt-Del reboots
the way it does everywhere else. `tests/init-session.c` asserts the mapping.

---

# 32. the libudev-record fix for #30 wrote nothing — impact 10/10

**How it affects things:** exactly like #30, on a real boot, after a green CI run
and a clean boot log. `starthyprland` still came up with a dead pointer and no
keyboard, and the boot log carried no line saying a record was written. The
first fix had shipped, passed its test, and done nothing.

**What happens:** `seed_udev_input_db()` builds the record path as
`<dbdir>/c<major>:<minor>` and opens it with `fopen(dst, "w")`, but the call in
the boot loop only created `/run/udev` — never `/run/udev/data` underneath it,
and the function did not make its own directory either. Every `fopen` therefore
failed with `ENOENT`, `written` stayed 0, the boot message was never printed,
and the launcher's warning fired. The boot log read exactly like a machine whose
input devices were not present, which sent the diagnosis at the kernel and the
device enumeration instead of at the six lines that were written to write a file
into a directory that did not exist.

**Root cause:** the seeder depended on its caller having made its output
directory, and the caller made only the parent. `tests/init-session.c` did not
catch it because the test fixture created the directory itself before calling
the function — the one arrangement in which the bug cannot happen. The test was
shaped around the code instead of around the use.

**Status:** fixed 2026-10-17. `seed_udev_input_db()` now makes its own database
directory (`mkdir(dbdir, 0755)`, EEXIST ignored on every pass after the first),
and PID 1 says `input: no /sys/class/input/event* node to seed yet` when it
writes none, so a future failure is legible at boot instead of looking like
absent hardware. The test fixture no longer creates the directory, so the test
fails if the seeder stops making it.

# 33. The power path fails silently — impact 6/10 [ASSIGNED TO FARCROWX]

**How it affects things:** two ways to lose the machine without a word. The
`shutdown` wrapper accepted arguments it did not understand: `shutdown +10`
(a normal util-linux incantation) powered the machine off **immediately**
instead of in ten minutes, `shutdown --bogus` powered it off too, and
`shutdown -r -h now` guessed which mode you meant. And if `reboot(2)`
refused, `on_power_signal()` called `_exit(0)`: PID 1 died, the kernel
panicked "Attempted to kill init", and nothing anywhere said why.

**What happens:** the flag loop in `iso/shutdown.sh` matched the flags it
knew and silently ignored every other argument, so an unsupported request
fell through to the default action (power off now). The image has no
scheduler, so there is no correct way to honour `+10` anyway -- the honest
answer is an error, not someone's machine powering off mid-work.

**Root cause:** parsing without a contract (anything unrecognised falls
through to the default) and a signal handler whose failure path was
`_exit(0)` -- the cheapest exit, taken exactly when a message matters most.

**Status:** fixed 2026-10-18. `shutdown.sh` validates every argument --
unknown options, conflicting mode flags, any time operand but `now` -- and
exits non-zero with a message on stderr without running an applet; `--help`
prints the exact interface. `on_power_signal()` reports through `write(2)`
(async-signal-safe; fd 2 is `/dev/console`) and returns instead of exiting,
and the main loop's `waitpid` retries on `EINTR` so a returned handler
cannot spawn a second shell on the same tty. `tests/shutdown-gate.sh`
asserts the rejection path (non-zero exit, no applet ran) and
`tests/init-session.c` drives the handler with a failing fake `reboot(2)`
plus the previously-unasserted `SIGPWR -> halt` mapping. Gates only -- not
booted.

---

# 34. the libudev records name no device type — input is still dead — impact 10/10 [ASSIGNED TO 12HRFORMAT]

**How it affects things:** exactly like #30 again, on a real boot, after the
records had been written and the boot log said so. Two fixes in (#30, #32), the
seeder reporting records written, and the session still came up with a pointer
that does not move and a keyboard that types nowhere.

**What happens:** libinput does not work out what a device is from its kernel
capabilities — it reads udev's `ID_INPUT_*` tags, and the gate near the top of
`evdev_device_create()` in libinput's `evdev.c` drops a device the moment its
tags say nothing beyond the type-agnostic one:

    if ((udev_tags & EVDEV_UDEV_TAG_INPUT) == 0 ||
        (udev_tags & ~EVDEV_UDEV_TAG_INPUT) == 0)
                goto err;   /* "not tagged as supported input device" */

`ID_INPUT` alone makes the second half of that test true, so every record this
image wrote was read, parsed and thrown away — the same outcome as the missing
directory in #32, reached from the other side. And the drop is silent where it
matters: libinput logs it at INFO, Aquamarine maps libinput's non-ERROR levels
to DEBUG, and Hyprland filters those, so nothing reaches the serial log.

**Root cause:** the seeder wrote the initialise stamp and `E:ID_INPUT=1`, which
is what libudev needs to call a device initialized, and stopped. On a real
machine the rest comes from udev's `input_id` builtin, which reads
`capabilities/{ev,key,rel,abs}` and `properties` out of sysfs and writes down
the verdict — `ID_INPUT_KEYBOARD`, `ID_INPUT_MOUSE`, `ID_INPUT_TOUCHPAD` and
the rest. This image has no udev, so nobody ever wrote them, and the two fixes
before this one repaired parts of the record that were never the part libinput
was reading.

**Status:** fix in the tree, **half-verified on a boot**. The classifier, the
sysfs walk and the record format are all proven: on the real boot after the
fix the **pointer moves**. The keyboard still types nowhere, and the gate above
leaves only two ways that can be: its record is missing, or its record carries
no type. Everything else was ruled out against libinput's source — a bare
`ID_INPUT_KEY` is enough (both it and `ID_INPUT_KEYBOARD` map to the same
`EVDEV_UDEV_TAG_KEYBOARD`), the word order matches systemd's parser, and the
key bitmap is well inside the seeder's buffer.

Neither the seeder nor the session said anything per device, so a boot could
not tell those two apart. Both do now:

- PID 1 logs one line per input device, every pass — the sysfs name and the
  tags it decided (`input: input0 "AT Translated Set 2 keyboard" -> KEY
  KEYBOARD`). A device whose `capabilities/ev` reads empty but whose key bitmap
  has real keys in it is still given its `KEY` tag: the one deliberate
  departure from udev here, on the grounds that an extra tag costs a setting
  and a missing one costs the device.
- `starthyprland` names every device and what its record says, and prints that
  list only when at least one device would be dropped. The old check asked
  "does any record carry a type", which the working mouse always answered yes
  to — it stayed silent through exactly this failure.
- `tests/starthyprland-gate.sh` drives the preflight against a fake input tree
  (cases 20-22): keyboard dropped, all typed, no records at all.

Closing this needs one more boot, whose log now names the fate of every device.

**That boot ran (2026-10-20).** Its log shows the seeder working end to end —
`input: wrote 4 libudev record(s), 4 naming a device type`, and per device
`input1 "AT Translated Set 2 keyboard" -> KEY KEYBOARD`. The keyboard's record
*does* carry its type, so the "missing type" half of the two possibilities is
gone. What is still unconfirmed is typing **inside a Hyprland session**: that
boot typed at the text console, which does not go through libinput. The entry
stays open until a `starthyprland` boot has a working keyboard in the
compositor.

---

# 35. the wizard offers the persistence disk while it is mounted — impact 6/10

**How it affects things:** the "Keeping your files" page is destructive — the
pick gets `mkfs.ext4 -L COPPER`'d. Offering the disk that is *currently* the
session's writable upper turns one absent-minded `ERASE` into wiping the
filesystem the machine is running from.

**What happened (2026-10-19, during bug 20's verification):** boot 1 formatted
the spare NVMe. On boot 2 `/init` claimed it and mounted it — the live-boot
marker read `upper=/dev/nvme0n1`, which `iso/live/init` only writes after the
mount succeeded — and the wizard's last page *still* listed that same
`nvme0n1` as a spare disk to erase. The pick was skipped and nothing was
formatted; every later boot was correct.

**Why it should be impossible:** `disk_in_use()` refuses any disk named by a
line in `/proc/mounts`, and `/dev/nvme0n1 ... /mnt/upper ext4 ...` should have
matched it. Either that read saw something else, or the page ran against a view
of the system without the mount. The original plan was to need one boot that
prints the wizard's `/proc/mounts` next to its offered list.

**Fix in tree (2026-10-19), without waiting for that boot.** The marker already
knew the answer: `/init` writes `upper=<disk>` on the same page as `media=`, and
the wizard was reading only `media=`. `read_boot_marker()` now reads both and
`is_upper_disk()` refuses that disk outright — a check on the marker cannot miss
a mounted layer, because the marker is written *after* the mount succeeded. That
is the authority now; `/proc/mounts` stays as the second line. Whether the
`/proc/mounts` read is also broken is still unproven, so the bug is not closed.

The automatic-take change made this urgent rather than cosmetic: had the page
auto-formatted a single candidate while this was open, the mounted upper could
have been formatted with no `ERASE` and no conversation at all. `tests/persist.sh`
now covers it — case 7 writes `upper=/dev/sdy` and asserts the disk is not
offered and nothing is formatted.

**Status:** open (fix in tree 2026-10-19, needs a boot to confirm). Caught by the
human, not a test — the fixture never mounted the disk it offered, so the old
gate could not see it.

---

# 36. a home is seeded once and never repaired — the Hyprland config loads half — impact 7/10

**How it affects things:** Hyprland starts, but from a config that only half
loads. The failing `require()` is the environment block — the thing that sets
the desktop's variables — so the compositor comes up with defaults its authors
never wrote, and the person running it has no reason to suspect the config
rather than the compositor. It is also permanent: once a home has a config, no
later image can add anything to it.

**What happens:** `~/.config/hypr/hyprland.lua` is there, so the launcher
concludes the user has a config and never seeds again -- but
`~/.config/hypr/conf/environments/default.lua` is not, and
`conf/functions.lua:26` is `require("conf." .. variant_name .. "." .. variant_file)`.
That file is one of ML4W's **intentional zero-byte Lua include stubs**, the ones
bug 26 had to exempt from the rootfs stage's empty-file gate: empty is valid Lua
and `require()` loads it. A home seeded by a build whose gate still dropped them
is missing exactly those files.

**Root cause, two of them on top of each other:**

1. The decision to seed was "does `~/.config/hypr/hyprland.lua` exist?", and a
   home seeded by an older image answers *yes*. So the seeding branch never ran
   again and the missing stub could never come back.
2. It could not have come back even if it had run:
   `cp -a -n "$SKEL"/. "$HOME"/` -- busybox's `cp` reads `-n` as "skip an
   existing **anything**". Given a `~/.config` that already exists it skips the
   whole directory, copies nothing below it, and reports success. Reproduced in
   the WSL Kali busybox 1.38.0: with `dst/sub` present and `src/sub/b` new,
   `busybox cp -a -n src/. dst/` copies nothing into `dst/sub`; GNU `cp -a -n`
   copies `b`. The image builds 1.36.1, and that `-n` behaviour is not
   version-specific.

**Why the file was missing at all, which is not a seeding problem:** bug 26
exempted the shipped skeleton from the rootfs stage's empty-file **gate** and
stopped there. The same stage's tree-wide empty-file **sweep** had no such
exemption, and its guards were written for `find .` while the tree is named by
an absolute path, so they matched nothing. A build that re-ran rootfs over a
cached tree deleted the stubs out of the skeleton already in it, and the
Hyprland stage's stamp still reported "already staged" and did not put them
back. So the ISO's own skeleton could be missing the file, and a home seeded
from it was broken from the first boot -- bug 40 is that half, fixed the same
day.

**Status:** fixed in the tree 2026-10-19. `starthyprland.sh` no longer uses
`cp` for this: `seed_config()` walks the shipped tree, makes the directories
that are missing, and copies only the files and symlinks that are absent -- a
file that is already there is never rewritten, so a user's edits survive. It
runs for a bare home as before, **and as a repair pass on every start** for a
home that already has a config, printing
`repaired the session config: added N missing file(s)` only when it changed
something. `tests/starthyprland-gate.sh` cases 23-25 lock the contract: a
partial home is repaired without touching the file that was there, a whole home
is left alone, and a fresh seed still carries zero-byte stubs and exec bits.
Boot-verify: the repair line on the first start of a home seeded before this,
and the session log no longer naming a missing module.

---

# 37. `ingot install` prints a GNU tar warning that reads like a failure — impact 1/10 (cosmetic)

**How it affects things:** the install looks like it is failing. It is not:
tar exits 0, every file lands, and `ingot` records the package. But a user who
sees `tar: usr/share/icons/Humanity/emblems/32: Directory renamed before its
status could be extracted` on a live boot reasonably stops and asks -- which is
what happened (2026-10-19).

**What happens:** the message is **GNU tar's**, not busybox's
(`grep -a "renamed before" /usr/bin/tar` matches; `/usr/bin/busybox` has no such
string). The payloads ship no `tar`, so the one that runs is the image's, from
the `Priority: required` closure. GNU tar emits that line when it has to move a
directory aside to replace it, which means it needs something **in the live
tree** to collide with.

**What was ruled out:** extracting the payload into an empty tree and over
itself, with GNU tar 1.35 and with busybox 1.38, exits 0 with no stderr; the
payload has no duplicate paths. Four candidate collisions were staged against
it (an existing directory, a mode-0700 directory, a symlink where the archive
has a directory, a nested file, a read-only directory) and none of them
reproduces it. So it is the live tree's own `Humanity` installation (the ISO's
icon theme) meeting the payload's copy, and only on the machine.

**Status:** benign, no fix needed. If it ever matters, one live
`ingot install` with the tar stderr captured to a file pins the exact entry.

**Found while looking, and worth knowing:** the payload carries 17
`@N`-suffixed names that are not part of the icon theme's real layout, e.g.
`usr/share/icons/Humanity/emblems@2 -> emblems` sitting next to the real
`emblems/` directory (and the same set under `Humanity-Dark`). They look like a
conflict-rename left behind by whatever merges a payload's closure into one
tree. Harmless -- a stray symlink pointing at the real directory -- but the next
payload build should stop producing them.

---

# 40. the rootfs empty-file sweep deleted the Hyprland skeleton's Lua stubs — impact 7/10

**How it affects things:** bug 26 exempted the shipped Hyprland skeleton from the
rootfs stage's empty-file **gate** and stopped there. The same stage also
**sweeps** every zero-byte file out of the tree just before that gate, and the
skeleton was not exempt from the sweep. A rebuild that re-ran rootfs over a
cached tree therefore deleted the skeleton's include stubs -- the files ML4W's
Lua configuration `require()`s -- and the ISO shipped without them. Every home
seeded from that ISO came up half-loaded, which is what the human hit. Bug 36 is
the other half: once a home has a config, it could not repair itself either.

**What happens, exactly:** `build_rootfs` runs
`find "$TGT" -type f -size 0 ... -delete`. Its guards were written for
`find .` -- `! -path './etc/motd'`, `! -path './etc/timezone'` -- while the tree
is named by an absolute path (`TGT="$WORK/rootfs"`), so no guard could ever
match: `find /path/rootfs` emits `/path/rootfs/etc/motd`, never `./etc/motd`.
`/etc/motd` and `/etc/timezone` are not zero bytes in the image, so that went
unnoticed; the skeleton's stubs are, and did not. Stage order makes it
intermittent and cache-dependent: rootfs is stage 6 and hypr is stage 8, so a
bare build copies the skeleton *after* the sweep and is fine. The damage needs a
rebuild where rootfs re-runs -- any edit under `iso/rootfs-overlay/` -- while
hypr's stamp still matches. Then the sweep deletes the stubs from the skeleton
already in the cached tree and nothing puts them back, and the ISO carries it.

**Fix, in the tree 2026-10-19:**

1. The sweep runs `( cd "$TGT" && find . ... )`, so its guards mean what they
   say, and it names the skeleton
   (`! -path './usr/share/copper/hyprland-skel/*'`) exactly as the gate already
   did. The now-effective `motd`/`timezone` guards are not a behaviour change:
   the gate exempts both, so the sweep was deleting files the next assertion
   was written to allow.
2. `build_hypr` no longer counts the tree as staged when the stub is gone:
   `conf/environments/default.lua` is part of its "already staged" condition, so
   a damaged skeleton re-runs the stage and gets a whole one.
3. The ISO stage reads the stub back **off the disc** with xorriso -- the same
   check the power links and sudo's mode already get -- and fails the build if it
   is not there. A regression cannot ship silently a second time.

**Status:** fixed in the tree 2026-10-19; `bash -n` and all five gates green
(`starthyprland-gate` cases 23-25 include the zero-byte stub contract).
Boot-verify: a boot whose seeded `~/.config/hypr/conf/environments/default.lua`
exists, and a session log that names no missing module.

---

# 42. `sudo startxfce` starts a desktop whose files belong to root — impact 6/10

**How it affects things:** "i need to launch it with sudo startxfce but still
why are we root?" sudo goes up and nothing brought the desktop back down, so
the panel's settings, every app's configuration and every file the session
creates are root's — while the account the wizard made sits there unused. Same
family as #19, different door.

**Why it is like that:** copper-init drops the console shell to the account in
`/etc/copper-firstboot.done` (`drop_to_session`, and the wizard writes that
file), so a plain `startxfce` is already that account's. But `sudo startxfce`
is what a person types when the plain one did not work, and sudo makes the
*launcher* root; the launcher had no inverse of its own.

**The fix (in the tree, 2026-10-19):** `iso/startxfce.sh` re-executes itself
through `sudo -u "$account" -H` when it is root and the marker names a real
account — late enough that the root-only work above it has already happened
(the splash is quit, the missing ingot pieces are installed). With no marker
(a first boot before the wizard) root is all there is and stays what it is,
which is the honest answer; `COPPER_USER=root` keeps a root desktop on purpose.
`tests/startxfce-gate.sh` case 23 covers all three with a stubbed sudo, so what
is asserted is the decision and not sudo.

**Status:** fix in the tree 2026-10-19 — `bash -n`, `sh -n`, all five gates
green (startxfce-gate: 90 checks). Boot-verify: `sudo startxfce` on an image
with a wizard-made account leaves `whoami` at the bottom of an
xfce4-terminal saying that account.

---

# 44. a non-root `startxfce` dies writing the input config — impact 10/10

**How it affects things:** after bug 42's fix the console shell is the wizard
account, and `startxfce` (or `sudo startxfce`, which bug 42 now re-executes as
that account) drops the user back at the prompt instead of painting a desktop,
with only

    /usr/bin/startxfce: line 487: can't create /etc/X11/xorg.conf: Permission denied

to explain it. Seen on a real boot (2026-10-20); the arrow in bug 30's entry
that said this path was "handled" was reading the code, not a boot.

**What happens, exactly:** the launcher writes its generated input config to
`/etc/X11/xorg.conf` when it can and falls back to `/tmp/xorg.conf` when it
cannot — it probes both with `: > "$cand"` and takes the first that succeeds.
The probe was written

    if mkdir -p "${cand%/*}" 2>/dev/null && { : > "$cand" 2>/dev/null; }; then

and `:` is a POSIX **special builtin**: a non-interactive shell must *exit*
when a special builtin's redirection fails, and dash and busybox ash both do.
`/etc/X11` is root's, the session user cannot write there, so the very first
candidate aborted the whole launcher before the `/tmp` fallback was ever tried.
The `2>/dev/null` did not even hide the message, because redirections are set up
left to right — `>` is attempted (and fails) before `2>/dev/null` is applied.

**Root cause:** a writability probe that runs a special builtin with a
redirection it expects to fail. The design was right — try the requested path,
fall back to `/tmp`, hand X the file that won — but the one construct used to
test the candidate kills the shell on exactly the machine the fallback exists
for.

**Fix (in the tree 2026-10-20):** the probe runs in a subshell,
`( : > "$cand" ) 2>/dev/null`, so a failed candidate costs one status and the
loop moves on; the group redirect also swallows the shell's own message. A
comment at the site records the trap, and `COPPER_XORGCONF_FALLBACK` (default
`/tmp/xorg.conf`) lets a test keep its fallback out of the shared `/tmp`.
`tests/startxfce-gate.sh` case 5c points the first candidate at a directory (no
user can redirect onto one) and asserts the launcher exits 0, writes the
fallback, reaches `input devices:`, and never prints `can't create`.

**Status:** fix in the tree 2026-10-20 — `sh -n` clean, gate green in the same
change. Reproduced before the fix and confirmed after it on this box: with
`COPPER_XORGCONF=/proc/xorg.conf` the launcher used to abort at the error and
now reports `input config written: /tmp/xorg.conf` and carries on. Boot-verify:
`startxfce` paints XFCE on a real machine whose `/etc/X11` belongs to root.
Like bug 25 it stays listed until that boot, because the failure was a real
boot's permissions, not something the gate can fully reproduce.

| bug 44 | 12hrformat | a non-root `startxfce` died writing the input config — `: >` is a special builtin, and a failed redirect exits a POSIX shell before the `/tmp` fallback | (fix in tree 2026-10-20) |
