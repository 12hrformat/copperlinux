# Copper OS — Handoff

> Read this first, then `iso/README.md` for the build internals.
> Written by whoever had the machine last. Everything in it is either
> verified or explicitly marked as unverified — there is no third category.

## What Copper is

Our own Linux distro, built from source. Not a rebrand of Debian or Arch,
and not a respin of them: the kernel is upstream but the `.config` is ours,
the userland is compiled in our own pipeline against musl, and the pieces
that make it *Copper* are written by hand.

- real **Linux kernel** (6.12.10 LTS, from kernel.org) with **our `.config`**
- userland **built from source**: musl, busybox, coreutils and friends
- **our own** shell (`copper-sh`), **our own** PID 1 (`copper-init`), **our
  own** first-boot wizard
- **all the standard Linux commands**, real tools — no stubs, no placeholders
- boots as an **ISO** in VMware / VirtualBox / QEMU
- first boot personalizes like a real distro OOBE
- speaks to **drivers** (wifi, bluetooth, firmware) and reaches the **internet**

Upstream projects are reference material. Nothing gets packaged as-is.

## Where things actually stand

The build pipeline is green end to end and produces a bootable-looking ISO
of about 29 MiB. The shell is finished and tested. Ethernet + DHCP is
written, unit-tested, and waiting on hardware.

**None of the boot path has ever been executed.** `grub.cfg`, the initramfs
`/init`, the overlay mount, `copper-init` itself and the wizard were all
written without a VM in front of anyone. That is the whole story of this
project right now: a lot of well-built parts and no proof they meet.

Read that as the first thing to fix, not as a footnote.

## Before you start: check which branch you have

As of this writing the local checkout was **6 commits ahead of
`origin/copper-os`**:

```
3080a84 note down the push blocker and the autocrlf that was fighting us [skip ci]
3432f4e write down how the network actually gets configured
5a9f57b force LF for everything that ends up in the ISO
d5171ac iso: fail the build when a kernel or busybox option goes missing
01ce3aa iso: ship a udhcpc lease script and a fallback resolver
18298f7 iso: get the box online before the wizard runs
```

If your branch tip is `77f2e6d`, **you do not have the networking work** —
it was never pushed, because the only credential on that machine belonged to
an account without write access to the fork. Find whoever has those commits
before you start, or you will rebuild the DHCP path from scratch for no
reason.

Confirm with `git log --oneline -7` and `git status -sb`.

---

# Goals

Ordered by what unblocks the most. Do them in this order.

## G1 — Boot the ISO ⚠️ blocks everything else

**Done looks like:** VMware (new VM, Ubuntu 64-bit guest, 2 GB, NAT
networking, `copper.iso` attached to the CD drive) powers on, GRUB shows the
menu, the kernel boots, the wizard asks for your name, and you land at a
`copper-sh` prompt.

There is no hypervisor on the build machine, so this needs a person at a
keyboard. Everything else in this document is guesswork until it happens.

The first-wave suspects, in rough order of likelihood:

1. **Kernel cmdline** in `iso/boot/grub.cfg` — `root=`, `console=`, `init=`
   are guesses. There is a "verbose" GRUB entry; use it to see how far it
   gets.
2. **The initramfs `init`** (`iso/live/init`) — finding the Copper medium,
   and the overlay `mount` options. The lowerdir is read-only ISO and the
   upper is tmpfs; a wrong `lowerdir` path fails here silently-ish.
3. **The console device** — if the kernel can't find `console=ttyS0` or
   `tty0` you get a black screen and no way to type anything.
4. **`switch_root`** — the args and the cwd it expects.

When it does boot, `cat /proc/cmdline` and the verbose boot log are the first
two things to read. Fix the boot path before touching anything else; nothing
downstream is testable until it works.

## G2 — Prove the network

**Done looks like,** in the `copper-sh` prompt after a boot:

```sh
ip a                      # an address from DHCP, on the wired NIC
ping 1.1.1.1              # raw IP, no DNS involved
wget https://example.com  # DNS and TLS together
```

The code for all of this exists — `bring_up_network()` in
`iso/src-init/copper-init.c` and our own lease script at
`iso/rootfs-overlay/usr/share/udhcpc/default.script` — and the lease script
is unit-tested (see below). What has never happened is a real DHCP server
answering.

If it doesn't come up, the suspects in order: the interface name (init picks
the first non-`lo` in `/sys/class/net` — confirm it isn't grabbing something
odd), VMware's NIC model (try e1000e, then vmxnet3), and whether the
gateway is on the same subnet as the lease.

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
without any manual fiddling.

