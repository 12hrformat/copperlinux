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

Copper has a twin: **Deadlight linux**, a cybersecurity-focused distro by the
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

## Wireless

There is no NetworkManager. On a machine with no wired connection, boot starts
`wpa_supplicant` against `/etc/wpa_supplicant/wpa_supplicant.conf` and then asks
`udhcpc` for an address, so a laptop joins the network it was last given before
anyone logs in. `copper wifi` (or `copper-wifi`) manages that file:

| Command | What it does |
|---|---|
| `copper wifi interfaces` | List the wireless interfaces. |
| `copper wifi list` | Scan and list nearby networks. |
| `copper wifi wlan0 scan` | Ask the radio for a scan. |
| `copper wifi wlan0 get-networks` | Show what the last scan found. |
| `copper wifi wlan0 connect SSID [PASS]` | Remember a network and bring the interface up. |
| `copper wifi wlan0 show` | Show the supplicant's state on that interface. |
| `copper wifi wlan0 disconnect` | Drop the radio. |
| `copper wifi add SSID [PASS]` | Remember a network. Without `PASS` it is joined as an open one. |
| `copper wifi up` | (Re)start the radio and ask for a lease now. |
| `copper wifi status` | Show the supplicant's state. |
| `copper wifi forget SSID` | Remove a remembered network. |

The interface-then-action shape is `iwctl`'s, minus the `station` keyword: name
the interface first, or leave it out and the first radio is used. Running
`copper wifi` with no arguments and a terminal opens the same commands as an
interactive prompt.

`add` runs `wpa_passphrase`, so the passphrase itself is never written to disk —
only the derived `psk`. A passphrase `wpa_passphrase` refuses is rejected before
the file is touched, so a bad one cannot leave a half-written block behind.
Writing needs root.

The kernel carries `CFG80211`/`MAC80211` and a driver per vendor family. The
firmware those drivers load ships as a curated subset of `linux-firmware` plus
`wireless-regdb` (the regulatory database is a separate package), kept in the
zstd-compressed form Ubuntu ships it. None of it has been tried against a real
radio yet — QEMU has no 802.11 adapter — so treat the driver list as "enabled",
not "verified". `tests/wifi-gate.sh` covers the config file handling, which is
the part that breaks quietly.

---

Run it locally with:

```sh
sudo bash iso/build.sh
```

or check the Actions logs for a CI run. A finished build uploads `copper.iso`
(~300 MB) as an Actions artifact.

---

## copper-sh

A small POSIX-style shell, written in C. Mostly builtins for now, so it can do
useful things before the rest of the userland is on the system. Anything not
built in falls through to `execvp` and runs from `$PATH`.

## Contact

Instagram: [@12hrformat](https://www.instagram.com/12hrformat/)
Email: [12hrformat](mailto:12hrformat@proton.me)
Discord: join copper linux's server: [discord](https://discord.gg/qCQdxNV9Va)