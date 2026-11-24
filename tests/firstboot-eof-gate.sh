#!/bin/sh
# Prove the first-boot wizard cannot hot-loop when its stdin runs out.
# The EOF guard never reached read_password() or type_into(), so closed stdin
# printed the reject messages forever and collect()'s retry loops re-asked a
# stdin that would never answer: 100% CPU on a boot nobody is watching.
# Compile the shipped source, run with closed stdin and no tty (setsid, since
# getpass would otherwise block on /dev/tty) and require exit 1 with the right
# message. /bin/busybox absolute paths keep any regression off this host's
# accounts; skips cleanly without a compiler or setsid.
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

# 124 from timeout means the hot loop is back.
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

# The transcript must reach the prompt without printing rejects forever.
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
