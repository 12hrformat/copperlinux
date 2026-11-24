#!/bin/sh
# Prove copper-sh survives the defects the 2026-10-30 audit found: a trailing
# pipe and a redirect-only line reached NULL argv, b_chmod turned "chmod xyz"
# into mode 0, tokenize_line overflowed its argv on a long line, and
# refresh_line's unbounded write length overread its stack buffer.
# Needs a C compiler; without one this test SKIPS, like xprobe-gate.sh.
# Run: sh tests/shell-gate.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d /tmp/shell-gate.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

CC=""
for c in gcc cc clang musl-gcc; do
    if command -v "$c" >/dev/null 2>&1; then CC="$c"; break; fi
done
if [ -z "$CC" ]; then
    echo "SKIPPED: no C compiler on this host"
    exit 0
fi

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n       %s\n' "$1" "$2"; fails=$((fails + 1)); }

# Build the real sources with -O2; the shipped code, not the flags, is under test.
if ! "$CC" -O2 -o "$TMP/copper-sh" "$REPO/src/main.c" "$REPO/src/builtins.c" \
        2>"$TMP/cc.log"; then
    echo "  FAIL copper-sh does not compile"
    sed 's/^/       /' "$TMP/cc.log"
    exit 1
fi
SH="$TMP/copper-sh"
cd "$TMP" || exit 1

# Non-tty shell: read_line_edited() takes the getline() fallback.
rc=0
out=""
run() {
    out=$("$SH" 2>&1)
    rc=$?
}

# 1. a trailing pipe must be an error message, never a signal.
printf 'true |\n' > in
run < in
if [ "$rc" -ge 128 ]; then
    bad "trailing pipe" "died on signal (rc=$rc); NULL argv reached the child"
elif ! printf '%s' "$out" | grep -q "no command after"; then
    bad "trailing pipe" "no diagnostic; rc=$rc out=$out"
else
    ok "trailing pipe is refused, not a crash"
fi

# chmod must reject non-octal: mode 0 from a typo is silent data damage.
printf 'x\n' > f
printf 'chmod xyz f\n' > in
run < in
mode=$(stat -c %a f)
if [ "$mode" = "0" ]; then
    bad "chmod validates its mode" "typo became mode 0 -- file is now unreachable"
elif ! printf '%s' "$out" | grep -q "invalid mode"; then
    bad "chmod validates its mode" "no diagnostic; mode is now $mode"
else
    ok "chmod refuses a non-octal mode and says so"
fi
printf 'chmod 600 f\nchmod 7777 f\n' > in
run < in
mode=$(stat -c %a f)
if [ "$mode" = "7777" ]; then
    ok "chmod accepts valid octal (600 and 7777 both applied)"
else
    bad "chmod accepts valid octal" "expected 7777, got $mode (out: $out)"
fi

# 300 two-byte words fit one line and must error, not overrun argv[].
{
    i=0
    while [ "$i" -lt 300 ]; do printf 'a '; i=$((i + 1)); done
    printf '\n'
} > in
run < in
if [ "$rc" -ge 128 ]; then
    bad "argv slot bound" "died on signal (rc=$rc); argv[] overflowed"
elif ! printf '%s' "$out" | grep -q "too many words"; then
    bad "argv slot bound" "no diagnostic; rc=$rc"
else
    ok "a 300-word line is refused before it overflows argv"
fi

# A redirect-only line is legal shell and must create the file, not crash.
printf '> only-redirect\n' > in
run < in
if [ "$rc" -ge 128 ]; then
    bad "redirect-only line" "died on signal (rc=$rc)"
elif [ ! -f only-redirect ]; then
    bad "redirect-only line" "file was not created; rc=$rc out=$out"
else
    ok "a redirect-only line creates the file and exits cleanly"
fi

# Everyday shapes still work, so the guards do not swallow real commands.
printf 'echo piped thing | wc -w\n' > in
run < in
if printf '%s' "$out" | grep -q '2'; then
    ok "an ordinary pipeline still runs"
else
    bad "an ordinary pipeline still runs" "out=$out"
fi

# Mirror refresh_line's clamp arithmetic statically: an overread does not
# crash on demand, so fail loudly if someone restores unbounded `n`.
if grep -A8 'static void refresh_line' "$REPO/src/main.c" | grep -q 'sizeof seq'; then
    ok "refresh_line clamps its write length to the buffer"
else
    bad "refresh_line clamps its write length" \
        "no clamp in refresh_line(); snprintf's return is unbounded again"
fi

# Chaining: ';' always, '&&' on success, '||' on failure, even with no spaces.
rm -f chain
printf 'echo one > chain; echo two >> chain\ntrue && echo three >> chain\nfalse && echo WRONG >> chain\nfalse || echo four >> chain\ntrue || echo WRONG >> chain\necho five&&echo six >> chain\n' > in
run < in
got=$(tr '\n' ' ' < chain 2>/dev/null)
if [ "$got" != "one two three four six " ]; then
    bad "command chaining" "chain file was '$got', wanted 'one two three four six '"
elif printf '%s' "$out" | grep -q 'WRONG'; then
    bad "command chaining" "a branch ran when its condition said not to"
elif ! printf '%s' "$out" | grep -q 'five'; then
    bad "command chaining" "no-space '&&' swallowed the command before it"
else
    ok "; && || chain in order and honour exit status"
fi

# A missing command must point at ingot, not just name itself.
printf 'definitely-not-a-command\n' > in
run < in
if ! printf '%s' "$out" | grep -q 'definitely-not-a-command: not installed or command not found'; then
    bad "missing command hint" "no 'not installed' diagnostic; out=$out"
elif ! printf '%s' "$out" | grep -q 'maybe try: sudo ingot install definitely-not-a-command'; then
    bad "missing command hint" "no ingot suggestion; out=$out"
else
    ok "a missing command says so and suggests ingot"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "shell-gate: all checks passed"
    exit 0
fi
echo "shell-gate: $fails check(s) FAILED"
exit 1
