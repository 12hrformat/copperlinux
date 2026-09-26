# Copper OS — Mission Handoff

> This file is the checkpoint for whoever picks this up next. It records what
> was decided, what is DONE and verified, what files exist, and the exact next
> steps. Read this first, then `iso/README.md` for the build internals.

## The goal (in the builder's own words)

Copper is **not** a rebranded Debian/Arch. It's **our own Linux distro**:

- the real **Linux kernel** (torvalds/linux / kernel.org) — we use it, we don't
  rewrite it — with **our own `.config`**
- userland **built from source** in our own build (musl, busybox, coreutils…)
- **our own** shell (`copper-sh`), **our own** init (`copper-init`), **our own**
  first-boot wizard
- ships **all the standard Linux commands** (no stubs — real tools, real work)
- boots as an **ISO** in VMware / VirtualBox / QEMU
- first boot asks to personalize like a real distro / Windows OOBE
- speaks to **drivers** (bluetooth via BlueZ, wifi, firmware) and has a
  **working internet connection**

Reference material (NOT to be packaged as-is): torvalds/linux, Arch, Debian.

## What is DONE and verified ✅

### copper-sh shell — complete & verified
- ~500 lines C in `src/` (history preserved inside `copper-os`)
- 36 builtins + pipes `|`, redirects `<` `>` `>>`, quoting, `#` comments,
  history, external PATH programs (fork+exec)
- **Verified by real execution**: compiled with real GCC 12.2
  (`-std=c11 -O2 -Wall -Wextra` → 0 errors, 0 warnings), ran a 44-command
  battery under **AddressSanitizer** → exit 0, no leaks/overruns
- Bugs fixed during testing: argv heap off-by-one (ASan), lost output from
  `_exit()` skipping stdio flush, history storing tokenized (compact) lines,
  children reading stale buffered stdin, `ls -l file` error, `ls` one-per-line
  to non-TTY (so `ls | grep` filters like real ls)
- PR link (shell vs upstream, optional — re-openable anytime by pushing the
  branch back, history lives inside `copper-os`):
  `https://github.com/Copper-linux/copper/compare/main...12hrformat:copper-sh`
- Remote compile/run harness (no local compiler; WSL broken on this machine):
  `%LOCALAPPDATA%\Temp\opencode\ce-compile.mjs` and `ce-run.mjs`
  (Compiler Explorer API, compiler `cg122` = x86-64 gcc 12.2 C mode)

### The OS build — GREEN ✅ (finalized 2026-09-24, run #11)
Branch **`copper-os`** (off `copper-sh`). From-source distro build — every stage
passed on CI and `copper.iso` was uploaded as an artifact (~29 MiB,
`actions/runs/35937198186/artifacts`):
- `iso/build.sh` — stage-able pipeline (`kernel|base|tools|copper|rootfs|
  initramfs|iso|all`), each stage skips work already done (CI-friendly):
  pinned Linux kernel **6.12.10 LTS** (reproducible, no live version lookup)
  built from kernel.org with our .config subset (overlayfs, tmpfs, devtmpfs,
  virtio/e1000/vmxnet3, ATA/SATA, ext4, pty; `MODULES` off — drivers built in),
  musl 1.2.5, busybox 1.36.1 (static, adduser/chpasswd/mount/hostname
  applets), coreutils 9.5 + grep 3.11 + sed 4.9 + findutils 4.9.0 + diffutils
  3.10 + tar 1.35 + gzip 1.13 + xz 5.4.6 all **static against musl**, then
  copper's own binaries, initramfs, and a GRUB ISO (BIOS+UEFI)
- `iso/src-init/copper-init.c` — **our PID 1**: console stdio, mounts proc/
  sys/devtmpfs/run, applies /etc/hostname, runs the wizard once (marker file),
  spawns + respawns copper-sh on tty1. Symlinked as `/sbin/init`.
