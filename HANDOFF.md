# Copper OS — Handoff

> Read this first, then `iso/README.md` for the build internals.
> Written by whoever had the machine last. Everything in it is either verified
> or explicitly marked as unverified — there is no third category.

## What Copper is

Our own Linux distro, built from source. Not a rebrand of Debian or Arch, and
not a respin of them: the kernel is upstream but the `.config` is ours, the
userland is compiled in our own pipeline against musl, and the pieces that
make it *Copper* are written by hand.

- real **Linux kernel** (6.12.10 LTS, from kernel.org) with **our `.config`**
- userland **built from source**: musl, busybox, coreutils and friends
- **our own** shell (`copper-sh`), **our own** PID 1 (`copper-init`), **our own**
  first-boot wizard
- **all the standard Linux commands**, real tools — no stubs, no placeholders
- boots as an **ISO** in VMware / VirtualBox / QEMU
- first boot personalizes like a real distro OOBE
- speaks to **drivers** (wifi, bluetooth, firmware) and reaches the **internet**

Upstream projects are reference material. Nothing gets packaged as-is.

---

# Read this part: the branch, and why it isn't on upstream

**Both previous PRs are merged.** Upstream `main` is now `7b4e5fd`
("Merge pull request #3 from farcrowx/copper-os"), so everything through
`d639326` is on `Copper-linux/copper`.

The new work is on a branch called **`patch-1`**, and it is **on the fork, not
on upstream**:

```
origin    https://github.com/12hrformat/copper.git      (read-only here)
fork      https://github.com/farcrowx/copper.git        (push target)
upstream  https://github.com/Copper-linux/copper.git    (read-only here)
```

`patch-1` lives on **`farcrowx/copper`** and is **9 commits ahead of upstream
`main`**, touching 6 files, +345/-48:

```
9750dac say it in both places: the screen and the serial log
2601222 init: ask sysfs what an interface is before handing it to DHCP
971b6e5 boot: put tty0 last so the screen is /dev/console again
0cf3fd9 iso: make the build fail on the things it used to ship silently
b7facc7 init: test for copper-init, not for the symlink pointing at it
a225b17 boot: send the console somewhere we can actually read it
307d6b9 iso: pin the script path before the cd, and fail safe in the stamps
d9b1ce1 iso: stamp stage outputs so a warm cache can't ship a stale one
3ae61c1 iso: create the overlay dirs after the tmpfs goes over them
```

**It needs a PR to land.** The only credential on this machine belongs to
`farcrowx`, and GitHub answers `push=False` for that account on
`Copper-linux/copper` (`admin=false, pull=true`). Somebody with write access
has to open `farcrowx:patch-1 → Copper-linux/copper:main`, or take the branch
and push it up directly.

To get it:

```sh
git fetch upstream fork
git log --oneline upstream/main..fork/patch-1     # should show the 9 above
git checkout -b patch-1 fork/patch-1
```

---

# Where things actually stand

**The box boots and gets onto the network.** This is not a projection. A
VMware guest, 2 GB, NAT, booting the ISO, produces this and nothing after it
is broken:

```
copper: initramfs up, medium is /dev/sr0
copper: handing over to copper-init
copper: eth0 is up, asking DHCP for an address
copper-net: dropping the address on eth0
copper-net: eth0 leased 192.168.179.129/24
copper-net: default route via 192.168.179.2
copper-net: nameserver 192.168.179.2
```

That is the whole boot path — kernel, initramfs, overlay, `switch_root`, our
PID 1, DHCP, netmask conversion, default route, resolver — verified on
hardware, from an artifact that was taken apart and read before it was
trusted.

**Last known-good ISO:** `copper4.iso`, sha256
`2355a64008c2aa48554510bc14e790e349191e38c031bab1dffa99cba09b338d`, 57.2 MB,
from CI run `36242735281` (sha `9750dac`).

## What has never run

Two things, and they are the whole remaining risk:

1. **The first-boot wizard.** `iso/firstboot/copper-firstboot.c` has never been
   executed on any machine. It compiles clean, and that is all anyone can say.
   The last thing on the screen during the successful boot was
   `copper-net: nameserver 192.168.179.2`; nobody has confirmed whether a
   wizard appeared after it or whether PID 1 dropped straight to a shell. This
   is the first thing to check, and it is central to the "personalizes like a
   real distro OOBE" requirement.
