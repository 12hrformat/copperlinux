#!/usr/bin/env bash
# Sabotage suite for tests/systemd-gate.sh: plant one exact-string defect per case in a copy and assert the gate exits non-zero naming the right thing.
# Writing it found real gate bugs (silent exit, errexit in a subshell, SIGPIPE, cases red for their own reasons); a no-op edit is a broken test, not a pass.
# Root only (the gate chroots). Run: sudo tests/systemd-gate-sabotage.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)

if [ "$(id -u)" -ne 0 ]; then
    echo "tests/systemd-gate-sabotage.sh must run as root: sudo tests/systemd-gate-sabotage.sh" >&2
    exit 1
fi
if [ ! -f "$REPO/tests/systemd-gate.sh" ]; then
    echo "FAIL $REPO/tests/systemd-gate.sh does not exist" >&2
    exit 1
fi
command -v python3 >/dev/null 2>&1 || {
    echo "FAIL no python3 (used for exact-string sabotage edits)" >&2
    exit 1
}

fails=0

# edit <file> <old> <new> — exact, single replacement, or fail loudly.
edit() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
if old not in s:
    sys.exit("NO-MATCH: " + old[:60])
open(path, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
}

# run_case <label> <file> <old> <new> <expected-text>
run_case() {
    label=$1; file=$2; old=$3; new=$4; expect=$5
    T=$(mktemp -d /tmp/systemd-sabotage.XXXXXX) || exit 1
    cp -a "$REPO" "$T/repo"
    if ! msg=$(edit "$T/repo/$file" "$old" "$new" 2>&1); then
        echo "BROKEN sabotage (did not apply): $label -- $msg"
        fails=$((fails + 1)); rm -rf "$T"; return
    fi
    out=$(bash "$T/repo/tests/systemd-gate.sh" 2>&1); rc=$?
# $expect is a REGEX: systemd's wording moves between 255/256+, and a fixed string made a correct gate look broken.
# See case 1 for the run where a fixed expectation reported a hole the gate did not have.
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "$expect"; then
        echo "  ok    gate rejects: $label"
    else
        echo "  FAIL  gate MISSED: $label (rc=$rc, expected to see: $expect)"
        printf '%s\n' "$out" | grep -i "fail" | head -4 | sed 's/^/          /'
        fails=$((fails + 1))
    fi
    rm -rf "$T"
}

B=iso/build.sh
C=iso/src-init/copper-init.c
U=iso/systemd

echo "sabotaging the systemd migration, one defect at a time:"

# A misplaced key is a real error; deleting it is a valid unit the gate should pass.
# Deleting the key leaves a valid unit, and the gate would be right to pass it.
# The key has to genuinely be misplaced to be a defect.
T=$(mktemp -d /tmp/systemd-sabotage.XXXXXX); cp -a "$REPO" "$T/repo"
python3 - "$T/repo/$U/copper-console.service" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
assert 'StartLimitIntervalSec=0' in s
s = s.replace('StartLimitIntervalSec=0\n', '', 1)
s = s.replace('[Service]\n', '[Service]\nStartLimitIntervalSec=0\n', 1)
open(p, 'w', encoding='utf-8').write(s)
PY
out=$(bash "$T/repo/tests/systemd-gate.sh" 2>&1); rc=$?
# Match the key name, not systemd's changing "Unknown key (name)?" wording, so the suite does not report a hole the gate did not have.
# 255 says "Unknown key name 'X' in section 'Service'"; 256+ drops the word name.
# A fixed string made the case MISS on CI while the gate had in fact gone red.
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "Unknown key( name)? 'StartLimitIntervalSec'"; then
    echo "  ok    gate rejects: StartLimitIntervalSec genuinely in [Service]"
else
    echo "  FAIL  gate MISSED: StartLimitIntervalSec in [Service] (rc=$rc)"
    fails=$((fails + 1))
fi
rm -rf "$T"

# 2. A directive that does not exist at all.
run_case "SocketMode= (not a directive)" "$U/copper-seatd.service" \
    'RuntimeDirectory=seatd' \
    'RuntimeDirectory=seatd
SocketMode=0660' \
    "Unknown key( name)? 'SocketMode'"

