#!/bin/sh
# Prove the real xprobe binary makes the liveness decision startxfce relies on,
# against a synthetic X server that speaks just enough of the wire protocol.
#
# xprobe is a static C binary; the image builds it in iso/build.sh with musl-gcc
# and stages it as /usr/bin/xprobe. This test compiles THE SOURCE with whatever
# C compiler the host has and drives the resulting binary through every socket
# state, asserting the exit-code contract described in iso/x11/probe/xprobe.c:
#
#   0  live       the display answered the handshake and the geometry query
#   1  not live   no socket, or the connection was refused
#   2  usage      the probe was called wrongly
#   3  unknown    something was reached but would not answer (timeout etc.)
#
# The synthetic server is plain python3 with no third-party modules. "reply"
# completes a real ConnectionSetup + GetGeometry round trip; "mute" accepts the
# connection and then says nothing -- the exact state that used to hang xprobe
# forever, because its reads had no timeout at all.
#
# Needs: a C compiler (gcc, cc, clang or musl-gcc) and python3. Without a
# compiler this test SKIPS and says so; it does not fail -- the Windows box
# this tree is maintained on has no gcc, and the CI image and build VM do.
#
# Run: sh tests/xprobe-gate.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/iso/x11/probe/xprobe.c"
BUILD="$REPO/iso/build.sh"
TMP=$(mktemp -d /tmp/xprobe-gate.XXXXXX) || exit 1
SOCK="$TMP/.X11-unix"
mkdir -p "$SOCK"
fails=0

cleanup() {
    pkill -P $$ 2>/dev/null
    rm -rf "$TMP" 2>/dev/null
}
trap cleanup EXIT INT TERM HUP

ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$2', got '$3'"; fi; }
has() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *)      bad "$1" "expected '$2' in the output; it said: $(printf '%s' "$3" | tr '\n' '|')" ;;
    esac
}

[ -f "$SRC" ] || { echo "FAIL  $SRC does not exist"; exit 1; }
[ -f "$BUILD" ] || { echo "FAIL  $BUILD does not exist"; exit 1; }

CC=${CC:-}
if [ -z "$CC" ]; then
    for c in gcc cc clang musl-gcc; do
        if command -v "$c" >/dev/null 2>&1; then CC=$c; break; fi
    done
fi
if [ -z "$CC" ]; then
    echo "=== no C compiler on this host; cannot build the real xprobe ==="
    echo "  SKIPPED (install gcc, or run this where the image is built)"
    exit 0
fi

# A synthetic X server on $SOCK/X0. mode reply|mute.
fakex() {
    python3 - "$SOCK/X0" "$1" >/dev/null 2>&1 <<'PY' &
import socket, struct, sys, time, os
path, mode = sys.argv[1], sys.argv[2]
try:
    os.unlink(path)
except OSError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(4)
while True:
    conn, _ = srv.accept()
    try:
        req = conn.recv(12)
        if len(req) < 12:
            conn.close()
            continue
        if mode == "mute":
            # Accept, read the setup request, never answer. This is the
            # "socket exists, something accepts, nothing speaks X" case.
            time.sleep(600)
        vendor = b"fakex"
        vendor_pad = (len(vendor) + 3) & ~3
        body = bytearray(32)
        struct.pack_into("<I", body, 0, 1000)          # release number
        struct.pack_into("<I", body, 4, 0x04000000)    # resource id base
        struct.pack_into("<I", body, 8, 0x003FFFFF)    # resource id mask
        struct.pack_into("<I", body, 12, 0)            # motion buffer size
        struct.pack_into("<H", body, 16, len(vendor))  # vendor_len
        struct.pack_into("<H", body, 18, 4096)         # max request length
        body[20] = 1   # roots_len (one screen)
        body[21] = 0   # pixmap_formats_len
        body[24] = 0   # scanline unit
        body[25] = 0   # scanline pad
        body[26] = 8   # min keycode
        body[27] = 255 # max keycode
        screen = bytearray(40)
        struct.pack_into("<I", screen, 0, 0x123456)    # root window
        struct.pack_into("<I", screen, 4, 0x20)        # default colormap
        struct.pack_into("<I", screen, 8, 0xFFFFFF)    # white pixel
        struct.pack_into("<I", screen, 12, 0x0)        # black pixel
        struct.pack_into("<H", screen, 20, 1280)       # width
        struct.pack_into("<H", screen, 22, 800)        # height
        screen[38] = 24                                # root depth
        screen[39] = 0                                 # num depths
        after = bytes(body) + vendor + b"\x00" * (vendor_pad - len(vendor)) + bytes(screen)
        length = len(after) // 4
        hdr = struct.pack("<BBHHH", 1, 0, 11, 0, length)
        conn.sendall(hdr + after)
        g = conn.recv(8)
        if len(g) < 8:
            conn.close()
            continue
        gr = bytearray(24)
        gr[0] = 1                       # reply type (1 = reply)
        gr[1] = 24                      # depth
        struct.pack_into("<H", gr, 2, 1)             # sequence
        struct.pack_into("<I", gr, 4, 0)             # reply length
        struct.pack_into("<I", gr, 8, 0x123456)      # root
        struct.pack_into("<H", gr, 16, 1280)         # width
        struct.pack_into("<H", gr, 18, 800)          # height
        conn.sendall(bytes(gr))
    except Exception:
        pass
    finally:
        conn.close()
PY
}

