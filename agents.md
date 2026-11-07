# Copper Linux — agent notes

Working notes for AI coding agents (and their humans) in this repository.

## What this is

Copper Linux is a hobby Linux distribution: a from-source built kernel + musl +
busybox + coreutils base, Copper's own shell (`copper-sh`) and first-boot wizard,
an XFCE/Hyprland desktop, a Plymouth boot splash, and systemd integration.
Everything that ships lives in this tree and is either built or asserted on by
the gates below.

## Build

`sudo bash iso/build.sh <stage>` — stages: `kernel`, `base`, `tools`, `copper`,
`rootfs`, `gui`, `hypr`, `plymouth`, `sudo`, `systemd`, `initramfs`, `iso`, `all`.

The `iso` stage is the packaging + read-back gate: it builds the ISO and then
extracts files back out of the artifact with xorriso to verify modes, ownership
and kernel command lines actually made it onto the disc.

## Test

`sudo ./tests/branch-gate.sh` runs the fast gate suite (shell, launchers, wizard,
persistence, ingot, systemd, console, plymouth, …). Individual gates: `bash
tests/<name>-gate.sh`. The workflow `.github/workflows/build-iso.yml` also runs
the full build and a QEMU boot of the default ISO.

## Commit style

- Subject prefixes: `fix:` for a fix. `bugs:` / `bug:` prefixes are **not**
  allowed — use `fix:` only.
- No AI slop, filler or boilerplate. Write the commit the way a careful human
  would.
- Always verify with tests before committing a fix.
- Don't close out with phrasing like "the owner booted, so the bug is closed" —
  it reads like the fix was vibecoded, not reasoned through.

## Working rules

- Always ask questions before fixing something. We do not want a bug where a
  feature was asked for.

## Conventions

- Gates are the source of truth for behaviour that is expensive to check by hand:
  a fix lands with the gate that proves it. `tests/*-gate.sh` and the checks in
  `iso/build.sh` must agree — when one changes, the other changes with it.
- Shell scripts in the tree are held to a POSIX-ish style for busybox applets;
  run the POSIX checks before assuming a script is fine.
- Comments in shell/C explain the *why*, not the what; keep that when editing.
- The tree is maintained on Windows (core.fileMode is off) — set the executable
  bit with `git update-index --chmod=+x <file>` for anything a gate runs.
