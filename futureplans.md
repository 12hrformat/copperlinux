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
[x] make a plymouth boot splash for copper (frames are in `iso/plymouth/plymouth-frames.zip`)
[] update: Now that the gui is working make it so gui automatically starts as soon as user enters
[] add persistence
[] add more packages in ingot repo
[] add a 'archinstall' type installation / debians installer / custom made (<-- preffered)

##### thats it for now i think but ill add things in the future
##### list below is made by ai i was busy

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
- [x] **test** — `tests/ingot-gate.sh` serves a fake Pages repo over localhost, installs with a sha256, and proves: right files land, dep installs first, hash mismatch refuses, /tmp stays clean, remove deletes, unknown/info/search/list behave, inspect shows the installed record, reinstall removes then reinstalls, update reinstalls when the page's sha256 moves. 29 assertions, all green in WSL as root and non-root; wired into `branch-gate.sh` and the workflow test list
- [ ] **release** — make the real Copper packages repo on GitHub pages, drop our packages with their sha256s in, publish the ISO, and boot it: `ingot install nmap`, run nmap, read it off a screendump

Also on the pile (not blockers, noted for later):
- sudo must actually work on the image first — `ingot install` needs root to write into `/`, and the live user isn't root. sudoers + wheel group are already staged
- busybox wget's TLS encrypts but doesn't verify certificates; fine for our own Pages repo, write it down before trusting a mirror
- "real url" for our own payloads will likely be GitHub Releases (Pages won't serve 100 MB files forever)
