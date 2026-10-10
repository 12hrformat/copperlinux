<img width="1242" height="788" alt="IMG_20260926_213859" src="https://github.com/user-attachments/assets/ba0b244f-ec8e-403d-b595-1a68c8b81463" />


<h1 align="center">Copper Linux</h1>

<p align="center">
  A daily-driving Linux distro, built from source, by a small team.
</p>

<p align="center">
  <a href="https://12hrformat.github.io/Copper-linux-website/">12hrformat.github.io/Copper-linux-website</a>
</p>

---

Copper is our own distro, not a rebrand of Debian or Arch. We build the
kernel, the libc, and the userland from source, and we write the parts that
make it *Copper* ourselves — the shell, the init system, the first-boot
setup. Arch and debian are good but we wanted to do it *our* way.

The source code of Arch linux and Debian was used for refrence, nothing more.

Copper has a twin: **deadlight linux**, a cybersecurity-focused distro built by the
same team, sharing the Copper base but aimed at security work instead of general daily use. Basically a reskin but preinstalled tools.

---

## Where things stand

| Part | Status |
|---|---|
| `copper-sh` (shell) | Works. Arrow-key line editing, history, pipes, redirects. |
| Networking | Works — wired only. DHCP on boot, `ping`/`nslookup`/`wget` present. |
| `copper charge` / `copper rollback` | Ship in the ISO. Logic tested end to end off-ISO; not yet run on a booted system. |
| First-boot wizard | Boots and asks its questions. A full run was verified: all six questions answered, nothing refused, no shell prompt. |
| Desktop | **Removed.** There was a framebuffer desktop, `copper-gui`, which drew a picture of a desktop with hardcoded strings and no window manager behind it. It is gone: `iso/gui/` is deleted, the build stage that compiled it is gone, and `gui=1` no longer means anything. XFCE is the desktop, and XFCE is real software doing real work rather than our own drawing. |
| X server (Xorg) | **Builds.** 1.21.1.9 with `modesetting_drv.so` and `libfbdevhw.so` both present. Not yet booted inside Copper — a server that compiles is a server that links. |
| `startxfce` | **Ships, and says why it cannot start.** It names the missing piece and returns a distinct exit code, so "XFCE isn't built yet" is never confused with a broken PATH. |
| XFCE | **Wanted, not started.** It is an X client, so it needs the server above plus glib, GTK3 and ~30 libraries, which means a glibc userspace alongside the static musl one. |
| Base system (kernel, musl, userland) | Building from source, CI green end to end. |
| Bootable ISO | Builds successfully. Boots in a VM. |
| WiFi | **Not supported. yet** Wired drivers only, no `wpa_supplicant`, and a VM has no wireless NIC anyway. |

### Display drivers, and what is actually proven

The first framebuffer build enabled `DRM_BOCHS` alone. That driver binds to
exactly one device — QEMU's Bochs VGA, PCI `1234:1111` — and every measurement
behind it was taken under QEMU `-vga std`, which is that one adapter. It shipped
and booted to a shell on any other machine, because nothing in the kernel matched
its display hardware and `copper-init` correctly fell back.

The kernel now builds in nine display options and asserts every one of them, so
a silently dropped symbol stops the build instead of shipping a shell. Measured
on one kernel, one boot per emulated device:

| Emulated device | Driver that bound | `/dev/fb0` |
|---|---|---|
| `-vga std` | `bochs-drm` | yes |
| `-vga virtio` | `virtio-gpu` | yes |
| `-device qxl-vga` | `qxl` | yes |
| `-device vmware-svga` | `vmwgfx` | **no, on QEMU** |
| `-device cirrus-vga` | *nothing* | no |
| VirtualBox | `vboxvideo` | **untestable** |

Three honest limits on that table:

- **VMware is unproven.** `vmwgfx` probes the adapter correctly and then prints
  `*ERROR* vmwgfx seems to be running on an unsupported hypervisor` and stops.
  It checks the hypervisor vendor, and QEMU is not VMware. The driver is the
  right one; only a real VMware guest can confirm it delivers a framebuffer.
- **VirtualBox cannot be tested at all.** QEMU has no VirtualBox display device
  — `-device vboxvga` is rejected as an invalid model name. `DRM_VBOXVIDEO` is a
  claim that it compiles, nothing more.
- **`FB_VESA` and `FB_EFI` were never exercised.** The test boots with `-kernel`
  directly, so no BIOS runs, and those two need a VGA BIOS. Only a real ISO boot
  through GRUB reaches them.

`cirrus-vga` has no driver and is a real gap. It is QEMU's legacy default rather
than anything a current VM hands out, so it is recorded rather than fixed.

## Boot, and starting a desktop

The first boot asks its questions and then lands on a **`copper-sh` prompt**.
That is the current default, and it is deliberate: the X server builds but has
never been booted on this kernel, so starting a desktop automatically would
either work or leave a blank screen. A shell in front of it means a failure in
the X stack costs a shell rather than the machine.