2. **Real internet traffic.** We have an address, a prefix, a default route
   and a nameserver. Nothing has yet proved that a name resolves or that a TCP
   connection completes. `ping 1.1.1.1` and a `wget` are still unrun.

---

# What was messed up, and what fixed it

Nine commits, and most of them exist because something was quietly wrong in a
way that looked like something else. Worth reading in order — several of these
cost a boot cycle each, and the reasons generalise.

## 1. The overlay directories were created before the tmpfs went over them

`iso/live/init` did `mkdir -p /mnt/upper/upper` and then
`mount -t tmpfs … /mnt/upper`. Mounting hides what was underneath, so the
overlay came up with no `upperdir` and died:

```
overlays: failed to resolve '/mnt/upper/upper': -2
```

Fix: mount the tmpfs **first**, then `mkdir` inside it. The whole staging
order is that one trick. `3ae61c1`.

## 2. CI shipped an ISO built from the *previous* commit

The nastiest one, because **the run was fully green**. `restore-keys:
copper-work-` deliberately restores the previous tree — that is what saves a
7-minute kernel build — but the stage guards were existence-only
(`[ -s "$TGT/boot/initrd.img" ] && skip`). Key changed, old tree restored, file
present, stage skipped. An ISO went out with an initrd packed from the old
`init`.

Fix: `stamped_skip` / `stamp_set` / `tree_hash` in `build.sh`. Every stage
stamps its output with a hash of its own inputs. `d9b1ce1`.

**Do not "fix" this by deleting `restore-keys`.** The fallback is not the bug;
it is what makes a warm cache survive an unrelated change. The stamps are what
make it sound.

## 3. `$0` is not a path you can hash after a `cd`

`SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")` is pinned before the
script `cd`s, because CI runs `sudo bash iso/build.sh kernel` — so `$0` is the
*relative* `iso/build.sh`, and line 20 `cd`s out from under it. `cat "$0"` then
had nothing to open, and under `set -euo pipefail` that killed the script 14
lines after a successful 7-minute kernel build. `307d6b9`.

## 4. My own rescue check was a false negative

Added in fix #1, to turn "switch_root on a root with no init" into something
readable. It read:

```sh
[ -x /mnt/merged/sbin/init ] || rescue "no /sbin/init in the merged root"
```

`/sbin/init` is a symlink to the **absolute** path `/usr/bin/copper-init`.
Before `switch_root` does its chroot, an absolute symlink resolves against the
initramfs root — where there is no `/usr/bin` at all. So the test followed the
link into the initramfs, found nothing, and reported a perfectly good ISO as
broken. It cost a boot cycle to find.

Fix: test the binary, not the link. `switch_root` still gets handed
`/sbin/init`, which resolves correctly after the chroot. `b7facc7`.

## 5. …and the build gate I added to catch #4 made the same mistake

`[ -e "$TGT/sbin/init" ]` — which also *follows* the link, this time to the
**build host's** `/usr/bin/copper-init`, which does not exist. Dangling, so
"missing", so the first CI run of the new gate failed on a staged tree that was
fine. It uses `readlink` now. `0cf3fd9`.

Worth internalising: **`-e` and `-x` follow symlinks. Any check on a
Copper-created link must use `readlink`, or it is testing the build machine.**

## 6. Stale files survived in two staging trees

`build_initramfs` and `build_rootfs` both copy into a `$TGT` that may have come
straight out of the cache, and `cp` only ever adds. A file or directory deleted
from the source came back in the next ISO — and because the ISO stage stamps
the whole tree, it did that while *looking* like a clean rebuild. `rm -rf` the
initramfs staging dir; keep a manifest of what the overlay contained last time
and drop whatever it no longer claims. `0cf3fd9`.

**The manifest has to be built from `iso/rootfs-overlay/`, not from `$TGT`.**
My first version diffed `$TGT` against itself, which is the cached directory
that still holds the stale file, so it could never fire. A test now pins that:
it runs the old logic against the scenario and asserts the file survives, so
the test cannot pass on the broken version.

## 7. The serial console addition made the screen lie

`console=tty0 console=ttyS0,115200` looked obviously right. It is not. **The
last `console=` on the command line is what `/dev/console` points at**, and that
is the only place userspace output goes. On a VM with no serial port, `ttyS0`
never registers, `/dev/console` has no working target, and the screen sits on
GRUB's "Booting up kernel" while the system boots perfectly out of sight. It
looks exactly like a hang. Cost hours. `971b6e5`.

Correct order is `console=ttyS0,115200 console=tty0` — register both, screen
last.

