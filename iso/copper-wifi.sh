#!/bin/busybox sh
# copper-wifi — join a wireless network from a Copper shell.
#
# Copper has no NetworkManager and no systemd. Joining a network is
# wpa_supplicant's job and the address afterwards is the DHCP client's; this is
# the short front end people actually type.
#
# The shape is iwd's, because that is the shape people already know: name the
# wireless interface, then the action, with no keyword in between.
#
#     copper-wifi interfaces            list wireless interfaces
#     copper-wifi wlan0 scan            ask the radio for a scan
#     copper-wifi wlan0 get-networks    show what the scan found
#     copper-wifi wlan0 connect SSID [PASS]
#     copper-wifi wlan0 show            current supplicant state
#     copper-wifi wlan0 disconnect      drop the radio
#
# With one radio the interface can be left out of the short verbs:
#
#     copper-wifi list                 scan and list nearby networks
#     copper-wifi scan                 ask for a scan and say so
#     copper-wifi get-networks         show what the last scan found
#     copper-wifi add SSID [PASS]      remember a network (no PASS = open)
#     copper-wifi up                   (re)start the radio and ask for a lease
#     copper-wifi status               show the current supplicant state
#     copper-wifi forget SSID          remove a remembered network
#
# copper-init runs the same supplicant at boot, so a network added here is the
# one the machine rejoins next time. Writing needs root: the config lives in
# /etc. There is no plaintext passphrase on disk — `add` runs wpa_passphrase and
# stores the derived psk.
#
# The paths are overridable with COPPER_WIFI_* variables, which is how
# tests/wifi-gate.sh drives the text handling and the radio path against scratch
# directories instead of the live system.

CONF=${COPPER_WIFI_CONF:-/etc/wpa_supplicant/wpa_supplicant.conf}
NETDIR=${COPPER_WIFI_NETDIR:-/sys/class/net}
SUP=${COPPER_WIFI_SUP:-/usr/sbin/wpa_supplicant}
CLI=${COPPER_WIFI_CLI:-/usr/sbin/wpa_cli}
PW=${COPPER_WIFI_PW:-/usr/sbin/wpa_passphrase}
DHCP=${COPPER_WIFI_DHCP:-/sbin/udhcpc}
PIDDIR=${COPPER_WIFI_PIDDIR:-/run}

die() {
    echo "copper-wifi: $*" >&2
    exit 1
}

# The programs only some subcommands need. `add` and `forget` are pure text
# edits, so they must not require a radio stack to run — a machine with no
# wpa_supplicant can still be given a config to use once it has one.
need_supplicant() {
    [ -x "$SUP" ] || die "wpa_supplicant is not installed (build the wifi stage)"
    [ -x "$CLI" ] || die "wpa_cli is not installed (build the wifi stage)"
}

