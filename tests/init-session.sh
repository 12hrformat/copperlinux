#!/bin/sh
# The session-privilege test. Run as root:  sudo tests/init-session.sh
#
# The logic under test is the drop in iso/src-init/copper-init.c: the console
# shell must run as the wizard's account, not as root, or the browser refuses
# to start. See tests/init-session.c for what is asserted and why, and
# HANDOFF.md, "the session runs as root", for the bug this closes.
#
# This file only does the build: it compiles the test (which #includes the
# init source directly) and runs it. Keeping the build in shell and the
# assertions in C means the test can call the static helpers in copper-init.c,
# which a linked-against-the-binary test could not.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/iso/src-init/copper-init.c"

if [ "$(id -u)" -ne 0 ]; then
    echo "tests/init-session.sh must run as root: sudo tests/init-session.sh" >&2
    exit 1
fi

if [ ! -f "$SRC" ]; then
    echo "FAIL $SRC does not exist" >&2
    exit 1
fi

# cc, or whatever the environment names. The image builds this file with the
# project's cc, but the test only needs a host compiler.
CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || {
    echo "FAIL no C compiler ($CC)" >&2
    exit 1
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# -I points the #include "copper-init.c" at the real source. No -Werror: this
# compiles the shipped file against the host's headers, and a warning that the
# image's musl build does not produce must not fail the gate.
if ! "$CC" -std=c11 -Wall -I "$REPO/iso/src-init" \
        -o "$TMP/init-session" "$REPO/tests/init-session.c" 2>"$TMP/cc.err"; then
    echo "FAIL could not compile the test against $SRC"
    sed 's/^/     /' "$TMP/cc.err"
    exit 1
fi

"$TMP/init-session"
