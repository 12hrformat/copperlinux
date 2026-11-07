# Copper boot splash (Plymouth)

The Copper boot animation: the owner's 150 frames of 1920×1080 PNG, played
full-quality over the boot, from just after the rootfs is up until just before
the login shell.

This directory is the source. The theme is built into the ISO by
`build_plymouth()` in `../build.sh`, started and stopped by the
`copper-plymouth` units in `../systemd/`, and handed off to the first-boot
wizard and then the desktop.

## What is here

    copper/copper.plymouth   theme descriptor (ModuleName=script)
    copper/copper.script     the frame player, Plymouth's script language
    copper/frames/1..150.png the owner's frames, untouched, 1:1

The frames are committed as 150 separate PNGs rather than an archive: the build
stage copies them straight into the image, and individual files never need a
zip step that can corrupt them. (An earlier `plymouth-frames.zip` was corrupt
and has been removed.)

## How it is built

`build_plymouth()` in `iso/build.sh` stages **prebuilt** Plymouth packages
rather than building Plymouth from source. Copper's rootfs has no
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

Copper boots systemd as PID 1 now, so the splash has units rather than an init
that owns it:

- `copper-plymouth.service` starts `plymouthd` during sysinit, before any
  status line can scroll over the animation. Its `ExecStartPost` is
  `copper-splash-show`, which asks for the first frame and stamps
  `/run/plymouth/started` with `/proc/uptime` in the same breath. The unit is
  conditional on the kernel's `splash` token, so the verbose and debug entries
  stay text.
- `copper-plymouth-quit.service` is the hand-back. Its `ExecStart` is
  `copper-splash-quit`, which reads `frame_count` and `Plymouth.SetRefreshRate`
  out of `copper.script`, waits out the remainder of `ceil(frames / rate)`
  against that stamp, then runs `plymouth --quit` and `plymouth --wait`. The
  wizard and the console are ordered on the far side of it, which is why the
  animation finishes before the registration table appears instead of being
  cut off around frame 20.

The helpers are guarded rather than optimistic:

- each one exits 0 when there is nothing to do, so a serial-only machine or a
  unit that was skipped is not a failed boot;
- `copper-splash-quit` asks `plymouth --ping` first and returns immediately if
  no daemon answers;
- the length comes from the theme itself, so re-exporting the animation with a
  different frame count cannot silently outrun the wait.

## The kernel command line

`iso/boot/grub.cfg`'s main entry carries:

```
splash plymouth.ignore-udev plymouth.ignore-serial-consoles quiet loglevel=3 systemd.show_status=1 console=ttyS0,115200 console=tty0
```

- `splash` turns the animation on. Remove it (or add `nosplash`, or
  `plymouth.enable=0`) to boot with a plain text console. The splash unit
  checks for the token, so the verbose and debug entries do not start it.
- `quiet loglevel=3` keeps kernel chatter off the screen. The boot report is
  the systemd `[ OK ]` block and nothing else.
- `systemd.show_status=1` is what makes that block appear. systemd's default
  `auto` suppresses status lines while a splash is up, so without it the
  console would be blank before the wizard.
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

`tests/plymouth-gate.sh` checks the parts that can be held still without a
boot: the plymouthd argv, the kernel switches, the two helpers, and that the
quit helper derives its wait from the theme instead of a copied number.

To watch the animation by hand, on a machine with the staged rootfs:

```sh
/usr/bin/plymouthd --mode=boot --pid-file=/run/plymouth/pid --no-daemon &
sleep 1
/usr/bin/copper-splash-show
sleep 8
/usr/bin/copper-splash-quit
```

`plymouth.ignore-udev` must be on the running kernel's command line for the
renderer to come up. A QEMU guest has no GPU driver, so expect the frame-buffer
renderer there; the animation is the same either way.
