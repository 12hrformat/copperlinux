# Systemd as PID 1 — migration

Status: **phase 1 in the tree, opt-in, and booted once (2026-10-21).** v0.9 still
ships busybox init; the default image is unchanged, its gates are green, and
this work is wired into the same gate set as everything else
(`tests/systemd-gate.sh` + `tests/systemd-gate-sabotage.sh`, run by
`tests/branch-gate.sh` and listed in CI). What exists now is the swap itself,
behind a stage you have to ask for:

```
sudo bash iso/build.sh systemd      # systemd as PID 1
sudo bash iso/build.sh              # busybox init, the shippable image
```

Phase 1 is deliberately **not** part of `all`/`full`. The line above this
document's estimate is the reason: a half-done swap is an **unbootable ISO**,
not a degraded one. Keeping it out of the default path means the image anyone
ships is never the half-finished one.

What is verified, and what is not, is at the end of this file. Read that before
trusting anything here.

**The systemd image has now been booted once** (2026-10-21), and it came up —
with four defects that every green gate had missed, one of which meant the
*next* boot would not happen at all. What that boot found is in
"The sixth push" below.

## Why this is a big deal

Going from busybox -> systemd is not "copying a package in." It changes:

- PID 1 and all boot ordering
- Network: udhcpc becomes systemd-networkd, lease files relocate
- Seat/DRM: separate seatd -> logind
- First boot: replaces two C daemons with service units + journal-first logging
- Service assumptions: everything Copper runs (`plymouth`, `inges`, `myscript`
  hooks) needs unit files
- Image size: +80 to +120MB of glibc libraries, a 10 percent-ish increase on
  an already full 700MB-ish ISO

Time estimate: 3 focused weeks of work, plus a week of boot-debugging on real
hardware.

## Recommendation (unchanged)

Ship v0.9 on busybox; treat the swap as a v1.5 project. Hyprland's `seatd` path
works fine as-is, and the real blockers are library-version issues, not the
init system. Phase 1 below is groundwork that can be done without committing to
the timeline — and without risking the launch image.

## What phase 1 actually does

### The swap is a symlink, not a kernel argument

This document used to say `Replace the init in the initramfs:
init=/lib/systemd/systemd`, and **that is wrong** — corrected here.

`iso/live/init` runs first, and it has to. It mounts proc/sys/devtmpfs, finds
the medium, builds the overlay out of the persistent disk and `switch_root`s
into it. An `init=` argument skips that entire script, so the machine would boot
the read-only squashfs directly: no overlay, no persistence, and `/etc` from the
medium. Same rootfs, different machine.

`/init` ends with `exec /sbin/init`. So the swap is one symlink:

```
/sbin/init -> /lib/systemd/systemd        (was -> /usr/bin/copper-init)
```

and everything about boot ordering follows from it. `build_systemd` makes that
link, and `init_flavour()` in `iso/build.sh` reads it back so every gate that
cares asks "which init is this"? rather than assuming.

### copper-init is not deleted; it stops being PID 1

`iso/src-init/copper-init.c` gained a **`--console`** mode (`console_main()`),
which is the tty1 half of that file and nothing else:

| copper-init did, as PID 1 | who does it under systemd |
| --- | --- |
| mount /proc /sys /dev /run | already done by `/init` before the switch_root |
| power signals (SIGTERM/SIGUSR1/2, SIGPWR, SIGINT) | systemd; a SIGTERM on a service must mean *stop* |
| `apply_hostname()` | `/etc/hostname` + systemd |
| DHCP | `copper-network.service` |
| `start_seatd()` | `copper-seatd.service` |
| dbus / polkit spawn | the packages' own units |
| `seed_udev_input_db()` (bug 34) | real `systemd-udevd` — the seeder is skipped |
| reap children | systemd reaps |
| **first-boot wizard** | still copper-init, via `copper-firstboot.service` |
| **session account drop + shell on tty1** | still copper-init, `--console` |

The three things kept are the three that are genuinely hard and already right:
the account drop (or Firefox refuses to start — the same reason
`tests/init-session.c` exists), the controlling terminal, and the respawn loop.
Re-implementing those in unit + `agetty` terms is not possible here anyway: the
image is built `--without-pam`, so there is no PAM stack for autologin to use.

