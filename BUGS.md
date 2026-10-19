# BUGS.md

> please note down all the bugs you come across in h1 heading (#) thier name and how they affect things on a scale of 1-10.

> remove any bugs if fixed and please write in this format [bug number [] fixed by [] ] at the bottom of the file so we can track how many bugs were there and who fixed them

Only bugs that are not fixed live here. Fixed ones are removed from the list —
their graves are in the tracker at the bottom of the file.

---

# 15. firefox install dies of ENOSPC — impact 10/10 (root cause was #20 — fixed and boot-verified)

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

Also caught in that same log: `mousepad`, `ristretto`, `xfce4-taskmanager`,
`xarchiver` answered `no package named X in the index` — the live index had
only 5 of the 9 packages. Their pages are published now; gone.

---

# 18. `sudo shutdown now` / `sudo reboot` do nothing — impact 4/10 [ASSIGNED TO FARCROWX]

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

**First real-boot evidence (2026-10-19, against CI run 131's ISO):** `sudo
reboot` printed red `System has not been booted with systemd as init system
(PID 1)` errors and **did not restart the machine** — the session sat there
until `sudo /sbin/reboot -f` forced it. Whatever #29 and #33 fixed, the command
a user actually types is still dead on a real boot. This is the missing
evidence this entry asked for; the entry stays open until a fix lands and a
boot proves it.

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

# 29. `sudo reboot` / `sudo shutdown` do nothing under busybox init — impact 8/10 [ASSIGNED TO FARCROWX]

**How it affects things:** on the booted image, typing `sudo reboot` or
`sudo shutdown now` prints "System has not been booted with systemd as init
system (PID 1). Can't operate." and the machine stays up. The user has to
know to type `busybox reboot` (or find the power button) — and most will not.
This is a real launch blocker for a live ISO: a user who cannot reboot cleanly
will yank the power, which is worse for the overlay and any mounted disks.

**What happens:** the systemd-flavoured copies are the ones PATH resolves.
Both the login shell's PATH (`etc/profile`, copper-init's `setenv`) and
`sudo`'s `secure_path` search **`/usr/sbin` before `/sbin`**, and
`systemd-sysv` -- kept by the empty dpkg status the Hyprland closure is
resolved against -- ships `/usr/sbin/reboot|poweroff|halt|shutdown|telinit ->
../bin/systemctl`. systemctl finds no systemd to talk to (PID 1 is
copper-init) and answers "System has not been booted with systemd". BusyBox
itself has working `reboot`/`poweroff`/`halt` applets, but they are not what
`reboot` resolves to.

**Root cause:** the image mixes glibc binaries from packages that assume
systemd with an init that is not systemd. The package set never re-points the
`reboot`/`shutdown`/`poweroff`/`halt` commands at the busybox applets -- in
*both* directories PATH searches for them.

**Status:** fixed 2026-10-18. The fix claimed 2026-10-17 relinked `/sbin`
only (rootfs and gui stages); the CI ISO built from it (run 39055205600, HEAD
6f40e31) still shipped `/usr/sbin/reboot -> ../bin/systemctl` -- verified by
reading the links back off that artifact -- so `sudo reboot` on that image
still resolves to systemctl. `build.sh` now relinks **both** directories
through one `power_links()` helper after every stage that copies packages
(copper, gui, hypr), and `build_iso` re-reads both link sets off the disc and
fails the build if any is wrong. Verified by the gates
(`tests/shutdown-gate.sh`, `tests/init-session.sh`) and by inspecting the
artifact -- a real boot of a fixed ISO has **not** been run yet. `sudo`'s
`wheel` model is unchanged.

**Why the busybox half of this is not guesswork.** The applet's own source
settles what "no `-f`" does, and it is the signal path. In busybox 1.36.1
(`init/halt.c`, the version `build_busybox` fetches) `halt_main()` ends with
`rc = 1;` and, when `-f` was not given, either
`rc = kill(1, signals[which])` with
`signals[] = { SIGUSR1, SIGUSR2, SIGTERM }` for halt / poweroff / reboot, or the
`FEATURE_CALL_TELINIT` branch that `execlp()`s `/sbin/telinit`. It is the
**signal** branch that is compiled in here: `FEATURE_CALL_TELINIT` is `default
y` *but* `depends on (HALT || POWEROFF || REBOOT) && !INIT`, `INIT` is `default
y`, and `build_busybox` runs `make defconfig` without touching either symbol.
So `reboot` (no `-f`) sends PID 1 **SIGTERM** -- exactly what `power_how()`
maps to `RB_AUTOBOOT` -- and it never execs the
`/usr/sbin/telinit -> systemctl` this bug is about. The chain is
link → applet → `kill(1, SIGTERM)` → `power_how()` → `reboot(2)`, and the CI
run that gate-checks the disc reads both link sets back off it
(`iso: power commands point at busybox/wrapper in sbin and usr/sbin, on the
disc`, run 39166175403). What is still missing is the same as before: a real
boot of an ISO built **after** 2026-10-18 09:50Z. An ISO built earlier still
answers with systemctl's message -- that is the 2026-10-19 report -- and
`readlink /usr/sbin/reboot` is the one command that tells the two apart.

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

# 32. the libudev-record fix for #30 wrote nothing — impact 10/10 [ASSIGNED TO 12HRFORMAT]

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

# 38. Discord is not in its payload — the first run downloads it, silently — impact 5/10

**How it affects things:** `discord` (1.0.161, page `network/discord`, payload
`discord-1.0.161.tar.gz`) is offered by `startxfce` like every other component,
its payload publishes, verifies, and installs. Then clicking it does nothing for
minutes: no window, no error, no process that finishes. The reasonable reading,
and the human's, is "it hung".

**What the payload actually contains:** not Discord. `usr/bin/discord` is the
vendor's **bootstrapper** — a shell script that looks for
`$XDG_CONFIG_HOME/discord/Discord`, and when that is not executable runs
`updater_bootstrap --zenity "$config_home/discord" stable
https://updates.discord.com/` and execs whatever that leaves behind.
`usr/share/discord/` holds `updater_bootstrap` (4.3 MB), an icon, a `.desktop`
and the deb's `postinst.sh`. There is no `Discord` binary, no `app.asar`, no
`.pak` anywhere in the 16,967 entries. Most of the 128,600,911 bytes is the
**dependency closure** for an app that is not there — `libLLVM.so.20.1` alone is
143 MB uncompressed.

**Why nothing appears:** the vendor launcher passes `--zenity`, because stdout is
not a tty — which is every launch from the menu. The bootstrap's own strings say
what that flag is for: `zenity --progress --text=Downloading Discord
--auto-kill`, and `Failed to wait on zenity!`. There is no `zenity` in the
payload and none in the image: nothing in either repository names it. So the
one thing that would have shown the download cannot start, and the progress the
bootstrap falls back to writing goes to **stderr**, which a `.desktop` launch
throws away.

**Reproduced on the published artifact**, extracted from the tarball and run in
a plain WSL with no zenity and no display:

    updater_bootstrap --zenity    /tmp/d d stable https://updates.discord.com/
    updater_bootstrap --no-zenity /tmp/d d stable https://updates.discord.com/

Both downloaded and neither hung: 20 MB in 30 s and 47 MB in 60 s, printing
`Downloading Discord - N%` to stderr, failing to wait on zenity and carrying on.
What that means on a real boot is minutes of silence while hundreds of
megabytes arrive, and only then an Electron app starting — viewed by someone
who clicked an icon.

**Not the whole story:** the app that arrives is extracted **as the user** into
`~/.config/discord`, so its own `chrome-sandbox` can never be root-owned and
setuid. Whether that aborts Discord or is saved by the kernel's user namespaces
is the second thing to measure, and it can only be measured after the download.

**Status:** open, diagnosed. The download is the wall the human hit; the
sandbox is the wall behind it. The fix is a packaging decision, not a code one:
either bake the real app into the payload so there is no first run to sit
through, or ship `zenity` so the vendor's progress dialog appears and the wait
is visible. Whichever way, `--zenity` without zenity is a launcher asking for
something the image does not have, and that is ours to notice.


---

# 39. the published `index.json` was missing its closing brace — impact 3/10

**How it affects things:** `ingot` itself is fine -- it reads the index as text,
one `"name": "category"` line at a time. Every other reader is not. `jq`, a
browser, `python -m json.tool`, any client that parses the file fails on it, and
it is served from GitHub Pages as the repository's index. A package repository
whose index is not JSON is one nobody can build a client against.

**What happens:** `12hrformat/copper-ingot-repo`'s
`iso/copper/pkg/index.json` ended with the last entry and a newline: one byte
short of the `}` that closes the object. The generator was an awk script
(`regen-index.sh`) that printed the entries and no terminator, it had run that
way since the repository was created, and nothing ever parsed the result --
`ingot`'s `category_for()` seds the line and never sees the end of the file.

**Fix, 2026-10-19:** the generator moves into the repository, as
`tools/index.py`, and is the only thing that writes the index. It validates
every page (JSON; `name` and `category` agreeing with the file and directory it
lives in; `version`, `url`, `size`, `sha256`, `depends` all present; `sha256` 64
hex characters), refuses a `depends` that names something with no page, writes
strict JSON with one entry per line (because `ingot` reads it as text), and then
**re-reads what it wrote** and asserts it parses and matches. `--check` fails if
the file is out of step with the pages. `tools/audit.py` covers the release
half: every page against the asset it points at (name, size, and the `sha256`
GitHub reports) plus any asset no page names. Two pages, `libpcap` and `tree`,
had no `depends` key at all and now carry `"depends": []` like the rest.

**Status:** fixed 2026-10-19. The index was regenerated (72 entries) and the
copy Pages actually serves was fetched back and parsed.

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

# 41. `fastfetch` paints the Ubuntu logo on a Copper machine — impact 6/10

**How it affects things:** the first command most people type on a new machine
tells them it is not Copper. fastfetch is not the problem — to everything that
asks, the image *is* Ubuntu. It also meant the owner's own config had nowhere
to live: the file they use was in a home the image has never seen.

**What happens, exactly.** Three facts, all measured on the 2026-10-19
artifact rather than reasoned about:

1. `/etc/os-release` — and its second copy at `/usr/lib/os-release` — is
   Ubuntu 24.04.5's, `ID=ubuntu`, `LOGO=ubuntu-logo`, byte for byte. So is
   `/etc/lsb-release`; `/etc/issue` says Ubuntu 24.04.5 LTS.
2. Nothing we ship put it there, and nothing we ship reads it, which is why it
   went unnoticed for weeks.
3. `build_gui` is what put it there. The closure apt computes for the display
   stack includes `base-files`, and `base-files` **is** `/etc/os-release`,
   `/etc/lsb-release`, `/etc/issue` and `/usr/lib/os-release`. The stage then
   merges with `cp -a "$STAGE/." "$TGT/"` — no `-n` — so the packages win over
   the same paths rootfs took from the overlay.

fastfetch reads os-release and only then its builtin table, `LOGO=` is not what
it looks at (`ID` is), and an unknown `ID` is resolved through `ID_LIKE` — so
`ID=copper, ID_LIKE="ubuntu debian"`, which is what the identity was meant to
say, *also* gets Ubuntu's logo. Both were reproduced against the artifact's own
fastfetch build in a mount namespace, by swapping /etc/os-release under it.

**The fix (in the tree, 2026-10-19):**

- Copper's own `iso/rootfs-overlay/etc/os-release`, `/etc/lsb-release` and
  `/etc/issue`: `NAME="Copper Linux"`, `ID=copper`, `ID_LIKE="ubuntu debian"`
  (true — the display stack is noble's), `LOGO=copper`.
- `build_gui` re-applies them **after** the packages land, and asserts
  `ID=copper` and that the two os-release copies agree: `copper_identity`,
  called at the end of the stage and on its cached early return, so a warm tree
  written before this existed is repaired too. `build_iso` asserts it again
  before the disc is written, which is what stops a later stage that brings its
  own os-release from shipping.
- The owner's config is the image default now
  (`iso/rootfs-overlay/etc/fastfetch/config.jsonc` +
  `/usr/share/copper/fastfetch-logo.*`), so this does not depend on anyone
  answering a prompt — `/etc/fastfetch/` is the last of fastfetch's search
  paths, so a user's `~/.config/fastfetch/` still wins.
- The logo is the one thing measurement changed: the config names a PNG, and
  this fastfetch build can only draw an image through kitty, iTerm, sixel or
  libchafa — none of which is in this build or in xfce4-terminal. A PNG logo
  comes out as the file's raw bytes (seen), or as nothing. So the image ships
  the PNG *rendered at build time* by chafa into truecolor half blocks
  (`/usr/share/copper/fastfetch-logo.txt`) and points the config at that;
  the PNG stays next to it for terminals that can draw it.

**Status:** fix in the tree 2026-10-19 — `bash -n`, `sh -n`, and the five
gates green. Boot-verify: `cat /etc/os-release` says `ID=copper` on the running
image and a fresh terminal shows Copper's logo.

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

# 43. Discord installs and then opens nothing — impact 5/10

**How it affects things:** `ingot install discord` reported success, the menu
entry was there, and launching it produced no window and no explanation — the
classic "it worked, so why is nothing happening". The owner's trial found the
shape of it: nothing on a plain start, a window with `--no-sandbox`, from a
terminal launch as well as the menu.

**Why:** on Linux Discord is a Chromium app behind a shell bootstrapper, and
Chromium will not start unless it can put its renderers under one of two
sandboxes — the kernel's, using unprivileged user namespaces, or its own
`chrome-sandbox` helper, which must be **root-owned and setuid**: Chromium
checks the ownership before it uses it and refuses to run rather than run
unsandboxed. That helper is inside the app directory, and the bootstrapper
installs the app directory into the *user's* `$XDG_CONFIG_HOME/discord/Discord`
on first run. Nothing a user's own process unpacks in their own home can be
root-owned and setuid, so that check can never be satisfied here.

Which also means this is a bug in the **payload**, not in the image: there is
no image-side wrapper that helps, because the vendor's own
`Exec=/usr/bin/discord --url -- %u` (and the terminal's `discord`) both hit
`/usr/bin/discord`, and that path belongs to the payload.

**The fix (2026-10-19):** a republished payload,
`discord-1.0.161-copper1.tar.gz`, with the vendor bootstrapper's two execs
given the flag and a header comment on that one file saying what was added and
why:

```sh
    exec "$config_home/$DIR/$app_dir/$EXE" --no-sandbox "$@"
    ...
exec "$discord_host" --no-sandbox "$@"
```

Nothing else in the archive changed — it was unpacked, the one file
rewritten, and repacked from the original's own name list: 16,967 entries
before and after, every mode and owner the same, the same 6,733 symlinks and
the same 135 of them dangling, and a full recursive compare of the two
extractions differs in exactly one file, that script (`hrwx`/hardlink
duplication is what a naive `tar -c -T` re-tar produces — `--no-recursion` is
the tell). The page's URL, sha256 and size moved with it.

**Status:** fixed in the payload the page points at (2026-10-19). Because it
is a payload and not an ISO, a machine already running the 2026-10-19 image
takes it with `ingot reinstall discord` — no rebuild. Boot-verify: `discord`
from the whisker menu opens.

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
2026-10-11, boot-verified 2026-10-19 — on the verification boots the upper
was a labelled 20 GB disk.)

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

**Copper's kernel has no VMware SCSI host driver.** The build asserts
`BLK_DEV_NVME`, `BLK_DEV_SD`, `ATA_PIIX` and (via defconfig) `SATA_AHCI`, but
nothing enables `SCSI_MPTSPI`, `SCSI_MPTSAS`, `SCSI_SYM53C8XX` or
`VMWARE_PVSCSI` — and `MODULES` is disabled, so none can arrive later. A
VMware disk attached as **SCSI (LSI Logic / LSI SAS / PVSCSI) is invisible to
the guest**: the wizard lists nothing and /init finds nothing. Add disks as
**NVMe** (first choice — build-gated) or SATA. Found the hard way during
bug 20's verification (2026-10-19).

---

# bug tracker

Every bug we ever hit and who killed it. No name = still open.
43 bugs total: 34 fixed, 8 open, 1 that only looked like one.

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
| bug 20 | 12hrformat | persistence isn't built — the writable layer is RAM | (boot-verified 2026-10-19) |
| bug 21 | 12hrformat | VMware framebuffer unproven — real VMware boot paints XFCE | (boot-verified 2026-10-11) |
| bug 22 | 12hrformat | ISO rationalised Rock Ridge flattened modes — sudo lost setuid | (e934a12, 553528f) |
| bug 23 | 12hrformat | a non-root X server dies grabbing the VT — `-novtswitch` was the wrong flag | (131b86d) |
| bug 24 | farcrowx, dragon | startxfce reuses a dead display when /tmp persists | (boot-verified 2026-10-19) |
| bug 25 | still open | plymouth never draws a frame — serial console forces the text splash |  |
| bug 26 | dragon | the empty-file gate rejected the Hyprland skel's intentional zero-byte files | (2026-10-16, completed 2026-10-19) |
| bug 27 | still open | ingot update deletes a package it then fails to reinstall |  |
| bug 28 | 12hrformat | payloads installed a binary you could not invoke by name | (2026-10-16) |
| bug 29 | 12hrformat, farcrowx | `sudo reboot` / `sudo shutdown` do nothing under busybox init | (2026-10-17, completed 2026-10-18) |
| bug 30 | 12hrformat | Hyprland had no keyboard or pointer — libinput wants udev records nothing wrote | (2026-10-17) |
| bug 31 | 12hrformat | Ctrl-Alt-Del did nothing — PID 1 ignored SIGINT | (2026-10-17) |
| bug 32 | 12hrformat | the libudev-record fix wrote nothing — seeder never made its own directory | (2026-10-18) |
| bug 33 | farcrowx | the power path fails silently — `shutdown` ate unknown args, PID 1 `_exit`ed on a failed reboot(2) | (2026-10-18) |
| bug 34 | still open | the libudev records name no device type — libinput drops every device whose only tag is `ID_INPUT` (pointer boot-verified 2026-10-18; keyboard still silent, PID 1 now names each device) | (fix in tree 2026-10-18) |
| bug 35 | still open | the wizard offers the persistence disk while it is mounted | (fix in tree 2026-10-19) |
| bug 36 | dragon | a home is seeded once and never repaired — busybox `cp -a -n` skips an existing directory, so a missing config file could never come back | (fix in tree 2026-10-19; needs a boot) |
| bug 37 | no fix needed | GNU tar's "Directory renamed before its status could be extracted" on `ingot install` — cosmetic, the payloads are intact | (explained 2026-10-19) |
| bug 38 | still open | Discord is not in its payload — the first run downloads it silently; diagnosed and reproduced on the artifact | (diagnosed 2026-10-19) |
| bug 39 | dragon | the published `index.json` was missing its closing brace — the generator wrote the entries and stopped | (fix in tree 2026-10-19) |
| bug 40 | dragon | the rootfs empty-file sweep deleted the Hyprland skel's Lua stubs — bug 26 exempted the gate, not the sweep | (fix in tree 2026-10-19) |
| bug 41 | 12hrformat | fastfetch shows the Ubuntu logo — the image's os-release is base-files', and the owner's config was never in the image | (fix in tree 2026-10-19) |
| bug 42 | 12hrformat | `sudo startxfce` leaves a root desktop — the launcher had no inverse of init's drop | (fix in tree 2026-10-19) |
| bug 43 | 12hrformat | Discord installs and opens nothing — its Chromium sandbox needs a root-owned setuid `chrome-sandbox`, and the app is unpacked into the user's own home | (payload republished 2026-10-19) |
