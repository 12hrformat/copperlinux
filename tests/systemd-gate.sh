#!/usr/bin/env bash
# Gate for the systemd migration (SYSTEMD-MIGRATION.md, phase 1).
#
# Copper boots its own PID 1 today: iso/src-init/copper-init.c, musl-static,
# symlinked at /sbin/init. The migration swaps that for systemd, opt-in via
# `bash iso/build.sh systemd`. This gate proves the pieces of that swap that
# can be proved WITHOUT booting a machine, and it is honest about which ones
# those are.
#
# What it checks, and why each one is here:
#
#   1. The units parse. systemd's own parser is the authority, so ask it
#      (systemd-analyze verify), skipping cleanly if the host has no systemd.
#      It is not the image's systemd -- a newer host accepts directives the
#      image's 255 does not -- so the real defence is the second half of this:
#      a key that does not belong in the section it is in is REJECTED by the
#      check, and that is exactly how this gate found StartLimitIntervalSec in
#      [Service] (it belongs in [Unit]) and SocketMode=, which does not exist.
#
#   2. build_systemd actually runs, and produces the tree the boot needs. The
#      package tools are stubbed -- apt-get hands back fake .debs, dpkg-deb
#      unpacks them -- so this is the REAL function out of iso/build.sh, not a
#      copy of its logic. The first version of the stage died here: a bare
#      `install ... *.network` glob with no matching file is "cannot stat
#      '*.network'" and killed the whole build. That is the class of bug this
#      catches.
#
#   3. The swap is coherent: /sbin/init is systemd, udevd is wanted by
#      sysinit.target, the Copper units are all wired, the power commands point
#      at systemctl and not at busybox, and -- the bit that is easy to get
#      wrong and impossible to see later -- nothing from the build host's
#      systemd-analyze is left behind in the tree.
#
# It does NOT boot anything, and it does not pretend a green run here means a
# bootable image. SYSTEMD-MIGRATION.md carries the honest status line; this
# gate is the part that can be mechanised.
#
# Root only (it chroots). Run: sudo tests/systemd-gate.sh
#
# handcrafted by 12hrformat (SYSTEMD-MIGRATION.md, phase 1)

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$REPO/iso/build.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "tests/systemd-gate.sh must run as root: sudo tests/systemd-gate.sh" >&2
    exit 1
fi
if [ ! -f "$BUILD" ]; then
    echo "FAIL $BUILD does not exist" >&2
    exit 1
fi

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }

# The wording systemd uses for an ordering cycle, in every form it has used.
# It is here, once, because three places need the same answer: the gate's own
# transaction check, the gate's test of the stage's check, and the stage's
# check itself. The stage's copy is asserted to be this one (section 7), so
# the three cannot drift apart.
#
# 255: "Found ordering cycle: ...", "Unable to break cycle ...", and
#      "Transaction order is cyclic."  256+ keeps the first and the third.
CYC_RE='ordering cycle|cyclic ordering|order is cyclic|break cycle'