# A bare *.network glob fails only under set -e, so this also proves the gate runs the stage with build.sh's flags.
# A bare `install ... *.network` with no matching file makes install exit 1.
# Under errexit that kills the stage; without it the next command succeeds and the stage passes.
run_case "bare *.network glob reinstated" "$B" \
    'for f in "$ROOT/systemd"/*.network; do' \
    'install -m 0644 "$ROOT/systemd"/*.network "$TGT/etc/systemd/network/"
  for f in "$ROOT/systemd"/*.network; do' \
    "build_systemd ran"

# 4. The swap itself not happening.
run_case "sbin/init not repointed to systemd" "$B" \
    'ln -sf /lib/systemd/systemd "$TGT/sbin/init"' \
    'true' \
    "init_flavour reads the staged tree as systemd"

# 5. A unit present but not wired into the target (a service that never starts).
run_case "copper-seatd.service left unwired" "$B" \
    'for u in copper-seatd.service copper-network.service copper-plymouth-quit.service copper-vmtools.service; do' \
    'for u in copper-network.service copper-plymouth-quit.service copper-vmtools.service; do' \
    "wired copper.target.wants/copper-seatd.service"

# --console removal would start PID-1 copper-init under systemd (mounts, signals, second seatd).
# copper-console.service would then start PID-1 copper-init under systemd.
# It would install power handlers, mount, and start a second seatd.
run_case "--console no longer recognised" "$C" \
    'strcmp(argv[1], "--console") == 0' \
    '0' \
    "copper-init recognises --console"

# Every re-run desktop stage calls power_links, so a busybox link there leaks into the systemd ISO.
# The wrapper links live in power_links, which the stage calls after swapping PID 1.
# One definition keeps the stage and later re-runs from disagreeing.
run_case "power commands left as busybox" "$B" \
    'ln -sf /sbin/shutdown "$root/sbin/$cmd"' \
    'ln -sf /bin/busybox "$root/sbin/$cmd"' \
    "sbin/reboot -> the wrapper"

# World-writable units get systemd warnings; the Windows source tree is 777.
# A world-writable unit is one systemd reads with a warning.
run_case "units installed 0777" "$B" \
    'install -m 0644 "$ROOT/systemd"/*.service "$TGT/etc/systemd/system/"' \
    'install -m 0777 "$ROOT/systemd"/*.service "$TGT/etc/systemd/system/"' \
    "installed copper-console.service"

# A leftover verifier carries the build host's libc into the ISO.
# The build host's libc riding into the ISO is the failure this prevents.
run_case "systemd-analyze left in the tree" "$B" \
    'while IFS= read -r f; do
      [ -n "$f" ] || continue
      rm -f "$TGT$f"
    done < "$added"' \
    ':' \
    "build-time systemd-analyze not left in the tree"

# A hash blind to symlinks would let CI report "systemd" while shipping busybox.
# CI builds the default first, runs this stage, then rebuilds as systemd behind a stamp.
# A blind hash would upload the busybox ISO under the systemd name.
run_case "tree_hash blind to the init swap" "$B" \
    '      find . -type l -printf '"'"'link %p -> %l\n'"'"' | LC_ALL=C sort' \
    '      :' \
    "tree_hash sees the init swap"

# Removing build_musl from the dispatch arm reproduced CI's unbound CC; section 2 calls build_systemd alone.
# CI saw 'line 638: CC: unbound variable' on the runner after 'copper built-ins'.
# The dispatch arm is the only place that shows the missing prerequisite.
run_case "systemd stage loses its toolchain prerequisite" "$B" \
    'systemd)    build_musl; build_busybox; build_rootfs' \
    'systemd)    build_rootfs' \
    "systemd stage runs its prerequisites"

# A deny-list tuned on systemd 261 kept host noise on 255 and failed the stage while the gate was green.
# A deny-list tuned on the dev box's 261 kept a host-artifact line on the runner's 255.
# That failed the build while local runs were green.
run_case "verify filter weakened to a version-specific deny-list" "$B" \
    '          | grep -E "Unknown (key|lvalue|section)|Failed to parse|Empty (ExecStart|section)|not a valid" \' \
    '          | grep -vE "Can'"'"'t show |failed with exit status|\(man\)" \' \
    "verify filter"

# A missing merged-usr bridge leaves the kernel nothing at /lib/systemd/systemd to exec; CI said "did not arrive" while the local fixture false-greened.
# Disable the whole outer condition: the fixture has a squatter, so neutering one branch would only remove dead code.
# CI said "39 packages unpacked (58M)" then "/lib/systemd/systemd did not arrive".
run_case "merged-usr bridge disabled entirely (PID 1 unreachable at /lib)" "$B" \
    '  if [ -x "$TGT/usr/lib/systemd/systemd" ]; then' \
    '  if false; then' \
    "lib/systemd/systemd resolves to a real executable"

# Second CI failure: the guard asked "is lib/systemd absent?", skipped the squatter and died claiming no packages.
# The guard asked 'is lib/systemd absent?' and answered no, so it skipped.
# The stage then died claiming the packages never arrived.
run_case "bridge no-ops when lib/systemd is already a real directory" "$B" \
    '      if [ ! -e "$TGT/lib/systemd/systemd" ]; then
        rm -rf "$TGT/lib/systemd"
        ln -sfn ../usr/lib/systemd "$TGT/lib/systemd"
        echo "  lib/systemd (real dir) -> usr/lib/systemd (merged-usr bridge)"' \
    '      if [ ! -e "$TGT/lib/systemd/systemd" ]; then
        echo "  (sabotage: squatter left in place)"' \
    "lib/systemd/systemd resolves to a real executable"

# Reinstating the old non-merged fixture must make case 13's bridge removal invisible: a fixture modelling the input wrongly certifies the wrong code.
# With the fake PID 1 at payload/lib/systemd/systemd, the stage's -x gate passes regardless.
# Dropping the bridge then goes unnoticed: the fixture certifies the wrong code.
if grep -q 'payload/usr/lib/systemd/systemd\|PD/usr/lib/systemd/systemd' \
        "$REPO/tests/systemd-gate.sh"; then
    echo "  ok    fixture models a real noble deb (PID 1 at usr/lib/systemd)"
else
    echo "  FAIL  fixture is not merged-usr-shaped; gate can false-green again"
    fails=$((fails + 1))
fi

# A boot found the unit pointing at a missing binary. Plant it in the fixture (the honest tree the stage sees), not in the assertion that catches it.
# Deleting it from the fixture makes the tree the stage sees honest.
# Planting it in the assertion would prove nothing; that assertion is the detector.
run_case "seatd binary missing from the tree" "tests/systemd-gate.sh" \
    '         usr/bin/seatd sbin/udhcpc bin/sh; do' \
    '         sbin/udhcpc bin/sh; do' \
    "no seatd binary at /usr/bin/seatd or /usr/sbin/seatd"

# build_rootfs clobbers the group build_gui appends; remove it from the fixture so the stage's assertion fires.
# build_gui appends the group, build_rootfs' second pass clobbers /etc/group.
# Removing the line from the fixture must make the assertion fire.
run_case "_seatd group lost from /etc/group" "tests/systemd-gate.sh" \
    "_seatd:x:999:\\n' \\" \
    "' \\" \
    "no _seatd group"

# Plant the hard-coded path after install by sabotaging the stage; the gate reads the installed unit.
# The gate reads the INSTALLED unit, not the source template.
# Sabotage the stage to write a hard-coded version after install.
run_case "copper-seatd.service hard-codes /usr/bin/seatd again" "$B" \
    'ln -sf /etc/systemd/system/copper.target \
         "$TGT/etc/systemd/system/multi-user.target.wants/copper.target"' \
    'ln -sf /etc/systemd/system/copper.target \
         "$TGT/etc/systemd/system/multi-user.target.wants/copper.target"
  printf '\''[Unit]\nDescription=Copper seat daemon (seatd)\nAfter=systemd-udev-settle.service\nBefore=copper-console.service\n[Service]\nType=simple\nExecStart=/usr/bin/seatd -g _seatd\nRestart=on-failure\nRuntimeDirectory=seatd\n[Install]\nWantedBy=copper.target\n'\'' > "$TGT/etc/systemd/system/copper-seatd.service"' \
    "copper-seatd.service searches both /usr/bin and /usr/sbin"

# No ldconfig here: leaving the unit unmasked is what put it in systemctl --failed on first boot.
# The image has no ldconfig and no /etc/ld.so.cache.
# systemd's own unit failed every boot and showed up in systemctl --failed.
run_case "ldconfig.service left unmasked" "$B" \
    'ln -sf /dev/null "$TGT/etc/systemd/system/ldconfig.service"' \
    ':' \
    "ldconfig.service is masked"

# A skip guard that drops its own guarantees rebuilds nothing and ships a tree pointing at a missing binary (bug 47).
# The gate does not run build_niri, so hold the shipped guard to its contract (section 8) instead.
# Section 8 of the gate holds the shipped guard to its contract.
run_case "niri skip guard blind to seatd" "$B" \
    '     && [ -n "$(find "$TGT/usr" -name seatd -type f -print -quit 2>/dev/null)" ] \
' \
    $'     && true \\\n' \
    "build_niri's skip guard still checks for seatd"

# Same shape as 20, for the _seatd group build_gui appends and build_rootfs clobbers.
# The group is appended by build_gui and clobbered by build_rootfs' second pass.
# A guard that stops asking skips the stage that would put it back.
run_case "gui skip guard blind to the _seatd group" "$B" \
    '     && grep -q '"'"'^_seatd:'"'"' "$TGT/etc/group" \
     && stamped_skip "$WORK/gui.stamp" "$SELF"; then' \
    '     && stamped_skip "$WORK/gui.stamp" "$SELF"; then' \
    "build_gui's skip guard still checks for the _seatd group"

# The shipped cycle: clear After=sysinit.target and Before=udevd, while udevd is Before=sysinit.target -- no boot.
# Per-unit verify missed it; only the transaction check can catch it.
# It fails the boot's initial transaction outright, not a degraded boot.
run_case "copper-tty-clear.service ordered into a cycle with sysinit.target" \
    "$U/copper-tty-clear.service" \
    'Before=sysinit.target systemd-udevd.service copper-firstboot.service copper-console.service' \
    'After=sysinit.target
Before=sysinit.target systemd-udevd.service copper-firstboot.service copper-console.service' \
    "form no ordering cycle"

# The stage runs on CI: a gate that only proves itself does not protect the build.
# The gate's own transaction check would see a planted cycle, but CI runs the stage.
# Removing the stage's check must go red.
T=$(mktemp -d /tmp/systemd-sabotage.XXXXXX); cp -a "$REPO" "$T/repo"
python3 - "$T/repo/$B" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "grep -qiE 'ordering cycle|cyclic ordering|order is cyclic|break cycle'"
assert old in s, "the stage's cycle check is not where it was expected"
s = s.replace(old, "grep -qiE 'nothing at all'", 1)
open(p, 'w', encoding='utf-8').write(s)
PY
out=$(bash "$T/repo/tests/systemd-gate.sh" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "stage checks the units for an ordering cycle"; then
    echo "  ok    gate rejects: the stage's ordering-cycle check disabled"
else
    echo "  FAIL  gate MISSED: the stage's ordering-cycle check disabled (rc=$rc)"
    printf '%s\n' "$out" | grep -i "fail" | head -4 | sed 's/^/          /'
    fails=$((fails + 1))
fi
rm -rf "$T"

# The fixture modelled a plain "Description=udev" unit, so the stage's cycle check was blind; noble's unit needs both lines.
# The old fixture said only 'Description=udev' and nothing else.
# The real noble unit needs DefaultDependencies=no and Before=sysinit.target; without both the stage is blind.
if grep -q 'Before=sysinit.target' "$REPO/tests/systemd-gate.sh" \
   && grep -q 'DefaultDependencies=no' "$REPO/tests/systemd-gate.sh"; then
    echo "  ok    fixture models systemd's own udevd unit (ordering included)"
else
    echo "  FAIL  fixture does not model systemd's udevd unit; the stage's cycle check is blind"
    fails=$((fails + 1))
fi

# One ISO boots either init: a link straight to systemctl talks to no systemd on a busybox boot.
# Every re-run desktop stage calls power_links, so this is where half-finished swaps leaked too.
# The `iso` chain re-runs desktop stages over the systemd tree, each calling power_links.
run_case "power_links links straight to systemctl" "$B" \
    'ln -sf /sbin/shutdown "$root/sbin/$cmd"' \
    'ln -sf /usr/bin/systemctl "$root/sbin/$cmd"' \
    "power_links on a systemd tree"

# The wizard runs first and did not claim tty1, so getty drew its banner over the form.
# The wizard runs FIRST (Before=copper-console.service), so the console's conflict never covered its window.
# getty@tty1.service drew its login banner over the form the user was filling in.
run_case "copper-firstboot.service no longer claims tty1 from getty" \
    "$U/copper-firstboot.service" \
    'Conflicts=getty@tty1.service
' \
    '#Conflicts=getty@tty1.service
' \
    "FAIL.*claims tty1 from getty"

# The other half of that pair, present before this suite existed.
# It was in the tree before this suite existed.
run_case "copper-console.service no longer claims tty1 from getty" \
    "$U/copper-console.service" \
    'Conflicts=getty@tty1.service
' \
    '#Conflicts=getty@tty1.service
' \
    "FAIL.*claims tty1 from getty"

# eth0 is a name, not a fact: no NIC means no network and an unexplained [FAILED] on the wizard's tty.
# eth0 holds only while it is the first NIC the kernel enumerates.
# With no wired NIC udhcpc exits non-zero and, with no Restart=, that is the end.
run_case "copper-network.service names an interface again" \
    "$U/copper-network.service" \
    'ExecStart=/usr/bin/copper-dhcp' \
    'ExecStart=/sbin/udhcpc -i eth0 -b -p /run/udhcpc.eth0.pid' \
    "FAIL.*execs the discovery helper"

# A unit naming a missing command fails silently.
# Removing the install line leaves the unit naming a command the image does not have.
# The unit never starts, silently, because a missing ExecStart is not a crash.
run_case "the stage stops installing the dhcp helper" \
    "$B" \
    '  install -D -m 0755 "$ROOT/systemd/copper-dhcp" \
          "$TGT/usr/bin/copper-dhcp"
' \
    '' \
    "FAIL.*dhcp helper installed executable"

# An unstamped helper edit made the stage skip and ship the PREVIOUS helper with a green light.
# The stage skips itself when its inputs still hash the same.
# Edit the helper, re-run, and the ISO shipped the PREVIOUS helper with a green light.
run_case "the stage stops stamping on the splash helper" \
    "$B" \
    '           "$ROOT/systemd/copper-splash-show" \
           "$ROOT/systemd/copper-splash-quit"; do' \
    '           "$ROOT/systemd/copper-splash-quit"; do' \
    "FAIL.*stamps on copper-splash-show"

# udhcpc and /bin/sh are what units exec; the verify filter treats "not executable" as host noise.
# /sbin/udhcpc is what the helper execs; /bin/sh is what the seatd unit's ExecStart runs.
# Either missing means a unit that can never start.
run_case "the stage stops asserting sbin/udhcpc is in the tree" \
    "$B" \
    'for cmd in usr/bin/copper-dhcp sbin/udhcpc bin/sh usr/sbin/plymouthd usr/bin/plymouth usr/bin/copper-zram usr/bin/copper-zram-stop; do' \
    'for cmd in usr/bin/copper-dhcp bin/sh; do' \
    "FAIL.*asserts sbin/udhcpc is in the tree"

# Host-side "not executable" is noise; inside the chroot it means the image is missing a binary.
# The allow-list is shared with the host-side parse check, where the line is genuinely noise.
# Inside the chroot the tree IS the machine, so it means the image lacks the binary.
run_case "the stage stops failing on a command the image does not have" \
    "$B" \
    'notexec="is not executable"' \
    'notexec="is nothing at all"' \
    "FAIL.*fails on a command the image does not have"

# No man pages ship, so Documentation=man: is a dead reference the migration document removed.
# The migration document removed the Documentation=file: lines for the same reason.
run_case "a Copper unit documents itself with something unreadable" \
    "$U/copper-network.service" \
    'Description=Copper DHCP client (busybox udhcpc)' \
    'Description=Copper DHCP client (busybox udhcpc)
Documentation=man:udhcpc(1)' \
    "FAIL.*carry no Documentation="

# ARPHRD_ETHER is what first_nonloop_iface asks for; any other type finds nothing and DHCP is skipped.
# first_nonloop_iface() in copper-init asks for exactly this type.
# Any other type finds nothing and DHCP is skipped on every machine.
run_case "the dhcp helper stops asking for ARPHRD_ETHER" \
    "$U/copper-dhcp" \
    'ether_type=1' \
    'ether_type=2' \
    "FAIL.*discovers the interface from sysfs"

echo
if [ "$fails" -eq 0 ]; then
    echo "sabotage suite: the gate catches every planted defect"
    exit 0
fi
echo "sabotage suite: $fails planted defect(s) NOT caught"
exit 1
