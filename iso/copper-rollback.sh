#!/bin/busybox sh
# copper rollback -- put files back the way they were before a charge.
#
# Usage: copper rollback [--list | --latest | <snapshot>]
#
#   (no args)  show what can be restored and how
#   --list     the same, but only the list
#   --latest   restore the most recent snapshot
#   <snapshot> restore that named snapshot
#
# Backups are written by 'copper charge', which snapshots every file the
# hotfix database refers to before it changes anything. That is why a rollback
# is available even after a charge that applied nothing: the snapshot is the
# state of those files at that moment, which is exactly what you want back.
#
# Old single-file backups (the format the first version wrote, where the
# backup name was a mangled path) are still accepted as an argument.

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

CONFIG_FILE="${COPPER_CONFIG:-/etc/copper/config}"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
fi
BACKUP_DIR="${BACKUP_DIR:-/var/backups/copper}"
LOG_FILE="${LOG_FILE:-/var/log/copper-charge.log}"

say() {
    echo "copper: $*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null
}

[ "$(id -u)" = 0 ] || { say "must run as root"; exit 1; }

# Snapshot names are timestamps, so they sort chronologically as text.
# "pre-rollback-*" directories sort after them, hence the digit test: a
# restore point must never be the thing a rollback rolls back.
snapshot_names() {
    for d in $(ls -1 "$BACKUP_DIR" 2>/dev/null); do
        case "$d" in
            [0-9]*) [ -d "$BACKUP_DIR/$d" ] && echo "$d" ;;
        esac
    done
}

newest_snapshot() {
    snapshot_names | tail -1
}

usage() {
    echo "usage: copper rollback [--list | --latest | <snapshot>]"
    echo ""
    echo "  --latest    restore the most recent snapshot"
    echo "  --list      list snapshots and the files in them"
    echo "  <snapshot>  restore that snapshot by name"
}

# ------------------------------------------------------------------- list
list_backups() {
    if [ ! -d "$BACKUP_DIR" ]; then
        say "there is no backup directory at $BACKUP_DIR, so there is nothing to roll back"
        echo ""
        echo "'copper charge' creates it, and writes a snapshot before it changes anything."
        return 1
    fi

    if [ -z "$(snapshot_names)" ]; then
        say "no snapshots in $BACKUP_DIR - there is nothing to roll back"
        echo ""
        echo "'copper charge' writes one every time it runs, before it changes"
        echo "anything, so running it once is enough to make rollback work."
        return 1
    fi

    echo "restore points in $BACKUP_DIR (oldest first):"
    for d in $(snapshot_names); do
        if [ -f "$BACKUP_DIR/$d/MANIFEST" ]; then
            printf "  %-24s %s file(s)\n" "$d" "$(grep -c . "$BACKUP_DIR/$d/MANIFEST")"
            while IFS= read -r t; do
                [ -n "$t" ] && printf "        %s\n" "$t"
            done < "$BACKUP_DIR/$d/MANIFEST"
        else
            printf "  %-24s %s file(s)\n" "$d" "$(ls -1 "$BACKUP_DIR/$d" 2>/dev/null | grep -c .)"
        fi
    done

    # Old-format single files, so an existing backup is never just invisible.
    loose=$(ls -1 "$BACKUP_DIR" 2>/dev/null | grep -v '^[0-9]' | grep -v '^pre-rollback')
    if [ -n "$loose" ]; then
        echo ""
        echo "single-file backups:"
        echo "$loose" | while IFS= read -r f; do
            [ -n "$f" ] && printf "  %-24s -> /%s\n" "$f" "$(echo "$f" | tr '_' '/')"
        done
    fi

    echo ""
    echo "restore the newest with: copper rollback --latest"
    return 0
}

