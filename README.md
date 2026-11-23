<img width="1512" height="807" alt="Screenshot 2026-10-10 123948" src="https://github.com/user-attachments/assets/af3e5fea-db73-4694-913a-8b0f190f804f" />

<h1 align="center">Copper Linux</h1>

<p align="center">
  A daily-driving Linux distro, built from source, by a small team.
</p>

<p align="center">
  <a href="https://12hrformat.github.io/copperlinux-site/">Copper Linux website</a>
</p>

---

Copper is our distro. Built from source, with a small, curated set of packages. It's designed to be a daily driver for Linux nerds, coders, and students who want something that feels like theirs. It's small, fast, and has a minimal base so you can add what you want. It has a GUI: three desktops, XFCE, Niri and Hyprland, never the default at
the same time. Copper is a daily driver: keep what you need, drop the rest.

Copper has a twin: **Deadlight linux**, a cybersecurity-focused distro by the
same team. Same base, different goal — a sibling build with the useful
tools already on it.

Copper linux is a work in progress. It's not ready for production use yet, but it's usable and fun to play with. The team is small, but we're working hard to make it better every day. Wanna contribute?

Copper linux also has its own package manager, **ingot**, which is hosted on GitHub Pages. It fetches packages from a JSON index on Pages, downloads the payload from the real URL, verifies the hash, and installs it. It's designed to be simple and fast.

Payloads live in GitHub releases, and on some networks the release CDN throttles a download to a crawl. ingot therefore fetches release assets through a public GitHub mirror first and falls back to the direct URL last, checking the page's sha256 on each source so a mirror that answers with the wrong bytes is skipped instead of trusted. The manifest always keeps the canonical URL. Set `INGOT_MIRRORS` to a space-separated list of prefixes (for example `INGOT_MIRRORS=https://ghfast.top`) to choose your own, or to `none` to talk to GitHub directly.

---

## Boot, and starting a desktop

First boot asks its questions, then lands on a **prompt**. That's
the current default and it's deliberate: the X stack is proven under QEMU but
not on every machine, so a failure in it costs a shell rather than the
machine.

|| Command | What it does |
||---|---|
|| `startxfce` | Starts the X server if one isn't already running, then XFCE on it. |
|| `startxfce --check` | Reports what's installed and exits, starting nothing. |
|| `startniri` | Starts niri — the optional second desktop — on the tty. |
|| `startniri --check` | Reports what's installed and exits, starting nothing. |
|| `starthyprland` | Seeds the Hyprland session config and starts the Hyprland compositor on the tty (requires `sudo ingot install hyprland` first). |
|| `starthyprland --check` | Reports what's installed and exits, starting nothing. |
|| `starthyprland --yes` / `--no` | Install the payload/components without asking, or start without them. |

On the default Copper-init image, **Ctrl+Alt+F3** opens a password-protected
login prompt on tty3. Use the account and password created during first boot;
Ctrl+Alt+F1 returns to the main session. The systemd image provides login
prompts on tty2 through tty6 as well.

First boot also asks which desktop you want, `xfce`, `niri` or `hyprland`;
XFCE is the default and both `niri` and `hyprland` are opt-in. Either launcher
works from the prompt whatever you picked.

## Sound

Copper ships **both** audio servers and starts whichever `/etc/copper.conf` names:

```
audio=pulseaudio      # the default
audio=pipewire        # pipewire + wireplumber + pipewire-pulse
```

The first-boot wizard asks for one and writes the line; switching later is a
one-line edit and a new session, not a reinstall. Both serve the PulseAudio
protocol, which is what firefox, mpv and cava speak.

A running server on a muted card is a silent machine that looks healthy in
every log, so the launchers do more than start a daemon: they call
`copper-audio init`, which unmutes and raises the playback controls on every
card the kernel reports. The same command is available from a prompt:

| Command | What it does |
|---|---|
| `copper-audio` / `copper-audio status` | The selected server, whether it is running, the cards and their Master level. |
| `copper-audio init` | Unmute and raise Master/PCM/Speaker/Headphone/Front/HDMI to 80% on every card, then store the state if it can. |
| `copper-audio test` | One second of 440 Hz on the default device. |
| `copper-audio server` | Just which server is up. |

The kernel ships the HDA driver, the Intel HDA controller and the Realtek,
analog, HDMI and SigmaTel codecs, which is what VMware and QEMU present. The
image has no card for anything else; if `/proc/asound/cards` is empty, the
machine's audio hardware is not HDA and the driver is genuinely missing.

## Niri desktop

Niri is Copper's second desktop, optional like Hyprland and never the default.
Its configuration is vendored in this repository under
`iso/rootfs-overlay/usr/share/copper/niri-skel`; the build copies it to
`/usr/share/copper/niri-skel` and `startniri` seeds it into the user's home.
It was originally pinned from `12hrformat/copper-niriconfig` at commit
`31f5477` (tarball sha256 `5834dc35…`).

Copper layers its own adjustments on top: a small `copper-tweaks.kdl`, shipped
in this repository and appended with niri's positional top-level `include`,
gentles the animation springs so motion settles instead of snapping, rounds
every window, and dims unfocused windows slightly. Removing the include line
restores the shipped configuration exactly.

## Hyprland desktop

Hyprland is Copper's third desktop. It is optional and never the default. Unlike
XFCE and Niri, **nothing Hyprland-specific is baked into the image**: the
compositor, its runtime libraries, the session config and the `starthyprland`
launcher all arrive as a single ingot payload. Install it with:

```
sudo ingot install hyprland
```

Once installed, it coexists with XFCE and Niri without touching either; each is
started by its own launcher. The first-boot wizard stores the choice in the
first line of `/etc/copper-desktop` and copper-init prints the matching launcher
hint (including the install command when the payload is absent).

```
| Command | What it does |
|---|---|
| `starthyprland` | Seeds the Hyprland session config, prepares the runtime and starts the compositor on the tty. |
| `starthyprland --check` | Reports what is installed and exits, starting nothing. |
| `starthyprland --yes` / `--no` | Offer, or decline, installing the components the manifest lists. |
```

The session config is Copper-branded and is installed with the payload at
`/usr/share/copper/hyprland-skel`. On first launch — and on every launch for a
home that is missing files the skeleton provides — the launcher seeds it into
the user's home from that tree, so a home wiped by hand or made another way is
still repairable in place:

| Path | What it is |
|---|---|
| `~/.config/hypr/hyprland.lua` | the compositor configuration (Hyprland 0.57 loads Lua, not the old `.conf`) |
| `~/.config/hypr/hyprpaper.conf` | wallpaper selection |
| `~/.config/hypr/hypridle.conf` | idle management (lock, then blank) |
| `~/.config/hypr/wallpapers/` | Copper's branded wallpaper |
| `~/.config/waybar/{config.jsonc,style.css}` | the bar |

To change any of it, edit the file in the home; the launcher only fills in what
is absent and never overwrites an existing one.

### Keybindings

The shipped configuration binds, as sensible defaults:

| Key | Action |
|---|---|
| SUPER + RETURN | Open kitty, the terminal |
| SUPER + SPACE | Open fuzzel, the application launcher |
| SUPER + E | Open thunar, the file manager |
| SUPER + Q | Close the active window (killactive) |
| SUPER + V | Toggle floating |
| SUPER + F | Fullscreen |
| SUPER + 1–9 | Switch workspace |
| SUPER + SHIFT + 1–9 | Move window to workspace |
| SUPER + mouse | Move and resize the window under the pointer |
| SUPER + M | Quit the compositor (a safe, documented exit; not a panic) |

### Installing the Hyprland payload

```
sudo ingot install hyprland
```

