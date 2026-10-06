#!/bin/bash
# Build gate: the hotfix database must survive the parser that reads it.
#
# The parser in copper-charge.sh is hand-written awk because the live system
# has no python3. It had a bug that no amount of reading would have caught and
# that a single-entry database could never reveal: it concatenated the whole
# file into one line, so every field came back as the LAST entry value and all
# but the last entry were invisible. It worked on the one entry that shipped.
#
# So this does not test the parser against a copy of the parser. It runs the
# real script and compares what comes out against what is actually in the file:
#
#   * one line out per fail_code key in the database
#   * no empty id, file, fail_code or new_code
#   * no line containing a tab inside a field, which would mean a value with a
#     tab in it has silently split into two fields
#
# Set HOTFIX_DB to check a different database file.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DB="${HOTFIX_DB:-$REPO/hotfixes.json}"
CHARGE="$REPO/iso/copper-charge.sh"

[ -f "$DB" ] || { echo "  assert_hotfix_db: no database at $DB"; exit 1; }
[ -f "$CHARGE" ] || { echo "  assert_hotfix_db: no copper-charge.sh"; exit 1; }

fails=0
bad() { echo "  assert_hotfix_db: $*"; fails=$((fails + 1)); }

# Count the entries the database actually declares. Count OCCURRENCES of the
# key, not the lines containing it: the same database minified onto one line is
# still three entries, and a line count would expect one.
want=$(grep -o '"fail_code"[[:space:]]*:' "$DB" | wc -l | tr -d ' ')
case "$want" in
    ''|*[!0-9]*) want=0 ;;
esac

if [ "$want" -eq 0 ]; then
    echo "  assert_hotfix_db: $DB declares no hotfixes; nothing to check"
    exit 0
fi

# Run the real parser, with the config pointed at this database and everything
# it would touch redirected into a scratch directory.
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT

out=$(COPPER_CONFIG=/dev/null \
      HOTFIX_DB="$DB" \
      HOTFIX_URL="http://127.0.0.1:1/none.json" \
      BACKUP_DIR="$scratch/backups" \
      LOG_FILE="$scratch/log" \
      sh "$CHARGE" --dump-entries 2>/dev/null)

got=$(printf '%s' "$out" | grep -c . || true)
case "$got" in
    ''|*[!0-9]*) got=0 ;;
esac

if [ "$got" -ne "$want" ]; then
    bad "$DB declares $want entries but the parser produced $got"
    printf '%s\n' "$out" | sed 's/^/      /'
    exit 1
fi

# Check every field in one pass. Done in awk rather than a while read loop
# because a loop on the right-hand side of a pipe runs in a subshell, and
# anything it counts is gone by the time the script checks it.
#
# NF != 5 catches a value containing a tab, which would otherwise split one
# field into two and quietly shift every later field along.
problems=$(printf '%s\n' "$out" | awk -F'\t' '
    {
        n++
        if ($1 == "")   { print "entry " n " has no id";       e++ }
        if ($2 == "")   { print "entry " n " has no file";     e++ }
        if ($3 == "")   { print "entry " n " has no fail_code"; e++ }
        if ($4 == "")   { print "entry " n " has no new_code";  e++ }
        if (NF != 5)    { print "entry " n " has " NF " fields, not 5"; e++ }
        if ($2 ~ /^\//) { print "entry " n " file is absolute: " $2; e++ }
    }
    END { exit (e > 0) }
' 2>&1)

if [ -n "$problems" ]; then
    echo "$problems" | sed 's/^/  assert_hotfix_db: /'
    fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
    exit 1
fi

echo "  assert_hotfix_db: $got entr(y/ies) from $(basename "$DB") read cleanly"