# ---------------------------------------------------------------- restore
# Put back everything in one snapshot. A restore is itself reversible: the
# current contents are copied aside first, so a rollback that turns out to be
# the wrong idea can be undone with 'copper rollback <that name>'.
restore_snapshot() {
    snap="$1"
    manifest="$BACKUP_DIR/$snap/MANIFEST"

    if [ ! -d "$BACKUP_DIR/$snap" ]; then
        say "no such snapshot: $snap"
        return 1
    fi
    if [ ! -f "$manifest" ]; then
        say "snapshot $snap has no manifest, so there is no way to tell which file is which"
        return 1
    fi

    pre="$BACKUP_DIR/pre-rollback-$(date '+%Y-%m-%d_%H-%M-%S')"
    mkdir -p "$pre" || { say "cannot create $pre"; return 1; }

    n=0
    failed=0
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        name=$(echo "${target#/}" | tr '/' '_')
        src="$BACKUP_DIR/$snap/$name"

        if [ ! -f "$src" ]; then
            say "  $target: no copy in this snapshot, skipping"
            failed=$((failed + 1))
            continue
        fi
        if [ ! -f "$target" ]; then
            say "  $target: no longer exists on this system, skipping"
            failed=$((failed + 1))
            continue
        fi

        cp "$target" "$pre/$name" 2>/dev/null
        if cp "$src" "$target"; then
            say "  restored $target"
            n=$((n + 1))
        else
            say "  $target: restore failed, file left as it was"
            failed=$((failed + 1))
        fi
    done < "$manifest"

    if [ "$n" -eq 0 ]; then
        say "nothing was restored from $snap"
        rmdir "$pre" 2>/dev/null
        return 1
    fi

    say "restored $n file(s) from $snap"
    say "the version from just before this rollback is in $pre"
    [ "$failed" -gt 0 ] && say "$failed file(s) could not be restored"
    return 0
}

# A single loose backup file, the format the first version of charge wrote.
# The name is the path with every / turned into _, so undoing that is the whole
# job. This used to replace "__" with "/", which can never match: tr emits one
# underscore per slash and never two in a row, so every restore failed with
# "target file not found".
restore_single() {
    name="$1"
    src="$BACKUP_DIR/$name"

    if [ ! -f "$src" ]; then
        say "no such backup: $name (try 'copper rollback --list')"
        return 1
    fi

    target="/$(echo "$name" | tr '_' '/')"

    if [ ! -f "$target" ]; then
        say "the file this backup came from is not on this system: $target"
        return 1
    fi

    pre="$BACKUP_DIR/pre-rollback-$(date '+%Y-%m-%d_%H-%M-%S')"
    mkdir -p "$pre" 2>/dev/null
    cp "$target" "$pre/$name" 2>/dev/null

    cp "$src" "$target" || { say "restore failed, $target left as it was"; return 1; }
    say "restored $name to $target"
    return 0
}

# ------------------------------------------------------------------- main
# Each branch sets RC explicitly rather than relying on the status of the last
# command it happened to run. The bare "copper rollback" path calls
# list_backups and then usage; whichever of those returns last is what the
# shell would exit with, so a run that found nothing to restore could exit 0
# and look like a job done properly.
RC=0

case "${1:-}" in
    --list|-l)
        list_backups || RC=1
        ;;
    --latest)
        snap=$(newest_snapshot)
        if [ -z "$snap" ]; then
            say "there are no snapshots in $BACKUP_DIR, so there is nothing to restore"
            echo ""
            echo "'copper charge' writes one every time it runs."
            exit 1
        fi
        echo "copper: restoring $snap"
        restore_snapshot "$snap" || RC=1
        ;;
    --help|-h)
        usage
        ;;
    "")
        list_backups || RC=1
        usage
        ;;
    *)
        if [ -d "$BACKUP_DIR/$1" ]; then
            restore_snapshot "$1" || RC=1
        else
            # Distinguish "that name looks like a snapshot but there is no such
            # snapshot" from "that name looks like an old single-file backup but
            # there is no such file". Both are refusals, but a user who just ran
            # --list has seen one of those two forms and should not be sent
            # looking for the other.
            case "$1" in
                [0-9]*) say "no such snapshot: $1 (try: copper rollback --list)"; RC=1 ;;
                *)       restore_single "$1" || RC=1 ;;
            esac
        fi
        ;;
esac

exit $RC