| Command | What it does |
|---|---|
| `startxfce` | Starts the X server if one is not already running, then XFCE on it. |
| `startxfce --check` | Reports what is installed and exits, starting nothing. |

`startxfce` exits **20** if there is no X server in the image, **21** if XFCE is
missing, **22** if the server started but never opened a display, **23** if the
server exited while starting, and **24** on a usage error. Those are a contract
— a script can branch on them without parsing the message.

Today it returns 20 or 21, because neither the X server nor XFCE is in the
image yet. That is the useful behaviour: it names what is absent instead of
printing `not found`, which is indistinguishable from a broken PATH.

Boot entries in GRUB:

| Entry | What you get |
|---|---|
| Copper Linux | Wizard if needed, then a shell |
| Copper Linux (framebuffer desktop) | The same, with `gui=1` so the desktop starts instead |
| Copper Linux (verbose) / (debug) | As above, with kernel messages |
| Copper Linux (initramfs shell) | A shell inside the initramfs, skipping the overlay |

---

## What's in this repo

```
Copper Linux
├── kernel          — Linux from kernel.org, our own .config
├── libc            — musl, built from source
├── userland        — coreutils, busybox, grep, sed, tar, ...
├── copper-sh       — our shell
├── copper-init     — our init, lives at /sbin/init
├── copper-firstboot — first-boot setup wizard
├── copper          — copper charge / rollback front end
├── hotfixes.json   — the hotfix database `copper charge` reads
└── copper.iso      — bootable live ISO (VMware / VirtualBox / QEMU)
```

The build pipeline (`iso/build.sh`) is staged — `kernel`, `base`, `tools`,
`copper`, `rootfs`, `initramfs`, `iso`, or `all` — and skips a stage if it's
already built, so re-runs on CI are cheap.

**Kernel:** Linux 6.12.10 LTS, with a trimmed config: ISO9660, overlayfs,
tmpfs, devtmpfs, virtio/e1000/vmxnet3 NICs, ATA/SATA, ext4, ptys. Drivers
are built in, no loadable modules.

**Base:** musl 1.2.5, busybox 1.36.1 (static, with adduser, chpasswd,
mount, hostname), coreutils 9.5, grep 3.11, sed 4.9, findutils 4.9.0,
diffutils 3.10, tar 1.35, gzip 1.13, xz 5.4.6 — all compiled from source
and linked statically against musl.

Run it locally with:

```sh
sudo bash iso/build.sh
```

or check the Actions logs for a CI run. A finished build uploads
`copper.iso` (~57 MB) as an Actions artifact.

---

## copper-init

Our own PID 1, not systemd. It mounts the basics, sets the hostname, runs
the first-boot wizard once, then keeps a `copper-sh` login shell alive on
tty1. Lives at `/sbin/init`.

The live initramfs (`iso/live/init`) finds the boot medium and builds a
writable overlay — read-only ISO root, tmpfs on top — before handing off
to `copper-init`. That overlay is also the mechanism persistence will use
once it's built out.

---

## copper-sh

A small POSIX-style shell, written in C. Mostly builtins for now, so it can
do useful things before the rest of the userland is on the system.
Anything not built in falls through to `execvp` and runs from `$PATH`.

| Command | Does |
|---|---|
| `cd`, `pwd` | navigate, print working directory |
| `ls`, `cat`, `head`, `tail`, `wc`, `grep` | inspect files |
| `echo`, `tee` | output |
| `cp`, `mv`, `rm`, `ln`, `mkdir`, `rmdir`, `touch`, `chmod` | file operations |
| `whoami`, `id`, `hostname`, `uname`, `date` | system info |
| `history`, `type`, `which`, `env` | shell/session info |
| `sleep`, `true`, `false`, `clear`, `exit` / `quit` | misc |

Also handles `#` comments, single and double quotes, backslash escapes,
pipes (`|`), and redirects (`<`, `>`, `>>`). Ctrl-C kills the running
command, not the shell.

Build it:

```sh
make
./copper-sh
```

Install system-wide:

```sh
make install    # /usr/local/bin/copper-sh
```

---

## copper charge — hotfixes without a reinstall

The idea: a bug is found, someone writes the fix down in `hotfixes.json`, and
anyone running Copper can pull that fix onto their live system in place. No
ISO rebuild, no reinstall, and if a fix turns out to be wrong there is a way
back.

```sh
copper charge                  # apply every hotfix that applies
copper charge --status         # (same thing — no real dry-run mode yet)
copper rollback                # list available backups
copper rollback <backup_name>  # put one back
```

Both need root. Backups land in `/var/backups/copper/`, and every action is
appended to `/var/log/copper-charge.log`.

### Writing a hotfix

`hotfixes.json` at the repo root. One entry per bug:

```json
{
  "hotfixes": [
    {
      "id": "demo-banner",
      "file": "etc/copper/demo.txt",
      "fail_code": "THIS LINE IS BROKEN",
      "new_code": "THIS LINE HAS BEEN FIXED BY COPPER CHARGE",
      "description": "Demo: proves charge can find, back up and patch a file"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `id` | Short name for this fix, used in the log |
| `file` | Path on the **live system**, relative to `/` |
| `fail_code` | The exact text to look for. Its absence means "already fixed" |
| `new_code` | What to put in its place |
| `description` | One line, shown when the fix is applied |

### How it decides

- `fail_code` present in the file → back it up, then replace it. Repeat until
  the text is gone.
- `fail_code` absent → skip with `already fixed?`. This is what makes
  `copper charge` safe to run twice, or on a machine that already has the fix.
- File missing → skip, do not create it. `copper charge` never writes a new
  file; it only patches one that already exists.

There is no automatic failure detection. A human maintainer writes the entry,
and `copper charge` applies the text edits. Anything subtler than a literal
string swap does not belong in this format.

### Where it gets the database

`/etc/copper/config`:

```sh
HOTFIX_URL="https://raw.githubusercontent.com/12hrformat/copper/main/hotfixes.json"
BACKUP_DIR="/var/backups/copper"
LOG_FILE="/var/log/copper-charge.log"
```

Point `HOTFIX_URL` at a fork or branch to test someone else's fixes.

**If `/etc/copper/hotfixes.json` exists it is used and the network is never
touched.** The ISO ships one so `copper charge` is testable with no network
at all. Delete that file to go back to always fetching.

### Rollback

`copper charge` writes backups under `/var/backups/copper/`, naming each one
after the file it came from with `/` turned into `_`:

```
/etc/copper/demo.txt   →   etc_copper_demo.txt
```

`copper rollback` with no arguments lists them; give it one name to restore.
The current file is saved as `<name>.pre-rollback` first, so a rollback can
itself be undone.

### Notes and limits

- The live system ships busybox `wget`, not `curl`. `copper charge` prefers
  `curl` when it is present and falls back to `wget` otherwise.
- The rootfs carries no CA bundle, so `wget` runs with
  `--no-check-certificate`. That is fine for fetching a JSON file from a
  known repo over a link you already trust; it is **not** fine for anything
  security-sensitive.
- Both scripts are plain busybox `sh`. No python on the live system.
- Only the first occurrence of `fail_code` is replaced per pass.

---

## Repo layout

```
src/main.c            shell loop, prompt, tokenizer, process launching
src/builtins.c        builtin commands + command table
src/builtins.h        interface between the two
hotfixes.json         hotfix database read by `copper charge`
iso/build.sh          from-source distro build
iso/copper.sh         installs as /usr/bin/copper
iso/copper-charge.sh  installs as /usr/bin/copper-charge
iso/copper-rollback.sh installs as /usr/bin/copper-rollback
iso/live/init         live initramfs
iso/boot/             GRUB config
iso/src-init/         copper-init source
iso/firstboot/        copper-firstboot source
iso/rootfs-overlay/   default /etc for the rootfs
tests/smoke.sh        sanity checks
Makefile
HANDOFF.md            current state, next-person notes
PR.md                 PR notes/template
```

---

## What's next

- **Boot an ISO on VMware and confirm the desktop appears.** The kernel now
  carries `DRM_VMWGFX`, the driver for that adapter, and it probes correctly
  under emulation. Whether it delivers `/dev/fb0` on real VMware hardware is the
  one thing in the driver table that QEMU cannot answer.
- **Boot Xorg inside Copper and check it over the wire protocol.** A screenshot
  cannot tell a healthy server from one that drew something and then died; a
  client connecting and being told the screen geometry can.
- **XFCE.** The requested end state. It needs the server above, then glib, GTK3
  and roughly thirty libraries, which means a glibc userspace alongside the
  static musl one. This is a project, not a flag — see `HANDOFF.md`.
- A confirmed clean first boot: wizard asks everything, creates the account,
  drops to a `dragon@copper` prompt
- `copper charge` run against a real booted system, not just off-ISO
- WiFi, if we decide a VM-testable target is possible at all
- `copper charge --status` as a real dry run
- `~/.copperrc` init file for the shell
- Shell history persisted to disk
- Tab completion in `copper-sh`

---

## Contributing

Small team, early stage, things will be rough. Read `HANDOFF.md` first.
Issues and pull requests welcome.

## License

Copper's own code — `copper-sh`, `copper-init`, `copper-firstboot`, and the
build scripts — is MIT licensed. See `LICENSE`.

The rest of the system is source-built from other projects, each under its
own license:

| Component | License |
|---|---|
| Linux kernel | GPLv2 |
| busybox | GPLv2 |
| coreutils, findutils, tar, gzip, sed, grep | GPLv3 |
| musl | MIT |
| Copper source files (`copper-sh`, `copper-init`, `copper-firstboot`, `copper` tools, build scripts) | MIT |

Building or distributing the full ISO means complying with all of the
above, not just Copper's own MIT terms.

## Contact

- Email: [12hrformat@proton.me](mailto:12hrformat@proton.me)
- Instagram: [@mommy_said_im_special](https://instagram.com/mommy_said_im_special)
- Or simply tag us in [Discussions](https://github.com/12hrformat/copper/discussions)
