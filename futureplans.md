# sigh so this are like my um todo list for the future of copper and deadlight linux:
[x] as of now i dont have a package manager so im building my own (ingot), hosted on github pages, not pacman
[x] make a gui for copper and deadlight linux
[x] make a package manager
[x] update the website and make it (actually) good
[] make documentation site
[] buy a custom domain
[] gain attention from linux users, and convince people to contribut
[] improve the tty
[] fastfetch logo
[] custom artwork (wallpapers, icons, etc)
[x] make a discord?
[] make some custom tools for deadlight linux
[x] make a plymouth boot splash for copper (frames and theme are in `iso/plymouth/copper/`)
[] update: Now that the gui is working make it so gui automatically starts as soon as user enters
[] add persistence (see BUGS.md)
[] add a way to install copper and deadlight linux to a hard drive (like archinstall or debian installer)
[] add more packages in ingot repo
[] add a 'archinstall' type installation / debians installer / custom made (<-- preffered)

##### thats it for now i think but ill add things in the future
##### list below is made by ai i was busy

---

## ranked next steps (written down 2026-10-14)

Ordered by what unblocks the most. This is the short list behind the
checkboxes above, with the reasoning kept so it doesn't have to be re-derived.

1. **A real installer** — the `install to a hard drive` / `archinstall` lines
   above (custom-made is the preferred one). Biggest hole: right now Copper is
   a live ISO plus the labelled-disk overlay trick for persistence. A real
   installer also retires bug 15 and bug 20's stopgap — real disk root, real
   space, no 50% tmpfs cap.
2. **Session auto-start** — the `gui automatically starts as soon as user
   enters` line. Today: boot → wizard → bare prompt → you type `startxfce`. A
   login/session step that asks once and remembers turns that into a desktop a
   normal person can reach.
3. **Grow the ingot repo** — `add more packages`. Five packages is a demo; the
   repo is the product.
4. **More terminal commands / improve the tty** — the `improve the tty` line.
5. **More desktops** — **Hyprland is in the tree**: the compositor, the ML4W
   config, `starthyprland`, and the wizard's Desktop question. Built and gated,
   not yet booted — see HANDOFF. **Awesome** is next. The Wayland/compositor
   stack was the real work, not one more package.
6. **Custom artwork** — wallpapers, icons. Cheap, high-visible identity.
7. **Docs site + custom domain** — the two unchecked lines at the top.

---

## ingot — the todo, in the order we do it

How it works (decided, don't re-decide): `ingot install nmap` fetches the
package's JSON page from GitHub Pages (`.../iso/copper/pkg/hacking/nmap`),
reads the REAL download url + sha256 out of the JSON, downloads the actual
payload from that url, verifies the hash, installs, and deletes the JSON from
`/tmp`. Pages holds only small JSON index files; big binaries live at the real
url, wherever that points.

- [x] **decide how it works** — json-on-pages → real url → sha256 → install → clean /tmp. The design is in `HANDOFF.md`
- [x] **rough sketch** — first `ingot` script is in `iso/rootfs-overlay/usr/bin/ingot` (install/remove/info/search), not wired in yet
- [x] **start working on it** — hammered out: dep recursion, index lookup, sha256 gate, /tmp cleanup, error paths. Two real bugs found and fixed by the gate test (index temp written to cwd instead of /tmp; recursion clobbering the outer install's globals, no `local` in POSIX sh). It is now a package manager, not a downloader
- [x] **add it into the iso** — ships as `usr/bin/ingot` + `/etc/ingot.conf` in the rootfs overlay; `build_rootfs` chmods it, `assert_shell_scripts_parse` audits it as a busybox tool, and `sh -n`/`busybox sh -n` both parse it clean
- [x] **test** — `tests/ingot-gate.sh` serves a fake Pages repo over localhost, installs with a sha256, and proves: right files land, dep installs first, hash mismatch refuses, /tmp stays clean, remove deletes, unknown/info/search/list behave, inspect shows the installed record, reinstall removes then reinstalls, update reinstalls when the page's sha256 moves; install/remove/reinstall/update on the real / refuse for non-root with a sudo hint. 31 assertions, all green in WSL as root and non-root; wired into `branch-gate.sh` and the workflow test list
- [ ] **release** — make the real Copper packages repo on GitHub pages, drop our packages with their sha256s in, publish the ISO, and boot it: `ingot install nmap`, run nmap, read it off a screendump

Also on the pile (not blockers, noted for later):
- sudo must actually work on the image first — `ingot install` needs root to write into `/`, and the live user isn't root. sudoers + wheel group are already staged
- busybox wget's TLS: the openssl-helper path verifies certs (openssl + ca-certificates now ship in the image); only the internal-TLS fallback skips verification, so don't trust a mirror if that note prints
- "real url" for our own payloads will likely be GitHub Releases (Pages won't serve 100 MB files forever)

---

## towards Copper Linux v1.2

the next tag. copper stops being "a desktop that works" and becomes the version
we'd hand someone, once these land. right now v1.2 is a target, not a date:

- [ ] **grow the ingot repo** — more packages than the current handful
      (firefox, mousepad, ristretto, xfce4-taskmanager, xarchiver). the repo is
      the product; five packages is a demo. this is the `add more packages in
      ingot repo` line above, with a number on it.
- [ ] **more terminal commands** — keep filling in the base so a fresh shell
      answers what people actually type. busybox + coreutils already cover a
      lot; this is about the gaps.
- [ ] **more than XFCE** — XFCE ships today, and **Hyprland** is built into the
      image behind the wizard's Desktop question (compositor + ML4W config +
      `starthyprland`; built and gated, the boot is still owed). v1.2 adds more
      desktops and window managers people can pick, **Awesome** next.
      (Hyprland was the wayland one — a compositor stack, not one more package.)
- [ ] **then tag it** — when those are in and booted on a real VM:
      **Copper Linux v1.2**.
