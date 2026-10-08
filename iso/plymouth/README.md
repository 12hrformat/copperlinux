# plymouth frames

Raw animation frames for a future Copper boot splash, as provided by the owner.

- `plymouth-frames.zip` — 150 PNG frames (~28 MB unpacked, ~27 MB zipped).
  Extracted, they are `1.png` … `150.png`.

Status: **not wired in.** Plymouth can't be taken from Ubuntu's package as-is
because `plymouth` depends on `systemd`, and copper-init (not systemd) is
PID 1 here. When this becomes a real project, the work is:

1. a hand-rolled splash (plymouth, or a simpler framebuffer loop) started by
   copper-init after the rootfs is up;
2. a clean hand-off when `startxfce` brings up X, so the splash and the
   desktop never fight for the screen.

See `futureplans.md` for where this sits on the list.