Roughly: enable `CFG80211` plus the driver in `build.sh`; build
**wpa_supplicant** from source (static musl) for association; keep busybox
`udhcpc` for the IP afterwards, since it already works; and drop the card's
firmware blobs (a `linux-firmware` subset) into the rootfs. Full
NetworkManager — glib and dbus from source — is the heavy end state for
roaming and a GUI, and is not required to get onto a network.

Note that `bring_up_network()` currently takes the first non-loopback
interface of *any* kind, in whatever order the directory reads. With wifi
present that is a coin flip. Skip anything with a `phy80211` directory.

## G5 — Bluetooth

**Done looks like:** `bluetoothctl` or equivalent sees a paired device.

BlueZ built from source, kernel `CONFIG_BT=y` with the relevant protocol
drivers. BlueZ wants a D-Bus daemon; that's the part to budget time for.

## G6 — Persistence

**Done looks like:** a reboot keeps your files.

The overlay's upper layer is currently tmpfs, so the session is throwaway by
design. Move the upper onto a real disk partition the user picks on the
wizard's last page — the same overlay mechanism, just a different `upperdir`.
`iso/live/init` already lays the overlay down, so this is a matter of
mounting a disk where the tmpfs goes and telling the wizard to offer it.

## G7 — Ship the PR

`PR.md` at the repo root is drafted and current, including the networking
work. PR #2 targets `copper-os` → `main`. Push the branch and open it, or
update the body if the status has moved on.

## G8 — A desktop

The long end. Worth saying plainly: it is far away, and nothing before it is
blocked on it.

---

# What is verified, and what is not

Being precise here matters, because a lot of this tree has never run and it
is easy to mistake "it compiles" for "it works".

## Has actually been executed

- **`copper-sh`** — compiled with real GCC 12.2
  (`-std=c11 -O2 -Wall -Wextra`, zero warnings) and run through a 44-command
  battery under **AddressSanitizer**: exit 0, no leaks, no overruns. Bugs
  that found and fixed: an argv heap off-by-one, output lost because `_exit()`
  skipped the stdio flush, history storing tokenized instead of the line you
  typed, children reading stale buffered stdin, `ls -l` on a single file, and
  `ls` going one-per-line on a non-TTY so `ls | grep` filters like real `ls`.
- **`tests/smoke.sh`** — 19 assertions over the shell's core behaviours. Run
  it before you touch the shell: `make && ./tests/smoke.sh`. Needs a local
  compiler; there isn't one on the build machine, so it runs wherever you're
  developing.
- **The DHCP lease script** — 58 assertions on `mask_to_prefix` (all 33 valid
  netmasks, generated rather than typed, plus non-contiguous and malformed
  input) and 25 more driving the whole script against a stub `ip`: every
  lease state, renew replacing the default route, a missing netmask falling
  back to /24, several routers, a nameserver-less lease keeping the fallback
  resolver, and an empty `$1` being refused.
- **The whole CI build**, green end to end — kernel, musl, busybox, all eight
  GNU tools, Copper's three binaries, rootfs, initramfs, GRUB ISO.
- **`sh -n`** on all three shipped shell scripts.
- **`copper-init.c` and `copper-firstboot.c`** compile clean under GCC 12.2
  with `-Wall -Wextra -Wpedantic -Wshadow -Wwrite-strings`.

Writing those lease-script tests found two real bugs: a non-contiguous mask
like `255.0.255.0` was accepted as a valid netmask, and a truncated
`255.255.255` was read as /32. The file had also carried a confident comment
claiming `$subnet` was a prefix length, which was simply false. Read the
busybox source rather than reasoning about it.

## Has never run

**Everything on the boot path.** `grub.cfg`, the initramfs `/init`, the
overlay mount, `copper-init`, the wizard, and DHCP against a real server.
No hypervisor on the build machine can run any of it. This is G1.

## The build gate

Two functions in `iso/build.sh` exist because a kernel that boots to a black
screen, or comes up with no NIC able to speak DHCP, is miserable to debug
from inside a VM — you get a dead machine and no error message, because from
the build's point of view nothing went wrong.

- `lint_scripts` — `sh -n` over the initramfs `init` and the lease script.
  Both are read by busybox ash on a machine with no shell to log into and fix
  them with.