# The interface with a wireless directory under sysfs. A station interface
# reports ARPHRD_ETHER in /sys/class/net/*/type, the same as wired, so the
# presence of a `wireless` directory is the only honest way to tell them apart.
find_iface() {
    ifc=
    for ifc in "$NETDIR"/*/wireless; do
        [ -d "$ifc" ] || continue
        ifc=${ifc#"$NETDIR"/}
        ifc=${ifc%/wireless}
        return 0
    done
    return 1
}

is_wireless() {
    [ -n "${1-}" ] && [ -d "$NETDIR/$1/wireless" ]
}

# Pick the interface to act on: the one named, or the first wireless one.
select_iface() {
    if [ -n "${1-}" ]; then
        is_wireless "$1" || die "$1 is not a wireless interface"
        ifc=$1
    else
        find_iface || die "no wireless interface on this machine"
    fi
}

pidfile() {
    echo "$PIDDIR/wpa_supplicant.$1.pid"
}

start_supplicant() {
    need_supplicant
    select_iface "${1-}"
    p=$(pidfile "$ifc")
    mkdir -p "$PIDDIR/wpa_supplicant"
    if [ -s "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null; then
        "$CLI" -i "$ifc" reconfigure >/dev/null 2>&1
        return 0
    fi
    "$SUP" -B -i "$ifc" -c "$CONF" -D nl80211 -P "$p" || \
        die "wpa_supplicant failed to start"
    sleep 1
}

# Turn `wpa_cli scan_results` into a one-line-per-network table. The raw output
# is one row per BSSID, so a network with two access points shows up twice; this
# keeps the strongest signal per ssid and prints the strongest first. awk's own
# string escape is used for the field separator rather than `-F'\t'`, which not
# every awk agrees on.
format_scan() {
    awk '
        BEGIN { FS = "\t" }
        NR == 1 { next }
        NF < 5  { next }
        {
            ssid = $5
            if (ssid == "") ssid = "(hidden)"
            sig = $3 + 0
            sec = "Open"
            if      ($4 ~ /WPA3/) sec = "WPA3"
            else if ($4 ~ /WPA2/) sec = "WPA2"
            else if ($4 ~ /WPA/)  sec = "WPA"
            else if ($4 ~ /WEP/)  sec = "WEP"
            if (!(ssid in best) || sig > best[ssid]) {
                best[ssid] = sig
                secs[ssid] = sec
            }
        }
        END {
            n = 0
            for (s in best) names[++n] = s
            for (i = 1; i <= n; i++)
                for (j = i + 1; j <= n; j++)
                    if (best[names[j]] > best[names[i]]) {
                        t = names[i]; names[i] = names[j]; names[j] = t
                    }
            if (n == 0) {
                print "no networks found (is the radio on? try: copper-wifi up)"
                exit
            }
            printf "%-32s %7s  %s\n", "SSID", "SIGNAL", "SECURITY"
            for (i = 1; i <= n; i++)
                printf "%-32s %7d  %s\n", substr(names[i], 1, 32), best[names[i]], secs[names[i]]
        }
    '
}

# --- actions ----------------------------------------------------------------

cmd_ifaces() {
    n=0
    for w in "$NETDIR"/*/wireless; do
        [ -d "$w" ] || continue
        name=${w#"$NETDIR"/}
        echo "${name%/wireless}"
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || echo "no wireless interfaces found"
}

cmd_scan() {
    start_supplicant "${1-}"
    "$CLI" -i "$ifc" scan >/dev/null 2>&1
    sleep 3
    echo "scanned on $ifc"
}

cmd_get_networks() {
    start_supplicant "${1-}"
    "$CLI" -i "$ifc" scan_results | format_scan
}

cmd_list() {
    start_supplicant
    "$CLI" -i "$ifc" scan >/dev/null 2>&1
    sleep 3
    "$CLI" -i "$ifc" scan_results | format_scan
}

cmd_status() {
    need_supplicant
    select_iface "${1-}"
    p=$(pidfile "$ifc")
    if [ -s "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null; then
        "$CLI" -i "$ifc" status
    else
        echo "$ifc is not connected (wpa_supplicant is not running)"
        echo "try: copper-wifi up"
    fi
}

cmd_add() {
    ssid=$1
    pass=${2-}
    [ -n "$ssid" ] || die "usage: copper-wifi add SSID [PASSPHRASE]"
    [ -w "$CONF" ] || die "$CONF is not writable (run with sudo)"
    # wpa_supplicant's own parser treats a quote or a backslash as syntax
    # inside a quoted ssid. Refuse rather than write a block that will not
    # parse and will make the whole file fail to load.
    case "$ssid" in
        *'"'*|*\\*) die "an ssid may not contain a quote or backslash" ;;
    esac
    # Work out the key material before touching $CONF. wpa_passphrase rejects a
    # passphrase shorter than 8 or longer than 63 characters and prints no psk
    # when it does; resolving the psk first means a rejected passphrase leaves
    # the file exactly as it was, instead of appending a network block with no
    # key -- which wpa_supplicant cannot use, and which is only noticed at the
    # next boot. The same goes for a machine with no wpa_passphrase installed:
    # the old code appended the opening lines and *then* died, so a missing
    # tool left a half-written network={ that broke every other network too.
    psk=""
    if [ -n "$pass" ]; then
        [ -x "$PW" ] || die "wpa_passphrase is not installed (build the wifi stage)"
        psk=$("$PW" "$ssid" "$pass" 2>/dev/null | sed -n 's/^[[:space:]]*psk=//p')
        [ -n "$psk" ] || die "wpa_passphrase rejected the passphrase (want 8 to 63 characters)"
    fi
    # printf writes the block in one piece; a tab is spelled \t so no literal
    # tab has to survive the build scripts that read this file.
    {
        printf '\nnetwork={\n'
        printf '\tssid="%s"\n' "$ssid"
        if [ -n "$pass" ]; then
            printf '\tpsk=%s\n' "$psk"
        else
            printf '\tkey_mgmt=NONE\n'
        fi
        printf '}\n'
    } >> "$CONF"
    echo "added '$ssid' to $CONF"
    # Apply it now, if the radio is already up. A failure here is not fatal:
    # the network is remembered and takes effect at the next boot anyway.
    if find_iface && [ -s "$(pidfile "$ifc")" ] && [ -x "$CLI" ]; then
        "$CLI" -i "$ifc" reconfigure >/dev/null 2>&1
    fi
}

cmd_forget() {
    ssid=$1
    [ -n "$ssid" ] || die "usage: copper-wifi forget SSID"
    [ -w "$CONF" ] || die "$CONF is not writable (run with sudo)"
    # Drop every network={...} block whose ssid= line matches, keep the rest.
    # awk with a small state machine, because the ssid= line that identifies a
    # block comes after the `network={` that opens it: the block is buffered in
    # "maybe" until the ssid line decides whether it is kept or dropped. A block
    # with no ssid at all cannot be identified, so it is kept.
    if awk -v want="ssid=\"$ssid\"" '
        /^[[:space:]]*network[[:space:]]*=[[:space:]]*\{/ { buf=$0 ORS; state="maybe"; next }
        state == "maybe" {
            buf = buf $0 ORS
            if ($0 ~ /^[[:space:]]*ssid[[:space:]]*=/) {
                line=$0
                sub(/^[[:space:]]*/, "", line)
                sub(/[[:space:]]*$/, "", line)
                if (line == want) { state="drop"; buf="" }
                else { state="keep"; printf "%s", buf; buf="" }
                next
            }
            if ($0 ~ /^[[:space:]]*\}/) { printf "%s", buf; buf=""; state="" }
            next
        }
        state == "drop" { if ($0 ~ /^[[:space:]]*\}/) { state=""; buf="" } next }
        state == "keep" { print; if ($0 ~ /^[[:space:]]*\}/) state=""; next }
        { print }
    ' "$CONF" > "$CONF.copper-wifi-new"; then
        mv "$CONF.copper-wifi-new" "$CONF"
    else
        rm -f "$CONF.copper-wifi-new"
        die "could not rewrite $CONF"
    fi
    echo "removed '$ssid' from $CONF (if it was there)"
}

