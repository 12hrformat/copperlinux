#!/bin/sh
# The account-file test that HANDOFF.md claimed existed and did not.
#
# Run as root:  sudo tests/account.sh
#
# The bug this guards against
# ---------------------------
# The wizard appends the new account to /etc/passwd, /etc/group and
# /etc/shadow. If any of those files did not end in a newline, the last
# existing record and the brand new one get welded into a single unparseable
# line, busybox then refuses to read the file at all ("addgroup: /etc/passwd:
# bad record"), and you get an account that exists on disk and does not work.
# It happened twice, on two different boots.
#
# Nothing asserted any of it. The fix (ensure_trailing_newline,
# create_user_direct) shipped on the strength of "we saw it work once on a real
# machine", which is not a test.
#
# Running it safely
# -----------------
# The wizard writes those three paths absolutely, so testing it without
# rewriting the host's real accounts is only possible by giving it a private
# /etc inside a mount namespace. That is the unshare below. Tests/account-gate.sh
# puts each original bug back and checks this file goes red, because a test
# that has never failed proves nothing.
#
# The three files are seeded WITHOUT a trailing newline on purpose: that is the
# exact state that caused the bug, and seeding a well-formed file would make
# this pass without exercising the fix at all.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
ROOT=${ACCT_ROOT:-/tmp/copper-acct-test}
WIZ=${ACCT_WIZ:-/tmp/copper-acct-test/wizard}
DRIVER="$REPO/tests/firstboot-drive.py"
# ACCT_SRC exists so tests/account-gate.sh can point this at a deliberately
# sabotaged copy of the source and check the assertions below actually fire.
SRC=${ACCT_SRC:-$REPO/iso/firstboot/copper-firstboot.c}

if [ "$(id -u)" -ne 0 ]; then
    echo "tests/account.sh must run as root: sudo tests/account.sh" >&2
    exit 1
fi

fail=0
ok()  { printf 'ok   : %s\n' "$1"; }
bad() { fail=1; printf 'FAIL : %s\n' "$1"; }

echo "account files: does a wizard run leave /etc readable?"
echo

command -v unshare >/dev/null 2>&1 || { echo "FAIL : unshare not available" >&2; exit 1; }

rm -rf "$ROOT"
mkdir -p "$ROOT/etc"

# Build the wizard from the real source, so the test tracks the shipped code
# rather than a binary somebody left behind.
if ! gcc -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter \
         -I "$(dirname "$SRC")" "$SRC" -o "$WIZ"; then
    echo "FAIL : copper-firstboot.c did not build" >&2
    exit 1
fi

# Copy the whole of /etc: the wizard needs skel, shells, localtime and more, and
# a stripped-down /etc would fail for reasons that have nothing to do with the
# thing under test.
cp -a /etc/. "$ROOT/etc/" 2>/dev/null

# Now replace the three account files with hand-built ones whose last line has
# no terminating newline -- the condition that caused the original bug.
printf 'root:x:0:0:root:/root:/bin/sh\nseeduser:x:1000:1000:Seed User:/home/seeduser:/bin/sh\n' \
    > "$ROOT/etc/passwd"
printf 'root:x:0:\nseedgroup:x:1000:\n' > "$ROOT/etc/group"
printf 'root:!:19000:0:99999:7:::\nseeduser:!:19000:0:99999:7:::\n' > "$ROOT/etc/shadow"

# Guarantee it: the writes above end with newlines, which is the *healthy* state,
# so strip the final byte to create the fault we are testing for.
for f in passwd group shadow; do
    truncate -s -1 "$ROOT/etc/$f"
    printf 'seeded /etc/%-7s last byte %s (no trailing newline)\n' \
        "$f" "$(tail -c 1 "$ROOT/etc/$f" | od -An -c | tr -d ' \n')"
done
echo

# ---------------------------------------------------------------- run it
out=$(unshare --mount --propagation private /bin/sh -c "
    mount --bind '$ROOT/etc' /etc || { echo 'bind mount failed'; exit 1; }
    cd /tmp
    exec python3 '$DRIVER' '$WIZ'
" 2>&1)
rc=$?

# The transcript is 40 screens of escape sequences. Show it only when it went
# wrong, or when VERBOSE=1, because otherwise the actual verdicts scroll away.
if [ $rc -ne 0 ] || [ "${VERBOSE:-0}" = 1 ]; then
    printf '%s\n' "$out"
else
    printf '%s\n' "$out" | grep '^===' | sed 's/^/  /'
fi

if [ $rc -ne 0 ]; then
    bad "the wizard run did not complete (exit $rc)"
    echo "$fail check(s) failed"
    exit 1
fi

# ---------------------------------------------------------------- assert
# Field counts, which is how the welded record was caught the first time:
#   passwd  name:passwd:uid:gid:gecos:home:shell          7
#   group   name:passwd:gid:members                       4
#   shadow  name:passwd:lastchg:min:max:warn:inact:exp:flag   9
parse() {
    file=$1; want=$2; lineno=0; badline=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        n=$(printf '%s' "$line" | awk -F: '{print NF}')
        if [ "$n" -ne "$want" ]; then
            badline=1
            printf '      %s line %d has %d fields, expected %d:\n' \
                   "$file" "$lineno" "$n" "$want"
            printf '        %s\n' "$line"
        fi
    done < "$ROOT/etc/$file"
    if [ $badline -eq 0 ]; then
        ok "$file: all $lineno lines have $want fields"
    else
        bad "$file has unparseable records"
    fi
}

parse passwd 7
parse group  4
parse shadow 9

bo_line=$(grep '^bo:' "$ROOT/etc/passwd" 2>/dev/null || true)
if [ -n "$bo_line" ]; then
    ok "/etc/passwd has a bo record"
    printf '      %s\n' "$bo_line"
else
    bad "/etc/passwd has no bo record"
    sed 's/^/      /' "$ROOT/etc/passwd"
fi

bo_uid=$(printf '%s' "$bo_line" | cut -d: -f3)
bo_gid=$(printf '%s' "$bo_line" | cut -d: -f4)

# The uid must not already belong to somebody else. This is not theoretical: the
# scan that picks a free uid read the password field instead of the uid, so it
# always produced 1000 and handed out a duplicate. The kernel compares home
# directory ownership numerically, so a shared uid means the first user owns the
# second user's files outright.
if [ -n "$bo_uid" ]; then
    dupes=$(awk -F: -v u="$bo_uid" '$3==u && $1!="bo" {print $1}' "$ROOT/etc/passwd")
    if [ -z "$dupes" ]; then
        ok "bo's uid $bo_uid is not already taken"
    else
        bad "bo's uid $bo_uid is also used by: $dupes"
    fi

    if [ "$bo_uid" = "$bo_gid" ]; then
        ok "bo's uid and gid match ($bo_uid), the adduser convention"
    else
        bad "bo has uid $bo_uid but gid $bo_gid"
    fi

    if grep -q "^bo:x:$bo_uid:" "$ROOT/etc/group"; then
        ok "/etc/group has bo:$bo_uid"
    else
        bad "/etc/group has no bo:$bo_uid record"
    fi

    if grep -q '^bo:!' "$ROOT/etc/shadow"; then
        ok "/etc/shadow has a locked bo entry"
    else
        bad "/etc/shadow has no bo entry"
    fi

    home=$(printf '%s' "$bo_line" | cut -d: -f6)
    if [ -d "$home" ]; then
        ok "$home exists"
    else
        bad "$home was not created"
    fi
fi

if [ $fail -gt 0 ]; then
    echo "$fail check(s) failed"
    exit 1
fi
echo "account files: all good"