- `require_kernel_config` / `require_bb_config` — read the `.config` files
  back after kconfig has had its say and refuse to continue, listing what
  went missing, if an option Copper leans on isn't set.

---

# Traps that will cost you a day

**Any change to a cache-key file is a full kernel rebuild.** The CI cache key
hashes `iso/build.sh`, `iso/live/init`, `iso/boot/grub.cfg`,
`iso/rootfs-overlay/**`, `iso/src-init/**`, `iso/firstboot/**` and `src/**`.
A change to *any one* of those throws away the whole `iso/work/` cache. And
the cache is only saved on job success, so a spurious assertion failure costs
a full rebuild too. Batch changes; don't dribble.

**Only add symbols to `require_kernel_config` that you have checked exist.**
That list is the reason a broken kernel config fails loudly instead of
booting mute, but a symbol that doesn't exist in 6.12 fails the build
immediately and expensively. `ETHERNET` is the cautionary tale: it was in the
list, and 6.12 removed it.

**`MODULES=n` means every `tristate` resolves to `y` or `n`,** never `m`. So a
`--enable`d tristate really is `=y` in the final `.config`, which is what
makes those assertions safe to write.

**`core.autocrlf` was `true` on the build machine** and quietly filled the
working tree with CRLF. A CR is invisible in a diff and it breaks things
quietly: a CR at the end of `PATH` in `/etc/profile` makes every command come
up "not found", CRLF in `passwd`/`hosts` breaks the lookups, and CRLF in a
script busybox ash runs turns every line into "command not found" during
boot. It is set to `false` now, and `.gitattributes` asks for LF everywhere.
Leave both alone.

---

# Config facts worth not rediscovering

Each of these cost a wrong turn once. All were checked against real sources.

- **busybox's `make defconfig` is not a stock config.** busybox patches
  kconfig with `const char conf_defname[] = "/dev/null"`
  (`scripts/kconfig/confdata.c:25`), so "defconfig" means *the Kconfig
  defaults*. There is no `configs/defconfig` in 1.36.1. Per-applet symbols
  live in `//config:config SYMBOL` comments inside the `.c` files and in the
  directory `Config.src` files. Don't go looking for a defconfig to patch.
- `CONFIG_STATIC` is `default n`, so it must be set explicitly — and **after**
  `make defconfig`, because reassigning a symbol defconfig already answered is
  silently dropped (first assignment wins). That's what `set_bb_config` is for.
- **6.12 has no `CONFIG_ETHERNET`.** The driver menu is unconditional under
  `NET`/`NETDEVICES`. `NET` and `NETDEVICES` are the real gates.
- In 6.12, `config INET` moved to `net/Kconfig` and `net/ipv4/Makefile` builds
  `tcp.o`/`udp.o` in `obj-y` unconditionally under `INET`. So `CONFIG_INET=y`
  (which `x86_64_defconfig` sets) is enough for IPv4; there is no separate
  TCP/UDP symbol to chase.
- `BLK_DEV_NVME` lives in `drivers/nvme/host/Kconfig` in 6.12, not
  `drivers/block/`. It's `tristate` with **no default**, so the explicit
  `--enable` in `build.sh` is what turns it on.
- `CONFIG_OVERLAY_FS` is also `tristate` with no default. The entire live-root
  design rests on `build.sh` passing `--enable OVERLAY_FS`.
- vmxnet3's Kconfig path isn't `drivers/net/ethernet/vmware/Kconfig` in 6.12
  (404) and the symbol name couldn't be pinned down. `build.sh` passes **both**
  `--enable VMXNET3` and `--enable VMWARE_VMXNET3`; kconfig drops
  whichever doesn't exist, which costs nothing. Deliberately not asserted.
- The whole assertion list was cross-checked against the real
  `x86_64_defconfig`: every symbol is either explicitly `=y` there or
  explicitly `--enable`d. Nothing depends on an unverified Kconfig default.
- **In busybox 1.36.1 udhcpc's source is `networking/udhcp/dhcpc.c`,** not
  `networking/udhcp.c` — the client was split into a directory, so grepping
  the old path finds nothing and makes the applet look missing. `ip` is split
  too: the address parsing is in `networking/libiproute/`, not `ip.c`.
- The environment udhcpc exports comes from the DHCP **option** names
  (`common.c:dhcp_optflags`). The consequence that matters: **`$subnet` is the
  netmask as a dotted quad** (option 1 is `OPTION_IP`), and `$mask` is the same
  mask as a decimal uint32. Neither is a prefix length.