cmd_up() {
    start_supplicant "${1-}"
    d="$PIDDIR/udhcpc.$ifc.pid"
    if [ -s "$d" ] && kill -0 "$(cat "$d")" 2>/dev/null; then
        echo "$ifc is up; DHCP is already running"
    else
        "$DHCP" -i "$ifc" -b -p "$d" || die "could not start DHCP"
        echo "$ifc is up, asking DHCP for an address"
    fi
}

# connect <iface> SSID [PASS]: reuse a remembered network, add a new one, and
# bring the interface up. A new SSID with no passphrase is joined as an open
# network, the same rule `add` uses. An empty <iface> means the first radio.
cmd_connect() {
    ifn=$1
    ssid=$2
    pass=${3-}
    [ -n "$ssid" ] || die "usage: copper-wifi connect SSID [PASSPHRASE]"
    select_iface "$ifn"
    if grep -qF "ssid=\"$ssid\"" "$CONF" 2>/dev/null; then
        echo "'$ssid' is already remembered"
    elif [ -n "$pass" ]; then
        cmd_add "$ssid" "$pass"
    else
        echo "'$ssid' is new; joining as an open network (add a PASSPHRASE if it is secured)"
        cmd_add "$ssid"
    fi
    cmd_up "$ifn"
}

cmd_disconnect() {
    select_iface "${1-}"
    stopped=0
    p=$(pidfile "$ifc")
    if [ -s "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null; then
        kill "$(cat "$p")" 2>/dev/null && stopped=1
    fi
    rm -f "$p"
    d="$PIDDIR/udhcpc.$ifc.pid"
    if [ -s "$d" ] && kill -0 "$(cat "$d")" 2>/dev/null; then
        kill "$(cat "$d")" 2>/dev/null
    fi
    rm -f "$d"
    if [ "$stopped" = 1 ]; then
        echo "disconnected $ifc"
    else
        echo "$ifc was not connected"
    fi
}

# `<iface> <action>` — the per-interface form, with no keyword in between.
cmd_iface_on() {
    ifn=$1
    action=${2-}
    [ -n "$action" ] || die "usage: copper-wifi $ifn scan|get-networks|connect SSID [PASS]|show|up|disconnect"
    case "$action" in
        scan)                  cmd_scan "$ifn" ;;
        get-networks|networks) cmd_get_networks "$ifn" ;;
        connect)               shift 2; cmd_connect "$ifn" "$@" ;;
        show|status)           cmd_status "$ifn" ;;
        up)                    cmd_up "$ifn" ;;
        disconnect)            cmd_disconnect "$ifn" ;;
        *)                     die "$ifn: unknown action '$action'" ;;
    esac
}

