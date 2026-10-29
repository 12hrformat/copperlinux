#!/bin/sh
# Prove the first-boot wizard cannot hot-loop when its stdin runs out.
#
# The 2026-10-30 audit found that the EOF guard (stdin_eof) never reached the
# password prompts or the fancy-mode field editor:
#
#   - read_password() loops on a rejected answer, and an empty answer is
#     always rejected, so a closed stdin printed "Password can't be empty."
#     / "Those didn't match" at full speed forever
#   - type_into() returned an empty answer on EOF without recording it, so
#     collect()'s retry loops (validating fields tight, secret fields every
#     900ms) re-asked a stdin that would never answer
#
# On a real machine that is a wizard spinning at 100% CPU on a boot nobody is
# watching -- exactly the failure mode the stdin_eof comment at the top of
# copper-firstboot.c says must never happen.
#
# The test compiles the shipped wizard source and runs it with closed stdin
# AND no controlling terminal (setsid), because getpass() reads /dev/tty and
# would otherwise block on a real terminal instead of taking the stdin
# fallback path where the bug lives. It asserts the wizard exits 1 with the
# "No answers were entered" message instead of running until killed.
#
# Safety: the apply path shells out to /bin/busybox (adduser, chpasswd) with
# absolute paths, which no non-Copper host has, so even a regression that let
# the wizard past the EOF check cannot change this machine's accounts.
#
# Needs a C compiler and setsid; skips cleanly without either, the same
# contract as xprobe-gate.sh and shell-gate.sh.
#
# Run: sh tests/firstboot-eof-gate.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/iso/firstboot/copper-firstboot.c"
TMP=$(mktemp -d /tmp/firstboot-eof-gate.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

CC=""
for c in gcc cc clang musl-gcc; do
    if command -v "$c" >/dev/null 2>&1; then CC="$c"; break; fi
done
if [ -z "$CC" ]; then
    echo "SKIPPED: no C compiler on this host"
    exit 0
fi
if ! command -v setsid >/dev/null 2>&1; then
    echo "SKIPPED: no setsid on this host (needed to detach the tty)"
    exit 0
fi

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n       %s\n' "$1" "$2"; fails=$((fails + 1)); }

if ! "$CC" -O2 -o "$TMP/wizard" "$SRC" 2>"$TMP/cc.log"; then
    echo "  FAIL copper-firstboot does not compile"
    sed 's/^/       /' "$TMP/cc.log"
    exit 1
fi

# Closed stdin, no controlling tty, hard 10s bound. 124 from timeout means it
# ran until killed: that is the hot loop this gate exists to catch.
setsid timeout 10 "$TMP/wizard" </dev/null >"$TMP/out.log" 2>&1
rc=$?

if [ "$rc" -eq 124 ]; then
    bad "wizard survives a dead stdin" \
        "still running after 10s -- the EOF hot loop is back"
elif [ "$rc" -ne 1 ]; then
    bad "wizard survives a dead stdin" \
        "expected exit 1, got $rc; tail: $(tail -1 "$TMP/out.log")"
elif ! grep -q "No answers were entered" "$TMP/out.log"; then
    bad "wizard survives a dead stdin" \
        "exited 1 but never said why; tail: $(tail -1 "$TMP/out.log")"
else
    ok "wizard aborts cleanly on a dead stdin (exit 1, says so, no loop)"
fi

# The password prompts are the specific loops that were missed: the transcript
# must show the question was reached (the fallback prints it on stdin) and
# that the wizard did not print the reject message forever.
n=$(grep -c "Password can't be empty\|Those didn't match" "$TMP/out.log")
if [ "$n" -gt 2 ]; then
    bad "password prompt stops on EOF" \
        "reject message printed $n times -- re-asking forever"
else
    ok "password prompt gives up on a dead stdin (reject printed $n time(s))"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "firstboot-eof-gate: all checks passed"
    exit 0
fi
echo "firstboot-eof-gate: $fails check(s) FAILED"
exit 1