- `iso/firstboot/copper-firstboot.c` — OOBE wizard: name, username
  (validated), hostname (default copper), timezone (default UTC, symlink
  /etc/localtime), root + user passwords. Account via `busybox adduser -h
  /home/U -s /usr/bin/copper-sh -G users,audio,video,dialout,cdrom U`;
  passwords via `busybox chpasswd`; writes `/etc/copper-firstboot.done`.
- `iso/rootfs-overlay/etc/…` — hostname, hosts, profile (full PATH + PS1),
  group (root/users/dialout/cdrom/audio/video), passwd (root+nobody), shadow
  (root locked until wizard), fstab (tmpfs /tmp), skel/.copperrc
- `iso/live/init` — initramfs script: mounts proc/sys/dev, finds the Copper
  medium (iso9660), sets up a **writable overlay** on top of the read-only ISO
  (read-only lowerdir + tmpfs upper — this is also how persistence will work
  later), switch_root to `/sbin/init`
- `iso/boot/grub.cfg` — GRUB menu, both "normal" and "verbose" entries
- `.github/workflows/build-iso.yml` — rebuilds with from-source deps only,
  **per-stage CI steps** (so the anonymous jobs API shows exactly which stage
  failed) + `actions/cache` on `iso/work/` so iterations are fast
- `src/builtins.c` — musl compat fixes (removed `nftw`, real recursive
  `rmtree`; `_GNU_SOURCE` + `_XOPEN_SOURCE 700`)
- `.gitattributes` — force LF eol for .sh/.c/.h/.yml/.service

## What's verified so far

- copper-sh: **verified** (real GCC, ASan battery, see above).
- copper-init.c / copper-firstboot.c: **compiled and installed in the green
  CI build** (`build_copper` stage, static musl, symlinked as `/sbin/init`).
  `copper-init.c` also compiles clean under GCC 12.2 with
  `-std=c11 -O2 -Wall -Wextra -Wpedantic -Wshadow -Wwrite-strings`.