# run <label> <want-rc> [XPROBE_TIMEOUT seconds]
run() {
    want=$2
    tmo=${3:-2}
    DISPLAY=:0 XPROBE_SOCKET_DIR="$SOCK" XPROBE_TIMEOUT="$tmo" \
        timeout 15 "$TMP/xprobe" >"$TMP/out" 2>"$TMP/err"
    rc=$?
    eq "  $1" "$want" "$rc"
}

echo "=== the source compiles the way the image builds it ==="
if $CC -std=c11 -O2 -Wall -Wextra -o "$TMP/xprobe" "$SRC" 2>"$TMP/cc.err"; then
    ok "compiles with $CC -std=c11 -Wall -Wextra"
else
    bad "compiles with $CC -std=c11 -Wall -Wextra" "$(cat "$TMP/cc.err")"
    echo "cannot continue without a binary"
    exit 1
fi
if [ -s "$TMP/cc.err" ]; then
    bad "compiles without warnings" "$(cat "$TMP/cc.err")"
else
    ok "compiles without warnings"
fi

echo
echo "=== case A: no socket at all ==="
run "no socket answers 1 (not live)" 1

echo
echo "=== case B: a stale socket file, nothing listening ==="
python3 -c "import socket,sys
s = socket.socket(socket.AF_UNIX)
s.bind('$SOCK/X0')
s.close()"
[ -S "$SOCK/X0" ] && echo "  (set up: socket file exists, nothing is listening)"
run "stale socket answers 1 (not live)" 1

echo
echo "=== case C: a listener that accepts but never speaks X ==="
fakex mute
fpid=$!
sleep 0.5
start=$(date +%s)
run "mute listener answers 3 (unknown), does not hang" 3
elapsed=$(($(date +%s) - start))
if [ "$elapsed" -le 8 ]; then
    ok "  bounded: returned in ${elapsed}s instead of hanging"
else
    bad "bounded" "took ${elapsed}s"
fi
kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
rm -f "$SOCK/X0"

echo
echo "=== case D: a live server answers the handshake ==="
fakex reply
fpid=$!
sleep 0.5
run "live server answers 0 (live)" 0
has "  completed the handshake" "handshake.status=success" "$(cat "$TMP/out")"
has "  read the geometry back" "getgeometry.status=ok" "$(cat "$TMP/out")"
has "  reported the width" "getgeometry.width=1280" "$(cat "$TMP/out")"
has "  reported the height" "getgeometry.height=800" "$(cat "$TMP/out")"
kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
rm -f "$SOCK/X0"

echo
echo "=== case E: usage errors answer 2 ==="
DISPLAY= XPROBE_SOCKET_DIR="$SOCK" XPROBE_TIMEOUT=2 "$TMP/xprobe" >/dev/null 2>&1
eq "  no DISPLAY answers 2 (usage)" 2 "$?"
DISPLAY=:0 XPROBE_SOCKET_DIR="$SOCK" XPROBE_TIMEOUT=2 "$TMP/xprobe" --bogus >/dev/null 2>&1
eq "  an unknown option answers 2 (usage)" 2 "$?"

echo
echo "=== case F: XPROBE_TIMEOUT bounds the wait, as configured ==="
fakex mute
fpid=$!
sleep 0.5
start=$(date +%s)
run "1s timeout returns unknown instead of hanging" 3 1
elapsed=$(($(date +%s) - start))
if [ "$elapsed" -ge 1 ] && [ "$elapsed" -le 6 ]; then
    ok "  honored: returned in ${elapsed}s (want about 1s)"
else
    bad "honored timeout" "took ${elapsed}s"
fi
kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
rm -f "$SOCK/X0"

echo
echo "=== case G: iso/build.sh stages the binary built from this source ==="
# No toolchain needed: this is a static check that the build integration exists,
# so the fix cannot silently ship as "source changed but the ISO never got it".
if grep -q -- '-o "$TGT/usr/bin/xprobe"' "$BUILD"; then
    ok "  the build compiles it to \$TGT/usr/bin/xprobe"
else
    bad "  the build compiles it to \$TGT/usr/bin/xprobe" "compile line not found"
fi
if grep -q -- '[ -x "$TGT/usr/bin/xprobe" ]' "$BUILD"; then
    ok "  the build refuses to skip a missing /usr/bin/xprobe"
else
    bad "  the build refuses to skip a missing /usr/bin/xprobe" "existence check not found"
fi
if [ "$(grep -c '"$ROOT/x11/probe/xprobe.c"' "$BUILD")" -ge 2 ]; then
    ok "  the source feeds both the skip-stamp and the build-stamp lists"
else
    bad "  the source feeds both the skip-stamp and the build-stamp lists" \
        "expected >=2 mentions, found $(grep -c '"$ROOT/x11/probe/xprobe.c"' "$BUILD")"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "all xprobe checks passed"
else
    echo "$fails xprobe checks FAILED"
    exit 1
fi