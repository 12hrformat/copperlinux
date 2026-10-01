#!/bin/busybox sh
# copper rollback — restore files from hotfix backups.
# handcrafted by 12hrformat
#
# Lists available backups and restores them. If a hotfix breaks
# something, this is how you undo it.
#
# Usage: sudo copper rollback [backup_file]

PATH=/bin:/sbin:/usr/bin:/usr/sbin

BACKUP_DIR="/var/backups/copper"
LOG_FILE="/var/log/copper-charge.log"

say() {
    echo "copper: $*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null
}

[ "$(id -u)" = 0 ] || { say "must run as root"; exit 1; }

mkdir -p "$BACKUP_DIR"

# List available backups
list_backups() {
    echo "available backups:"
    ls -1 "$BACKUP_DIR" 2>/dev/null | while IFS= read -r f; do
        echo "  $f"
    done
}

# Restore a specific backup
restore_backup() {
    local name="$1"
    local src="$BACKUP_DIR/$name"

    if [ ! -f "$src" ]; then
        say "backup not found: $name"
        return 1
    fi

    # Convert the backup name back to the path it came from.
    #
    # copper-charge writes backup names by turning every / into _, so
    # /usr/bin/foo becomes usr_bin_foo. This used to undo that by replacing
    # "__" (a double underscore) with "/", which can never match: tr produces
    # one underscore per slash, never two in a row. Restoring therefore always
    # failed with "target file not found". Replace every _ with / instead.
    local target="/$(echo "$name" | tr '_' '/')"

    if [ ! -f "$target" ]; then
        say "target file not found: $target"
        return 1
    fi

    # Back up current before restoring
    cp "$target" "$BACKUP_DIR/$(echo "$target" | tr '/' '_').pre-rollback"

    # Restore
    cp "$src" "$target"
    say "restored $name → $target"
}

# Main
if [ $# -eq 0 ]; then
    list_backups
    echo ""
    echo "usage: sudo copper rollback <backup_name>"
    exit 0
fi

case "$1" in
    --list|-l)
        list_backups
        ;;
    *)
        restore_backup "$1"
        ;;
esac