## 8. …which then made the serial log useless

Fixing #7 correctly left the file getting the kernel's half of the boot and
none of ours, and under `quiet` — the entry anyone actually boots — **0 bytes**.
Measured, not assumed.

So `say()` in all three places (initramfs, PID 1, lease script) now writes to
stdout *and* to `/dev/ttyS0`, guarded by `[ -c /dev/ttyS0 ]` so a machine with
no serial port does nothing. `9750dac`.

Practical upshot: **you never have to photograph or transcribe a screen
again.** Point the VM's serial port at a file and paste that.

## 9. DHCP was broadcasting into a tunnel

This is the one that mattered most, and it was hiding in plain sight:

```
copper-net: no lease on sit0 yet, still asking
udhcpc: no lease, forking to background
```

`sit0` is not a network card. It is the IPv6-in-IPv4 tunnel the `sit` module
creates at boot, and with `MODULES=n` every driver is built in, so it exists
before the real NIC finishes probing. `first_nonloop_iface()` took the first
name in `/sys/class/net` that wasn't `lo`, so it got `sit0`, brought it up with
`SIOCSIFFLAGS`, and broadcast DHCP discovers into an interface that cannot
carry them. `eth0` sat there untouched and never even reported link up,
because nothing had asked it to.

Fix: read `/sys/class/net/<if>/type` (the `ARPHRD_*` value) and only accept
`ARPHRD_ETHER`, or `ARPHRD_IEEE80211_RADIOTAP` when there is no wired one.
That skips `sit0`, `gre0`, `ip6tnl0`, `ipip0`, `teql0`, `tun0` and `ifb0`
without naming any of them, and it no longer depends on directory order.
`2601222`.

The old code carried a comment predicting this exact failure. It was right, and
it was still worth doing properly.

---

# Goals

Ordered by what unblocks the most.

## G1 — Confirm the first-boot wizard ⚠️ blocks the identity claim

**Done looks like:** the screen after `copper-net: nameserver …` shows the
wizard asking for a name, and a `copper-sh` prompt afterwards.

Boot `copper4.iso`, screenshot the window. That is the whole task. Nothing
downstream — persistence especially — is testable until it is answered, and it
has never been executed, so expect it to be the next thing to break.

## G2 — Prove the internet, not just DHCP

**Done looks like:**

```sh
ping -c 1 1.1.1.1          # raw IP, no DNS
nslookup example.com       # resolver works
wget -O - http://example.com   # HTTP end to end
```

We have a lease, a route and a resolver. None of the three above has run. The
cheap version is to add a reachability probe to the lease script's `bound`
handler so the next log answers it without anyone typing commands; the honest
version is to run the three commands at a `copper-sh` prompt and paste the
output.

## G3 — Static-IP escape hatch

Some networks don't hand out leases, and a DHCP-only box is a box that can't
be used on one.

**Done looks like:** a `/etc/network`-style file (interface, address, netmask
or prefix, gateway, nameservers) that `copper-init` reads and applies instead
of starting `udhcpc`, when the file is present and non-empty. Missing file
means DHCP, as it does today.

## G4 — WiFi

Bigger than ethernet, because `MODULES=off` means the wireless driver and
`CONFIG_CFG80211` have to be compiled into the kernel `.config` directly.

**Done looks like:** the box associates with an access point and gets a lease
without manual fiddling.

Roughly: enable `CFG80211` plus the driver in `build.sh`; build
**wpa_supplicant** from source (static musl) for association; keep busybox
`udhcpc` for the IP afterwards, since it now demonstrably works; and drop the
card's firmware blobs (a `linux-firmware` subset) into the rootfs.
NetworkManager — glib and dbus from source — is the heavy end state for
roaming and a GUI, and is not required to get onto a network.

The interface-selection bug that broke wired DHCP is already handled for wifi:
`first_nonloop_iface()` now asks sysfs for the `ARPHRD_*` type and prefers
`ARPHRD_ETHER` over `ARPHRD_IEEE80211_RADIOTAP`, so a wireless NIC no longer
turns it into a coin flip.

## G5 — Bluetooth

**Done looks like:** `bluetoothctl` or equivalent sees a paired device.

BlueZ built from source, kernel `CONFIG_BT=y` with the relevant protocol
drivers. BlueZ wants a D-Bus daemon; that's the part to budget time for.

## G6 — Persistence

**Done looks like:** a reboot keeps your files.