TMP=$(mktemp -d /tmp/systemd-gate.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

# ---------------------------------------------------------------- 1. parse --
# A unit's keys must be in the right section. systemd-analyze is the only thing
# that knows; if it is absent, say so rather than claim a pass.
#
# The modes are fixed FIRST, in a private copy: the source tree is 777 on a
# Windows checkout, and systemd-analyze pairs each "marked world-writable"
# warning with the filename on the line BEFORE the message, so a name-based
# filter would keep them whatever order it ran in. Copying to 0644 removes the
# question. (build_systemd installs 0644; gate 3 checks that installed mode.)
if command -v systemd-analyze >/dev/null 2>&1; then
    UD="$TMP/units"; mkdir -p "$UD"
    install -m 0644 "$REPO"/iso/systemd/*.service "$UD/" 2>/dev/null || true
    install -m 0644 "$REPO"/iso/systemd/*.target  "$UD/" 2>/dev/null || true

    # The unit SEARCH PATH has to include $UD, or a Wants=/After= that names
    # another Copper unit cannot be resolved and the graph systemd checks is
    # not the graph the boot will build. Without this the gate was verifying
    # each unit in isolation with half its dependencies missing -- which is
    # exactly why it could not see an ordering cycle (see the transaction check
    # below). The rest of the path is the host's own, which is where the base
    # units live: sysinit.target, systemd-udevd.service and the rest.
    UPATH="$UD:/etc/systemd/system:/run/systemd/system:/usr/local/lib/systemd/system:/usr/lib/systemd/system:/lib/systemd/system"

    for u in "$UD"/*.service "$UD"/*.target; do
        [ -e "$u" ] || continue
        out=$(SYSTEMD_UNIT_PATH="$UPATH" systemd-analyze verify "$u" 2>&1 || true)
        # Which of systemd-analyze's lines are a complaint about THIS unit?
        #
        # The filter used to be a deny-list (drop "Command X is not
        # executable", a missing man page, and the host's own noise) and keep
        # "about this unit" via grep -F "$base". That is host-version
        # dependent, and CI proved it: on ubuntu-24.04's systemd 255 the same
        # units produce lines that do NOT match the deny-list, so two units
        # reported FAIL for messages that were really about the HOST -- units
        # this image does not ship (systemd-udev-settle.service is Ubuntu's,
        # the seatd/udhcpc ExecStart paths only exist inside the image).
        # A gate whose verdict changes with the runner's systemd version is a
        # gate that goes red for green code, so it is an allow-list now.
        #
        # What is allowed to fail a unit, and only this: a key systemd does not
        # know, a key in the wrong section, or a missing/empty ExecStart. Those
        # are answered by the unit's own text and cannot be an artifact of what
        # the host happens to have installed. Everything else -- "not
        # executable", "not found", a missing man page, a dependency unit the
        # host does not carry -- is the build host talking about itself, and
        # the stage's own chrooted check (section 2/3) is what tests those.
        base=${u##*/}
        left=$(printf '%s\n' "$out" \
            | grep -E "Unknown (key|lvalue|section)|Failed to parse|Empty (ExecStart|section)|not a valid" \
            | grep -F "$base" \
            | grep -c . || true)
        if [ "$left" = 0 ]; then
            ok "unit parses: $base"
        else
            bad "unit parses: $base" "$(printf '%s' "$out" | tr '\n' '|')"
        fi
    done

    # ---- ONE transaction, not one unit at a time ---------------------------
    #
    # An ORDERING CYCLE only exists in a transaction: it is a loop BETWEEN
    # units, so systemd-analyze has to be given all of them at once to see it.
    # Verified one unit at a time, every unit in the loop looks perfect on its
    # own -- and that is not a theoretical gap.
    #
    # copper-tty-clear.service shipped with `After=sysinit.target` AND
    # `Before=systemd-udevd.service`, while systemd's own udevd unit carries
    # `Before=sysinit.target` (read out of the noble 255.4 udev package this
    # image unpacks). That closes a loop:
    #
    #     sysinit.target -> copper-tty-clear.service -> systemd-udevd.service
    #                    -> sysinit.target
    #
    # and the cycle is on sysinit.target, so the boot's initial transaction
    # fails outright: not a degraded boot, no boot. The per-unit loop above
    # reported every unit as parsing perfectly.
    #
    # The check is deliberately NOT scoped to a unit name: systemd decides
    # which job it drops when it breaks a cycle, so the message can name any
    # unit in the loop.
    out=$(SYSTEMD_UNIT_PATH="$UPATH" systemd-analyze verify \
              "$UD"/*.service "$UD"/*.target 2>&1 || true)
    if printf '%s\n' "$out" | grep -qiE "$CYC_RE"; then
        bad "the units form no ordering cycle" \
            "$(printf '%s' "$out" | grep -iE 'cycle|cyclic' | tr '\n' '|')"
    else
        ok "the units form no ordering cycle (verified as ONE transaction)"
    fi
else
    echo "  skip  systemd-analyze not on this host; unit parse checks skipped"
fi

# ------------------------------------------------- 2. run the real stage ----
# A mock staged rootfs shaped like the one gui+hypr+copper would leave, then
# the real build_systemd() out of iso/build.sh, with apt-get/dpkg-deb stubbed.
TGT="$TMP/work/rootfs"; WORK="$TMP/work"; DL="$TMP/work/downloads"
ROOT="$REPO/iso"; REPO_V="$REPO"; SELF="$BUILD"; JOBS=2
export WORK DL ROOT SELF JOBS TGT

mkdir -p "$TGT/bin" "$TGT/sbin" "$TGT/usr/bin" "$TGT/usr/sbin" "$TGT/lib" \
         "$TGT/usr/lib/x86_64-linux-gnu" "$TGT/usr/share" "$TGT/etc" \
         "$TGT/run" "$TGT/tmp" "$TGT/home" "$TGT/root" "$TGT/var/log" \
         "$TGT/mnt" "$TGT/boot" "$TGT/dev"
mkdir -p "$WORK" "$DL"
mknod -m 666 "$TGT/dev/null" c 1 3 2>/dev/null \
    || cp -a /dev/null "$TGT/dev/null" 2>/dev/null || true
for b in usr/bin/copper-init usr/bin/copper-firstboot usr/bin/copper-sh \
         usr/bin/seatd sbin/udhcpc; do
    printf '#!/bin/sh\nexit 0\n' > "$TGT/$b"; chmod 0755 "$TGT/$b"
done
printf '#!/bin/sh\nexit 0\n' > "$TGT/sbin/shutdown"; chmod 0755 "$TGT/sbin/shutdown"
# the loader PID 1 will name as its interpreter
if [ -e /lib64/ld-linux-x86-64.so.2 ]; then
    cp -L /lib64/ld-linux-x86-64.so.2 \
          "$TGT/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
fi
# build_copper's state, so the stage is flipping real links and not making it up
ln -sf /usr/bin/copper-init "$TGT/sbin/init"
for c in reboot poweroff halt; do
    ln -sf /bin/busybox "$TGT/sbin/$c"; ln -sf /bin/busybox "$TGT/usr/sbin/$c"
done
ln -sf /sbin/shutdown "$TGT/usr/sbin/shutdown"

# The GUI closure runs BEFORE this stage and leaves a real, populated
# usr/lib/systemd behind -- 454 paths, all under usr/lib, none under lib (verified
# by unpacking the closure; the packages never write a literal lib/systemd). So by
# the time the bridge runs, usr/lib/systemd already exists as a directory, and the
# stage has to expose it at /lib anyway. The fixture models that, and also leaves a
# real empty lib/systemd that SQUATS on the name, because that is the state the
# guard has to survive: a guard that only asked "is lib/systemd absent?" declined
# to bridge and the stage then died claiming the packages never arrived. Left
# empty on purpose -- the trap is `[ -d lib/systemd ]` being true.
mkdir -p "$TGT/usr/lib/systemd/user" "$TGT/lib/systemd"
printf '[Unit]\nDescription=placeholder\n' > "$TGT/usr/lib/systemd/user/dconf.service"

# /etc/group, with the _seatd line build_gui appends. The stage now ASSERTS this
# group exists (a boot proved the group can be lost -- build_rootfs overwrites
# /etc/group from the overlay on the second pass and the appending stage skips),
# so the fixture has to carry it or the good run fails for the wrong reason.
# The sabotage suite deletes the line to prove the assertion fires.
printf 'root:x:0:\nnobody:x:65534:\nusers:x:100:\nwheel:x:10:\n_seatd:x:999:\n' \
    > "$TGT/etc/group"

STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/apt-get" <<'STUBEOF'
#!/bin/sh
arch=""
for a in "$@"; do
    case "$a" in Dir::Cache::archives=*) arch=${a#*=} ;; esac
done
printf '%s\n' "$@" | grep -q -- "--download-only" || exit 0
mkdir -p "$arch"
[ -n "${COPPER_TEST_DEB_DIR:-}" ] && cp "$COPPER_TEST_DEB_DIR"/*.deb "$arch/" 2>/dev/null
exit 0
STUBEOF
cat > "$STUB/dpkg-deb" <<'STUBEOF'
#!/bin/sh
[ "${1:-}" = "-x" ] || exit 0
mkdir -p "$3"
tar -C "$3" -xf "$2" 2>/dev/null || true
exit 0
STUBEOF
chmod 0755 "$STUB/apt-get" "$STUB/dpkg-deb"

PD="$TMP/payload"; mkdir -p "$PD/usr/lib/systemd/system" "$PD/usr/bin"
# merged-usr, the way a real noble deb is: PID 1 ships at usr/lib/systemd/systemd
# and usr/bin/systemd is a symlink THROUGH /lib to it. The fixture used to put
# the fake PID 1 at payload/lib/systemd/systemd -- a layout no Debian-family deb
# has produced since merged-usr -- so the stage's `[ -x $TGT/lib/systemd/systemd ]`
# gate passed against the fixture while a real build died with "39 packages
# unpacked (58M)" and "/lib/systemd/systemd did not arrive". A fixture that
# models the input wrongly certifies the wrong code; this one now models the deb.
printf '#!/bin/sh\nexit 0\n' > "$PD/usr/lib/systemd/systemd"; chmod 0755 "$PD/usr/lib/systemd/systemd"
ln -sf ../lib/systemd/systemd "$PD/usr/bin/systemd"
printf '#!/bin/sh\nexit 0\n' > "$PD/usr/bin/systemctl";  chmod 0755 "$PD/usr/bin/systemctl"
for u in sysinit.target multi-user.target getty.target; do
    printf '[Unit]\nDescription=%s\n' "$u" > "$PD/usr/lib/systemd/system/$u"
done
# systemd's OWN udevd unit, modelled on the real noble 255.4 udev package
# (udev_255.4-1ubuntu8.18_amd64.deb, unpacked and read). Two lines matter:
#
#   DefaultDependencies=no   without it systemd adds an automatic
#                            After=sysinit.target, which would contradict the
#                            Before= below and fake a cycle of its own;
#   Before=sysinit.target    this is the edge that closes the loop with
#                            copper-tty-clear.service's After=sysinit.target.
#
# The fixture used to say "Description=udev" and nothing else, so the ordering
# graph the stage's chrooted verify walked was not the graph the boot builds --
# the same "a fixture that models its input wrongly certifies the wrong code"
# trap, once more.
printf '[Unit]\nDescription=Rule-based Manager for Device Events and Files\nDefaultDependencies=no\nBefore=sysinit.target\n\n[Service]\nType=notify\nExecStart=/usr/lib/systemd/systemd-udevd\n' \
    > "$PD/usr/lib/systemd/system/systemd-udevd.service"
# The settle unit, which copper-firstboot.service and copper-seatd.service both
# order themselves after. Real noble ships it; without it those two After= lines
# point at nothing.
printf '[Unit]\nDescription=Wait for udev To Complete Device Initialization\nDefaultDependencies=no\nBefore=sysinit.target\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=udevadm settle\n' \
    > "$PD/usr/lib/systemd/system/systemd-udev-settle.service"
printf '[Unit]\nDescription=Trigger udev uevent handling\nDefaultDependencies=no\nBefore=sysinit.target\n\n[Service]\nType=oneshot\nExecStart=/usr/lib/systemd/systemd-udev-trigger\n' \
    > "$PD/usr/lib/systemd/system/systemd-udev-trigger.service"
# the real udev package ships udevadm at /usr/bin; the settle unit execs it by
# bare name, so it has to be in the tree for the ExecStart to resolve
printf '#!/bin/sh\nexit 0\n' > "$PD/usr/bin/udevadm"; chmod 0755 "$PD/usr/bin/udevadm"
# systemd's own ldconfig.service, exactly as the deb ships it: ExecStart=/sbin/
# ldconfig -X. This image has no ldconfig, so the unit failed on the first boot
# and showed up in `systemctl --failed`. build_systemd masks it now; the payload
# carries the vendor unit so the mask has a real name to shadow and a sabotage
# case can prove the assertion reads it back.
printf '[Unit]\nDescription=Rebuild Dynamic Linker Cache\nConditionNeedsUpdate=/etc\n\n[Service]\nType=oneshot\nExecStart=/sbin/ldconfig -X\n' \
    > "$PD/usr/lib/systemd/system/ldconfig.service"
DEBDIR="$TMP/debs"; mkdir -p "$DEBDIR"
tar -C "$PD" -cf "$DEBDIR/systemd.deb" .
tar -C "$PD" -cf "$DEBDIR/udev.deb" .
tar -C "$PD" -cf "$DEBDIR/systemd-sysv.deb" .
export COPPER_TEST_DEB_DIR="$DEBDIR"

# Bring in the real helpers and the real function. eval of the extracted
# definition is the point: this gate must fail when build_systemd changes, so
# it runs the shipped code, not a paraphrase of it.
#
# It runs in a SEPARATE bash process, though, and that is not incidental -- see
# the runner below. The extraction still happens here so the code under test is
# literally this repo's build.sh.
extract() { sed -n "/^$1()/,/^}/p" "$BUILD"; }
eval "$(extract init_flavour)"
eval "$(extract power_links)"
eval "$(extract stamped_skip)"
eval "$(extract stamp_set)"
copper_identity() { :; }      # re-asserting /etc/os-release is not under test
eval "$(extract build_systemd)"

PATH="$STUB:$PATH"
export PATH

# Run build_systemd the way build.sh runs it: `set -euo pipefail`.
#
# Three things here are load-bearing and each one was a false green first:
#
# 1. build_systemd reports a bad stage the way every stage in build.sh does --
#    `exit 1`. That is correct in build.sh (it ends the script) and fatal in
#    this gate (it would end THIS script before anything is printed, while the
#    trap is about to delete the log holding the reason). So the call must not
#    be able to end the gate.
#
# 2. `set -e` is how the real build behaves, and without it the gate calls a
#    stage green that the real build cannot get through. The bare
#    `install ... *.network` bug is exactly that: with no matching file install
#    exits 1, and without errexit the next command succeeds and the stage
#    "passes". That was a real false green in this gate, caught by sabotage.
#
# 3. The flags have to be set in the process that DEFINES the function, not in
#    a subshell that calls it. `set -e` inside a subshell does not reach a
#    function defined in the parent -- bash captures the errexit state where
#    the function was defined -- so `( set -e; build_systemd )` runs the stage
#    with errexit off, reproducing false green 2 while looking correct. The
#    same trap applies to putting the call in an `if` condition, where bash
#    suppresses errexit for the whole condition. A fresh bash process with the
#    function defined inside it is the only form that is actually faithful.
#
# The runner is written to a file and its exit status read from that file's
# child, so a crash (a syntax error in the extracted function) is a failure and
# not a stale read.
RUN="$TMP/run-stage.sh"
{
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    extract init_flavour
    extract power_links
    extract stamped_skip
    extract stamp_set
    extract build_systemd
    echo 'copper_identity() { :; }'
    echo 'build_systemd'
} > "$RUN"
STAGE_RC="$TMP/stage.rc"
if bash "$RUN" > "$TMP/stage.log" 2>&1; then
    echo 0 > "$STAGE_RC"
else
    echo "$?" > "$STAGE_RC"
fi
if [ ! -s "$STAGE_RC" ]; then
    bad "build_systemd ran" "$(tr '\n' '|' < "$TMP/stage.log")"
elif [ "$(cat "$STAGE_RC")" = 0 ]; then
    ok "build_systemd ran (under set -euo pipefail, as build.sh does)"
else
    # Show WHY. The status alone is useless here: the stage's own error text is
    # in the log, and a gate that reports only "it failed" makes the next reader
    # re-run it by hand.
    bad "build_systemd ran" "$(tr '\n' '|' < "$TMP/stage.log")"
fi

# ----------------------------------------------------- 3. the staged tree ---
if [ "$(init_flavour "$TGT" 2>/dev/null)" = systemd ]; then
    ok "init_flavour reads the staged tree as systemd"
else
    bad "init_flavour reads the staged tree as systemd" "$(init_flavour "$TGT" 2>/dev/null)"
fi

eq_link() {   # eq_link <label> <path> <want>
    got=$(readlink "$2" 2>/dev/null || echo missing)
    if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "wanted $3, got $got"; fi
}

eq_link "sbin/init -> /lib/systemd/systemd" "$TGT/sbin/init" /lib/systemd/systemd
for cmd in reboot poweroff halt shutdown; do
    eq_link "sbin/$cmd -> systemctl"      "$TGT/sbin/$cmd"      /usr/bin/systemctl
    eq_link "usr/sbin/$cmd -> systemctl"  "$TGT/usr/sbin/$cmd"  /usr/bin/systemctl
done

# ---- 3a. power_links asks the tree which init it carries ---------------------
# This is the bug CI shipped and every gate here missed. The `iso` chain re-runs
# the desktop stages over the tree -- build_rootfs clobbers /etc/group, and the
# _seatd group is part of what those stages' skip guards ask about, so they
# re-run -- and each of them calls power_links. A power_links that always wrote
# busybox quietly undid the systemd flavour's systemctl links on the way to the
# disc, and the systemd ISO failed its own read-back gate:
#
#     iso: the ISO boots systemd but its power commands are wrong:
#          sbin/reboot -> /bin/busybox usr-sbin/reboot -> /bin/busybox ...
#
# The gate runs the systemd stage over a mocked tree, so it never sees the
# desktop stages re-run -- and a gate that cannot see the path cannot guard it.
# But the function that was wrong is power_links, and it can be exercised
# directly against a tree of each flavour: the question it has to answer is
# "which init does this tree carry", and both answers are checked here.
ptree() {   # ptree <dir> <what sbin/init points at>
    rm -rf "$1"; mkdir -p "$1/sbin" "$1/usr/sbin"
    ln -sf "$2" "$1/sbin/init"
}
PS="$TMP/power-systemd"; ptree "$PS" /lib/systemd/systemd
power_links "$PS"
for cmd in reboot poweroff halt shutdown; do
    eq_link "power_links on a systemd tree: sbin/$cmd -> systemctl" \
            "$PS/sbin/$cmd" /usr/bin/systemctl
    eq_link "power_links on a systemd tree: usr/sbin/$cmd -> systemctl" \
            "$PS/usr/sbin/$cmd" /usr/bin/systemctl
done
PB="$TMP/power-busybox"; ptree "$PB" /usr/bin/copper-init
power_links "$PB"
for cmd in reboot poweroff halt; do
    eq_link "power_links on a busybox tree: sbin/$cmd -> busybox" \
            "$PB/sbin/$cmd" /bin/busybox
    eq_link "power_links on a busybox tree: usr/sbin/$cmd -> busybox" \
            "$PB/usr/sbin/$cmd" /bin/busybox
done
eq_link "power_links on a busybox tree: usr/sbin/shutdown -> the wrapper" \
        "$PB/usr/sbin/shutdown" /sbin/shutdown

# ---- 3b. PID 1 resolves at the path /sbin/init names -----------------------
# The stage's own gate is `[ -x $TGT/lib/systemd/systemd ]`, and this is the
# check that would have gone red on the runner's second run. Copper's tree is
# not merged-usr, so a noble deb's usr/lib/systemd/systemd has to be reachable
# at /lib/systemd/systemd by the time the kernel execs it -- and usr/bin/systemd,
# which the deb ships as a symlink `../lib/systemd/systemd`, has to resolve too.
# A fixture that put PID 1 at payload/lib/systemd/systemd hid both. These read
# the tree, not the fixture: assert /lib/systemd/systemd exists as a regular
# executable file THROUGH whatever /lib/systemd is, and that the deb's own
# usr/bin/systemd link lands on it.
if [ -x "$TGT/lib/systemd/systemd" ] && [ -f "$TGT/lib/systemd/systemd" ]; then
    ok "lib/systemd/systemd resolves to a real executable (PID 1 is reachable)"
else
    bad "lib/systemd/systemd resolves to a real executable (PID 1 is reachable)" \
        "not an executable regular file: $(ls -ld "$TGT/lib/systemd/systemd" 2>&1)"
fi
if [ "$(readlink -f "$TGT/usr/bin/systemd" 2>/dev/null)" = \
     "$(readlink -f "$TGT/lib/systemd/systemd" 2>/dev/null)" ]; then
    ok "usr/bin/systemd (the deb's own link) resolves to the same PID 1"
else
    bad "usr/bin/systemd (the deb's own link) resolves to the same PID 1" \
        "usr/bin/systemd -> $(readlink -f "$TGT/usr/bin/systemd" 2>/dev/null)"
fi

# The fixture deliberately starts with a REAL empty lib/systemd directory (see
# the mkdir in the mock rootfs above). After the stage it must be a symlink to
# usr/lib/systemd: the bridge has to normalise a squatter, not skip past it. The
# executable check above would also catch a skip, but this names the mechanism,
# so a regression points at the guard rather than at the packages.
if [ -L "$TGT/lib/systemd" ] && [ "$(readlink "$TGT/lib/systemd")" = ../usr/lib/systemd ]; then
    ok "lib/systemd squatter normalised to a symlink at usr/lib/systemd"
else
    bad "lib/systemd squatter normalised to a symlink at usr/lib/systemd" \
        "$(ls -ld "$TGT/lib/systemd" 2>&1)"
fi


for want in \
    copper.target.wants/copper-tty-clear.service \
    copper.target.wants/copper-firstboot.service \
    copper.target.wants/copper-console.service \
    copper.target.wants/copper-seatd.service \
    copper.target.wants/copper-network.service \
    multi-user.target.wants/copper.target \
    sysinit.target.wants/systemd-udevd.service
do
    if [ -L "$TGT/etc/systemd/system/$want" ]; then
        ok "wired $want"
    else
        bad "wired $want" "not a symlink"
    fi
done

# The units must be present as real files at mode 644 -- a unit installed 0777
# is one systemd reads with a warning, and the source tree is 777 on Windows.
for u in copper.target copper-tty-clear.service copper-firstboot.service \
         copper-console.service copper-seatd.service copper-network.service; do
    f="$TGT/etc/systemd/system/$u"
    if [ ! -f "$f" ]; then
        bad "installed $u" "missing"
        continue
    fi
    m=$(stat -c '%a' "$f" 2>/dev/null || echo '?')
    if [ "$m" = 644 ]; then ok "installed $u (0644)"; else bad "installed $u" "mode $m"; fi
done

# copper-init has to survive: copper-console.service runs its --console half.
if [ -x "$TGT/usr/bin/copper-init" ]; then
    ok "copper-init kept for copper-console.service"
else
    bad "copper-init kept for copper-console.service" "missing or not executable"
fi

# ---- the seat: the binary and the group -----------------------------------
# Both were wrong on the first real boot. The unit named /usr/bin/seatd while
# noble installs /usr/sbin/seatd, so its ExecStart resolved to nothing; and the
# _seatd group was gone because a later build_rootfs overwrote /etc/group and
# the stage that appends the group skipped. These assert the two things the
# boot needed, in the tree the stage produced.
if [ -x "$TGT/usr/bin/seatd" ] || [ -x "$TGT/usr/sbin/seatd" ]; then
    ok "a seatd binary is present where copper-seatd.service searches"
else
    bad "a seatd binary is present where copper-seatd.service searches" \
        "neither /usr/bin/seatd nor /usr/sbin/seatd is executable"
fi
if grep -q '^_seatd:' "$TGT/etc/group"; then
    ok "/etc/group carries the _seatd group"
else
    bad "/etc/group carries the _seatd group" "$(cat "$TGT/etc/group" 2>&1 | tr '\n' '|')"
fi
# The unit must actually search both directories, the way copper-init.c does --
# a unit that hard-codes one is the bug this is guarding against, and reading
# the installed unit is the only way to see it.
if grep -q '/usr/bin/seatd' "$TGT/etc/systemd/system/copper-seatd.service" \
   && grep -q '/usr/sbin/seatd' "$TGT/etc/systemd/system/copper-seatd.service"; then
    ok "copper-seatd.service searches both /usr/bin and /usr/sbin"
else
    bad "copper-seatd.service searches both /usr/bin and /usr/sbin" \
        "$(grep ExecStart "$TGT/etc/systemd/system/copper-seatd.service" 2>&1 | tr '\n' '|')"
fi

# ---- ldconfig is masked ----------------------------------------------------
# The image has no ldconfig and no /etc/ld.so.cache; systemd's shipped unit
# fails every boot. It is masked (/dev/null), and that is asserted because a
# mask that silently failed to install is exactly the failure being fixed.
if [ "$(readlink "$TGT/etc/systemd/system/ldconfig.service" 2>/dev/null)" = /dev/null ]; then
    ok "ldconfig.service is masked (the image has no ldconfig)"
else
    bad "ldconfig.service is masked (the image has no ldconfig)" \
        "readlink says '$(readlink "$TGT/etc/systemd/system/ldconfig.service" 2>/dev/null || echo missing)'"
fi

# ---- the console clear -----------------------------------------------------
# The first thing a user sees after the kernel text is this unit's erase, and
# the whole value is the ORDER: clear before the units that print, or the status
# lines land on top of the kernel's scrollback and the boot reads as two screens.
# So both halves are asserted -- the helper is exec'd where the unit names it,
# and the ordering names the two things that paint on tty1.
if [ -x "$TGT/usr/bin/copper-tty-clear" ]; then
    ok "console-clear helper installed executable at /usr/bin/copper-tty-clear"
else
    bad "console-clear helper installed executable at /usr/bin/copper-tty-clear" \
        "$(ls -l "$TGT/usr/bin/copper-tty-clear" 2>&1)"
fi
if grep -qE '^ExecStart=/usr/bin/copper-tty-clear$' \
        "$TGT/etc/systemd/system/copper-tty-clear.service"; then
    ok "copper-tty-clear.service execs the helper"
else
    bad "copper-tty-clear.service execs the helper" \
        "$(grep ExecStart "$TGT/etc/systemd/system/copper-tty-clear.service" 2>&1 | tr '\n' '|')"
fi
# Before= must name at least the wizard: it is the thing that draws the form, and
# a clear that runs after it would erase the form a user is filling in.
if grep -qE '^Before=.*copper-firstboot\.service' \
        "$TGT/etc/systemd/system/copper-tty-clear.service"; then
    ok "copper-tty-clear.service is ordered before the wizard"
else
    bad "copper-tty-clear.service is ordered before the wizard" \
        "$(grep Before "$TGT/etc/systemd/system/copper-tty-clear.service" 2>&1 | tr '\n' '|')"
fi
# And it must NOT be ordered after the target it is also ordered before.
# `After=sysinit.target` together with `Before=systemd-udevd.service` is an
# ordering cycle, because systemd's own udevd unit is ordered before
# sysinit.target -- and a cycle on sysinit.target fails the boot's initial
# transaction outright. This line is worth having on its own: the transaction
# check above needs systemd-analyze, and a host without it skips the parse
# checks entirely (the dev box is Windows). This one reads the installed unit
# and needs nothing.
if grep -qE '^After=sysinit\.target' "$TGT/etc/systemd/system/copper-tty-clear.service"; then
    bad "copper-tty-clear.service is not ordered after sysinit.target" \
        "After=sysinit.target with Before=systemd-udevd.service is a cycle on sysinit.target"
else
    ok "copper-tty-clear.service is not ordered after sysinit.target (no cycle)"
fi
# And the script must actually emit the erase, not merely exist: read the
# sequence out of the installed file so a helper gutted to `exit 0` goes red.
if grep -q '033\[r' "$TGT/usr/bin/copper-tty-clear" \
   && grep -q '033\[2J' "$TGT/usr/bin/copper-tty-clear" \
   && grep -q '/dev/tty1' "$TGT/usr/bin/copper-tty-clear"; then
    ok "the clear helper writes the erase sequence to /dev/tty1"
else
    bad "the clear helper writes the erase sequence to /dev/tty1" \
        "$(grep -E '033|tty1' "$TGT/usr/bin/copper-tty-clear" 2>&1 | tr '\n' '|')"
fi

# The build-time verifier must not be left in the image. It is copied into the
# tree to be run chrooted and removed again; a leftover is the build host's
# libc riding into the ISO.
if [ -e "$TGT/usr/bin/systemd-analyze" ]; then
    bad "build-time systemd-analyze not left in the tree" "it is still there"
else
    ok "build-time systemd-analyze not left in the tree"
fi

# ----------------------------------------------------------- 4. the C half --
# --console is the migration's entry point into copper-init. If it stopped
# being recognised, copper-console.service would start PID-1 copper-init under
# systemd: it would install the power handlers, mount, and try to start a
# second seatd and dhcp client.
if grep -q -- '"--console"' "$ROOT/src-init/copper-init.c"; then
    ok "copper-init recognises --console"
else
    bad "copper-init recognises --console" "no match in iso/src-init/copper-init.c"
fi
if grep -q 'g_console_only' "$ROOT/src-init/copper-init.c"; then
    ok "the console path is gated (no mounts, no signals, no seeder)"
else
    bad "the console path is gated" "g_console_only not found"
fi

# ------------------------------------------- 5. the swap is VISIBLE to CI --
# The CI workflow builds the default ISO first, then runs this stage, then
# rebuilds the ISO as the systemd flavour. That last rebuild is guarded by
# build_iso's stamp, which hashes the staged tree with tree_hash(). If
# tree_hash could not see the swap the rebuild would be SKIPPED and CI would
# upload the busybox ISO as "copper-iso-systemd" -- a green run advertising a
# migration that never happened. The swap is symlinks, and the original
# tree_hash hashed only `find -type f`, so it could not see them: this check
# exists because that was a real hole, not a hypothetical one.
eval "$(extract tree_hash)"
thT=$(mktemp -d "$TMP/th.XXXXXX")
mkdir -p "$thT/sbin"
ln -sf /usr/bin/copper-init "$thT/sbin/init"
before=$(tree_hash "$thT")
ln -sf /lib/systemd/systemd  "$thT/sbin/init"      # symlink-only change
after=$(tree_hash "$thT")
if [ "$before" != "$after" ]; then
    ok "tree_hash sees the init swap (a rebuilt ISO cannot be stamp-skipped)"
else
    bad "tree_hash sees the init swap" \
        "a symlink-only change left the tree hash identical; build_iso would ship a stale flavour"
fi

# ------------------------------------- 6. the stage's dispatch line is right --
# CI runs `bash iso/build.sh systemd` as its own invocation. build_copper needs
# the toolchain build_musl exports ($CC/$CFLAGS), and section 2 cannot see that,
# because it calls build_systemd alone against an already-populated tree. So the
# dependency is checked where it actually lives: the dispatch case in build.sh.
#
# This is the check that would have caught the real failure this gate missed.
# On ubuntu-24.04 the systemd step died at `line 638: CC: unbound variable`
# after "==> copper built-ins", because `systemd)` did not list build_musl and
# the runner has no CC of its own. Every other compiling stage lists it; the
# diff that added `systemd)` left it out. Reading the case arm here means the
# gate fails on the same line CI fails on, without a runner.
line=$(grep -E '^[[:space:]]*systemd\)' "$BUILD" || true)
if [ -z "$line" ]; then
    bad "systemd stage is dispatched in build.sh" "no 'systemd)' case arm found"
else
    missing=""
    for dep in build_musl build_busybox build_rootfs build_copper; do
        case "$line" in
            *"$dep"*) ;;
            *) missing="$missing $dep" ;;
        esac
    done
    if [ -z "$missing" ]; then
        ok "systemd stage runs its prerequisites (build_musl, busybox, rootfs, copper)"
    else
        bad "systemd stage runs its prerequisites" \
            "the 'systemd)' dispatch line is missing:$missing"
    fi
fi

# require_toolchain is what turns a future omission into a sentence instead of
# an unbound-variable crash, so its presence is part of the contract too.
if grep -q '^require_toolchain()' "$BUILD" \
   && grep -q 'require_toolchain' <(sed -n '/^build_copper()/,/^}/p' "$BUILD"); then
    ok "build_copper fails loudly when the toolchain is absent"
else
    bad "build_copper fails loudly when the toolchain is absent" \
        "no require_toolchain guard in build_copper (a missing build_musl would crash on CC)"
fi

# --------------------------- 7. the stage's verify filter is version-stable --
# This is the second CI failure, and the one the gate's own green run missed:
# build_systemd's chrooted `systemd-analyze verify` kept any line naming the
# unit and dropped a DENY-list of known noise. That list was tuned on the dev
# box's systemd 261 and does not match 255's wording, so on the ubuntu-24.04
# runner a host-artifact line survived and the STAGE exited 1 -- "build_systemd
# ran" went red in the gate while `bash tests/systemd-gate.sh` was green here.
#
# Section 2 cannot catch it (it calls build_systemd, which only fails on 255),
# so the filter's CONTRACT is tested directly instead: run the stage's own
# filter expression over synthetic verify output and assert it accepts the two
# wordings of a real misplaced key and rejects the host-noise shapes. Version
# strings are inputs here, so this passes on whatever systemd the dev box has
# and fails the moment the filter goes back to a version-specific deny-list.
vfilter() {   # vfilter <unit> <line...> -> prints lines that would fail the unit
    ul=$1; shift
    printf '%s\n' "$@" \
      | grep -E "Unknown (key|lvalue|section)|Failed to parse|Empty (ExecStart|section)|not a valid" \
      | grep -F "$ul" || true
}

# The expression above must BE the stage's expression, not a copy of it that
# can drift. build_systemd's chrooted verify builds `left` with this exact
# regex; if someone weakens it back to a deny-list, the behavioural checks
# below would keep passing while the stage went red on CI again -- the original
# bug, one layer up. So assert the stage still carries the allow-list.
VF_RE='Unknown \(key\|lvalue\|section\)\|Failed to parse\|Empty \(ExecStart\|section\)\|not a valid'
if grep -q "grep -E \"$VF_RE\"" "$BUILD"; then
    ok "the stage's verify filter is the allow-list this gate tests"
else
    bad "the stage's verify filter is the allow-list this gate tests" \
        "build_systemd no longer filters verify output with the allow-list regex"
fi

# ---- and the stage checks for an ORDERING CYCLE, in one transaction -------
#
# The allow-list above is about a unit's own text: a key in the wrong section,
# a parse error, an empty ExecStart. A cycle is about the RELATIONSHIP between
# units, and it can only be seen when they are verified TOGETHER -- verified one
# at a time, every unit in the loop is perfect on its own. That is exactly how
# copper-tty-clear.service shipped ordered into a cycle on sysinit.target, and
# the stage had no check that could see it.
#
# The stage's copy of the pattern is asserted to be the gate's, for the same
# reason VF_RE is: three places answer this question (the gate's transaction
# check, the gate's test of the stage's check, and the stage itself), and
# three copies of an answer drift.
if grep -qF "grep -qiE '$CYC_RE'" "$BUILD"; then
    ok "the stage checks the units for an ordering cycle, in one transaction"
else
    bad "the stage checks the units for an ordering cycle, in one transaction" \
        "build_systemd has no ordering-cycle check; a cycle on sysinit.target would ship"
fi
# And the stage must give systemd-analyze more than one unit at a time,
# because that is the only way a cycle exists to be found.
if grep -qF 'verify $vlist' "$BUILD"; then
    ok "the stage verifies the units as one transaction (cycles are only visible there)"
else
    bad "the stage verifies the units as one transaction" \
        "build_systemd does not pass the whole unit set to one verify call"
fi

U1=copper-seatd.service
# real defects: 255 spells it "Unknown key name", 256+ dropped "name"
d255="/etc/systemd/system/$U1:12: Unknown key name 'SocketMode' in section 'Service', ignoring."
d261="/etc/systemd/system/$U1:12: Unknown key 'SocketMode' in section 'Service', ignoring."
dempty="/etc/systemd/system/$U1:5: Empty section [Service], ignoring."
dparse="/etc/systemd/system/$U1:3: Failed to parse file: bad assignment."
# host noise that must NOT fail the unit
nman="/etc/systemd/system/$U1:9: Can't show udhcpc(1), ignoring: No such file or directory"
ncmd="/etc/systemd/system/$U1:20: Command /usr/bin/seatd is not executable, ignoring."
ndep="Dependency failed. Failed to start /etc/systemd/system/$U1."
nmiss="/usr/lib/systemd/system/systemd-udev-settle.service: not found"

check_v() {   # check_v <label> <expect-nonempty> <lines...>
    _l=$1; _want=$2; shift 2
    _got=$(vfilter "$U1" "$@")
    if { [ "$_want" = yes ] && [ -n "$_got" ]; } \
       || { [ "$_want" = no ] && [ -z "$_got" ]; }; then
        ok "verify filter $_l"
    else
        bad "verify filter $_l" "got [$(printf '%s' "$_got" | tr '\n' '|')], wanted nonempty=$_want"
    fi
}
check_v "rejects a misplaced key, systemd 255 wording" yes "$d255"
check_v "rejects a misplaced key, systemd 256+ wording" yes "$d261"
check_v "rejects an empty section"                     yes "$dempty"
check_v "rejects a parse error"                        yes "$dparse"
check_v "ignores a missing man page (host)"            no  "$nman"
check_v "ignores 'Command ... is not executable' (host)" no "$ncmd"
check_v "ignores a dependency the host lacks"          no  "$ndep"
check_v "ignores noise about another unit"             no  "$nmiss"

# The cycle filter is a SEPARATE filter, and it is not scoped to a unit name.
# A cycle is a property of the whole transaction, and systemd decides which
# job it drops when it breaks one -- so the message can name any unit in the
# loop, and a filter that looked for one unit's name would miss it.
cycf() { printf '%s\n' "$@" | grep -iE "$CYC_RE" || true; }

# The three wordings systemd has used, all of which must be caught.
c255="sysinit.target: Found ordering cycle: systemd-udevd.service/start after copper-tty-clear.service/start after sysinit.target/start - after systemd-udevd.service"
c255b="sysinit.target: Unable to break cycle starting with sysinit.target/start"
c255c="Requested transaction contains an unfixable cyclic ordering dependency: Transaction order is cyclic. See system logs for details."
cunit="copper-tty-clear.service: Failed to create copper-tty-clear.service/start: Transaction order is cyclic. See system logs for details."

check_c() {   # check_c <label> <expect-nonempty> <lines...>
    _l=$1; _want=$2; shift 2
    _got=$(cycf "$@")
    if { [ "$_want" = yes ] && [ -n "$_got" ]; } \
       || { [ "$_want" = no ] && [ -z "$_got" ]; }; then
        ok "cycle filter $_l"
    else
        bad "cycle filter $_l" "got [$(printf '%s' "$_got" | tr '\n' '|')], wanted nonempty=$_want"
    fi
}
check_c "rejects 'Found ordering cycle'"          yes "$c255"
check_c "rejects 'Unable to break cycle'"         yes "$c255b"
check_c "rejects 'unfixable cyclic ordering'"     yes "$c255c"
check_c "rejects 'Transaction order is cyclic'"    yes "$cunit"
# and it must not fire on the noise a real verify prints
check_c "ignores 'Failed to parse'"               no  "$dparse"
check_c "ignores 'Command ... is not executable'" no  "$ncmd"
check_c "ignores 'not found'"                     no  "$nmiss"

# ---------------- 8. the desktop stages' skip guards still ask about seatd --
# build_gui and build_hypr decide whether a CACHED tree can be skipped. A
# guard that asks only about the desktop stack skips a tree that has LOST
# seatd -- or the _seatd group build_gui appends and build_rootfs' second
# pass clobbers -- and the tree that ships points copper-seatd.service at a
# binary that is not there. That is not hypothetical: the first boot found
# exactly that (bug 47 -- the unit named /usr/bin/seatd, and noble installs
# /usr/sbin/seatd), and the reason it shipped is that the guard had stopped
# asking.
#
# This gate runs the systemd stage over a mocked tree; it does not run
# build_gui or build_hypr, so there is no runtime path here to exercise. What
# can be checked -- and what is checked -- is the shipped condition itself,
# read out of build.sh rather than paraphrased. The window is the two lines
# before the skip call: that is where the guards' own conditions live.
if extract build_hypr | grep -B2 'stamped_skip "\$WORK/hypr.stamp"' \
     | grep -q 'name seatd -type f'; then
    ok "build_hypr's skip guard still checks for seatd"
else
    bad "build_hypr's skip guard still checks for seatd" \
        "the guard no longer asks whether the tree still has a seatd binary"
fi
if extract build_gui | grep -B2 'stamped_skip "\$WORK/gui.stamp"' \
     | grep -q '_seatd:'; then
    ok "build_gui's skip guard still checks for the _seatd group"
else
    bad "build_gui's skip guard still checks for the _seatd group" \
        "the guard no longer asks whether the tree still has the _seatd group"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "systemd migration gate: all checks passed"
    echo "(piece checks only -- a real boot is still the thing that closes it)"
    exit 0
fi
echo "systemd migration gate: $fails check(s) failed"
exit 1
