#!/bin/sh
# firstboot-validators.sh -- compile the real validators, not a copy of them.
# The wizard interpolates username, hostname and timezone into shell commands.
# The source's validators are the only thing standing between a wizard answer
# and system(), so test the shipped functions themselves.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/iso/firstboot/copper-firstboot.c"
TMP=$(mktemp -d /tmp/copper-firstboot-validators.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT

if ! command -v cc >/dev/null 2>&1; then
    echo "SKIPPED no C compiler here"
    exit 0
fi

cat > "$TMP/check.c" <<EOF
#define main copper_firstboot_unused_main
#include "$SRC"
#undef main

static int fails = 0;
static void want(const char *what, int got, int expected) {
    if (got == expected) {
        printf("  ok   %s\n", what);
    } else {
        printf("  FAIL %s (got %d, wanted %d)\n", what, got, expected);
        fails++;
    }
}

int main(void) {
    want("valid_user accepts dragon",        valid_user("dragon"),     1);
    want("valid_user accepts under_score-1", valid_user("under_score-1"), 1);
    want("valid_user rejects empty",         valid_user(""),           0);
    want("valid_user rejects leading dash",  valid_user("-h"),         0);
    want("valid_user rejects shell syntax",  valid_user("a;b"),        0);
    want("valid_host accepts copper",        valid_host("copper"),     1);
    want("valid_host accepts a.b-c",         valid_host("a.b-c"),      1);
    want("valid_host rejects empty",         valid_host(""),           0);
    want("valid_host rejects leading dash",  valid_host("-h"),         0);
    want("valid_host rejects shell syntax",  valid_host("a;b"),        0);
    want("valid_tz accepts UTC",             valid_tz("UTC"),          1);
    want("valid_tz accepts Europe/London",   valid_tz("Europe/London"), 1);
    want("valid_tz accepts Etc/GMT-5",       valid_tz("Etc/GMT-5"),    1);
    want("valid_tz rejects empty",           valid_tz(""),             0);
    want("valid_tz rejects leading dash",    valid_tz("-x"),           0);
    want("valid_tz rejects traversal",       valid_tz("../../etc"),    0);
    return fails ? 1 : 0;
}
EOF

if ! cc -std=c11 -O0 -o "$TMP/check" "$TMP/check.c" 2>"$TMP/cc.log"; then
    echo "FAIL the real firstboot source did not compile in the validator harness"
    sed 's/^/       /' "$TMP/cc.log"
    exit 1
fi
"$TMP/check"