- The DHCP lease script: **executed and tested** (see "What has actually been
  executed" below).
- The **whole pipeline builds green**: kernel 6.12.10, musl 1.2.5, busybox
  1.36.1 (static), all eight GNU tools (static musl), Copper's three
  binaries, rootfs, initramfs, and the GRUB ISO — artifact `copper.iso`
  (~29 MiB, sha256 `cc00fe05…86ace2`) from run #11.
- `.gitattributes` now forces LF for everything that lands in the ISO. This
  is not cosmetic: `core.fileMode` is off on Windows, and a CRLF in
  `/etc/profile` puts a CR at the end of `$PATH` so every command comes up
  "not found", while a CRLF in `passwd`/`hosts` breaks the lookups and a
  CRLF in the initramfs `init` breaks the boot. CI checks out on Linux so its
  ISOs were never affected, but a tree built on Windows was.

## Config facts worth not rediscovering

Checked against real sources, not assumed. Each of these cost a wrong turn
once already.

- **busybox's `make defconfig` is not a stock config.** busybox patches
  kconfig with `const char conf_defname[] = "/dev/null"`
  (`scripts/kconfig/confdata.c:25`), so "defconfig" means *the Kconfig
  defaults*. There is no `configs/defconfig` in 1.36.1. Per-applet symbols
  live in `//config:config SYMBOL` comments inside the `.c` files and in the
  directory `Config.src` files. Don't go looking for a defconfig to patch.
- `CONFIG_STATIC` is `default n` in busybox's root `Config.in`, so it has to
  be set explicitly. It also has to be set **after** `make defconfig` —
  reassigning a symbol that defconfig already answered is silently dropped by
  conf (first assignment wins), which is exactly what `set_bb_config` exists
  to work around.
- **6.12 has no `CONFIG_ETHERNET`.** The symbol is gone; the driver menu is
  unconditional under `NET`/`NETDEVICES`. Asserting it fails the build.
- In 6.12, `config INET` moved to `net/Kconfig`, and `net/ipv4/Makefile`
  builds `tcp.o`/`udp.o` in `obj-y` unconditionally under `INET`. So
  `CONFIG_INET=y` (which `x86_64_defconfig` does set) is sufficient for
  IPv4; there is no separate TCP/UDP symbol to chase.
- `BLK_DEV_NVME` lives in `drivers/nvme/host/Kconfig` in 6.12, not
  `drivers/block/`. It's `tristate` with **no default**, so the explicit
  `--enable` in `build.sh` is what turns it on.
- vmxnet3's Kconfig path isn't `drivers/net/ethernet/vmware/Kconfig` in
  6.12 (404), and the symbol name couldn't be pinned down. `build.sh` passes
  **both** `--enable VMXNET3` and `--enable VMWARE_VMXNET3`; kconfig drops
  whichever doesn't exist, which costs nothing. Deliberately **not asserted**.
- `CONFIG_OVERLAY_FS` is `tristate` with no default either — the entire
  live-root design rests on `build.sh` passing `--enable OVERLAY_FS`.
- Useful default: with `MODULES=n`, every `tristate` symbol resolves to `y`
  or `n`, never `m`. So a `--enable`d tristate really is `=y` in the final
  `.config`, which is what makes the assertions in `build.sh` safe.
- The full assertion list was cross-checked against the real
  `x86_64_defconfig`: every symbol is either explicitly `=y` there or
  explicitly `--enable`d by `build.sh`. Nothing depends on an unverified
  Kconfig default.
- `udhcpc -b` does not exit: after its retries it forks into the background
  and keeps trying forever. So init can fire it and move on — no `-n`.
- udhcpc does **not** put `PATH` in the lease script's environment, so init
  has to set it before the exec.
- busybox installs udhcpc at `/sbin/udhcpc`, `ip`/`ifconfig`/`route` in
  `/sbin`, `ping` in `/bin`, `wget`/`nslookup` in `/usr/bin`, and
  `switch_root` in `/sbin`. It does **not** install a lease script, which is
  why we ship our own.
- `wget`'s `https://` is busybox's internal TLS (psst). It encrypts but does
  **not** verify certificates. Fine for a tarball, not for a login.
- **In busybox 1.36.1 udhcpc's source is `networking/udhcp/dhcpc.c`**, not
  `networking/udhcp.c` — the client was split out into a directory, so
  grepping for the old path finds nothing and looks like the applet is
  missing. `ip` is likewise split: the address parsing lives in
  `networking/libiproute/`, not in `networking/ip.c`.
- The environment udhcpc exports comes from the DHCP **option** names
  (`common.c:dhcp_optflags`). The consequence that matters: **`$subnet` is the
  netmask as a dotted quad** (option 1 is `OPTION_IP`), and `$mask` is the
  same mask as a decimal uint32. Neither is a prefix length.
- busybox `ip` *does* accept a dotted mask after the slash, though:
  `get_prefix_1` (`networking/libiproute/utils.c`) tries `bb_strtou` on the
  text after `/` and falls back to parsing it as a netmask when the number
  comes out wider than the address. That's why upstream's own
  `examples/udhcp/simple.script` can write `ip addr add $ip/$subnet`. We
  convert to a prefix length ourselves anyway, so the script doesn't depend
  on that fallback staying where it is.

## What has actually been executed (and what hasn't)

Worth being precise about, because a lot of this tree has never run.

**Has run:**
- `copper-sh` — the 44-command ASan battery. See above.
- The whole CI build, green end to end.
- `mask_to_prefix` in the lease script — 58 assertions (all 33 valid netmasks
  generated rather than typed, plus non-contiguous and malformed input).
- The lease script end to end against a fake `ip`, 25 assertions: a plain
  /24 lease, renew replacing the default route (del before add), a missing
  netmask falling back to /24, several routers, a lease with no nameserver
  keeping the fallback resolver, deconfig, leasefail, an unknown state, and
  an empty `$1` being refused.
- `sh -n` on all three shipped shell scripts, and `copper-init.c` under
  GCC 12.2 with `-Wall -Wextra -Wpedantic -Wshadow -Wwrite-strings`.

**Has never run:** everything on the boot path. `grub.cfg`, the initramfs
`/init`, the overlay mount, `copper-init` itself, the wizard, and DHCP against
a real server. No VM on this machine can run them. That is checklist item 1.

Writing the tests above found two real bugs in the lease script: a
non-contiguous mask like `255.0.255.0` was accepted as a valid netmask, and a
truncated `255.255.255` was read as /32. Both are fixed. Worth remembering
that the file had a plausible-looking comment claiming `$subnet` was a prefix
length, which was simply false — reading the busybox source beat reasoning
about it.

## Tooling notes for this machine

- **Git for Windows is installed**, so a real POSIX shell is available at
  `C:\Program Files\Git\bin\bash.exe`. That means `sh -n` on the shipped
  scripts, and — more usefully — shell *logic* can be unit tested on this
  machine with a fake `ip` on `PATH`, no VM and no compiler needed. The lease
  script got both treatments because of it. Don't assume there's no way to
  test shell here.
- No local C toolchain — no gcc/clang/tcc, no WSL, no container runtime. C
  verification goes through Compiler Explorer's API (`cg122` = x86-64
  gcc 12.2, C mode), driven by a script under `%LOCALAPPDATA%\Temp\opencode`.
