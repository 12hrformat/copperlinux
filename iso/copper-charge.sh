#!/bin/busybox sh
# copper charge -- take a restore point, then fetch and apply hotfixes.
#
# Reads hotfixes.json from the repo, finds the failing code in local files,
# replaces it with the fixed code.
#
# Usage: copper charge [--status | --backup]
#
#   (no flag)   back up everything a hotfix could touch, then apply
#   --status    report what would change and change nothing
#   --backup    take the restore point and stop
#
# Why the backup comes first
#
# The first version of this copied a file at the moment it patched it. That
# means a machine where nothing needed patching ended up with no backups at
# all, so "copper rollback" had nothing to restore and could only say so --
# which is exactly the question it exists to answer, asked too late. It also
# meant the one file a hotfix touched was the only file you could undo, and
# that a second hotfix on the same file overwrote the first one's backup.
#
# Now every run writes a full snapshot of every file the database refers to,
# BEFORE anything is modified, whether or not any of them turn out to need
# fixing. A snapshot is a restore point: "put these files back the way they
# were at 16:30", which is the thing you actually want after a bad charge,
# and it exists even when the charge did nothing.

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# Read config if it exists.
#
# COPPER_CONFIG is overridable so this can be pointed at a different config --
# for testing off a real system, and for a machine that keeps more than one.
CONFIG_FILE="${COPPER_CONFIG:-/etc/copper/config}"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
fi

# Defaults if config is missing
HOTFIX_URL="${HOTFIX_URL:-https://raw.githubusercontent.com/12hrformat/copperlinux/main/hotfixes.json}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/copper}"
LOG_FILE="${LOG_FILE:-/var/log/copper-charge.log}"

# If a hotfix database is installed locally, use it and skip the network
# entirely. Lets you test a fix on a machine with no route out, and means a
# dead network degrades to "use what is already here" instead of a hard
# failure. Delete this file to go back to always fetching.
LOCAL_DB="${HOTFIX_DB:-/etc/copper/hotfixes.json}"

say() {
    echo "copper: $*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null
}

die() {
    say "$*"
    exit 1
}

# ------------------------------------------------------------------ flags
MODE="apply"
case "${1:-}" in
    --status|-s)  MODE="status" ;;
    --backup|-b)  MODE="backup" ;;
    --dump-entries|-d) MODE="dump" ;;
    --help|-h)
        echo "usage: copper charge [--status | --backup | --dump-entries]"
        echo ""
        echo "  --status        say what would change, change nothing"
        echo "  --backup        take a restore point and stop"
        echo "  --dump-entries  print every entry as id/file/fail/new/description"
        exit 0
        ;;
esac

# ------------------------------------------------------------ the database
TMP=$(mktemp) || die "mktemp failed"
BLOCKS=$(mktemp) || die "mktemp failed"
trap 'rm -f "$TMP" "$BLOCKS"' EXIT INT TERM

if [ -f "$LOCAL_DB" ]; then
    [ "$MODE" = "dump" ] || say "using installed hotfix database $LOCAL_DB"
    cp "$LOCAL_DB" "$TMP" || die "cannot read $LOCAL_DB"
else
    [ "$MODE" = "dump" ] || say "fetching hotfixes from $HOTFIX_URL"
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
        die "could not fetch hotfixes (rc=$FETCH_RC) - no network, or the file is not there yet"
    fi
fi

if ! grep -q '"fail_code"' "$TMP"; then
    say "no hotfixes defined - nothing to apply"
    if [ "$MODE" = "backup" ]; then
        say "no database entries, so there is nothing to snapshot either"
    fi
    exit 0
fi

