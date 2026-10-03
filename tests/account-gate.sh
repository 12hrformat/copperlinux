#!/bin/sh
# Prove tests/account.sh catches the three bugs it exists for, by putting each
# one back and checking the test goes red.
#
# Run as root:  sudo tests/account-gate.sh
#
# A green test proves nothing until it has been seen to fail. The bug
# tests/account.sh guards was found by booting real hardware twice. The reason
# it came back a third time would be that everyone trusted a check that had
# never failed -- and the POSIX gate in iso/build.sh once printed "the busybox
# tools are POSIX sh" while checking zero files, so that is not a hypothetical.
#
# Each case copies the source, breaks it in one specific way, and runs the real
# assertions against the result. The repository source is never modified. If a
# sabotage no longer applies, that is reported as a failure: it means the source
# has moved on and this gate is no longer testing anything.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
TEST="$REPO/tests/account.sh"
SB=${GATE_ROOT:-/tmp/copper-acct-gate}

if [ "$(id -u)" -ne 0 ]; then
    echo "tests/account-gate.sh must run as root: sudo tests/account-gate.sh" >&2
    exit 1
fi

pass=0
fail=0

case_run() {
    name=$1
    sabotage=$2
    dir="$SB/$name"

    rm -rf "$dir"
    mkdir -p "$dir/src"
    cp "$REPO/iso/firstboot/copper-firstboot.c" "$dir/src/"

    python3 - "$dir/src/copper-firstboot.c" "$sabotage" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); mode = sys.argv[2]
s = p.read_text(encoding='utf-8')
before = s

if mode == 'uid_scan':
    # The original bug: read the password field instead of the uid, so atoi("x")
    # is 0, the v > 0 test throws it away, and every account is handed 1000.
    s = s.replace("            char *c2 = strchr(c1 + 1, ':');\n"
                  "            if (!c2) continue;\n"
                  "            int v = atoi(c2 + 1);          /* third field: uid */",
                  "            int v = atoi(c1 + 1);")
elif mode == 'shadow_fields':
    # The original bug: one colon too many, ten fields where shadow takes nine,
    # which shifts every field after the password one place to the right.
    s = s.replace('%s:!:0:0:99999:7:::', '%s:!::0:0:99999:7:::')
elif mode == 'no_newline_fix':
    # Switch off the trailing-newline repair, so the new record welds onto the
    # last existing one and the file stops parsing.
    s = s.replace('static void ensure_trailing_newline(const char *path) {',
                  'static void ensure_trailing_newline(const char *path) {\n'
                  '    return; (void)path;')
elif mode == 'clean':
    pass
else:
    raise SystemExit(f'unknown sabotage: {mode}')

if s == before and mode != 'clean':
    raise SystemExit(f'SABOTAGE DID NOT APPLY: {mode} -- the source has '
                     'changed, so this gate no longer tests anything')

p.write_text(s, encoding='utf-8')
PY
    if [ $? -ne 0 ]; then
        printf 'FAIL : %-14s sabotage did not apply\n' "$name"
        fail=$((fail + 1))
        return
    fi

    ACCT_SRC="$dir/src/copper-firstboot.c" \
    ACCT_ROOT="$dir/etc" \
    ACCT_WIZ="$dir/wizard" \
        "$TEST" > "$dir/out" 2>&1
    rc=$?

    if [ $rc -ne 0 ]; then
        printf 'ok   : %-14s the test went red, as it must\n' "$name"
        grep '^FAIL' "$dir/out" | head -2 | sed 's/^/       /'
        pass=$((pass + 1))
    else
        printf 'FAIL : %-14s still passed -- it does not catch this bug\n' "$name"
        fail=$((fail + 1))
    fi
}

echo "account test: proving it catches the bugs it is for"
echo

case_run uid_scan       uid_scan
case_run shadow_fields  shadow_fields
case_run no_newline_fix no_newline_fix

echo
if [ $fail -gt 0 ]; then
    echo "$pass proved, $fail not proved"
    exit 1
fi
echo "all $pass bugs are caught"