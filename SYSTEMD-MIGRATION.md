# Systemd as PID 1 — migration proposal for Copper Linux

Status: **proposal / not started.** v0.9 runs busybox init. This document
exists so the swap can be decided and scoped on a fixed question rather than
as a surprise on a hot build.

## Why this is a big deal

Going from busybox -> systemd is not "copying a package in." It changes:

- PID 1 and all boot ordering
- Network: udhcpc becomes systemd-networkd, lease files relocate
- Seat/DRM: separate seatd  -> logind
- First boot: replaces two C daemons with service units + journal-first logging
- Service assumptions: everything Copper runs (`plymouth`, `inges`, `myscript`
  hooks) needs unit files
- Image size: +80 to +120MB of glibc libraries, a 10 percent-ish increase on
  an already full 700MB-ish ISO

Time estimate: 3 focused weeks of work, plus a week of boot-debugging on real
hardware. A half-done swap is an **unbootable ISO**, not a degraded one.

## Recommendation

Ship v0.9 on busybox, plan this as a v1.5 project. Hyprland's `seatd` path
works fine as-is in our (tested) boot, and the real blockers are library
version issues, not the init system. So no urgent justifier for this change.

If product direction genuinely needs systemd features, do the migration as a
separate named sprint at a time when nobody is panicking to launch.

## What actually has to change (by layer)

### 0. Choose the base

- Base image becomes 100% glibc: every existing tool becomes its glibc
  equivalent. Ours currently mixes (musl static init + glibc userspace).
  Decision: do not port musl-mode systemd; lean on glibc throughout:
  `build_gnu` already brings a base of Gnu packages, no change there.
- Dpkg is not on the path; keep `apt-get download` there as the fetch tool.

### 1. PID 1 swap

- Build stage installs: `systemd systemd-sysv systemd-boot eos...`
  Most crucially `systemd` package itself + `udev` + `modprobe` chain.
- Replace the init in the initramfs: `init=/lib/systemd/systemd`.
- The first-boot contract in `iso/src-init/copper-init.c` collapses into `systemd`?:
  - `start_seatd()` -> unit + `logind` (seatd probably retired)
  - `start_dbus()` -> becomes `dbus.service`
  - `start_wpa_supplicant()` -> `wpa_supplicant.service`
  - udhcpc lease -> `systemd-networkd` + ack unit.

  Copper specific single-binary (`copper-firstboot`) becomes a oneshot unit:
  `ConditionPathExists=!/etc/copper-firstboot.done`.

- `build_initramfs` becomes dracut/generator-style.

### 2. Login backend

- `loginctl` surfaces the XFCE user; Hyprland session via `hypridle`).
- `XDG_RUNTIME_DIR` comes from `pam_systemd` rather than our manual `mkdir`.
- `dbusb-dispatch` is more options under new add-on process.

### 3. Session handoff (Hyprland)

- Right now starthyprland relies on seatd from init.
- Move to: `logind` (user seat), `dbus`, `polkit` policy, then `start-hyprland`.
- Guest-mode and pam config gets addressed via systemd PAM accounts.
- `hyprland-guiutils` can be hosted as an `apply-updates.service`.

### 4. What actually tears the bad thing out

- Every `read -r answer / case` terminal questions becomes units behind
  `systemctl status`.
- The quiet / noisy boot ordering comes from sync vs async kexec semantics
  rather than `sleep`/busy loop.
- Logging via `journalctl` instead of dmesg.

## risks expected during a migration (the bad case)

1. **Layout chroots fail**: `build_hypr` chains `chroot $TGT /usr/bin/Hyprland
   --version`; we need `systemctl status` equivalent.
2. **Compose manager depends on `u...`**: every package tends to depend on
   `systemd` after a swap.
3. **Image size explosion**: maybe 100MB.
4. **udev/hwdb entries**: lots of packaging of `/etc/udev/hwdb.bin`.
5. **Boot failure on VMs**: firstboot gets worse.

## Phasing if someone says "start tomorrow"

- Week 1: new rootfs on systemd stage, only X11/XFCE desktop in VM.
- Week 2: Hyprland under logind, session units.
- Week 3: bootsplash/networking overlap (plymouth deferred or kept).
- Week 4: rollback path + tests.

## Recommendation

v1.5 track, not launch requirement. See HANDOFF.md for the v0.9 decision
working assumption. Hypland is library-version-limited, not init-limited.
Keep busybox for first ship; queue this doc as README-seen under
`docs/systemd-migration.md`.

---
`copper-init.c` will remain the sole init driving `start_seatd`, `start_dbus`,
`firstboot` until a migration is explicitly funded.