usage() {
    cat <<'EOF'
usage: copper-wifi <command> [args]

  interfaces            list the wireless interfaces

  list                  scan and list nearby networks
  scan [iface]          ask the radio for a scan
  get-networks [iface]  show what the last scan found
  connect SSID [PASS]   join a network, adding it first if it is new

  <iface> scan          the same, for one interface
  <iface> get-networks
  <iface> connect SSID [PASS]
  <iface> show          supplicant state for that interface
  <iface> up            start the supplicant and ask DHCP
  <iface> disconnect    stop the radio on that interface

  add SSID [PASS]       remember a network (no PASS means open)
  up [iface]            (re)start wpa_supplicant and ask DHCP
  status [iface]        show the supplicant's current state
  forget SSID           remove a remembered network
  menu                  interactive prompt (same as no arguments)

A network added here is stored in /etc/wpa_supplicant/wpa_supplicant.conf and
rejoined at every boot. Needs sudo.
EOF
}

# A tiny interactive prompt offering the same commands. Reached by running
# copper-wifi with no arguments on a terminal, or by asking for `menu`. Each
# command runs in a subshell so one refused SSID does not end the session.
# Arguments with spaces are not quoted here; use the one-shot form for those.
interactive() {
    echo "Copper wireless console. 'help' for commands, 'quit' to leave."
    while :; do
        printf 'copper-wifi> '
        IFS= read -r line || { echo; break; }
        set -f
        set -- $line
        set +f
        [ $# -ge 1 ] || continue
        case "$1" in
            quit|exit|q) break ;;
        esac
        ( dispatch "$@" ) || :
    done
}

# One place where a word becomes an action, shared by the command line and the
# prompt so the two can never drift apart.
dispatch() {
    cmd=${1-}
    case "$cmd" in
        interfaces|ifaces|devices) cmd_ifaces ;;
        list)                  cmd_list ;;
        scan)                  cmd_scan ;;
        get-networks|networks) cmd_get_networks ;;
        connect)               shift; cmd_connect "" "$@" ;;
        add)                   shift; cmd_add "$@" ;;
        forget|remove)         shift; cmd_forget "$@" ;;
        up)                    cmd_up ;;
        status)                cmd_status ;;
        menu|interactive|-i)   interactive ;;
        help|--help|-h)        usage ;;
        '')
            if [ -t 0 ]; then interactive; else usage; fi ;;
        *)
            if is_wireless "$cmd"; then
                shift
                cmd_iface_on "$cmd" "$@"
            else
                die "unknown command '$cmd' (try: copper-wifi help)"
            fi ;;
    esac
}

dispatch "$@"
