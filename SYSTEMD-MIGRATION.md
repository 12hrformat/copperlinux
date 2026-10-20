# Systemd as PID 1 — migration

Status: **phase 1 in the tree, opt-in, NOT yet booted.** v0.9 still ships
busybox init; the default image is unchanged, its gates are green, and this
work is wired into the same gate set as everything else
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
- repoints `/sbin/init` and the power commands (`/sbin` **and** `/usr/sbin`) at
  systemd's own, after `build_copper`'s `power_links()` pointed them at busybox.
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
- The sabotage suite (`tests/systemd-gate-sabotage.sh`, new) plants eleven
  defects — misplaced key, nonexistent directive, bare glob, no repoint, unwired
  unit, removed `--console`, busybox power links, 0777 units, leaked build tool,
  a `tree_hash` blinded to symlinks, and a `systemd)` dispatch line without its
  toolchain — and every one is caught. That suite is
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

Both are recorded here rather than in the commit alone because they are the
argument for the two new checks: a gate that is green only on the machine it was
written on is not a gate.

**NOT verified — this is the honest gap:**

- **It has never been booted.** Not in a VM, not on hardware. Nothing in this
  repo can boot an ISO in CI, so this is structural verification only.
- Package closure size is unmeasured (the dev box has no noble mirrors, so the
  closure could not be downloaded here).
- Nothing has exercised systemd's actual startup: udevd, unit ordering at boot,
  the wizard's terminal under `StandardInput=tty`, or the console service's
  restart behaviour.

**A green `tests/systemd-gate.sh` is not a bootable image.** It says the pieces
are coherent. The thing that closes this is a VMware boot of the systemd ISO,
same as bugs 15/18/25/34/35/38/44.

## Remaining work (phase 2+)

- **Boot it.** Nothing below is worth doing before this happens.
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
