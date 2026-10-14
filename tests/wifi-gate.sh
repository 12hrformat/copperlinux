#!/usr/bin/env bash
# wifi-gate.sh — prove copper-wifi's config handling on scratch directories.
#
# copper-wifi's risky part is not the radio, it is the text: `add` writes a
# network={...} block and `forget` has to remove exactly that block and nothing
# else. A mistake there either loses a saved network or corrupts the file so
# wpa_supplicant refuses to load any of them, and neither shows up until
# somebody boots a laptop.
#
# The script takes every path it uses from COPPER_WIFI_* variables, so this test
# drives the real file against a scratch config, a fake sysfs tree and stub
# binaries. No root, no radio, no wpa_supplicant.
#
# Prints "  ok <what>" / "  FAIL <what>" and a summary, like the other gates.

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
SELF="$REPO/iso/copper-wifi.sh"

ok=0
bad=0
say_ok()  { printf '  ok %s\n' "$1"; ok=$((ok + 1)); }
say_bad() { printf '  FAIL %s\n' "$1"; bad=$((bad + 1)); }

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then say_ok "$1"; else
        say_bad "$1"
        printf '        expected: %s\n' "$2"
        printf '        actual:   %s\n' "$3"
    fi
}

check_grep() { # check_grep <label> <pattern> <text>
    if printf '%s' "$3" | grep -q -- "$2"; then say_ok "$1"; else
        say_bad "$1"
        printf '        wanted a line matching: %s\n' "$2"
        printf '        in: %s\n' "$3"
    fi
}

check_not_grep() {
    if printf '%s' "$3" | grep -q -- "$2"; then
        say_bad "$1"
        printf '        should not have matched: %s\n' "$2"
    else
        say_ok "$1"
    fi
}

[ -f "$SELF" ] || { echo "wifi-gate: $SELF is missing" >&2; exit 1; }

# A POSIX shell to run the script with, rather than its /bin/busybox shebang
# which only exists in the image. dash is the strictest one available; fall
# back to sh, then bash.
shell=""
for c in dash sh bash; do
    command -v "$c" >/dev/null 2>&1 && { shell=$(command -v "$c"); break; }
done
if [ -z "$shell" ]; then echo "wifi-gate: no shell to run copper-wifi with"; exit 0; fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/net" "$TMP/run"
CONF="$TMP/wpa_supplicant.conf"
NETDIR="$TMP/net"