The ingot payload pulls the full Hyprland session closure from the community
Hyprland PPA (`ppa:cppiber/hyprland`) — Ubuntu 24.04 carries no Hyprland package
of its own, it only appears in Ubuntu 25.10, and the Hypr* team maintains no
packages, so this archive is where the session comes from. The payload carries
the compositor, the session tools, the matching input libraries and Copper's
branded config together, so the install is a single transaction rather than a
set of half-independent packages. The payload is built and published in the
`copper-ingot-repo` project; the ISO itself only needs `ingot` to fetch it.

### Troubleshooting

| Symptom | Meaning |
|---|---|
| `starthyprland: no seatd socket at /run/seatd.sock` | PID 1 did not start seatd. The user must be in the `_seatd` group, and a reboot (or log out and back in) is what picks up the group membership. On the default image copper-init starts seatd, this line is not expected. |
| `starthyprland: no writable runtime directory` | `/run/user/<uid>` was not made. copper-init creates it; a manual boot without the default init may leave `/run` empty. |
| `starthyprland: forcing software rendering` | The DRM node has a card0 but no render node (a VM with no 3D). On real hardware that line never prints. |
| the compositor dies with a "cannot find shared library" error | A package in the image is older than the one the compositor was linked against. Re-run the build so the stage's shared-library precedence applies. |

### Known hardware limitations

- Only the console VT with a DRM framebuffer is supported. No display manager
  and no graphical login is configured, and none is started by this launcher:
  the compositor takes over the VT the launcher started on.
- Any machine with a render node works up to the compositor's own limits; any
  machine with a DRM node but no render node is forced to software rendering,
  which is substantially slower.
- Hyprland session integration with a graphical login/display manager is not
  implemented: Copper starts the compositor from a TTY, and the launcher is the
  only entry point.
- The screen locker (hyprlock), the wallpaper (hyprpaper), idle management
  (hypridle) and the notification daemon (dunst) are staged for the session.
  Their clients and the polkit agent run after the session has started and need
  a running session bus, which the launcher starts for them.

`startxfce` exits **20** if there's no X server in the image, **21** if XFCE is
missing, **22** if the server started but never opened a display, **23** if the
server exited while starting, and **24** on a usage error. That's a contract —
a script can branch on the exit code without parsing a message.

### Bootloader is pluggable

The ISO build does not hardcode a menu or a packaging tool. It reads the shared
entry list at `iso/boot/entries` (one `id|title|kernel command line` per line)
and asks a provider selected by `COPPER_BOOTLOADER=<name>` (default: `grub`) to
render that list and package the media. A provider lives in
`iso/bootloaders/<name>/provider.sh` and exports `bootloader_configure`,
`bootloader_make_iso` and an optional `bootloader_check`. See
`iso/bootloaders/README.md`. GRUB is the provider that ships, producing one
BIOS+UEFI image with no second bootloader binary.

Boot entries (rendered from `iso/boot/entries`):

| Entry | What you get |
|---|---|
| Copper Linux | Wizard if needed, then a shell (init comes from `/etc/copper-init`) |
| Copper Linux (systemd init) | Boots the systemd payload via `copper.init=systemd` |
| Copper Linux (verbose) | As above, with kernel messages |
| Copper Linux (debug) | Everything logged, panic-on-hang so a wedge reboots and shows its face |
| Copper Linux (initramfs shell) | A shell inside the initramfs, skipping the overlay — splits "kernel/initrd broken" from "our /init broke" in half |

---

Run it locally with:

```sh
sudo bash iso/build.sh
```

or check the Actions logs for a CI run. A finished build uploads `copper.iso`
(~300 MB) as an Actions artifact.

---

## Contact

Instagram: [@12hrformat](https://www.instagram.com/12hrformat/)
Email: [12hrformat](mailto:12hrformat@proton.me)
Discord: join copper linux's server: [discord](https://discord.gg/qCQdxNV9Va)