- CE is **glibc**, not musl, so it cannot validate musl-specific code —
  `src/builtins.c` uses musl's `S_ISVTX` and CE reports it as an error. The
  musl build in CI is the real oracle for those files.
- CE's multi-file compile is broken server-side right now, and writing to
  stderr from node aborts on this box (`UV_HANDLE_CLOSING`) — capture stdout
  only.
- The GitHub **jobs/runs** API is readable unauthenticated, but downloading
  an artifact returns **401**, and there is no `gh` CLI here. So the built
  ISO cannot be fetched or inspected from this machine; only its existence
  and its stage-by-stage logs can.
- Neither VMware, VirtualBox nor QEMU is installed, so no boot test is
  possible from here. That is checklist item 1 and it needs a person.
- **`core.autocrlf` was `true` on this box.** That, not git, is what filled
  the working tree with CRLF, and it survived a `git checkout-index -f -a`
  because git hashes the two the same. It is set to `false` now, so the local
  tree matches the index. Leave it that way; `.gitattributes` asks for LF and
  the config was quietly overriding it.
- **Pushing needs a credential this machine does not have.** Git Credential
  Manager offers only `farcrowx`, and GitHub answers
  `Permission to 12hrformat/copper.git denied to farcrowx` — 403. There is no
  `gh` CLI and no SSH key either, so the only route is a token the owner
  supplies, or pushing from an account that can already write. The five
  networking commits were sitting on disk waiting on this.

## What is MISSING (next person's checklist) ⚠️

1. **Boot the ISO** in VMware (new VM, Ubuntu 64-bit guest, attach
   `copper.iso`, power on) and walk the first-boot wizard. The kernel+init
   boot path and overlay rootfs are the big untested surface; initramfs
   `/init` and grub.cfg were written blind, so expect first-wave fixes
   (kernel cmdline, overlay mount points, tty).
2. ~~**Ship the byline**~~ — **done**. `7a3e877 add copper byline across the
   tree` is pushed; the `handcrafted by 12hrformat` header is on every
   authored file in the working branch.
3. **PR**: PR #2 (`copper-os` → `main`) is open on the fork; title +
   description drafted, deliverable is `PR.md`. Restore it from
   `77f2e6d^:PR.md` (it was deleted in `77f2e6d`) and add the networking
   work before sending it.
