# Copper boot splash (Plymouth)

The Copper boot animation: the owner's 150 frames of 1920×1080 PNG, played
full-quality over the boot, from just after the rootfs is up until just before
the login shell.

This directory is the source. The theme is built into the ISO by
`build_plymouth()` in `../build.sh`, started and stopped by `copper-init`
(PID 1), and handed off to the desktop before XFCE starts.

## What is here

    copper/copper.plymouth   theme descriptor (ModuleName=script)
    copper/copper.script     the frame player, Plymouth's script language
    copper/frames/1..150.png the owner's frames, untouched, 1:1

The frames are committed as 150 separate PNGs rather than an archive: the build
stage copies them straight into the image, and individual files never need a
zip step that can corrupt them. (An earlier `plymouth-frames.zip` was corrupt
and has been removed.)

## How it is built

`build_plymouth()` in `iso/build.sh` stages Ubuntu's **prebuilt** Plymouth
packages rather than building Plymouth from source. Copper's rootfs has no
systemd and no udev, and building the current Plymouth (`24.004.60`) without
udev does not produce a working splash — so the prebuilt binaries are taken and
the parts that would pull systemd in are simply never used.

The stage:

- downloads `plymouth`, `libplymouth5`, `libdrm2`, `libudev1`, `libevdev2`,
  `libxkbcommon0` and the host's PNG library with `apt-get download`, which
  resolves no dependencies (an install would drag in systemd and udev);
- copies only what a live image uses into the target rootfs: `/usr/sbin/plymouthd`,
  `/usr/bin/plymouth`, `libply*.so`, the `script` and `text` plugins, and the
  DRM and frame-buffer renderers. The systemd units, SysV init script and
  initramfs-tools hooks the package ships are deliberately left behind;
- installs the theme to `/usr/share/plymouth/themes/copper/`;
- writes `/etc/plymouth/plymouthd.conf` with `[Daemon] Theme=copper`;
- checks that the daemon and client actually run **inside the staged rootfs**
  (`chroot $TGT … --help`), so a missing library fails the build rather than
  producing a splash that silently never appears.

`libply-splash-core.so.5` links against `libudev.so.1`. The library is staged so
the loader is satisfied, but with `plymouth.ignore-udev` on the kernel command
line (see below) the udev path is never entered.

## How it runs

**Started and stopped by `copper-init` (PID 1).** There is no service manager in
this image, so the splash is the init's job:

- `splash_start()` runs right after `/proc`, `/sys`, `/dev` and `/run` are
  mounted, and before anything prints — with the console redirected, the
  animation covers the boot instead of scrolling underneath it.
- `splash_stop()` runs before the first-boot wizard and the login shell, so the
  console is back in text mode before anything asks the user a question.

Both are guarded rather than assumed:

- the kernel command line must ask for it (`splash`, and not `nosplash` or
  `plymouth.enable=0`), matched as exact tokens in `/proc/cmdline`;
- both `/usr/sbin/plymouthd` and `/usr/bin/plymouth` must be present — a splash
  that cannot be quit would sit on the console the login shell needs;
- the daemon must answer `plymouth --ping` before `--show-splash` is sent, so a
  broken Plymouth costs a short bounded pause, not a hang. If the
  console-attached start fails, the daemon is restarted once without
  `--attach-to-session` before the idea is dropped.

`plymouthd` runs with `--no-daemon`, so it stays a direct child of PID 1 and is
reaped by `waitpid` when it quits; no zombie is left behind.

**`iso/startxfce.sh` quits it defensively.** copper-init normally stops the
splash long before, but a session started by hand or through another path could
still find it up. A splash holding the console is what makes Xorg fail with
"Switching VT failed", so `startxfce.sh` pings Plymouth and quits it before it
touches the VT. `--check` and `--help` exit before this and never touch it.

## The kernel command line

`iso/boot/grub.cfg`'s main entry carries:

```
quiet splash plymouth.ignore-udev console=ttyS0,115200 console=tty0
```

- `splash` turns the animation on. Remove it (or add `nosplash`, or
  `plymouth.enable=0`) to boot with a plain text console.
- `plymouth.ignore-udev` is required. This image runs no udev, and without the
  switch `plymouthd` waits on a device enumeration that never happens and the
  screen stays black. With it, `plymouthd` drives DRM or the framebuffer
  directly.
- `plymouth.splash=<name>` selects a different theme by name, overriding
  `/etc/plymouth/plymouthd.conf`.

The verbose, debug and initramfs-shell entries deliberately have no `splash`.

## Quality

The frames are used exactly as delivered:

- full 1920×1080, no downscaling — the theme scales only to fit a screen that is
  not 16:9, preserving the aspect ratio and letter/pillarboxing rather than
  stretching;
- frames are decoded on demand, one per tick. Preloading all 150 would cost over
  a gigabyte resident (a decoded 1080p frame is about 8 MB);
- they play at 24 fps, which is the rate the theme requests, and the last frame
  is **held** rather than looped, so the animation does not visibly restart
  while the rest of the boot finishes.

## Testing

There is no automated test yet. On a machine with the staged rootfs:

```sh
/usr/bin/plymouthd --mode=boot --pid-file=/run/plymouth/pid --attach-to-session --no-daemon &
sleep 1
/usr/bin/plymouth --ping && /usr/bin/plymouth --show-splash
sleep 3
/usr/bin/plymouth quit
```

`plymouth.ignore-udev` must be on the running kernel's command line for the
renderer to come up. A QEMU guest has no GPU driver, so expect the frame-buffer
renderer there; the animation is the same either way.