# Extract one field from one entry block.
#
# Every comment in and around this awk program must avoid the apostrophe
# character. The program is inside a single-quoted shell string, so a single
# apostrophe in a comment inside it closes the quote early and the rest of the
# awk is handed to the shell to execute -- which fails as "buf[depth]: not
# found" and gives no hint that a comment caused it.
extract_field() {
    echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

# Split the database into one line per hotfix entry.
#
# This has to key off the OWN keys of each object, not just whether the text
# "fail_code" appears somewhere inside it. The obvious version -- start a
# buffer at the outermost brace, print it when the depth returns to zero --
# concatenates the entire file into a single line, because the top-level
# object holding "hotfixes": [ ... ] is itself an object. Every field is then
# extracted with a greedy sed from that one line, so every field comes back as
# the LAST entry value and every entry except the last is silently invisible.
# One entry in the shipped database is the only reason that was never noticed.
#
# So each open brace gets its own buffer, and an object counts as an entry
# only if fail_code and file are its own immediate keys -- which the wrapper
# object is not, because it holds them one level down inside the array.
awk '
BEGIN { depth = 0 }
{
    line = $0
    n = length(line)
    for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (c == "{") {
            depth++
            buf[depth] = "{"
            hasfail[depth] = 0
            hasfile[depth] = 0
            continue
        }
        if (c == "}") {
            if (hasfail[depth] && hasfile[depth]) print buf[depth]
            depth--
            continue
        }
        if (depth > 0) {
            # Text appended to buf[depth] was written directly inside that
            # object; a nested object accumulates into its own buffer. So a key
            # recognised here belongs to this object and not to a child.
            buf[depth] = buf[depth] c
            if (buf[depth] ~ /"fail_code"[[:space:]]*:[[:space:]]*$/) hasfail[depth] = 1
            if (buf[depth] ~ /"file"[[:space:]]*:[[:space:]]*$/)       hasfile[depth] = 1
        }
    }
}
' "$TMP" > "$BLOCKS"

[ -s "$BLOCKS" ] || say "the database has no usable entries"

# Print every entry, one per line, tab separated.
#
# This is the parser's only externally visible output, so it is also what the
# build gate asserts against: the number of lines must equal the number of
# fail_code keys in the database file, and no field may come back empty. That
# is the check that would have caught the parser silently reading only the last
# entry, which shipped because the database had exactly one entry and one
# entry always works.
if [ "$MODE" = "dump" ]; then
    while IFS= read -r block; do
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$(extract_field "$block" id)" \
            "$(extract_field "$block" file)" \
            "$(extract_field "$block" fail_code)" \
            "$(extract_field "$block" new_code)" \
            "$(extract_field "$block" description)"
    done < "$BLOCKS"
    exit 0
fi

# Root is only needed from here on. --help and --dump-entries must work for
# anybody, because they change nothing and are the first thing to reach for
# when working out why a charge did nothing.
[ "$(id -u)" = 0 ] || die "must run as root"

mkdir -p "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"

# ------------------------------------------------------------------ backups
# A snapshot directory per run, named for when it was taken. MANIFEST holds the
# real path of every file copied in, because the backup filename is a mangled
# path and only the manifest knows for sure what it maps back to.
STAMP=$(date '+%Y-%m-%d_%H-%M-%S')
SNAP=""
take_snapshot() {
    SNAP="$BACKUP_DIR/$STAMP"
    # Two charges inside the same second must not share a directory.
    n=2
    while [ -e "$SNAP" ]; do
        SNAP="$BACKUP_DIR/${STAMP}-$n"
        n=$((n + 1))
    done
    mkdir -p "$SNAP" || die "cannot create $SNAP"
    : > "$SNAP/MANIFEST"

    copied=0
    seen=""
    while IFS= read -r block; do
        target=$(extract_field "$block" "file")
        [ -n "$target" ] || continue
        full_path="/$target"
        [ -f "$full_path" ] || continue

        # Two hotfix entries naming the same file would copy it twice and list
        # it twice, and the second listing would make rollback restore it and
        # then restore it again.
        case " $seen " in
            *" $full_path "*) continue ;;
        esac
        seen="$seen $full_path"

        name=$(echo "$target" | tr '/' '_')
        if cp "$full_path" "$SNAP/$name" 2>/dev/null; then
            echo "$full_path" >> "$SNAP/MANIFEST"
            copied=$((copied + 1))
        fi
    done < "$BLOCKS"

    if [ "$copied" -eq 0 ]; then
        # Remove the manifest too. rmdir alone fails on a directory that is not
        # empty, so leaving it behind would show up in "copper rollback --list"
        # as a restore point holding zero files, which reads as data loss.
        rm -f "$SNAP/MANIFEST"
        rmdir "$SNAP" 2>/dev/null
        SNAP=""
        say "no local files to snapshot (the hotfix targets are not present on this system)"
    else
        say "backed up $copied file(s) to $SNAP"
    fi
}

if [ "$MODE" = "backup" ]; then
    take_snapshot
    if [ -n "$SNAP" ]; then
        say "backup only - nothing was applied"
        say "undo it with: copper rollback $STAMP"
    fi
    exit 0
fi

