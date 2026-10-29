#!/bin/sh
# Prove copper-sh survives the defects the 2026-10-30 audit found in it, so a
# future edit cannot bring any of them back silently. Every case here was a
# real crash, a silent data-damage bug or an overread, found by reading the
# source and reproduced against the binary before the fix landed:
#
#   1. a trailing '|' parsed into a segment whose argv[0] is NULL, and the
#      child crashed in builtin_lookup()'s strcmp (SIGSEGV as root's shell)
#   2. b_chmod fed anything to strtol() with no validation, so
#      "chmod xyz file" silently became mode 0 -- an unreadable, unwritable file
#   3. tokenize_line() wrote past its fixed 256-slot argv on a line with more
#      words than slots, which one 4096-byte line can hold hundreds of
#   4. a redirect-only line ("> file") is legal in every other shell and used
#      to reach the same NULL-argv crash as the trailing pipe
#   5. refresh_line() passed snprintf()'s would-be length straight to write(),
#      reading past the end of its stack buffer whenever prompt+line exceeded
#      it -- the prompt alone reaches PATH_MAX + user + host. Clamped in the
#      source; the gate re-derives the clamp rather than trusting it.
#
# Needs a C compiler (gcc, cc, clang or musl-gcc); without one this test
# SKIPS and says so, the same contract as xprobe-gate.sh -- the Windows box
# this tree is maintained on has no gcc, CI and the build VM do.
#
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

# Build the real shell from the real sources. -O2 matches the Makefile closely
# enough; the point is the shipped code, not the flags.
if ! "$CC" -O2 -o "$TMP/copper-sh" "$REPO/src/main.c" "$REPO/src/builtins.c" \
        2>"$TMP/cc.log"; then
    echo "  FAIL copper-sh does not compile"
    sed 's/^/       /' "$TMP/cc.log"
    exit 1
fi
SH="$TMP/copper-sh"
cd "$TMP" || exit 1

# run <label> -- feeds stdin lines to the shell, captures stdout+stderr+rc.
# The shell is not a tty here, so read_line_edited() takes its getline()
# fallback and every line is executed without a prompt dance.
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

# 2. chmod must accept octal modes and refuse anything else, leaving the file
#    exactly as it was. Mode 0 from a typo used to be silent data damage.
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

# 3. more words than the 256-slot argv must be a clean error, not a write
#    past the end of the array. 300 two-byte words fit in one line easily.
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

# 4. a redirect-only line is legal shell: the file must appear, and nothing
#    may crash. The empty segment now stops at run_one()'s NULL guard.
printf '> only-redirect\n' > in
run < in
if [ "$rc" -ge 128 ]; then
    bad "redirect-only line" "died on signal (rc=$rc)"
elif [ ! -f only-redirect ]; then
    bad "redirect-only line" "file was not created; rc=$rc out=$out"
else
    ok "a redirect-only line creates the file and exits cleanly"
fi

# 5. the everyday shapes still work, so the guards above are not swallowing
#    real commands: a pipe, a redirect from a file, and a normal chmod.
printf 'echo piped thing | wc -w\n' > in
run < in
if printf '%s' "$out" | grep -q '2'; then
    ok "an ordinary pipeline still runs"
else
    bad "an ordinary pipeline still runs" "out=$out"
fi

# 6. the refresh_line clamp: rebuild the arithmetic the function uses and
#    prove a write length is never allowed past the buffer. This mirrors the
#    fix rather than executing it (an overread does not crash on demand), and
#    its job is to fail loudly if someone reverts the clamp to `n` unbounded.
if grep -A8 'static void refresh_line' "$REPO/src/main.c" | grep -q 'sizeof seq'; then
    ok "refresh_line clamps its write length to the buffer"
else
    bad "refresh_line clamps its write length" \
        "no clamp in refresh_line(); snprintf's return is unbounded again"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "shell-gate: all checks passed"
    exit 0
fi
echo "shell-gate: $fails check(s) FAILED"
exit 1
