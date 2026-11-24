#!/bin/sh
# Prove the system bus, polkit daemon and session agent can meet.
# An agent alone is a promise: polkitd needs D-Bus activation, the messagebus
# and polkitd accounts, the setuid helper, and a rule naming wheel (the wizard's
# user is in neither sudo nor admin). Otherwise a prompt cannot authorise.
# Everything here is static; actual dbus-daemon binding needs a boot (bug 45).
# Run: sh tests/polkit-gate.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
INIT="$REPO/iso/src-init/copper-init.c"
PASSWD="$REPO/iso/rootfs-overlay/etc/passwd"
GROUP="$REPO/iso/rootfs-overlay/etc/group"
RULE="$REPO/iso/rootfs-overlay/etc/polkit-1/rules.d/10-copper-wheel.rules"
BUILD="$REPO/iso/build.sh"

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }

eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$2', got '$3'"; fi; }

for f in "$INIT" "$PASSWD" "$GROUP" "$RULE" "$BUILD"; do
    [ -f "$f" ] || { echo "  FAIL  $f does not exist"; exit 1; }
done

# First occurrence only: the caller wants an ordering witness, not a count.
line_of() { grep -n "$1" "$2" 2>/dev/null | head -n1 | cut -d: -f1; }

# ---- the bus starts, and starts before the shell -------------------------
if grep -q 'static void start_system_bus(void)' "$INIT"; then
    ok "copper-init has a system-bus starter"
else
    bad "copper-init has a system-bus starter" "no start_system_bus() in $INIT"
fi
if grep -q 'start_system_bus();' "$INIT"; then
    ok "run_session calls it"
else
    bad "run_session calls it" "nothing calls start_system_bus()"
fi
call_ctx=$(grep -B4 -n 'start_system_bus();' "$INIT" 2>/dev/null)
case "$call_ctx" in
    *'!g_console_only'*) ok "it is the PID-1 half only (not under --console)" ;;
    *) bad "it is the PID-1 half only (not under --console)" "$call_ctx" ;;
esac
bus=$(line_of 'start_system_bus();' "$INIT")
shell=$(line_of 'spawn_tty(1);' "$INIT")
if [ -n "$bus" ] && [ -n "$shell" ] && [ "$bus" -lt "$shell" ]; then
    ok "the bus is up before the login shell is spawned"
else
    bad "the bus is up before the login shell is spawned" \
        "call at ${bus:-?}, shell at ${shell:-?}"
fi
# --system selects system.conf and the socket; --fork leaves nothing to reap.
if grep -qE 'execl\(exe, "dbus-daemon", "--system", "--fork"' "$INIT"; then
    ok "it starts dbus-daemon --system --fork"
else
    bad "it starts dbus-daemon --system --fork" "the argv is different"
fi
if grep -qF 'mkdir("/run/dbus", 0755)' "$INIT" \
   && grep -qF '/run/dbus/system_bus_socket' "$INIT"; then
    ok "it makes /run/dbus and checks the socket it should have made"
else
    bad "it makes /run/dbus and checks the socket it should have made" \
        "no mkdir or no socket path"
fi

# The bus must look up messagebus before dropping privileges and polkitd after
# activation; the runtime writer is the repair path, overlay records the norm.
mb=$(line_of 'ensure_system_user("/etc/passwd", "/etc/group", "messagebus"' "$INIT")
pd=$(line_of 'ensure_system_user("/etc/passwd", "/etc/group", "polkitd"' "$INIT")
fork=$(line_of 'execl(exe, "dbus-daemon"' "$INIT")
if [ -n "$mb" ] && [ -n "$pd" ] && [ -n "$fork" ] \
   && [ "$mb" -lt "$fork" ] && [ "$pd" -lt "$fork" ]; then
    ok "both accounts are repaired before the bus starts"
else
    bad "both accounts are repaired before the bus starts" \
        "messagebus ${mb:-?}, polkitd ${pd:-?}, exec ${fork:-?}"