The overlay's upper layer is currently tmpfs, so the session is throwaway by
design. Move the upper onto a real disk partition the user picks on the
wizard's last page — same overlay mechanism, different `upperdir`.
`iso/live/init` already lays the overlay down, so this is a matter of mounting
a disk where the tmpfs goes and telling the wizard to offer it.

## G7 — Land `patch-1`

See the top of this document. It needs a PR from an account with write access
to `Copper-linux/copper`, or someone with that access pushing it.

## G8 — A desktop

The long end. Worth saying plainly: it is far away, and nothing before it is
blocked on it.

---

# What is verified, and what is not

Being precise here matters, because it is easy to mistake "it compiles" for
"it works".

## Has actually been executed

- **The boot path, end to end, on a real machine.** Kernel → initramfs →
  overlay → `switch_root` → `copper-init`. The log at the top of this document
  is the evidence.
- **DHCP against a real server.** A lease, `/24` derived from a
  `255.255.255.0` netmask, a default route, and a resolver. `mask_to_prefix`
  had only ever been unit-tested before this; it is now correct in production.
- **`copper-sh`** — compiled with real GCC 12.2
  (`-std=c11 -O2 -Wall -Wextra`, zero warnings) and run through a 44-command
  battery under **AddressSanitizer**: exit 0, no leaks, no overruns. Bugs that
  found and fixed: an argv heap off-by-one, output lost because `_exit()`
  skipped the stdio flush, history storing tokenized instead of the line you
  typed, children reading stale buffered stdin, `ls -l` on a single file, and
  `ls` going one-per-line on a non-TTY so `ls | grep` filters like real `ls`.
- **`tests/smoke.sh`** — 19 assertions over the shell's core behaviours. Run it
  before you touch the shell.
- **The DHCP lease script** — 58 assertions on `mask_to_prefix` (all 33 valid
  netmasks, generated rather than typed, plus non-contiguous and malformed
  input) and 25 more driving the whole script against a stub `ip`.
- **The stage-stamp logic** — 11 assertions including the exact regression
  (output present *and* input moved on must rebuild), and a separate harness
  proving the helpers survive `set -euo pipefail`.
- **The build gates** — overlay-manifest pruning against a simulated warm
  cache, the CRLF gate, and the `readlink` comparison, with a check that the
  *old* manifest logic fails the same scenario.
- **The logging paths** — all three `say()` implementations reach both the
  screen and `ttyS0`, with the `-c` guard proven to skip a non-character
  device.
- **The whole CI build**, green end to end — kernel, musl, busybox, all eight
  GNU tools, Copper's three binaries, rootfs, initramfs, GRUB ISO.
- **`sh -n`** on all three shipped shell scripts, plus at build time via
  `lint_scripts`.
- **`copper-init.c` and `copper-firstboot.c`** compile clean under GCC 12.2
  with `-Wall -Wextra -Wpedantic -Wshadow -Wwrite-strings`, and in CI against
  musl.

## Has never run

- **The first-boot wizard.** Compiles; never executed. G1.
- **Any real internet traffic.** No `ping`, no `nslookup`, no `wget`. G2.

## A note on green CI runs

**A green run does not mean the artifact is correct.** Run `36220249701` was
fully green and shipped an ISO built from the previous commit's `init`. Always
take the artifact apart: mount it, `gzip -dc` the initrd, decode the cpio, read
`/init` back out, and parse the ISO's Rock Ridge records if you need to know
what a symlink points at. Windows shows 8.3 names because the image has Rock
Ridge and **no Joliet** — `COPPER_I` is `copper-init`, and that is cosmetic,
not a bug.

## The build gates

- `lint_scripts` — `sh -n` over the initramfs `init` and the lease script. Both
  are read by busybox ash on a machine with no shell to log into and fix them
  with.
- `require_kernel_config` / `require_bb_config` — read the `.config` files back
  after kconfig has had its say and refuse to continue, listing what went
  missing.
- `build_copper` — checks the staged tree actually contains the binaries and
  lease script `switch_root` needs, and that `sbin/init` is a symlink to
  `/usr/bin/copper-init`. Uses `readlink`, not `-e`; see bug #5.

---

# Traps that will cost you a day

**Any change to a cache-key file is a full kernel rebuild.** The CI cache key
hashes `iso/build.sh`, `iso/live/init`, `iso/boot/grub.cfg`,
`iso/rootfs-overlay/**`, `iso/src-init/**`, `iso/firstboot/**` and `src/**`. A
change to *any one* of those throws away the whole `iso/work/` cache. The cache
is saved even on failure (`if: always()`), so a red run still warms the next
one. Batch changes; don't dribble.

