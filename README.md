<img width="1512" height="807" alt="Screenshot 2026-10-10 123948" src="https://github.com/user-attachments/assets/af3e5fea-db73-4694-913a-8b0f190f804f" />

<h1 align="center">Copper Linux</h1>

<p align="center">
  A daily-driving Linux distro, built from source, by a small team.
</p>

<p align="center">
  <a href="https://12hrformat.github.io/copperlinux-site/">Copper Linux website</a>
</p>

---

Copper is our distro. Not a Debian or Arch rebrand — built from source, with a small, curated set of packages. It's designed to be a daily driver for Linux nerds, coders, and students who want something that feels like theirs. It's small, fast, and has a minimal base so you can add what you want. It has a GUI, but the default is a shell — so you can learn Linux without being forced into a desktop environment. It's built to be simple, but not simplistic.

Copper has a twin: **deadlight linux**, a cybersecurity-focused distro by the
same team. Same base, different goal — basically a reskin, but with the useful
tools already on it.

Copper linux is a work in progress. It's not ready for production use yet, but it's usable and fun to play with. The team is small, but we're working hard to make it better every day. Wanna contribute?

Copper linux also has its own package manager, **ingot**, which is hosted on GitHub Pages. It's not pacman, but it works. It fetches packages from a JSON index on Pages, downloads the payload from the real URL, verifies the hash, and installs it. It's designed to be simple and fast.

---

## Boot, and starting a desktop

First boot asks its questions, then lands on a **prompt**. That's
the current default and it's deliberate: the X stack is proven under QEMU but
not on every machine, so a failure in it costs a shell rather than the
machine.

| Command | What it does |
|---|---|
| `startxfce` | Starts the X server if one isn't already running, then XFCE on it. |
| `startxfce --check` | Reports what's installed and exits, starting nothing. |

`startxfce` exits **20** if there's no X server in the image, **21** if XFCE is
missing, **22** if the server started but never opened a display, **23** if the
server exited while starting, and **24** on a usage error. That's a contract —
a script can branch on the exit code without parsing a message.

Boot entries in GRUB:

| Entry | What you get |
|---|---|
| Copper Linux | Wizard if needed, then a shell |
| Copper Linux (verbose) | As above, with kernel messages |
| Copper Linux (debug) | Everything logged, panic-on-hang so a wedge reboots and shows its face |
| Copper Linux (initramfs shell) | A shell inside the initramfs, skipping the overlay — splits "kernel/initrd broken" from "our /init broke" in half |

---

## What's in this repo

```
Copper Linux
├── kernel           — Linux from kernel.org, our own .config
├── libc             — musl, built from source
├── userland         — coreutils, busybox, grep, sed, tar, ...
├── copper-sh        — our shell
├── copper-init      — our init, lives at /sbin/init
├── copper-firstboot — first-boot setup wizard
├── copper           — copper charge / rollback front end
├── ingot            — our package manager (GitHub Pages repo)
├── hotfixes.json    — the hotfix database `copper charge` reads
├── copper.iso       — bootable live ISO (VMware / VirtualBox / QEMU)
```

The build pipeline (`iso/build.sh`) is staged — `kernel`, `base`, `tools`,
`copper`, `rootfs`, `gui`, `sudo`, `initramfs`, `iso`, or `all` — and skips a
stage if it's already built, so re-runs on CI are cheap.

**Kernel:** Linux 6.12.10 LTS, with a trimmed config: ISO9660, overlayfs,
tmpfs, devtmpfs, virtio/e1000/vmxnet3 NICs, ATA/SATA, ext4, ptys. Drivers are
built in, no loadable modules.

**Base:** musl 1.2.5, busybox 1.36.1 (static, with adduser, chpasswd, mount,
hostname), coreutils 9.5, grep 3.11, sed 4.9, findutils 4.9.0, diffutils 3.10,
tar 1.35, gzip 1.13, xz 5.4.6 — all compiled from source and linked statically
against musl.

Run it locally with:

```sh
sudo bash iso/build.sh
```

or check the Actions logs for a CI run. A finished build uploads `copper.iso`
(~300 MB) as an Actions artifact.

---

## copper-init

Our own PID 1, not systemd. It mounts the basics, sets the hostname, runs the
first-boot wizard once, then keeps a `copper-sh` login shell alive on tty1.
Lives at `/sbin/init`.

The live initramfs (`iso/live/init`) finds the boot medium and builds a
writable overlay — read-only ISO root, tmpfs on top — before handing off to
`copper-init`. Persistence (G6) is the plan to move that writable layer onto a
real disk partition.

---

## copper-sh

A small POSIX-style shell, written in C. Mostly builtins for now, so it can do
useful things before the rest of the userland is on the system. Anything not
built in falls through to `execvp` and runs from `$PATH`.

## Contact

Instagram: [@12hrformat](https://www.instagram.com/12hrformat/)
Email: [12hrformat](mailto:12hrformat@proton.me)
Discord: join copper linux's server: [discord](https://discord.gg/qCQdxNV9Va)