#!/bin/busybox sh
# copper charge — fetch and apply hotfixes from the Copper repo.
# handcrafted by 12hrformat
#
# Reads hotfixes.json from the repo, finds failing code in local files,
# backs up the original, and replaces it with the fixed code.
#
# Usage: sudo copper charge

PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Read config if it exists
CONFIG_FILE="/etc/copper/config"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
fi

# Defaults if config is missing
HOTFIX_URL="${HOTFIX_URL:-https://raw.githubusercontent.com/Copper-linux/copper/main/hotfixes.json}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/copper}"
LOG_FILE="${LOG_FILE:-/var/log/copper-charge.log}"

# If a hotfix database is installed locally, use it and skip the network
# entirely. Lets you test a fix on a machine with no route out, and means a
# dead network degrades to "use what is already here" instead of a hard
# failure. Delete this file to go back to always fetching.
LOCAL_DB="/etc/copper/hotfixes.json"

say() {
    echo "copper: $*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null
}

[ "$(id -u)" = 0 ] || { say "must run as root"; exit 1; }

mkdir -p "$BACKUP_DIR"

TMP=$(mktemp)
if [ -f "$LOCAL_DB" ]; then
    say "using installed hotfix database $LOCAL_DB"
    cp "$LOCAL_DB" "$TMP"
else
    say "fetching hotfixes from $HOTFIX_URL"
    # The live system ships busybox wget, not curl. Prefer curl when it
    # exists (nicer errors), fall back to wget.
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$HOTFIX_URL" -o "$TMP" 2>/dev/null
        FETCH_RC=$?
    else
        # busybox wget has no -f/-s/-L in the same shape; -q quiet, -O outfile,
        # and it follows redirects itself. --no-check-certificate because the
        # live rootfs carries no CA bundle.
        wget -q --no-check-certificate -T 20 -O "$TMP" "$HOTFIX_URL" 2>/dev/null
        FETCH_RC=$?
    fi
    if [ "$FETCH_RC" -ne 0 ] || [ ! -s "$TMP" ]; then
        say "could not fetch hotfixes (rc=$FETCH_RC) — no network, or the file is not there yet"
        rm -f "$TMP"
        exit 1
    fi
fi

if ! grep -q '"fail_code"' "$TMP"; then
    say "no hotfixes defined — system is up to date"
    rm -f "$TMP"
    exit 0
fi

# Extract hotfix entries using awk (no python3 needed on the live system)
extract_field() {
    echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

awk '
BEGIN { depth=0; buf="" }
{
    for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") {
            if (depth == 0) buf = ""
            depth++
        }
        if (depth > 0) buf = buf c
        if (c == "}") {
            depth--
            if (depth == 0 && buf ~ /fail_code/) {
                print buf
            }
        }
    }
}
' "$TMP" | while IFS= read -r block; do
    hid=$(extract_field "$block" "id")
    target=$(extract_field "$block" "file")
    fail_code=$(extract_field "$block" "fail_code")
    new_code=$(extract_field "$block" "new_code")
    desc=$(extract_field "$block" "description")

    [ -z "$hid" ] && hid="unknown"
    [ -z "$target" ] && { say "skipping $hid — no file"; continue; }
    [ -z "$fail_code" ] && { say "skipping $hid — no fail_code"; continue; }

    full_path="/$target"
    if [ ! -f "$full_path" ]; then
        say "skipping $hid — $target not found"
        continue
    fi

    if ! grep -qF "$fail_code" "$full_path"; then
        say "skipping $hid — fail_code not in $target (already fixed?)"
        continue
    fi

    # Back up the original
    backup_path="$BACKUP_DIR/$(echo "$target" | tr '/' '_')"
    cp "$full_path" "$backup_path"

    # Apply the fix: replace first occurrence of fail_code with new_code
    sed -i "s|$(echo "$fail_code" | sed 's/[&/\]/\\&/g')|$(echo "$new_code" | sed 's/[&/\]/\\&/g')|" "$full_path"

    say "applied $hid — $desc"
    say "  backed up to $backup_path"
done

rm -f "$TMP"
say "charge complete"