**The kernel command line's last `console=` is `/dev/console`.** See bug #7.
This is the single most counter-intuitive thing in the whole boot, it produces
a fake hang, and it cost the most time.

**`console=ttyS0,115200` on a VM with no serial port is not a no-op.** It
takes `/dev/console` away from `tty0`. Add the serial port *and* put `tty0`
last.

**Only add symbols to `require_kernel_config` that you have checked exist.**
A symbol that doesn't exist in 6.12 fails the build immediately and
expensively. `ETHERNET` is the cautionary tale: it was in the list, and 6.12
removed it.

**`MODULES=n` means every `tristate` resolves to `y` or `n`,** never `m`. So a
`--enable`d tristate really is `=y` in the final `.config`.

**`core.autocrlf` was `true` on the build machine** and quietly filled the
working tree with CRLF. A CR is invisible in a diff and it breaks things
quietly: a CR at the end of `PATH` in `/etc/profile` makes every command come up
"not found", CRLF in `passwd`/`hosts` breaks the lookups, and CRLF in a script
busybox ash runs turns every line into "command not found" during boot. It is
`false` now and `.gitattributes` asks for LF everywhere. Leave both alone.

**`git commit -- <paths>` commits the working tree, not the index**, which
leaks `update-index --chmod=+x` changes into a later commit. Use index-only:
`git reset -q; git add -- <files>; git update-index --chmod=+x -- <f>; git commit`.

**`core.fileMode` is off on Windows**, so exec bits need
`git update-index --chmod=+x`. `iso/live/init` and the lease script are mode
100755 and must stay that way.

---

# Config facts worth not rediscovering

Each of these cost a wrong turn once. All were checked against real sources.

- **busybox's `make defconfig` is not a stock config.** busybox patches kconfig
  with `const char conf_defname[] = "/dev/null"`
  (`scripts/kconfig/confdata.c:25`), so "defconfig" means *the Kconfig
  defaults*. There is no `configs/defconfig` in 1.36.1. Per-applet symbols live
  in `//config:config SYMBOL` comments inside the `.c` files and in the
  directory `Config.src` files.
- `CONFIG_STATIC` is `default n`, so it must be set explicitly — and **after**
  `make defconfig`, because reassigning a symbol defconfig already answered is
  silently dropped (first assignment wins). That's what `set_bb_config` is for.
- **6.12 has no `CONFIG_ETHERNET`.** The driver menu is unconditional under
  `NET`/`NETDEVICES`. Those are the real gates.
- In 6.12, `config INET` moved to `net/Kconfig` and `net/ipv4/Makefile` builds
  `tcp.o`/`udp.o` in `obj-y` unconditionally under `INET`. So `CONFIG_INET=y`
  (which `x86_64_defconfig` sets) is enough for IPv4.
- `BLK_DEV_NVME` lives in `drivers/nvme/host/Kconfig` in 6.12. It's `tristate`
  with **no default**, so the explicit `--enable` in `build.sh` turns it on.
- `CONFIG_OVERLAY_FS` is also `tristate` with no default. The entire live-root
  design rests on `build.sh` passing `--enable OVERLAY_FS`.
- vmxnet3's Kconfig path isn't `drivers/net/ethernet/vmware/Kconfig` in 6.12
  and the symbol name couldn't be pinned down. `build.sh` passes **both**
  `--enable VMXNET3` and `--enable VMWARE_VMXNET3`; kconfig drops
  whichever doesn't exist. Deliberately not asserted.
- **In busybox 1.36.1 udhcpc's source is `networking/udhcp/dhcpc.c`,** not
  `networking/udhcp.c` — the client was split into a directory. `ip` is split
  too: address parsing is in `networking/libiproute/`.
- The environment udhcpc exports comes from the DHCP **option** names. The
  consequence that matters: **`$subnet` is the netmask as a dotted quad**, and
  `$mask` is the same mask as a decimal uint32. Neither is a prefix length.
- busybox `ip` *does* accept a dotted mask after the slash: `get_prefix_1`
  (`networking/libiproute/utils.c`) falls back to parsing it as a netmask. We
  convert to a prefix length ourselves rather than depending on that.
- `udhcpc -b` does not exit — after its retries it forks into the background
  and keeps trying forever. So init can fire it and move on; no `-n` needed.