# ------------------------------------------------------------------ report
# Work out what would change, without touching anything, so --status can
# report it and the apply pass knows whether it is about to do anything.
# This is a first pass over the block file, not a stored list of fields: a
# fail_code containing the delimiter would silently shift every later field
# along, and the original single-pass form had no such hazard.
count_pending=0
while IFS= read -r block; do
    hid=$(extract_field "$block" "id")
    target=$(extract_field "$block" "file")
    fail_code=$(extract_field "$block" "fail_code")
    desc=$(extract_field "$block" "description")

    [ -n "$hid" ] || hid="unknown"

    if [ -z "$target" ]; then
        [ "$MODE" = "status" ] && say "skipping $hid - no file"
        continue
    fi
    if [ -z "$fail_code" ]; then
        [ "$MODE" = "status" ] && say "skipping $hid - no fail_code"
        continue
    fi

    full_path="/$target"
    if [ ! -f "$full_path" ]; then
        [ "$MODE" = "status" ] && say "skipping $hid - $target is not on this system"
        continue
    fi

    if ! grep -qF "$fail_code" "$full_path"; then
        [ "$MODE" = "status" ] && say "skipping $hid - $target does not need it (already fixed?)"
        continue
    fi

    count_pending=$((count_pending + 1))
    [ "$MODE" = "status" ] && say "would apply $hid to $target - $desc"
done < "$BLOCKS"

if [ "$MODE" = "status" ]; then
    if [ "$count_pending" -eq 0 ]; then
        say "nothing to apply - this system matches the hotfix database"
    else
        say "$count_pending hotfix(es) would be applied; no files were changed and no backup was taken"
        say "run 'copper charge' to back up and apply"
    fi
    exit 0
fi

# ------------------------------------------------------------------ apply
# The snapshot happens here, before the first sed, and covers every file a
# hotfix refers to rather than only the ones about to change.
take_snapshot

# One id per line per successful apply. Counting is done by reading this file
# rather than by incrementing a variable inside the loop: the loop is the
# right-hand side of a pipe, so it runs in a subshell and anything it counts
# is discarded before the next line runs. Recounting from the log file instead
# would be worse -- it counts every charge ever run, not this one.
RESULTS=$(mktemp) || die "mktemp failed"
trap 'rm -f "$TMP" "$BLOCKS" "$RESULTS"' EXIT INT TERM

while IFS= read -r block; do
    hid=$(extract_field "$block" "id")
    target=$(extract_field "$block" "file")
    fail_code=$(extract_field "$block" "fail_code")
    new_code=$(extract_field "$block" "new_code")
    desc=$(extract_field "$block" "description")

    [ -n "$hid" ] || hid="unknown"

    if [ -z "$target" ]; then
        say "skipping $hid - the entry names no file"
        continue
    fi
    if [ -z "$fail_code" ]; then
        say "skipping $hid - the entry has no fail_code, so there is nothing to match on"
        continue
    fi

    full_path="/$target"
    if [ ! -f "$full_path" ]; then
        # Said out loud on purpose. An entry whose target is not installed is
        # the one skip a person cannot work out for themselves: it looks
        # identical on screen to a hotfix that applied, and the usual reading
        # of a quiet charge is that nothing needed doing.
        say "skipping $hid - $target is not on this system"
        continue
    fi

    # Re-check rather than trust the first pass: between then and now the file
    # may have been edited, and applying on a stale match corrupts it.
    if ! grep -qF "$fail_code" "$full_path"; then
        say "skipping $hid - $target does not need it (already fixed?)"
        continue
    fi

    if sed -i "s|$(echo "$fail_code" | sed 's/[&/\]/\\&/g')|$(echo "$new_code" | sed 's/[&/\]/\\&/g')|" "$full_path"; then
        say "applied $hid to $target - $desc"
        echo "$hid" >> "$RESULTS"
    else
        say "FAILED to apply $hid to $target - the file was left as it was"
    fi
done < "$BLOCKS"

applied=$(grep -c . "$RESULTS" 2>/dev/null)
# grep -c prints its count AND exits 1 when nothing matched, so a plain
# "|| echo 0" would append a second line and produce "0\n0" -- which the
# arithmetic below then rejects as a bad number. Take the count if it is one,
# otherwise zero.
case "$applied" in
    '' | *[!0-9]*) applied=0 ;;
esac

if [ -n "$SNAP" ]; then
    say "restore point: copper rollback ${SNAP#$BACKUP_DIR/}"
else
    say "no restore point was needed - nothing was modified"
fi

if [ "$applied" -gt 0 ]; then
    say "charge complete - $applied hotfix(es) applied"
else
    say "charge complete - nothing needed patching, this system was already up to date"
fi