4. **Get Copper online — ethernet first, then wifi.** Kernel networking is
   already covered (INET/TCP/UDP, PACKET, UNIX, e1000/e1000e, vmxnet3,
   virtio_net all built in, `MODULES=off`) and the busybox we ship compiled
   with `ip`, `ifconfig`, `udhcpc`, `ping`, `wget` (internal TLS), `nslookup`,
   `nc`, `route`. Concretely:
   - **Step 1 — Ethernet + DHCP: WRITTEN, waiting on a boot test.** Four
     pieces, all in the tree:
     1. `iso/rootfs-overlay/usr/share/udhcpc/default.script` — **our own**
        lease script, not busybox's `simple.script`. Handles deconfig /
        `bound|renew` / leasefail, converts the netmask into a prefix length
        (rejecting anything that isn't a proper run of ones, /24 as the
        fallback), honours `$broadcast`, replaces the default route on renew,
        and writes `/etc/resolv.conf` from `$dns`/`$domain`. A lease with no
        nameserver leaves the shipped fallback resolver alone rather than
        replacing it with nothing. Tested — see above.
     2. `bring_up_network()` in `iso/src-init/copper-init.c` — finds the
        first non-`lo` interface in `/sys/class/net` (polls 20×100ms for a
        cold NIC), raises it with a `SIOCSIFFLAGS` ioctl, then `fork`s and
        `execle`s `/sbin/udhcpc -i <iface> -b -p /run/udhcpc.<iface>.pid`.
        No subprocess, so nothing depends on where busybox's applet links
        landed. The child sets `PATH` itself, because udhcpc does not set
        one for the lease script. It runs **before** the wizard, so DHCP
        negotiates while the user is still typing their name.
     3. `iso/rootfs-overlay/etc/resolv.conf` — fallback `1.1.1.1` /
        `9.9.9.9`, so DNS exists before (or without) a lease.
     4. `require_kernel_config` / `require_bb_config` in `iso/build.sh`
        assert the options this leans on survived `olddefconfig`, so a
        kernel that can't reach the network fails the **build** rather than
        booting mute.
     - **All that is left is item 1 above**: boot it and run `ip a`,
       `ping 1.1.1.1`, `wget https://example.com`. Nothing on this path has
       ever run in front of a VM.
   - **Step 2 — static-config escape hatch:** later, a `/etc/network`-style
     file (interface/ip/gw/dns) that copper-init reads instead of DHCP.
   - **Step 3 — WiFi (bigger lift):** because `MODULES=off`, the wireless
     driver and `CONFIG_CFG80211` must be built into the kernel `.config`
     directly. Build **wpa_supplicant** from source (static musl) for
     association, keep busybox udhcpc for the IP, and drop the card's
     firmware blobs (linux-firmware subset) into the rootfs. Full
     NetworkManager (glib + dbus from source) is the heavy end-state for
     wifi roaming and a GUI later.
5. **Phase 3 after Copper has internet**: Bluetooth (BlueZ from source + kernel
   `CONFIG_BT=y`), remaining linux-firmware blobs, then a GUI/desktop.
6. **Persistence** = mount a writable disk as the overlay upper (currently
   tmpfs = session-only), i.e. real "install or always-save" mode.

## Repo map

- Local repo: the current checkout (re-cloned from the fork, because the old
  `copper-terminal` path from the previous machine does not exist here).
- `origin` = `https://github.com/12hrformat/copper.git` (the fork; push works).
  Upstream `Copper-linux/copper` gives a 403 on push, so PRs go via the fork.
- Branches pushed: **`copper-os` only** (tip `77f2e6d`). The old branches
  (`main`, `copper-sh`, `patch-1`) were deleted; the shell history survives
  inside `copper-os`.
- No local compiler; verify C via the Compiler Explorer harness above.
- The CI cache key hashes `iso/build.sh`, `iso/live/init`, `iso/boot/grub.cfg`,
  `iso/rootfs-overlay/**`, `iso/src-init/**`, `iso/firstboot/**` and `src/**`.
  A change to **any** of those invalidates the whole `iso/work/` cache, so
  each push is a full rebuild - batch changes into one push instead of
  dribbling them out.

## Rules to keep (user asked)

- Human-sounding commit messages & code — nothing that reads like AI slop.
- Keep Copper's identity; Arch/Debian source is reference only.
- Verification > vibes: compile clean, run the battery under ASan before
  claiming a command works. Never ship a fake/placeholder command.