- busybox `ip` *does* accept a dotted mask after the slash: `get_prefix_1`
  (`networking/libiproute/utils.c`) tries `bb_strtou` on the text after `/` and
  falls back to parsing it as a netmask when the number comes out wider than
  the address. That's how upstream's own `examples/udhcp/simple.script` gets
  away with `ip addr add $ip/$subnet`. We convert to a prefix length
  ourselves anyway rather than depending on that fallback.
- `udhcpc -b` does not exit — after its retries it forks into the background
  and keeps trying forever. So init can fire it and move on; no `-n` needed.
- udhcpc does **not** put `PATH` in the lease script's environment, so init
  has to set it before the exec.
- busybox installs udhcpc at `/sbin/udhcpc`, `ip`/`ifconfig`/`route` in
  `/sbin`, `ping` in `/bin`, `wget`/`nslookup` in `/usr/bin`, `switch_root`
  in `/sbin`. It does **not** install a lease script, which is why we ship
  our own.
- `wget`'s `https://` is busybox's internal TLS. It encrypts but does **not**
  verify certificates. Fine for pulling a tarball, not for a login.

---

# Repo map

```
iso/build.sh              stage pipeline: kernel|base|tools|copper|rootfs|initramfs|iso|all
iso/live/init             initramfs script: find the ISO, lay a writable overlay, switch_root
iso/boot/grub.cfg         GRUB menu, normal and verbose entries
iso/src-init/copper-init.c    our PID 1
iso/firstboot/copper-firstboot.c   the OOBE wizard
iso/rootfs-overlay/       /etc and friends that land in the rootfs
iso/rootfs-overlay/usr/share/udhcpc/default.script   our DHCP lease script
src/                      copper-sh: main.c, builtins.c, builtins.h
tests/smoke.sh            19-assertion shell smoke test
.github/workflows/build-iso.yml   per-stage CI steps + workspace cache
PR.md                     drafted PR body
```

- `origin` = `https://github.com/12hrformat/copper.git` (the fork). Upstream
  `Copper-linux/copper` returns 403 on push, so PRs go via the fork.
- Branches: **`copper-os` only**. The old `main`, `copper-sh` and `patch-1`
  branches were deleted; the shell's history survives inside `copper-os`.
- Last green CI run: `35937198186` (sha `468ba4c`), artifact `copper.iso`
  ~29 MiB. The run after it was cancelled.
- **Pushing needs a credential the build machine didn't have.** Git Credential
  Manager offered only `farcrowx`, and GitHub answered
  `Permission to 12hrformat/copper.git denied to farcrowx`. No `gh` CLI, no
  SSH key. Get a token from the owner or push from an account that can
  already write.

## Tooling on the build machine

- **Git for Windows is installed**, so a real POSIX shell is at
  `C:\Program Files\Git\bin\bash.exe`. That gives you `sh -n` on the shipped
  scripts and — more usefully — the ability to unit test shell logic with a
  stub binary on `PATH`, no VM and no compiler. The lease script got both
  treatments because of it. Don't assume there's no way to test shell here.
- No local C toolchain: no gcc/clang/tcc, no WSL, no container runtime. C
  verification goes through Compiler Explorer's API (`cg122` = x86-64 gcc
  12.2, C mode), driven by a script under `%LOCALAPPDATA%\Temp\opencode`.
- **CE is glibc, not musl**, so it cannot validate musl-specific code.
  `src/builtins.c` uses musl's `S_ISVTX` and CE reports it as an error; the
  musl build in CI is the real oracle for those files.
- CE's multi-file compile is broken server-side, and writing to stderr from
  node aborts on that box (`UV_HANDLE_CLOSING`) — capture stdout only.
- The GitHub jobs/runs API is readable unauthenticated, but downloading an
  artifact returns **401**. So the built ISO can't be fetched or inspected
  from the build machine; only its existence and its stage-by-stage logs can.
- No VMware, VirtualBox or QEMU. That's why G1 needs a person.

---

# Rules to keep

- Human-sounding commit messages and code. Nothing that reads like AI slop.
- Keep Copper's identity distinct. Arch and Debian are reference material, not
  packaging material.
- **Verification over vibes.** Compile clean, run the battery under ASan
  before claiming a command works, and never ship a fake or placeholder
  command. A command that exists but doesn't work is worse than a missing
  one, because it lies.
- When something is unverified, say so in the commit message and in this
  file. The gap between "it builds" and "it boots" is the whole problem here.