- udhcpc does **not** put `PATH` in the lease script's environment, so init has
  to set it before the exec.
- busybox installs udhcpc at `/sbin/udhcpc`, `ip`/`ifconfig`/`route` in
  `/sbin`, `ping` in `/bin`, `wget`/`nslookup` in `/usr/bin`, `switch_root` in
  `/sbin`. It does **not** install a lease script, which is why we ship one.
- `wget`'s `https://` is busybox's internal TLS. It encrypts but does **not**
  verify certificates. Fine for pulling a tarball, not for a login.

---

# Repo map

```
iso/build.sh              stage pipeline: kernel|base|tools|copper|rootfs|initramfs|iso|all
iso/live/init             initramfs: find the ISO, lay a writable overlay, switch_root
iso/boot/grub.cfg         GRUB menu: normal, verbose, debug, initramfs-shell
iso/src-init/copper-init.c    our PID 1
iso/firstboot/copper-firstboot.c   the OOBE wizard  (never executed)
iso/rootfs-overlay/       /etc and friends that land in the rootfs
iso/rootfs-overlay/usr/share/udhcpc/default.script   our DHCP lease script
src/                      copper-sh: main.c, builtins.c, builtins.h
tests/smoke.sh            19-assertion shell smoke test
.github/workflows/build-iso.yml   per-stage CI steps + workspace cache
PR.md                     drafted PR body
```

---

# Tooling and how to drive a boot

## Getting the ISO

Artifacts download fine now, using the Git Credential Manager token. Earlier
notes saying this returns 401 are out of date. Capture the token into a
variable and never print it:

```sh
out=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill)
tok=$(printf '%s\n' "$out" | sed -n 's/^password=//p')
curl -sL -H "Authorization: Bearer $tok" \
  https://api.github.com/repos/farcrowx/copper/actions/artifacts/<id>/zip -o iso.zip
```

## The VM

VMware Workstation, guest OS **Linux / Other Linux 6.x kernel 64-bit**, 2 GB,
2 processors, **NAT** networking (bridged may not answer DHCP), and the ISO on
the CD drive with **Connected at power on** ticked.

Then **Add… → Serial Port**, "This end is connected to" → **Output to file** →
`C:\Users\hp\Desktop\copper-boot.txt` (VMware insists on a `.txt` name and will
warn that the file does not exist; accept it, it creates the file) → **Connect
at power on**.

Boot the **verbose** entry while diagnosing. The `copper:` and `copper-net:`
lines now reach the file on *every* entry, so paste that file rather than
photographing a screen.

## Tooling on the build machine

- **Git for Windows** gives a real POSIX shell at
  `C:\Program Files\Git\bin\bash.exe`. That allows `sh -n` on the shipped
  scripts and — more usefully — unit testing shell logic with a stub binary on
  `PATH`, no VM and no compiler. Most of the tests in this branch were written
  that way. Don't assume there's no way to test shell here.
- **This box cannot create a symlink at all** — `ln -s` fails regardless of
  privilege, because Windows wants Developer Mode for native symlinks. So any
  test of symlink *behaviour* has to stub `readlink`; the real thing is CI's to
  prove, and it does.
- No local C toolchain: no gcc/clang/tcc, no WSL, no container runtime. C
  verification goes through Compiler Explorer's API, which is **glibc, not
  musl**, so it cannot validate musl-specific code. CI is the real oracle.
- PowerShell gotchas that cost time: no heredocs (write the message to a file
  and use `git commit -F`); inline `bash -lc` with quotes and `$` gets mangled
  (write a `.sh` and invoke it); `curl.exe` mangles JSON in `--data-raw` (write
  the body to a file, use `--data-binary @file`); nested `$'\r'` through
  `bash -lc` arrives as a literal backslash-r, so CR checks must live in a
  script file.

---

# Rules to keep

- Human-sounding commit messages and code. Nothing that reads like AI slop.
- Keep Copper's identity distinct. Arch and Debian are reference material, not
  packaging material.
- **Verification over vibes.** Compile clean, run the battery under ASan before
  claiming a command works, and never ship a fake or placeholder command. A
  command that exists but doesn't work is worse than a missing one, because it
  lies.
- **Read the artifact, not the CI run.** A green build has shipped a stale ISO
  here. It will again.
- When something is unverified, say so in the commit message and in this file.
  The gap between "it builds" and "it boots" is what this project has been
  living on, and bugs #4 through #9 were all invisible to the build.