# A stub wpa_passphrase: the real one prints the derived psk, and this prints a
# fixed one so the test can look for it.
cat > "$TMP/bin/wpa_passphrase" <<'EOF'
#!/bin/sh
echo "	psk=deadbeefcafe"
EOF
# The other two just have to exist and be executable for the keeps checks.
for t in wpa_supplicant wpa_cli udhcpc; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$t"
done
chmod +x "$TMP/bin"/*

wifi() {
    COPPER_WIFI_CONF="$CONF" \
    COPPER_WIFI_NETDIR="$NETDIR" \
    COPPER_WIFI_SUP="$TMP/bin/wpa_supplicant" \
    COPPER_WIFI_CLI="$TMP/bin/wpa_cli" \
    COPPER_WIFI_PW="$TMP/bin/wpa_passphrase" \
    COPPER_WIFI_DHCP="$TMP/bin/udhcpc" \
    COPPER_WIFI_PIDDIR="$TMP/run" \
    "$shell" "$SELF" "$@"
}

cat > "$CONF" <<'EOF'
ctrl_interface=DIR=/run/wpa_supplicant GROUP=wheel
update_config=1
EOF
BASE=$(wc -c < "$CONF")

# --- add a secured network -------------------------------------------------
out=$(wifi add "Copper Net" "hunter2" 2>&1)
rc=$?
check "add secured exits 0" 0 "$rc"
check_grep "add writes the ssid" 'ssid="Copper Net"' "$(cat "$CONF")"
check_grep "add writes the derived psk, not the passphrase" 'psk=deadbeefcafe' "$(cat "$CONF")"
case "$(cat "$CONF")" in
    *hunter2*) say_bad "add must not store the passphrase in the clear" ;;
    *)         say_ok "the passphrase is nowhere in the file" ;;
esac

# --- add an open network ---------------------------------------------------
out=$(wifi add "Guest" 2>&1)
check "add open exits 0" 0 "$?"
check_grep "open network uses key_mgmt=NONE" 'key_mgmt=NONE' "$(cat "$CONF")"
check "the open network has two blocks" 2 "$(grep -c '^network={' "$CONF")"

# --- add refuses an ssid it cannot write safely ----------------------------
cp "$CONF" "$CONF.before"
out=$(wifi add 'Bad"Name' "x" 2>&1)
rc=$?
check "add refuses an ssid with a quote" 0 "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "a refused add changes nothing" "$(cat "$CONF.copper-wifi-new" 2>/dev/null)$(cat "$CONF")" "$(cat "$CONF")"

# --- forget removes exactly one block --------------------------------------
out=$(wifi forget "Copper Net" 2>&1)
rc=$?
check "forget exits 0" 0 "$rc"
body=$(cat "$CONF")
case "$body" in
    *"Copper Net"*) say_bad "forget left the removed network behind" ;;
    *) say_ok "forget removed the network" ;;
esac
check_grep "forget kept the other network" 'ssid="Guest"' "$body"
check_grep "forget kept the header" 'ctrl_interface=DIR=/run/wpa_supplicant' "$body"
check "no stray temp file left" "" "$(ls "$CONF.copper-wifi-new" 2>/dev/null)"

# --- forget of an unknown ssid changes nothing -----------------------------
before=$(cat "$CONF")
out=$(wifi forget "Not There" 2>&1)
check "forget unknown exits 0" 0 "$?"
check "forget unknown leaves the file identical" "$before" "$(cat "$CONF")"

# --- a block with no ssid line is preserved --------------------------------
cat > "$CONF" <<'EOF'
ctrl_interface=DIR=/run/wpa_supplicant

network={
	key_mgmt=NONE
}
EOF
wifi forget "Anything" >/dev/null 2>&1
check_grep "a network block with no ssid survives forget" 'key_mgmt=NONE' "$(cat "$CONF")"

# --- a quote in an ssid is refused -----------------------------------------
before=$(cat "$CONF")
if wifi add 'bad"name' "pw" >/dev/null 2>&1; then
    say_bad "add accepted an ssid containing a quote"
else
    say_ok "add refuses an ssid containing a quote"
fi
check "the refused add wrote nothing" "$before" "$(cat "$CONF")"

# --- no radio present is reported, not crashed -----------------------------
out=$(wifi status 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no wireless interface'; then
    say_ok "status with no radio names the problem"
else
    say_bad "status with no radio should fail with 'no wireless interface'"
    printf '        exit %s, output: %s\n' "$rc" "$out"
fi

# --- and a radio present, with a live supplicant pid ------------------------
mkdir -p "$NETDIR/wlan0/wireless"
sleep 1000 &            # a pid that is definitely alive
LIVE=$!
echo "$LIVE" > "$TMP/run/wpa_supplicant.wlan0.pid"
out=$(wifi status 2>&1)
check "status with a running supplicant exits 0" 0 "$?"
kill "$LIVE" 2>/dev/null

# --- add refuses what wpa_passphrase refuses, without writing --------------
# The real wpa_passphrase prints no psk and exits non-zero outside 8..63
# characters. The first version appended the block and only then invoked it, so
# a refused passphrase left a `network={}` with no key behind it and still said
# "added". An all-or-nothing add is the contract these checks pin.
base=$(cat "$CONF")
cat > "$TMP/bin/wpa_passphrase_reject" <<'EOF'
#!/bin/sh
echo "Passphrase must be 8..63 characters" >&2
exit 1
EOF
chmod +x "$TMP/bin/wpa_passphrase_reject"
wifi_pw() { # wifi_pw <wpa_passphrase> <args...>
    COPPER_WIFI_CONF="$CONF" \
    COPPER_WIFI_NETDIR="$NETDIR" \
    COPPER_WIFI_SUP="$TMP/bin/wpa_supplicant" \
    COPPER_WIFI_CLI="$TMP/bin/wpa_cli" \
    COPPER_WIFI_PW="$1" \
    COPPER_WIFI_DHCP="$TMP/bin/udhcpc" \
    COPPER_WIFI_PIDDIR="$TMP/run" \
    shift; "$shell" "$SELF" "$@"
}
if wifi_pw "$TMP/bin/wpa_passphrase_reject" add SecNet short >/dev/null 2>&1; then
    say_bad "add accepted a passphrase wpa_passphrase refuses"
else
    say_ok "add fails when wpa_passphrase refuses the passphrase"
fi
check "a refused passphrase leaves the config untouched" "$base" "$(cat "$CONF")"

if wifi_pw "$TMP/bin/not-there" add SecNet hunter22 >/dev/null 2>&1; then
    say_bad "add succeeded with wpa_passphrase missing"
else
    say_ok "add fails cleanly when wpa_passphrase is missing"
fi
check "a missing wpa_passphrase writes no half network block" "$base" "$(cat "$CONF")"

# --- the radio path: list / up / status ------------------------------------
# The stubs above only had to exist. These record how they were called, so the
# flags copper-wifi hands the real tools are pinned: a wrong -D, a missing -P,
# or a udhcpc without -b is the kind of thing only a radio would notice.
REC="$TMP/rec"; mkdir -p "$REC"
rm -f "$TMP/run"/*.pid
RLOG="$TMP/rec.log"
cat > "$REC/wpa_supplicant" <<'EOF'
#!/bin/sh
echo "wpa_supplicant $*" >> "$LOG"
pidfile=
while [ $# -gt 0 ]; do
    case "$1" in -P) pidfile=$2; shift 2 ;; *) shift ;; esac
done
sleep 31337 >/dev/null 2>&1 </dev/null &
echo $! > "$pidfile"
exit 0
EOF
cat > "$REC/udhcpc" <<'EOF'
#!/bin/sh
echo "udhcpc $*" >> "$LOG"
pidfile=
while [ $# -gt 0 ]; do
    case "$1" in -p) pidfile=$2; shift 2 ;; *) shift ;; esac
done
sleep 31337 >/dev/null 2>&1 </dev/null &
echo $! > "$pidfile"
exit 0
EOF
cat > "$REC/wpa_cli" <<'EOF'
#!/bin/sh
echo "wpa_cli $*" >> "$LOG"
last=
for a in "$@"; do last=$a; done
case "$last" in
    scan_results)
        printf 'bssid / frequency / signal level / flags / ssid\n'
        printf 'aa:bb:cc:dd:ee:ff\t2412\t-42\t[WPA2-PSK-CCMP]\tCopperLab\n'
        ;;
    status)
        echo "wpa_state=COMPLETED"
        ;;
esac
exit 0
EOF
chmod +x "$REC"/*
wifi_rec() {
    LOG="$RLOG" \
    COPPER_WIFI_CONF="$CONF" \
    COPPER_WIFI_NETDIR="$NETDIR" \
    COPPER_WIFI_SUP="$REC/wpa_supplicant" \
    COPPER_WIFI_CLI="$REC/wpa_cli" \
    COPPER_WIFI_PW="$TMP/bin/wpa_passphrase" \
    COPPER_WIFI_DHCP="$REC/udhcpc" \
    COPPER_WIFI_PIDDIR="$TMP/run" \
    "$shell" "$SELF" "$@"
}

: > "$RLOG"
out=$(wifi_rec list 2>&1)
check "list exits 0" 0 "$?"
check_grep "list starts the supplicant on the nl80211 driver" \
    '-D nl80211' "$(cat "$RLOG")"
check_grep "list pins the pidfile the boot path also writes" \
    '-P .*wpa_supplicant\.wlan0\.pid' "$(cat "$RLOG")"
check_grep "list scans and then reads the results" \
    'wpa_cli -i wlan0 scan_results' "$(cat "$RLOG")"
check_grep "list prints what the scan found" 'CopperLab' "$out"

: > "$RLOG"
out=$(wifi_rec up 2>&1)
check "up exits 0" 0 "$?"
check_grep "up starts udhcpc in the background with a pidfile" \
    'udhcpc -i wlan0 -b -p .*udhcpc\.wlan0\.pid' "$(cat "$RLOG")"
check_grep "up says the interface is up" 'asking DHCP' "$out"

: > "$RLOG"
out=$(wifi_rec up 2>&1)
check_grep "a second up notices the running DHCP client" 'already running' "$out"
check_not_grep "a second up starts no second DHCP client" \
    'udhcpc' "$(cat "$RLOG")"

: > "$RLOG"
out=$(wifi_rec status 2>&1)
check "status exits 0" 0 "$?"
check_grep "status asks the supplicant" 'wpa_cli -i wlan0 status' "$(cat "$RLOG")"
check_grep "status prints the supplicant state" 'wpa_state=COMPLETED' "$out"

: > "$RLOG"
wifi_rec add "ApplyNet" hunter22 >/dev/null 2>&1
check_grep "add reconfigures an already-running supplicant" \
    'wpa_cli -i wlan0 reconfigure' "$(cat "$RLOG")"
check_grep "add while up still stores the network" \
    'ssid="ApplyNet"' "$(cat "$CONF")"

# --- the iface-first grammar (copper-wifi wlan0 ...) ------------------------
# iwd names the interface, then the action, with no keyword between; these pin
# that shape and the guards around a name that is not a wireless interface.
: > "$RLOG"
out=$(wifi_rec interfaces 2>&1)
check "interfaces exits 0" 0 "$?"
check_grep "interfaces lists the radio" 'wlan0' "$out"

: > "$RLOG"
out=$(wifi_rec wlan0 scan 2>&1)
check "wlan0 scan exits 0" 0 "$?"
check_grep "wlan0 scan asks the supplicant to scan" \
    'wpa_cli -i wlan0 scan$' "$(cat "$RLOG")"
check_grep "wlan0 scan says it did something" 'scanned on wlan0' "$out"

: > "$RLOG"
out=$(wifi_rec wlan0 get-networks 2>&1)
check "wlan0 get-networks exits 0" 0 "$?"
check_grep "wlan0 get-networks reads the results" \
    'wpa_cli -i wlan0 scan_results' "$(cat "$RLOG")"
check_grep "wlan0 get-networks prints the table header" 'SSID' "$out"
check_grep "wlan0 get-networks prints the network" 'CopperLab' "$out"

if wifi_rec eth0 scan >/dev/null 2>&1; then
    say_bad "a non-wireless interface name was accepted"
else
    say_ok "a non-wireless interface name is refused"
fi
if wifi_rec wlan0 bogus >/dev/null 2>&1; then
    say_bad "an unknown iface action was accepted"
else
    say_ok "an unknown iface action is refused"
fi

: > "$RLOG"
out=$(wifi_rec wlan0 connect JoinNet hunter22 2>&1)
check "wlan0 connect exits 0" 0 "$?"
check_grep "connect adds the network" 'ssid="JoinNet"' "$(cat "$CONF")"
check_grep "connect brings the interface up" 'wlan0 is up' "$out"

out=$(printf 'interfaces\nquit\n' | wifi_rec menu 2>&1)
check_grep "the prompt greets" 'console' "$out"
check_grep "the prompt runs an iface command" 'wlan0' "$out"

out=$(wifi_rec wlan0 disconnect 2>&1)
check "wlan0 disconnect exits 0" 0 "$?"
check_grep "disconnect says so" 'disconnected wlan0' "$out"

# Stop the stub daemons the radio path left behind.
for p in "$TMP"/run/*.pid; do
    [ -s "$p" ] && kill "$(cat "$p")" 2>/dev/null
done

# ---------------------------------------------------------------------------
echo
echo "wifi-gate summary: $ok ok, $bad failed"
if [ "$bad" -ne 0 ]; then
    echo "FAIL"
    exit 1
fi
echo "PASS"
exit 0
