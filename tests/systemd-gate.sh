#!/usr/bin/env bash
# Gate for the systemd migration (SYSTEMD-MIGRATION.md, phase 1): unit parse, the real build_systemd stage on stubs, staged-tree assertions -- but no boot.
# Root only (it chroots). Run: sudo tests/systemd-gate.sh
# It proves what can be proved without a machine; SYSTEMD-MIGRATION.md carries the honest status line.
#

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

# One cycle wording shared by gate and stage (section 7): three copies of this answer drift.
# 255: "Found ordering cycle", "Unable to break cycle", "Transaction order is cyclic"; 256+ keeps first and third.
# Section 7 asserts the stage's copy matches, so the gate, the test and the stage cannot drift apart.
CYC_RE='ordering cycle|cyclic ordering|order is cyclic|break cycle'

TMP=$(mktemp -d /tmp/systemd-gate.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

# ---------------------------------------------------------------- 1. parse --
# systemd-analyze is the authority on keys/sections; copy units to 0644 first so a Windows 777 tree's world-writable warnings cannot skew the filter, and skip cleanly if absent.
# Modes are fixed FIRST in a private copy: systemd-analyze pairs its world-writable warning with the filename on the previous line.
if command -v systemd-analyze >/dev/null 2>&1; then
    UD="$TMP/units"; mkdir -p "$UD"
    install -m 0644 "$REPO"/iso/systemd/*.service "$UD/" 2>/dev/null || true
    install -m 0644 "$REPO"/iso/systemd/*.target  "$UD/" 2>/dev/null || true

# $UD must be on the unit search path or cross-unit Wants=/After= stay unresolved; the host path supplies sysinit.target, udevd and friends.
# Without it each unit was verified in isolation with half its dependencies missing, which is how a real cycle went unseen.
# The rest of the path is the host's, where sysinit.target and udevd live.
    UPATH="$UD:/etc/systemd/system:/run/systemd/system:/usr/local/lib/systemd/system:/usr/lib/systemd/system:/lib/systemd/system"

    for u in "$UD"/*.service "$UD"/*.target; do
        [ -e "$u" ] || continue
        out=$(SYSTEMD_UNIT_PATH="$UPATH" systemd-analyze verify "$u" 2>&1 || true)
# Allow-list, not a deny-list: one tuned on the dev box's 255 let host-only units (udev-settle, seatd/udhcpc paths) fail this unit on CI.
# Only unknown keys/sections, parse failures and empty ExecStart are unit defects; "not executable" and missing deps are the build host talking about itself.
# The old deny-list produced host-version-dependent verdicts: on 255 unrelated host units reported FAIL for green code.
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
# A cycle exists only between units: one-at-a-time verify saw copper-tty-clear.service as perfect while it was After=sysinit.target and Before=systemd-udevd.service, and udevd is Before=sysinit.target -- no boot.
# Include host getty@tty1/getty.target/multi-user.target: leaving udevd out once hid that same cycle. Don't scope the check to a unit; systemd may name any unit in the loop.
    out=$(SYSTEMD_UNIT_PATH="$UPATH" systemd-analyze verify \
              "$UD"/*.service "$UD"/*.target \
              getty@tty1.service getty.target multi-user.target 2>&1 || true)
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
# Mock rootfs and stub apt-get/dpkg-deb, then run the REAL build_systemd() out of iso/build.sh.
# The package tools are stubbed, but the function under test is the shipped one, not a paraphrase of it.
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
         usr/bin/seatd sbin/udhcpc bin/sh; do
    printf '#!/bin/sh\nexit 0\n' > "$TGT/$b"; chmod 0755 "$TGT/$b"
done
for b in usr/sbin/plymouthd usr/bin/plymouth; do
    printf '#!/bin/sh\nexit 0\n' > "$TGT/$b"; chmod 0755 "$TGT/$b"
done
# Units exec /sbin/agetty but Debian ships usr/sbin on this non-merged tree; without the bridge there is no login prompt on any VT or serial console.
# Without a real agetty the stage fails, which is the point: no agetty means no login prompt anywhere.
printf '#!/bin/sh\nexit 0\n' > "$TGT/usr/sbin/agetty"; chmod 0755 "$TGT/usr/sbin/agetty"
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

# The GUI closure leaves usr/lib/systemd populated and a real empty lib/systemd squats on the bridge name; the guard must normalise it or the stage dies claiming no packages.
# The fixture models that with a real empty lib/systemd squatter, the trap being `[ -d lib/systemd ]` reading true.
# A guard that only asked 'is lib/systemd absent?' declined to bridge and the stage died claiming no packages.
mkdir -p "$TGT/usr/lib/systemd/user" "$TGT/lib/systemd"
printf '[Unit]\nDescription=placeholder\n' > "$TGT/usr/lib/systemd/user/dconf.service"

# build_rootfs overwrites /etc/group and the appending stage skips, so the fixture must carry _seatd or the good run fails; sabotage deletes it.
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
# Model a real noble deb: PID 1 at usr/lib/systemd/systemd with usr/bin/systemd linking through /lib. A fixture putting it at payload/lib passed while real builds died.
# The old fixture used payload/lib/systemd/systemd, which no merged-usr deb has produced since merged-usr.
# That let the stage's -x gate pass while a real build died with '/lib/systemd/systemd did not arrive'.
printf '#!/bin/sh\nexit 0\n' > "$PD/usr/lib/systemd/systemd"; chmod 0755 "$PD/usr/lib/systemd/systemd"
ln -sf ../lib/systemd/systemd "$PD/usr/bin/systemd"
printf '#!/bin/sh\nexit 0\n' > "$PD/usr/bin/systemctl";  chmod 0755 "$PD/usr/bin/systemctl"
for u in sysinit.target multi-user.target getty.target; do
    printf '[Unit]\nDescription=%s\n' "$u" > "$PD/usr/lib/systemd/system/$u"
done
# Model noble's udev unit: DefaultDependencies=no stops systemd adding After=sysinit.target (which would fake a cycle with the Before= below), and Before=sysinit.target is the real cycle edge.
# The old fixture said only 'Description=udev', so the chrooted verify walked a graph the boot never builds.
# That is the same input-model trap as the PID 1 fixture, once more.
printf '[Unit]\nDescription=Rule-based Manager for Device Events and Files\nDefaultDependencies=no\nBefore=sysinit.target\n\n[Service]\nType=notify\nExecStart=/usr/lib/systemd/systemd-udevd\n' \
    > "$PD/usr/lib/systemd/system/systemd-udevd.service"
# Noble ships the settle unit; two Copper units order after it and would point at nothing without it.
# copper-firstboot.service and copper-seatd.service both order after it.
printf '[Unit]\nDescription=Wait for udev To Complete Device Initialization\nDefaultDependencies=no\nBefore=sysinit.target\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=udevadm settle\n' \
    > "$PD/usr/lib/systemd/system/systemd-udev-settle.service"
printf '[Unit]\nDescription=Trigger udev uevent handling\nDefaultDependencies=no\nBefore=sysinit.target\n\n[Service]\nType=oneshot\nExecStart=/usr/lib/systemd/systemd-udev-trigger\n' \
    > "$PD/usr/lib/systemd/system/systemd-udev-trigger.service"
# Settle execs udevadm by bare name, so it must be in the tree.
# The real udev package puts udevadm at /usr/bin; the unit execs it by bare name.
printf '#!/bin/sh\nexit 0\n' > "$PD/usr/bin/udevadm"; chmod 0755 "$PD/usr/bin/udevadm"
# The vendor ldconfig unit fails here (no ldconfig); the payload gives the mask a real name to shadow and sabotage something to read back.
# ExecStart=/sbin/ldconfig -X, exactly as the deb ships it.
# The payload carries the vendor unit so the mask has a real name to shadow.
printf '[Unit]\nDescription=Rebuild Dynamic Linker Cache\nConditionNeedsUpdate=/etc\n\n[Service]\nType=oneshot\nExecStart=/sbin/ldconfig -X\n' \
    > "$PD/usr/lib/systemd/system/ldconfig.service"
DEBDIR="$TMP/debs"; mkdir -p "$DEBDIR"
tar -C "$PD" -cf "$DEBDIR/systemd.deb" .
tar -C "$PD" -cf "$DEBDIR/udev.deb" .
tar -C "$PD" -cf "$DEBDIR/systemd-sysv.deb" .
export COPPER_TEST_DEB_DIR="$DEBDIR"

# Eval the repo's own functions so the gate fails when build_systemd changes; the separate bash process below is needed because errexit is captured where a function is defined.
# The extraction happens here so the code under test is literally this repo's build.sh.
# A fresh bash process below is needed because errexit is captured where a function is defined.
extract() { sed -n "/^$1()/,/^}/p" "$BUILD"; }
eval "$(extract init_flavour)"
eval "$(extract power_links)"
eval "$(extract stamped_skip)"
eval "$(extract stamp_set)"
copper_identity() { :; }      # re-asserting /etc/os-release is not under test
eval "$(extract build_systemd)"

PATH="$STUB:$PATH"
export PATH

# Run under `set -euo pipefail` in a fresh bash that DEFINES the functions there: a subshell or an `if` condition suppresses errexit and passed the bare-*.network bug, while the stage's `exit 1` must not end this gate.
# Write the runner to a file and read its status from a child, so a syntax error is a failure and not a stale read.
# Section 2's false-green history is why all three details matter: stage exit, errexit, and where the function is defined.
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
# Show the stage's log: the status alone makes the next reader re-run it by hand.
# Otherwise a reader must re-run the stage by hand to learn anything.
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
# Power commands link the wrapper, not systemctl: a direct link SIGTERMs its own client and leaves a half-stopped prompt.
# A direct systemctl link blocks until the transaction finishes and stops the unit the caller's shell belongs to.
# systemd SIGTERMs the client, the job cancels, and the machine hands back a half-stopped prompt.
for cmd in reboot poweroff halt; do
    eq_link "sbin/$cmd -> the wrapper"     "$TGT/sbin/$cmd"     /sbin/shutdown
    eq_link "usr/sbin/$cmd -> the wrapper" "$TGT/usr/sbin/$cmd" /sbin/shutdown
done
# shutdown is Copper's wrapper too: systemd-sysv's waits a minute on a bare call, so it must be a real file here, not a systemctl link.
# systemd-sysv's shutdown waits a minute on a bare invocation -- the 'sudo shutdown does not work' report.
# Its eventual /sbin/poweroff execs this same systemctl, so sbin/shutdown must be the real wrapper file.
if [ -f "$TGT/sbin/shutdown" ] && [ ! -L "$TGT/sbin/shutdown" ]; then
    ok "sbin/shutdown is the Copper wrapper (a real file)"
else
    bad "sbin/shutdown is the Copper wrapper (a real file)" \
        "$(ls -ld "$TGT/sbin/shutdown" 2>&1)"
fi
eq_link "usr/sbin/shutdown -> the wrapper" \
        "$TGT/usr/sbin/shutdown" /sbin/shutdown

# /sbin is a real directory here, so the units' /sbin/agetty name needs a link to usr/sbin or every getty restarts forever (the blank-VT report).
# getty@.service and serial-getty@.service exec /sbin/agetty, and Copper's /sbin is a real directory.
eq_link "sbin/agetty -> the tree's agetty" "$TGT/sbin/agetty" /usr/sbin/agetty

# ---- 3a. power_links asks the tree which init it carries ---------------------
# Desktop stages re-run over the tree and each calls power_links; one that always wrote busybox undid the systemd links on the way to the disc (CI's read-back failure).
# Exercise the function directly against both flavours: the question is which init the tree carries, and both answers are checked here.
ptree() {   # ptree <dir> <what sbin/init points at>
    rm -rf "$1"; mkdir -p "$1/sbin" "$1/usr/sbin"
    ln -sf "$2" "$1/sbin/init"
}
PS="$TMP/power-systemd"; ptree "$PS" /lib/systemd/systemd
power_links "$PS"
for cmd in reboot poweroff halt; do
    eq_link "power_links on a systemd tree: sbin/$cmd -> the wrapper" \
            "$PS/sbin/$cmd" /sbin/shutdown
    eq_link "power_links on a systemd tree: usr/sbin/$cmd -> the wrapper" \
            "$PS/usr/sbin/$cmd" /sbin/shutdown
done
if [ -f "$PS/sbin/shutdown" ] && [ ! -L "$PS/sbin/shutdown" ]; then
    ok "power_links on a systemd tree: sbin/shutdown is the wrapper"
else
    bad "power_links on a systemd tree: sbin/shutdown is the wrapper" \
        "$(ls -ld "$PS/sbin/shutdown" 2>&1)"
fi
eq_link "power_links on a systemd tree: usr/sbin/shutdown -> the wrapper" \
        "$PS/usr/sbin/shutdown" /sbin/shutdown
PB="$TMP/power-busybox"; ptree "$PB" /usr/bin/copper-init
power_links "$PB"
# One image boots either init, so both flavours get the same wrapper links and it picks the applet at runtime.
# The wrapper picks the busybox applet at runtime, so the links cannot be flavour-specific.
for cmd in reboot poweroff halt; do
    eq_link "power_links on a busybox tree: sbin/$cmd -> the wrapper" \
            "$PB/sbin/$cmd" /sbin/shutdown
    eq_link "power_links on a busybox tree: usr/sbin/$cmd -> the wrapper" \
            "$PB/usr/sbin/$cmd" /sbin/shutdown
done
if [ -f "$PB/sbin/shutdown" ] && [ ! -L "$PB/sbin/shutdown" ]; then
    ok "power_links on a busybox tree: sbin/shutdown is the wrapper"
else
    bad "power_links on a busybox tree: sbin/shutdown is the wrapper" \
        "$(ls -ld "$PB/sbin/shutdown" 2>&1)"
fi
eq_link "power_links on a busybox tree: usr/sbin/shutdown -> the wrapper" \
        "$PB/usr/sbin/shutdown" /sbin/shutdown

# ---- 3b. PID 1 resolves at the path /sbin/init names -----------------------
# Noble ships PID 1 under usr/lib; assert /lib/systemd/systemd resolves through the bridge and the deb's usr/bin/systemd link lands on it.
# The stage's own gate is `[ -x $TGT/lib/systemd/systemd ]`; these read the tree, not the fixture.
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

# The fixture starts with a real lib/systemd; it must end a symlink, so a skipped guard is named rather than a generic package failure.
# The mkdir in the mock rootfs leaves that squatter in place deliberately.
# The executable check above would also catch a skip, but this names the mechanism.
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
    copper.target.wants/copper-plymouth-quit.service \
    copper.target.wants/copper-vmtools.service \
    sysinit.target.wants/copper-plymouth.service \
    sysinit.target.wants/copper-zram.service \
    multi-user.target.wants/copper.target \
    sysinit.target.wants/systemd-udevd.service \
    getty.target.wants/getty@tty2.service \
    getty.target.wants/getty@tty3.service \
    getty.target.wants/getty@tty4.service \
    getty.target.wants/getty@tty5.service \
    getty.target.wants/getty@tty6.service
do
    if [ -L "$TGT/etc/systemd/system/$want" ]; then
        ok "wired $want"
    else
        bad "wired $want" "not a symlink"
    fi
done

# The splash needs an owner at sysinit and a quit ordered before wizard/console, so the hand-off direction is checked too.
# The daemon runs during sysinit so the first status line cannot scroll the splash away.
# Both units are wired, and the ordering to the console is the hand-off direction.
if [ -L "$TGT/etc/systemd/system/sysinit.target.wants/copper-plymouth.service" ]; then
    ok "wired sysinit.target.wants/copper-plymouth.service (splash starts at sysinit)"
else
    bad "wired sysinit.target.wants/copper-plymouth.service" "not a symlink; the splash has no owner"
fi
if [ -L "$TGT/etc/systemd/system/copper.target.wants/copper-plymouth-quit.service" ]; then
    ok "wired copper.target.wants/copper-plymouth-quit.service (splash quits before the console)"
else
    bad "wired copper.target.wants/copper-plymouth-quit.service" "not a symlink; the splash never gets told to quit"
fi
if grep -qE '^Before=.*copper-firstboot\.service' \
     "$TGT/etc/systemd/system/copper-plymouth-quit.service"; then
    ok "copper-plymouth-quit.service is ordered before the wizard"
else
    bad "copper-plymouth-quit.service is ordered before the wizard" \
        "$(grep Before "$TGT/etc/systemd/system/copper-plymouth-quit.service" 2>&1 | tr '\n' '|')"
fi
if grep -qE '^Before=.*copper-console\.service' \
     "$TGT/etc/systemd/system/copper-plymouth-quit.service"; then
    ok "copper-plymouth-quit.service is ordered before the console"
else
    bad "copper-plymouth-quit.service is ordered before the console" \
        "$(grep Before "$TGT/etc/systemd/system/copper-plymouth-quit.service" 2>&1 | tr '\n' '|')"
fi

# Helpers make the splash play all frames and leave the clock to wait; assert both are installed at the exact paths the units name.
# The quit helper makes the splash play all 150 frames instead of stopping on the first network beat.
# The show helper leaves the clock it can wait against; both are exec'd where the units name them.
for h in copper-splash-show copper-splash-quit; do
    if [ -x "$TGT/usr/bin/$h" ]; then
        ok "splash helper installed executable at /usr/bin/$h"
    else
        bad "splash helper installed executable at /usr/bin/$h" \
            "$(ls -l "$TGT/usr/bin/$h" 2>&1)"
    fi
done
if grep -qE '^ExecStartPost=-?/usr/bin/copper-splash-show$' \
        "$TGT/etc/systemd/system/copper-plymouth.service"; then
    ok "copper-plymouth.service shows the splash through the helper"
else
    bad "copper-plymouth.service shows the splash through the helper" \
        "$(grep ExecStart "$TGT/etc/systemd/system/copper-plymouth.service" 2>&1 | tr '\n' '|')"
fi
if grep -qE '^ExecStart=/usr/bin/copper-splash-quit$' \
        "$TGT/etc/systemd/system/copper-plymouth-quit.service"; then
    ok "copper-plymouth-quit.service quits through the helper"
else
    bad "copper-plymouth-quit.service quits through the helper" \
        "$(grep ExecStart "$TGT/etc/systemd/system/copper-plymouth-quit.service" 2>&1 | tr '\n' '|')"
fi
# The verbose and debug grub entries must not be covered by the splash.
if grep -qE '^ConditionKernelCommandLine=splash$' \
        "$TGT/etc/systemd/system/copper-plymouth.service"; then
    ok "copper-plymouth.service is conditional on the splash token"
else
    bad "copper-plymouth.service is conditional on the splash token" \
        "$(grep Condition "$TGT/etc/systemd/system/copper-plymouth.service" 2>&1 | tr '\n' '|')"
fi

# Units must be 0644: the source tree is 777 on Windows and systemd warns on world-writable units.
# A 0777 unit is one systemd reads with a warning.
for u in copper.target copper-tty-clear.service copper-firstboot.service \
         copper-console.service copper-seatd.service copper-network.service \
         copper-zram.service copper-plymouth.service copper-plymouth-quit.service \
         copper-vmtools.service; do
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
# First boot found the unit naming /usr/bin/seatd (noble installs /usr/sbin) and the _seatd group clobbered by build_rootfs.
# These assert the two things the boot needed, in the tree the stage produced.
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
# The installed unit must search both paths like copper-init.c; a hard-coded path is the bug this guards.
# Reading the installed unit is the only way to see it.
if grep -q '/usr/bin/seatd' "$TGT/etc/systemd/system/copper-seatd.service" \
   && grep -q '/usr/sbin/seatd' "$TGT/etc/systemd/system/copper-seatd.service"; then
    ok "copper-seatd.service searches both /usr/bin and /usr/sbin"
else
    bad "copper-seatd.service searches both /usr/bin and /usr/sbin" \
        "$(grep ExecStart "$TGT/etc/systemd/system/copper-seatd.service" 2>&1 | tr '\n' '|')"
fi

# ---- the display follows the VMware window --------------------------------
# resolutionKMS, not vmwgfx alone, refits the display to the host window; upstream disables it without Xorg, so tools.conf must enable it. A host without open-vm-tools is reported, not silently skipped.
# A host that carries no open-vm-tools builds an image without the daemon; saying so beats a silent skip.
if [ -x "$TGT/usr/bin/vmtoolsd" ] || [ -x "$TGT/usr/sbin/vmtoolsd" ]; then
    ok "vmtoolsd is present where copper-vmtools.service searches"
    if grep -qE '^[[:space:]]*enable[[:space:]]*=[[:space:]]*true' \
            "$TGT/etc/vmware-tools/tools.conf" 2>/dev/null; then
        ok "resolutionKMS is explicitly enabled in tools.conf"
    else
        bad "resolutionKMS is explicitly enabled in tools.conf" \
            "$(cat "$TGT/etc/vmware-tools/tools.conf" 2>&1 | tr '\n' '|')"
    fi
else
    printf '  note  open-vm-tools did not ship on this host; no display autofit in this image\n'
fi

# ---- ldconfig is masked ----------------------------------------------------
# No ldconfig/ld.so.cache here, so the vendor unit fails every boot; assert the mask installed.
# A mask that silently failed to install is exactly the failure being fixed.
if [ "$(readlink "$TGT/etc/systemd/system/ldconfig.service" 2>/dev/null)" = /dev/null ]; then
    ok "ldconfig.service is masked (the image has no ldconfig)"
else
    bad "ldconfig.service is masked (the image has no ldconfig)" \
        "readlink says '$(readlink "$TGT/etc/systemd/system/ldconfig.service" 2>/dev/null || echo missing)'"
fi

# ---- the console clear -----------------------------------------------------
# Clear must run before anything that paints tty1 or status lines land on kernel scrollback; read the installed helper and its ordering.
# Both halves are asserted: the helper path and the ordering naming the two things that paint tty1.
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
# Before= must name the wizard: a clear after it erases the form a user is filling in.
# Before= must name at least the wizard, the thing that draws the form.
if grep -qE '^Before=.*copper-firstboot\.service' \
        "$TGT/etc/systemd/system/copper-tty-clear.service"; then
    ok "copper-tty-clear.service is ordered before the wizard"
else
    bad "copper-tty-clear.service is ordered before the wizard" \
        "$(grep Before "$TGT/etc/systemd/system/copper-tty-clear.service" 2>&1 | tr '\n' '|')"
fi
# After=sysinit.target with Before=systemd-udevd.service is a cycle on sysinit.target that fails the initial transaction; this text-only check covers hosts without systemd-analyze.
# systemd's udevd unit is ordered before sysinit.target, so the loop closes and the initial transaction fails outright.
# The transaction check needs systemd-analyze, which a Windows dev box lacks; this one reads the installed unit and needs nothing.
if grep -qE '^After=sysinit\.target' "$TGT/etc/systemd/system/copper-tty-clear.service"; then
    bad "copper-tty-clear.service is not ordered after sysinit.target" \
        "After=sysinit.target with Before=systemd-udevd.service is a cycle on sysinit.target"
else
    ok "copper-tty-clear.service is not ordered after sysinit.target (no cycle)"
fi
# Read the installed helper so a copy gutted to `exit 0` goes red.
# The sequence is read out of the installed file, so a helper gutted to exit 0 goes red.
if grep -q '033\[r' "$TGT/usr/bin/copper-tty-clear" \
   && grep -q '033\[2J' "$TGT/usr/bin/copper-tty-clear" \
   && grep -q '/dev/tty1' "$TGT/usr/bin/copper-tty-clear"; then
    ok "the clear helper writes the erase sequence to /dev/tty1"
else
    bad "the clear helper writes the erase sequence to /dev/tty1" \
        "$(grep -E '033|tty1' "$TGT/usr/bin/copper-tty-clear" 2>&1 | tr '\n' '|')"
fi

# ---- the console owns tty1 -------------------------------------------------
# Wizard, console and getty@tty1 all claim the same tty; without Conflicts= getty draws over them. Both Copper units need it: measured with live systemd, dropping the job is not the same as stopping it after, and the wizard runs first.
# Without the conflict getty starts alongside them and draws a login banner over the wizard's form.
for u in copper-firstboot.service copper-console.service; do
    if grep -qE '^Conflicts=.*getty@tty1\.service' \
            "$TGT/etc/systemd/system/$u"; then
        ok "$u claims tty1 from getty"
    else
        bad "$u claims tty1 from getty" \
            "no Conflicts= against getty@tty1.service; getty would draw over the console"
    fi
done

# ---- the DHCP interface is discovered, not assumed -------------------------
# eth0 is a name, not a fact: no wired NIC means udhcpc exits and, without Restart=, no network. copper-init asks sysfs via first_nonloop_iface; the unit must exec the discovery helper.
# The busybox image never had this: copper-init asks sysfs with first_nonloop_iface, skipping tunnels.
if [ -x "$TGT/usr/bin/copper-dhcp" ]; then
    ok "dhcp helper installed executable at /usr/bin/copper-dhcp"
else
    bad "dhcp helper installed executable at /usr/bin/copper-dhcp" \
        "$(ls -l "$TGT/usr/bin/copper-dhcp" 2>&1)"
fi
if grep -qE '^ExecStart=/usr/bin/copper-dhcp$' \
        "$TGT/etc/systemd/system/copper-network.service"; then
    ok "copper-network.service execs the discovery helper"
else
    bad "copper-network.service execs the discovery helper" \
        "$(grep ExecStart "$TGT/etc/systemd/system/copper-network.service" 2>&1 | tr '\n' '|')"
fi
# A literal -i in ExecStart is the bug, wherever it sits.
# A literal interface in ExecStart is the bug wherever it sits.
if grep -qE '^ExecStart=.*[[:space:]]-i[[:space:]]' \
        "$TGT/etc/systemd/system/copper-network.service"; then
    bad "copper-network.service does not name an interface itself" \
        "$(grep ExecStart "$TGT/etc/systemd/system/copper-network.service" 2>&1 | tr '\n' '|')"
else
    ok "copper-network.service does not name an interface itself"
fi
# The helper itself must ask sysfs for ARPHRD_ETHER like first_nonloop_iface; the image is wired-only.
# A helper that names eth0 inside itself has moved the bug rather than fixed it.
# ARPHRD_ETHER is the point; a radio type would hand DHCP an interface with no supplicant.
if grep -q 'iface_type()' "$TGT/usr/bin/copper-dhcp" \
   && grep -q 'ether_type=1' "$TGT/usr/bin/copper-dhcp" \
   && ! grep -q 'radiotap' "$TGT/usr/bin/copper-dhcp"; then
    ok "the dhcp helper discovers the interface from sysfs"
else
    bad "the dhcp helper discovers the interface from sysfs" \
        "$(grep -E 'iface_type|ether_type|radiotap' "$TGT/usr/bin/copper-dhcp" 2>&1 | tr '\n' '|')"
fi
# Interfaces are not /dev nodes; the old gate was always false and silently skipped DHCP.
# devtmpfs never creates /dev/eth0, so the old `[ -e /dev/$ifname ]` gate was always false.
if grep -q -- '-e "/dev/\$ifname"' "$TGT/usr/bin/copper-dhcp"; then
    bad "the dhcp helper does not gate on a /dev node" \
        "$(grep '/dev/\$ifname' "$TGT/usr/bin/copper-dhcp" 2>&1 | tr '\n' '|')"
else
    ok "the dhcp helper does not gate on a /dev node"
fi
# -b lets the parent exit and cgroup cleanup kill the renewing child.
# With -b the parent exits after the lease and systemd's cgroup kills the daemonised child meant to renew it.
if grep -A2 '^exec /sbin/udhcpc' "$TGT/usr/bin/copper-dhcp" | grep -q -- ' -f '; then
    ok "the dhcp helper keeps udhcpc in the foreground (-f)"
else
    bad "the dhcp helper keeps udhcpc in the foreground (-f)" \
        "$(grep -A2 '^exec /sbin/udhcpc' "$TGT/usr/bin/copper-dhcp" 2>&1 | tr '\n' '|')"
fi

# ---- compressed swap, so a 4 GB machine can run the desktop ---------------
if [ -x "$TGT/usr/bin/copper-zram" ]; then
    ok "zram helper installed executable at /usr/bin/copper-zram"
else
    bad "zram helper installed executable at /usr/bin/copper-zram" \
        "$(ls -l "$TGT/usr/bin/copper-zram" 2>&1)"
fi
if grep -qE '^ExecStart=/usr/bin/copper-zram$' \
        "$TGT/etc/systemd/system/copper-zram.service"; then
    ok "copper-zram.service execs the zram helper"
else
    bad "copper-zram.service execs the zram helper" \
        "$(grep ExecStart "$TGT/etc/systemd/system/copper-zram.service" 2>&1 | tr '\n' '|')"
fi
if grep -q 'swapon /dev/zram0' "$TGT/usr/bin/copper-zram"; then
    ok "the zram helper actually swaps the device on"
else
    bad "the zram helper actually swaps the device on" \
        "$(grep -n swapon "$TGT/usr/bin/copper-zram" 2>&1 | tr '\n' '|')"
fi

# ---- the shutdown is bounded (the ~10 minute `sudo reboot`) ----------------
# systemd-shutdown's swapoff_all() has no timeout, so zram must be gone in the unit's bounded ExecStop before it runs.
# swapoff_all() reads /proc/swaps after the unit phase, so the swap must be gone before that in a bounded ExecStop.
if [ -x "$TGT/usr/bin/copper-zram-stop" ]; then
    ok "zram stop helper installed executable at /usr/bin/copper-zram-stop"
else
    bad "zram stop helper installed executable at /usr/bin/copper-zram-stop" \
        "$(ls -l "$TGT/usr/bin/copper-zram-stop" 2>&1)"
fi
if grep -q 'swapoff /dev/zram0' "$TGT/usr/bin/copper-zram-stop"; then
    ok "the stop helper actually deactivates /dev/zram0"
else
    bad "the stop helper actually deactivates /dev/zram0" \
        "$(grep -n swapoff "$TGT/usr/bin/copper-zram-stop" 2>&1 | tr '\n' '|')"
fi
if grep -q 'drop_caches' "$TGT/usr/bin/copper-zram-stop"; then
    ok "the stop helper frees page cache before swapoff"
else
    bad "the stop helper frees page cache before swapoff" \
        "without it swapoff reclaims while it runs; that is the stall"
fi
if grep -qx 'ExecStop=-/usr/bin/copper-zram-stop' \
        "$TGT/etc/systemd/system/copper-zram.service"; then
    ok "copper-zram.service drains swap in its own stop job"
else
    bad "copper-zram.service drains swap in its own stop job" \
        "$(grep ExecStop "$TGT/etc/systemd/system/copper-zram.service" 2>&1 | tr '\n' '|')"
fi
# DefaultDependencies=no removes shutdown.target's implicit edges; the explicit pair is what gives these units a stop job.
# Without the explicit Conflicts= and Before= pair these units have no stop job at all.
# The helper above is then never reached.
for u in copper-zram.service copper-plymouth.service; do
    if grep -qx 'Conflicts=shutdown.target' "$TGT/etc/systemd/system/$u" \
       && grep -qx 'Before=shutdown.target' "$TGT/etc/systemd/system/$u"; then
        ok "$u is in the shutdown transaction (DefaultDependencies=no trap)"
    else
        bad "$u is in the shutdown transaction (DefaultDependencies=no trap)" \
            "$(grep -E '^(Conflicts|Before)=' "$TGT/etc/systemd/system/$u" 2>&1 | tr '\n' '|')"
    fi
done
# The manager-wide cap on every other unit's stop.
if [ -f "$TGT/etc/systemd/system.conf.d/copper-shutdown.conf" ] \
   && grep -qx 'DefaultTimeoutStopSec=10s' \
          "$TGT/etc/systemd/system.conf.d/copper-shutdown.conf"; then
    ok "the manager-wide stop timeout is capped at 10 s"
else
    bad "the manager-wide stop timeout is capped at 10 s" \
        "$(cat "$TGT/etc/systemd/system.conf.d/copper-shutdown.conf" 2>&1 | tr '\n' '|')"
fi
if [ "$(stat -c '%a' "$TGT/etc/systemd/system.conf.d/copper-shutdown.conf" 2>/dev/null)" = 644 ]; then
    ok "the system.conf.d drop-in is mode 644"
else
    bad "the system.conf.d drop-in is mode 644" \
        "$(ls -l "$TGT/etc/systemd/system.conf.d/copper-shutdown.conf" 2>&1)"
fi
# The console cgroup's own bound stops a wedged compositor from holding shutdown.target.
# The desktop lives in the console unit's cgroup, so a per-unit bound is what releases shutdown.target.
if grep -qx 'KillMode=mixed' "$TGT/etc/systemd/system/copper-console.service" \
   && grep -qx 'TimeoutStopSec=5s' "$TGT/etc/systemd/system/copper-console.service"; then
    ok "copper-console.service stops its cgroup in 5 s"
else
    bad "copper-console.service stops its cgroup in 5 s" \
        "$(grep -E '^(KillMode|TimeoutStopSec)=' "$TGT/etc/systemd/system/copper-console.service" 2>&1 | tr '\n' '|')"
fi

if [ -f "$TGT/etc/systemd/journald.conf" ] \
   && grep -qE '^RuntimeMaxUse=' "$TGT/etc/systemd/journald.conf"; then
    ok "journald is capped (the live image has no journal to keep)"
else
    bad "journald is capped (the live image has no journal to keep)" \
        "$(cat "$TGT/etc/systemd/journald.conf" 2>&1 | tr '\n' '|')"
fi

# ---- no Documentation= the image cannot open --------------------------------
# No man pages ship, so Documentation=man:... is a dead reference systemd-analyze reports on every build.
# The migration document already dropped the Documentation=file: lines for the same reason.
if grep -qE '^Documentation=' "$TGT/etc/systemd/system/copper-"*.service 2>/dev/null; then
    bad "the Copper units carry no Documentation= the image cannot open" \
        "$(grep -H '^Documentation=' "$TGT/etc/systemd/system/copper-"*.service 2>&1 | tr '\n' '|')"
else
    ok "the Copper units carry no Documentation= the image cannot open"
fi

# The chrooted verifier is copied in and removed; a leftover carries the build host's libc into the ISO.
# It is copied into the tree to be run chrooted, then removed again.
if [ -e "$TGT/usr/bin/systemd-analyze" ]; then
    bad "build-time systemd-analyze not left in the tree" "it is still there"
else
    ok "build-time systemd-analyze not left in the tree"
fi

# ----------------------------------------------------------- 4. the C half --
# --console is the entry point: if unrecognised, copper-console.service starts PID-1 copper-init under systemd, which mounts and starts a second seatd/DHCP.
# It would install power handlers, mount, and try to start a second seatd and dhcp client.
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
# CI rebuilds the systemd ISO behind tree_hash's stamp; a hash blind to symlinks skipped it and uploaded the busybox ISO as "copper-iso-systemd".
# The original tree_hash hashed only `find -type f`, so symlinks were invisible and the rebuild skipped -- a real hole.
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
# Check the dispatch arm, not just build_systemd: section 2 calls it alone and cannot see build_copper's $CC need. CI's `systemd)` arm omitted build_musl and died on an unbound CC.
# CI failed at 'line 638: CC: unbound variable' because the systemd arm omitted build_musl while every other compiling stage lists it.
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
# A DENY-list tuned on systemd 261 kept host noise on 255 and failed the stage on CI while this gate was green; section 2 cannot see it. Test the filter's contract against both wordings as synthetic input.
# Section 2 cannot catch it: it runs build_systemd, which only fails on 255, while the gate here stays green.
vfilter() {   # vfilter <unit> <line...> -> prints lines that would fail the unit
    ul=$1; shift
    printf '%s\n' "$@" \
      | grep -E "Unknown (key|lvalue|section)|Failed to parse|Empty (ExecStart|section)|not a valid" \
      | grep -F "$ul" || true
}

# Assert the stage still uses this allow-list, or the behavioural checks pass while CI goes red again.
# build_systemd's chrooted verify builds `left` with this exact regex.
# If it is weakened back to a deny-list, the behavioural checks keep passing while the stage goes red on CI again.
VF_RE='Unknown \(key\|lvalue\|section\)\|Failed to parse\|Empty \(ExecStart\|section\)\|not a valid'
if grep -q "grep -E \"$VF_RE\"" "$BUILD"; then
    ok "the stage's verify filter is the allow-list this gate tests"
else
    bad "the stage's verify filter is the allow-list this gate tests" \
        "build_systemd no longer filters verify output with the allow-list regex"
fi

# ---- the stage stamps on the helpers it installs ---------------------------
# Helpers in iso/systemd/ are stamp inputs; omitting one let an edit ship the PREVIOUS helper with a green light. Read the list from source, not a copy.
# Reading the input list from source means a dropped helper is a change in the thing under test, not in a copy.
sdin_block() { sed -n '/^  local sdin=/,/^  done$/p' "$BUILD"; }
SB=$(sdin_block)
for h in copper-tty-clear copper-dhcp copper-zram copper-zram-stop \
         copper-splash-show copper-splash-quit \
         system.conf.d; do
    if printf '%s\n' "$SB" | grep -q "systemd/$h"; then
        ok "the systemd stage stamps on $h"
    else
        bad "the systemd stage stamps on $h" \
            "iso/systemd/$h is installed by the stage but is not one of its stamp inputs"
    fi
done

# ---- the stage asserts the commands the units name are in the tree ---------
# A unit naming a missing ExecStart fails silently. Read build_systemd's own `for cmd in` loop (other loops exist) rather than grepping names that also appear in comments.
# The names also appear in comments, so grepping the file would pass on a stage that had stopped asserting one.
STAGE_EXEC_LOOPS=$(extract build_systemd | grep -oE 'for cmd in [^;]+;')
for c in usr/bin/copper-dhcp sbin/udhcpc bin/sh usr/bin/copper-zram usr/bin/copper-zram-stop; do
    if printf '%s\n' "$STAGE_EXEC_LOOPS" | grep -qF "$c"; then
        ok "the stage asserts $c is in the tree"
    else
        bad "the stage asserts $c is in the tree" \
            "build_systemd's assertion loop does not cover $c: $STAGE_EXEC_LOOPS"
    fi
done
if grep -qF '[ ! -x "$TGT/$cmd" ]' "$BUILD"; then
    ok "the stage's assertion loop checks that the command is executable"
else
    bad "the stage's assertion loop checks that the command is executable" \
        "build_systemd does not test that the command is executable"
fi

# ---- and inside the chroot, a missing command is a defect ------------------
# In the chroot the tree IS the machine: "not executable" means a missing image binary, not host noise.
# The build host has none of Copper's binaries, so host-side 'not executable' is noise; the chroot needs its own rule.
if grep -qF 'notexec="is not executable"' "$BUILD"; then
    ok "the stage fails on a command the image does not have"
else
    bad "the stage fails on a command the image does not have" \
        "build_systemd's chrooted verify does not treat 'is not executable' as a defect"
fi

# ---- and the stage checks for an ORDERING CYCLE, in one transaction -------
# Cycles need the whole transaction verified at once; one-unit-at-a-time verification hid the sysinit.target cycle. Keep this pattern identical to the gate's and the stage's.
# copper-tty-clear.service shipped in a cycle on sysinit.target because the stage had no check that could see it.
if grep -qF "grep -qiE '$CYC_RE'" "$BUILD"; then
    ok "the stage checks the units for an ordering cycle, in one transaction"
else
    bad "the stage checks the units for an ordering cycle, in one transaction" \
        "build_systemd has no ordering-cycle check; a cycle on sysinit.target would ship"
fi
# One verify call over all units is the only way a cycle is visible.
# verify $vlist is the only form that puts the whole unit set in one transaction.
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

# Cycle messages are not unit-scoped: systemd may name any unit in the loop.
# A cycle is a property of the whole transaction, and systemd decides which job it drops when it breaks one.
# A filter scoped to one unit's name would miss the message.
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
# Skip guards that stop asking about seatd / _seatd ship a tree whose unit points at a missing binary (bug 47). This gate only reads the shipped conditions from build.sh.
# The window is the two lines before the skip call, where the guards' own conditions live.
if extract build_niri | grep -B2 'stamped_skip "\$WORK/niri.stamp"' \
     | grep -q 'name seatd -type f'; then
    ok "build_niri's skip guard still checks for seatd"
else
    bad "build_niri's skip guard still checks for seatd" \
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
