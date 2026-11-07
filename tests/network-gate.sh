#!/bin/sh
# Prove the DHCP lease script always leaves the box with a working resolver.
#
# This exists because a real ISO shipped a lease script that wrote
# /etc/resolv.conf only when the lease carried a search domain. A normal
# lease has no domain, so the file stayed as the shipped fallback --
# 1.1.1.1 and 9.9.9.9 -- and on a network that blocks public DNS every
# lookup died as "bad address", which is what took `ingot install` down.
#
# The script hardcodes /etc/resolv.conf, so the test copies it and rewrites
# that one line into a scratch directory. `ip` is a stub that records its
# arguments, which is also how the netmask-to-prefix arithmetic is checked
# without touching the host's interfaces.
#
# Run: sh tests/network-gate.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO/iso/rootfs-overlay/usr/share/udhcpc/default.script"
FALLBACK="$REPO/iso/rootfs-overlay/etc/resolv.conf"

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }

[ -f "$SCRIPT" ] || { echo "  FAIL  $SCRIPT is missing"; exit 1; }
[ -f "$FALLBACK" ] || { echo "  FAIL  $FALLBACK is missing"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
IPLOG="$TMP/ip.log"
: > "$IPLOG"

# Stand-in for ip(8): the test cares what the script asked for, not whether
# this host can configure an interface. `route del` has to fail, or the
# script's "while ip route del default" loop never ends -- real ip(8) exits
# non-zero once there is no default route left to delete.
cat > "$TMP/bin/ip" <<'EOF'
#!/bin/sh
echo "$*" >> "$IPLOG"
case "$*" in
    "route del"*) exit 1 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/ip"

# The script under test, with only its resolver path redirected.
sed "s|^RESOLV_CONF=/etc/resolv.conf\$|RESOLV_CONF=$TMP/resolv.conf|" \
    "$SCRIPT" > "$TMP/lease"
chmod +x "$TMP/lease"

run_lease() {   # run_lease <state> [assignment...]
    state=$1; shift
    rm -f "$TMP/resolv.conf"
    : > "$IPLOG"
    env -i PATH="$TMP/bin:/usr/bin:/bin" IPLOG="$IPLOG" "$@" \
        sh "$TMP/lease" "$state" >"$TMP/out" 2>&1
    rc=$?
}

# ---- the bug: a lease with no search domain still gets a resolver ----------
run_lease bound interface=eth0 ip=10.0.2.15 subnet=255.255.255.0 \
    broadcast=10.0.2.255 router=10.0.2.2 dns=10.0.2.3
if [ "$rc" -eq 0 ] && [ -s "$TMP/resolv.conf" ] \
   && grep -qx 'nameserver 10.0.2.3' "$TMP/resolv.conf"; then
    ok "a lease with no domain still writes the DHCP nameserver"
else
    bad "a lease with no domain still writes the DHCP nameserver" \
        "rc $rc, resolv.conf: $(cat "$TMP/resolv.conf" 2>/dev/null | tr '\n' ' ')"
fi
if grep -qx 'nameserver 1.1.1.1' "$TMP/resolv.conf" 2>/dev/null \
   && grep -qx 'nameserver 9.9.9.9' "$TMP/resolv.conf" 2>/dev/null; then
    ok "the public fallbacks are kept alongside it"
else
    bad "the public fallbacks are kept alongside it" \
        "$(cat "$TMP/resolv.conf" 2>/dev/null | tr '\n' ' ')"
fi

# ---- a lease with a domain keeps the search line ---------------------------
run_lease renew interface=eth0 ip=10.0.2.15 subnet=255.255.255.0 \
    router=10.0.2.2 dns=10.0.2.3 domain=lan.example
if grep -qx 'search lan.example' "$TMP/resolv.conf" 2>/dev/null; then
    ok "a lease with a domain records its search domain"
else
    bad "a lease with a domain records its search domain" \
        "$(cat "$TMP/resolv.conf" 2>/dev/null | tr '\n' ' ')"
fi

# ---- a lease with no DNS at all still leaves the fallback ------------------
run_lease bound interface=eth0 ip=10.0.2.15 subnet=255.255.255.0 \
    router=10.0.2.2 dns=
if grep -qx 'nameserver 1.1.1.1' "$TMP/resolv.conf" 2>/dev/null \
   && grep -qx 'nameserver 9.9.9.9' "$TMP/resolv.conf" 2>/dev/null; then
    ok "a lease that carries no nameserver still leaves the fallback"
else
    bad "a lease that carries no nameserver still leaves the fallback" \
        "$(cat "$TMP/resolv.conf" 2>/dev/null | tr '\n' ' ')"
fi

# ---- a server that repeats a public resolver does not get two lines --------
run_lease bound interface=eth0 ip=10.0.2.15 subnet=255.255.255.0 \
    router=10.0.2.2 dns="1.1.1.1 10.0.2.3"
n=$(grep -cx 'nameserver 1.1.1.1' "$TMP/resolv.conf" 2>/dev/null || true)
if [ "$n" = 1 ] && grep -qx 'nameserver 10.0.2.3' "$TMP/resolv.conf"; then
    ok "a repeated public resolver is written once"
else
    bad "a repeated public resolver is written once" \
        "$n copies of 1.1.1.1"
fi

# ---- the netmask becomes a prefix length ----------------------------------
for mask in 255.255.255.0:24 255.255.0.0:16 255.0.255.0:24 none:24; do
    want=${mask##*:}
    mask=${mask%%:*}
    [ "$mask" = none ] && mask=
    run_lease bound interface=eth0 ip=10.0.2.15 subnet="$mask" \
        router=10.0.2.2 dns=10.0.2.3
    if grep -q "addr add 10.0.2.15/$want " "$IPLOG"; then
        ok "netmask '${mask:-none}' installs a /$want address"
    else
        bad "netmask '${mask:-none}' installs a /$want address" \
            "$(grep 'addr add' "$IPLOG" 2>/dev/null || echo 'no addr add')"
    fi
done

# ---- deconfig must not wipe the resolver ----------------------------------
run_lease bound interface=eth0 ip=10.0.2.15 subnet=255.255.255.0 \
    router=10.0.2.2 dns=10.0.2.3
before=$(cat "$TMP/resolv.conf" 2>/dev/null)
: > "$IPLOG"
env -i PATH="$TMP/bin:/usr/bin:/bin" IPLOG="$IPLOG" interface=eth0 \
    sh "$TMP/lease" deconfig >"$TMP/out" 2>&1
if [ -n "$before" ] && [ "$(cat "$TMP/resolv.conf" 2>/dev/null)" = "$before" ]; then
    ok "deconfig leaves the resolver alone"
else
    bad "deconfig leaves the resolver alone" \
        "before '$before', after '$(cat "$TMP/resolv.conf" 2>/dev/null)'"
fi

# ---- the fallback file itself is usable on a box with no lease yet --------
if grep -Eq '^[[:space:]]*nameserver[[:space:]]+[0-9]' "$FALLBACK"; then
    ok "the shipped fallback resolver names at least one server"
else
    bad "the shipped fallback resolver names at least one server" \
        "$(cat "$FALLBACK" | tr '\n' ' ')"
fi
if LC_ALL=C grep -q "$(printf '\r')" "$SCRIPT"; then
    bad "the lease script has no CR characters" "CRLF would break every line"
else
    ok "the lease script has no CR characters"
fi

if [ "$fails" -eq 0 ]; then
    echo "all network checks passed"
    exit 0
fi
echo "FAILED: $fails check(s)"
exit 1