fi

pw_id()  { awk -F: -v n="$1" '$1 == n { print $3 }' "$PASSWD"; }
pw_gid() { awk -F: -v n="$1" '$1 == n { print $4 }' "$PASSWD"; }
gr_id()  { awk -F: -v n="$1" '$1 == n { print $3 }' "$GROUP"; }

for u in messagebus polkitd; do
    uid=$(pw_id "$u")
    gid=$(pw_gid "$u")
    ggid=$(gr_id "$u")
    if [ -n "$uid" ] && [ -n "$gid" ] && [ -n "$ggid" ] \
       && [ "$gid" = "$ggid" ] \
       && [ "$uid" -gt 100 ] && [ "$uid" -lt 1000 ] \
       && [ "$ggid" -gt 100 ] && [ "$ggid" -lt 1000 ]; then
        ok "the overlay ships $u:$uid:$gid with a matching group"
    else
        bad "the overlay ships $u:$uid:$gid with a matching group" \
            "passwd gid ${gid:-?}, group gid ${ggid:-?}"
    fi
done
if [ "$(pw_id messagebus)" != "$(pw_id polkitd)" ]; then
    ok "the two service accounts have different uids"
else
    bad "the two service accounts have different uids" "both are $(pw_id messagebus)"
fi

# ---- the helper the agent runs ------------------------------------------
if grep -qF 'usr/lib/polkit-1/polkit-agent-helper-1' "$BUILD"; then
    ok "the build knows the helper's real path"
else
    bad "the build knows the helper's real path" "not named in build.sh"
fi
fixes=$(grep -c 'chmod 4755 "$TGT/usr/lib/polkit-1/polkit-agent-helper-1"' "$BUILD" 2>/dev/null || true)
if [ "$fixes" -ge 2 ]; then
    ok "both the niri stage and the iso pin make it setuid root"
else
    bad "both the niri stage and the iso pin make it setuid root" \
        "$fixes chmod site(s), wanted at least 2"
fi
if grep -q 'extract /usr/lib/polkit-1/polkit-agent-helper-1' "$BUILD"; then
    ok "the ISO's mode is read back off the disc, not trusted from the tree"
else
    bad "the ISO's mode is read back off the disc, not trusted from the tree" \
        "no xorriso extract for the helper"
fi

# ---- the pieces polkitd activates ---------------------------------------
if grep -qF 'usr/share/dbus-1/system-services/org.freedesktop.PolicyKit1.service' "$BUILD"; then
    ok "the build requires polkitd's system-bus activation file"
else
    bad "the build requires polkitd's system-bus activation file" "not gated"
fi
if grep -qF 'usr/share/dbus-1/system.conf' "$BUILD"; then
    ok "the build requires the system bus's own configuration"
else
    bad "the build requires the system bus's own configuration" "not gated"
fi

# ---- polkit's idea of an administrator ----------------------------------
if grep -qF 'return ["unix-group:wheel"];' "$RULE"; then
    ok "polkit treats wheel as the admin group"
else
    bad "polkit treats wheel as the admin group" \
        "the rule does not return unix-group:wheel"
fi
base=$(basename "$RULE")
num=${base%%-*}
if [ -n "$num" ] && [ "$num" -lt 49 ]; then
    ok "the rule loads before Ubuntu's sudo/admin rules"
else
    bad "the rule loads before Ubuntu's sudo/admin rules" \
        "$base sorts at $num, after 49-ubuntu-admin.rules"
fi

# ---- the writer's own test ----------------------------------------------
if grep -q 'ensure_system_user(pwp, grp, "messagebus"' "$REPO/tests/init-session.c"; then
    ok "the account writer is exercised against a fixture"
else
    bad "the account writer is exercised against a fixture" \
        "init-session.c does not call it"
fi

if [ "$fails" -eq 0 ]; then
    echo "all polkit checks passed"
    exit 0
fi
echo "FAILED: $fails check(s)"
exit 1