`g_console_only` is the flag that turns off the PID-1 half; it is set only by
`--console`, so the busybox path is behaviourally unchanged.

### The units (`iso/systemd/`)

All Copper-owned, so nothing here patches a package's own units:

| unit | what it is | replaces |
| --- | --- | --- |
| `copper.target` | groups Copper's services, says why the ordering is what it is | — |
| `copper-firstboot.service` | the wizard, `ConditionPathExists=!/etc/copper-firstboot.done` | the `stat()` in `main()` |
| `copper-console.service` | `copper-init --console` on tty1 | the session loop in `main()` |
| `copper-seatd.service` | `seatd -g _seatd` | `start_seatd()` |
| `copper-network.service` | `busybox udhcpc -i eth0 -b` | `start_dhcp()` |
| `copper-network.conf` | why the file exists (bug 34's premise) | — |
| `99-default.link -> /dev/null` | keep kernel NIC names (eth0, not ens33) | — |

`getty@tty1` is `Conflicts=`'d and `Before=getty.target`: two things writing the
same tty is the two-shells bug in unit form.

**Ordering is `After=`, never `Requires=`.** The wizard must run before the
console and the seat before the user can start Hyprland, and that is ordering —
so the units spell it `After=` and pull each other in with `Wants=`. The first
cut used `Requires=`, which is a hard dependency in both directions and turns any
single failure into the "unbootable, not degraded" outcome this document opens
with: a seatd that would not start cancelled the wizard (no account, no
persistence offered) and a wizard that could not format a disk cancelled
`copper-console.service` — on a machine where that unit is the only way in. A
black tty with no login is not a smaller failure than a missing seat; it is a
larger one. `Wants=` + `After=` keeps the order and drops the coupling.

There are no `Documentation=file:` lines for the same reason a build gate exists:
the path they pointed at (`/usr/share/doc/copper/SYSTEMD-MIGRATION.md`) is not
installed into the image, and a unit that documents itself with a file nobody
can open is worse than one that does not. `man:` entries remain, because a real
distro has those man pages; the build-time verify treats a missing `man:` as host
noise (see the stage, below).

**No `systemd-networkd`, no `logind`** in this phase, on purpose. Moving the
network stack and the seat at the same time as PID 1 would mean a dark screen
with three possible causes.

### The stage (`build_systemd` in `iso/build.sh`)

- `apt-get download` closure for `systemd udev systemd-sysv`, unpacked with
  `dpkg-deb -x` and copied in with `cp -a -n` — the same empty-dpkg-status
  pattern the `gui` and `hypr` stages use. Existing files win (`-n`): a library
  the desktop closure already staged was chosen by the desktop's resolver.
- installs and wires the units by hand rather than `systemctl enable` (which
  wants a chroot, a running dbus, and a systemd being called into from a build).
  Enabling is just symlinks.
- re-asserts the glibc loader at `/lib64/ld-linux-x86-64.so.2`, then proves with
  `readelf` that PID 1's interpreter exists in the tree.
- repoints `/sbin/init` at systemd's own, and asks `power_links()` for the power
  commands (`/sbin` **and** `/usr/sbin`). `power_links()` answers from the
  tree's **own PID 1** — it reads `sbin/init` and links busybox's applets or
  `systemctl` accordingly — so the stage and every stage that re-runs over the
  tree later cannot disagree about what the machine wants. That question has to
  be asked every time: the `iso` chain re-runs the desktop stages over the
  tree, and each of them calls `power_links()`.
- verifies the units with `systemd-analyze`, **chrooted** into the staged tree,
  so `ExecStart` resolves the way it will at boot.

## What is verified, and what is not

**Verified here, mechanically:**

- `bash iso/build.sh` and `sh -n` on touched scripts parse.
- `tests/init-session.sh` passes: the `--console` split did not change the
  session-account logic, the udev seeder, or the power-signal mapping.
- `tests/systemd-gate.sh` (new) runs the **real** `build_systemd()` under
  build.sh's own `set -euo pipefail`, against a mock staged rootfs, with
  apt/dpkg stubbed; checks the swap, the wiring, the modes, the power links, and
  that nothing from the build host is left in the tree; and runs the units
  through the `systemd-analyze` parser.
- The parse half of that gate ran for real, not skipped: `systemd-analyze` 261
  was present on the dev box and verified all five units. The **image** carries
  systemd **255** (what noble ships), so the parse check is a *newer* parser
  accepting the units — the conservative direction (a key 261 accepts and 255
  does not would still slip through), and the reason the gate also rejects a key
  in the wrong section rather than trusting the version. A host with no
  `systemd-analyze` says `skip` out loud instead of claiming a pass.
- The **merged-usr bridge** was checked against the real package, offline: the
  noble `systemd` deb (`255.4`, 3.47 MB) was downloaded, unpacked into a mock
  non-merged tree, and the stage's bridge applied. `/lib/systemd/systemd` is an
  ELF executable with interpreter `/lib64/ld-linux-x86-64.so.2`, and the deb's
  own `usr/bin/systemd` link resolves to it. Without the bridge that path is
  absent — the third CI failure reproduced exactly.
- The sabotage suite (`tests/systemd-gate-sabotage.sh`, new) plants **twenty-five**
  defects — misplaced key, nonexistent directive, bare glob, no repoint, unwired
  unit, removed `--console`, busybox power links, 0777 units, leaked build tool,
  a `tree_hash` blinded to symlinks, a `systemd)` dispatch line without its
  toolchain, the stage's verify filter weakened to a version-specific
  deny-list, the merged-usr bridge dropped (twice — gone, and present but
  no-opping on the squatter), the gate's own fixture un-merged-usr'd and its
  udevd unit mis-modelled, the seatd binary and the `_seatd` group missing, the
  seatd unit back to one hard-coded path, `ldconfig.service` unmasked, the
  hypr/gui skip guards blinded, the ordering cycle that shipped, the stage's own
  cycle check dropped, and `power_links()` blind to the tree's init — and every
  one is caught. That suite is
  what found three real bugs during development, including a `readelf | sed |
  head` pipeline that aborts under `set -o pipefail` and would have killed a
  real build.

**What the first real CI run found (and the gate did not):**

The push was green locally and red on the runner, twice, and both were real:

- **`build`: `iso/build.sh: line 638: CC: unbound variable`.** The `systemd)`
  arm of the dispatch case listed `build_rootfs; build_gui; …; build_copper`
  and omitted `build_musl` — which is the stage that exports `$CC`, `$CFLAGS`
  and the musl `PATH`. Every other compiling stage lists it (`copper)`,
  `initramfs)`, `iso)`) because `build_copper` needs it; `full()` never showed
  the omission because it calls `build_musl` first. CI runs
  `bash iso/build.sh systemd` as its own invocation, so `build_copper` reached
  `$CC … copper-sh` with the variable unset and `set -u` ended the build. The
  fix is the missing prerequisite on the dispatch line, plus `require_toolchain`
  in `build_copper` so a future omission is a sentence naming the cause instead
  of a crash naming a shell variable. The gate could not see this because it
  calls `build_systemd` alone against an already-built tree; it now also reads
  the dispatch arm (section 6), and the sabotage suite plants the omission.
- **`checks`: the unit-parse and sabotage checks failed on systemd 255.** The
  parse filter was a deny-list ("drop 'Command … is not executable', drop a
  missing man page"), which is host-version dependent: on 255 the same units
  emit lines that do not match it, so units failed for messages about the
  *host*, not the unit. It is an allow-list now — only an unknown key, a key in
  the wrong section, or a missing `ExecStart` can fail a unit, and those come
  from the unit's own text. Separately, the sabotage expectations were fixed
  strings, and systemd changed its wording between 255
  (`Unknown key name 'X' in section 'Service'`) and 256+ (`Unknown key 'X'`), so
  the suite reported "missed" for defects the gate *had* caught (rc=1). The
  expectations are regexes now. A suite that goes red on the runner's distro
  rather than on the code is its own bug.

A second push then showed the same wording problem in the **stage** itself,
which is the one that would have failed a real build: `build_systemd`'s
chrooted `systemd-analyze verify` used the same deny-list, so on the runner it
kept a host-artifact line and exited 1 — `build_systemd ran` went red in the
gate while the gate was green on the dev box. It is now the same allow-list.
The gate could not have caught it by running the stage (the stage only fails on
255), so it tests the filter's contract directly, feeding it both wordings of a
real defect and four shapes of host noise; a twelfth sabotage plants the
deny-list to prove that check is load-bearing.

A third push got further still — `checks` green, the default ISO built and
uploaded — and died inside the stage:

```
  39 packages unpacked (58M)
  0 empty package files pruned
systemd: /lib/systemd/systemd did not arrive from the packages
```

This one was not a wording problem; it was the migration reading its own input
wrong. Ubuntu's `systemd` deb ships PID 1 at **`/usr/lib/systemd/systemd`**, not
`/lib/systemd/systemd` — every Debian-family tree since bookworm is **merged-usr**,
where `/lib` *is* `/usr/lib` written as a top-level symlink, so the packages only
ever write the `/usr/lib` name. Copper's tree is **not** merged-usr: `/lib` here
is a real directory holding the musl loader and busybox. So the packages landed
at `$TGT/usr/lib/systemd/systemd` and nothing landed at `$TGT/lib/systemd/systemd`,
which is the path the kernel is handed by `/sbin/init`. The ISO would have been
unbootable, not merely failed a check. The deb's own `/usr/bin/systemd` symlink
(`../lib/systemd/systemd`) dangled for the same reason.

The fix is the merge, scoped to the one subtree that needs it: a
`lib/systemd -> ../usr/lib/systemd` symlink. systemd was compiled with
`SYSTEMD_UTIL_DIR=/usr/lib/systemd`, so it reads its units natively and is
content; only PID 1 itself has to also answer at `/lib`.

**Why the gate was green here and red on the runner is the useful part.** The
gate stubs `dpkg-deb` with `tar`, so the "package" it feeds the stage is whatever
the fixture says — and the fixture put its fake PID 1 at
`payload/lib/systemd/systemd`, a layout no Debian-family deb has produced since
merged-usr. The stage's own `[ -x $TGT/lib/systemd/systemd ]` gate then passed
against the *fixture*, certifying a stage that cannot handle a real deb. A test
that models its input wrongly certifies the wrong code. The fixture is now
merged-usr-shaped, and two checks read the tree rather than the fixture:
`lib/systemd/systemd` must be an executable regular file through whatever
`lib/systemd` is, and the deb's own `usr/bin/systemd` must resolve to the same
binary. The real package was downloaded and both were confirmed against it
offline; sabotage case 13 drops the bridge and the gate catches it.

### The fourth push: the bridge was there and still did not fire

The bridge above landed, the gate went green, and CI failed **identically**:

```
  39 packages unpacked (58M)
cp: warning: behavior of -n is non-portable and may change in future; use --update=none instead
  0 empty package files pruned
systemd: /lib/systemd/systemd did not arrive from the packages
```

Note what is *not* in that transcript: the bridge's own line
(`lib/systemd -> usr/lib/systemd (merged-usr bridge...)`) never printed. The
packages arrived; the code that exposes them declined to run. The old guard was

```sh
if [ -d "$TGT/usr/lib/systemd" ] && [ ! -e "$TGT/lib/systemd" ]; then
```

and it has a blind spot the fixture did not model: it asks *"is `lib/systemd`
absent?"*, so **any** pre-existing `lib/systemd` — a real directory left by an
earlier stage, or by a cached tree — makes it skip, and PID 1 is then never
linked into place. Three candidate causes were checked against the real inputs
before touching the code:

1. **The deb does not ship `usr/lib/systemd`.** Ruled out: the noble deb
   `systemd_255.4-1ubuntu8.18_amd64.deb` was downloaded and unpacked, and it
   ships `./usr/lib/systemd/systemd`; the whole 39-package closure unpacks PID 1
   *only* under `usr/lib`.
2. **`cp -a -n` refuses to merge into an existing `usr/lib`.** Ruled out by
   direct repro: `-n` skips clobbering *files*, not descending into existing
   *directories*, so `usr/lib/systemd` lands.
3. **Something leaves a `lib/systemd` behind first.** Not ruled out, and the only
   survivor. Nothing in this repo creates one and the packages do not either, but
   a **cached** tree can: the CI cache is saved with `if: always()` (see
   `build-iso.yml`), so the tree from every *failed* run is restored by the next
   one, including runs that died mid-stage.

The fix does not depend on which of those it was, because it stops asking the
wrong question. The bridge is now keyed off the **file** — `usr/lib/systemd/systemd`
— and then makes `/lib` answer for it from *any* state: it leaves an existing
symlink alone, normalises a real `lib/systemd` directory into the symlink the rest
of the tree expects (unless that directory holds a PID 1 of its own, which is a
genuinely merged tree and is left untouched), and prints what it found when it
cannot. The failure message now dumps the actual layout of `lib/systemd` and
`usr/lib/systemd` instead of only asserting.

The honesty checks behind this: `tests/systemd-gate.sh`'s mock rootfs now starts
with a **real empty `lib/systemd` directory** — the squatter — and asserts the
stage turns it into the symlink, so the guard's blind spot is a modelled input,
not a comment. Sabotage case 13 plants the missing bridge; the new case 15 plants
a bridge that no-ops on the squatter, and the gate catches both.

All of this is recorded because it is the argument for the newer checks: a gate
that is green only on the machine it was written on is not a gate, and one that
is green only against its own fixture is not one either. This is the second time
the same stage failed that test in the same way.

### The fifth push: green, and the runner said which branch it took

CI run `39569804960` passed both jobs. The stage's own line in the runner's log
is the confirmation that it was the squatter all along:

```
  39 packages unpacked (58M)
  lib/systemd (real dir) -> usr/lib/systemd (merged-usr bridge)
```

That is the **`elif [ -d "$TGT/lib/systemd" ]` branch** — a real directory
squatting on `lib/systemd`. The old guard asked `[ ! -e "$TGT/lib/systemd" ]`,
got "no", and skipped; the new one normalised the squatter and moved on. So the
third theory above was the right one, and it is now a fact read off the runner
rather than a hypothesis. `checks` (13m57s) and `build` (7m56s) both went green,
and **`copper-systemd.iso` was built and uploaded** alongside the default
`copper.iso`.

### The sixth push: the first real boot, and what it found

The systemd ISO was booted on **2026-10-21** — the first time ever. It came
up. It also came up with four defects, and the interesting thing about all
four is that a green gate had missed every single one.

**Bugs 47 and 48 — two units that failed on every boot.** `copper-seatd.service`
exec'd `/usr/bin/seatd`, but noble ships seatd at **`/usr/sbin/seatd`**: the
unit hard-coded one path where `copper-init.c` had always searched both. Every
restart printed `[FAILED]` onto the very tty the wizard was drawing on, so the
form corrupted as the user typed into it. And systemd's own `ldconfig.service`
runs `ExecStart=/sbin/ldconfig -X` — an image with **no ldconfig at all** —
so it was one of the two entries in `systemctl --failed`. Both are fixed: the
seatd unit searches both directories and its restart is bounded, and
`ldconfig.service` is masked with `/dev/null`, which systemd reads as "exists,
must not run".

**Bug 49 — the boot reads as two half-screens.** The kernel's own text stays
on tty1 and systemd paints its status lines underneath it.
`copper-tty-clear` and `copper-tty-clear.service` erase the screen in between.

**Bug 50 — and then the image did not boot at all.** The unit added for bug 49
was ordered `After=sysinit.target` AND `Before=systemd-udevd.service`, while
systemd's own `systemd-udevd.service` carries `Before=sysinit.target`. Those
three lines close a loop:

```
sysinit.target -> copper-tty-clear.service -> systemd-udevd.service
               -> sysinit.target
```

systemd reports it as "Found ordering cycle" and then "**Unable to break cycle
starting with sysinit.target/start**" — and the cycle is on `sysinit.target`,
so the boot's **initial transaction** fails: not a degraded boot, no boot.

It survived a green gate because the gate verified each unit **one at a time**,
and a cycle only exists in a transaction: every unit in the loop was perfect on
its own. The unit is now ordered `Before=sysinit.target systemd-udevd.service
copper-firstboot.service copper-console.service` with no `After=` at all —
`DefaultDependencies=no` is what keeps it out of the loop — and both the gate
and the stage verify the units **in one call** and fail on a cycle.

That last one is the lesson worth keeping, and it is the third time this
project has been bitten by a check that was green against its own fixture: the
gate's fixture modelled systemd's udevd unit as `Description=udev` with no
ordering in it, so the graph the stage walked was not the graph the boot
builds. The fixture now models the **real** unit, read out of the noble
`udev_255.4-1ubuntu8.18_amd64.deb` the image unpacks:

```
[Unit]
Description=Rule-based Manager for Device Events and Files
DefaultDependencies=no
Before=sysinit.target
```

and sabotage cases 22-24 prove the three new checks can fail.

**And the suite that proves the gate can fail was itself red.** While fixing
the above, `tests/systemd-gate-sabotage.sh` was found to be failing **five of
its own cases** — cases that had never been run against the tree they were
written for. `tests/branch-gate.sh` runs that suite, so the gate set had been
red since the commit that added the cases (it was never pushed, so nobody saw
it). Every one of the five was a defect in the *case*, not in the gate, and
they failed three different ways: two planted a shell **syntax error** instead
of the defect they meant (the replacement swapped the `if` line but left the
body and the closing `fi` behind, so `build.sh` could not be sourced at all,
and the gate went red for a reason that had nothing to do with the case); one
was anchored to a line of `build.sh` that had since been re-wrapped, so its
exact-string edit no longer applied; and two asked the gate to catch something
in a stage the gate **does not run** — `build_gui` and `build_hypr` are never
called by `tests/systemd-gate.sh`, so no planting can make the gate notice
their skip guards.

The last pair is the dangerous kind: read at face value, they say "the gate is
blind to the hypr/gui skip guards", which is a false conclusion you would act
on. The gate now **can** say that — section 8 reads the shipped skip guards
out of `build.sh` and fails if they stop asking about `seatd` and the
`_seatd` group — so the two cases assert a real claim instead of a fiction.
The other three now plant in the gate's **fixture** (the tree the stage
builds) rather than in the stage's own assertions, because the assertions are
the thing doing the catching.

**NOT verified — this is the honest gap:**

- **It has been booted exactly once** (2026-10-21, in a VMware guest), and that
  boot found four defects — bugs 47, 48, 49 and 50 — of which bug 50 meant the
  next boot would not have happened at all. One boot is not a test suite:
  anything that only shows up on the *second* boot, on real hardware, on a
  different disk controller, or with a serial console instead of a VT is still
  unverified, and so is every one of the four fixes above, which have not been
  booted since.
- Package closure size is unmeasured (the dev box has no noble mirrors, so the
  closure could not be downloaded here).
- Nothing has exercised systemd's actual startup: udevd, unit ordering at boot,
  the wizard's terminal under `StandardInput=tty`, or the console service's
  restart behaviour.
- **The disk-controller fix is untested on the hardware it is for.** Bug 46 added
  `SCSI`/`SCSI_LOWLEVEL`/`SCSI_MPT3SAS`/`VMWARE_PVSCSI`/`SCSI_VIRTIO` because a
  VMware Quick Setup guest showed the wizard **no disk at all** — VMware's default
  controller is LSI Logic SAS (`mpt3sas`), and the kernel had `ATA_PIIX`,
  `BLK_DEV_SD` and `BLK_DEV_NVME` but no SCSI host adapter. The symbols are
  asserted so a dropped one stops the build (see `require_kernel_config`, and
  `tests/kernel-gate.sh`), but "asserted =y" is a claim that it compiles, not
  that it bound to a disk. That needs the same VMware boot.

**A green `tests/systemd-gate.sh` is not a bootable image.** It says the pieces
are coherent. The thing that closes this is a VMware boot of the systemd ISO,
same as bugs 15/18/25/34/35/38/44 — and bug 46 is closed by the same boot, since
a machine that cannot see its disk cannot get as far as the wizard. The boot
that has happened so far is the proof of the point: it found four defects the
gate called green, one of which was fatal.

### The seventh push: the ISO's own read-back gate caught the swap being undone

CI run `39760973097` got all the way to packaging the disc and then failed the
**ISO's own read-back gate**:

```
iso: the ISO boots systemd but its power commands are wrong:
     sbin/reboot -> /bin/busybox usr-sbin/reboot -> /bin/busybox ...
iso: systemd expects /usr/bin/systemctl there, not a busybox applet
```

The gate is the one in `build_iso`: it reads `/sbin/init` off the finished
image, decides from it which init the disc boots, and then checks that the
power commands on the disc agree. The image booted systemd, and the power
commands were busybox's. Both facts were true of the same tree.

The cause is that **the swap was undone on the way to the disc**. The `iso`
chain re-runs the desktop stages over the tree: `build_rootfs` clobbers
`/etc/group`, which takes the `_seatd` group with it, and that group is part of
what the gui and hypr stages' skip guards ask about — so those stages run
again, and each of them calls `power_links()`. `power_links()` did not know
which init the tree carried; it always wrote busybox's applets. The systemd
stage had done the right thing, and then the desktop stages overwrote it.

So the tree's flavour was never remembered in a variable, and every caller
guessed — or, rather, every caller asserted the default. The staged tree
outlives any one `build.sh` run (it is cached between runs), so "what does this
tree boot" has to be answered by **reading the tree**, not by remembering.

`init_flavour()` already existed and already answered exactly that question, by
reading `sbin/init`. `power_links()` now asks it, and links `systemctl` or
busybox accordingly:

- `power_links()` is the **one** definition of the layout. `build_systemd()`
  calls it like everybody else does, instead of carrying its own copy of the
  systemctl loop, so the stage and the stages that re-run over the tree later
  cannot disagree about what a systemd machine wants.
- `default_flavour()` puts Copper's own `/sbin/shutdown` wrapper back when it
  takes a tree *back* from systemd, because busybox ships no shutdown applet —
  the wrapper **is** the shutdown command on a default tree. (`rm` first, so
  what is left is a regular file and not a link. `install` replaces a symlink
  rather than writing through it — checked, not assumed — but removing it
  outright says what is meant and does not depend on that.)
- The `systemd` chain now normalises to the default flavour before it swaps,
  so the stage is re-runnable and always starts from a known tree.

**Why the gate did not see it.** `tests/systemd-gate.sh` runs `build_systemd`
against a mocked tree, so it never sees the desktop stages re-run over that
tree — and a gate that cannot see the path cannot guard it. But the function
that was wrong is `power_links()`, and it can be exercised directly against a
tree of each flavour: section 3a of the gate now checks that a systemd tree
gets `systemctl` links and a busybox tree gets busybox's applets and the
wrapper. Sabotage case 25 plants the opposite defect — `power_links()` blind
to the tree's init — and the gate catches it.

## Remaining work (phase 2+)

- **Boot it again**, with the fixes for bugs 47-50 in it. The first boot found
  four defects; the next one is what says the fixes are fixes. Nothing below is
  worth doing before that happens.
- Network: `udhcpc` -> `systemd-networkd` (+ the lease/resolver files).
- Seat: `seatd` -> `logind`, which is what makes
  `XDG_RUNTIME_DIR`/`pam_systemd` real and retires `prepare_session_dirs`.
- Plymouth: `build_plymouth` deliberately drops plymouth's units, so the splash
  needs a Copper unit (or an attach-mode decision) under systemd.
- `wpa_supplicant.service`.
- First-boot contract: move the wizard's own questions onto journal-first
  logging (`systemctl status`, `journalctl`) instead of the console dialogue.
- Image size: measure the real growth and decide.
- Rollback path: how a machine gets back to the busybox image.

## risks expected during a migration (the bad case)

1. **Layout chroots fail**: `build_hypr` chains `chroot $TGT /usr/bin/Hyprland
   --version`; we need `systemctl status` equivalent.
2. **Compose manager depends on `u...`**: every package tends to depend on
   `systemd` after a swap.
3. **Image size explosion**: maybe 100MB.
4. **udev/hwdb entries**: lots of packaging of `/etc/udev/hwdb.bin`.
5. **Boot failure on VMs**: firstboot gets worse.

---

Phase 1 is in the tree. `copper-init.c` remains the sole init on the default
image, and on the systemd image it remains the console: `--console`, one unit,
`copper-console.service`.
