#!/usr/bin/env bash
# ingot gate test.
#
# Serves a fake GitHub Pages repo over localhost, points ingot at it via
# INGOT_REPO, and drives the REAL client (iso/rootfs-overlay/usr/bin/ingot,
# the same file that ships in the ISO) with INGOT_ROOT pointing at a scratch
# tree so nothing outside it is touched. Proves the whole design:
#
#   - the payload files land exactly where the tar said
#   - dependencies install first (cog before pinwheel)
#   - a sha256 mismatch refuses the payload and unpacks nothing
#   - the /tmp/<name> JSON is gone after every path
#   - an already-installed package is refused
#   - remove deletes exactly what the manifest recorded
#   - unknown names fail with a name, not a stack trace
#   - info prints the package JSON and cleans /tmp
#   - search greps the index
#
# Needs: python3 (to serve), wget, tar, sha256sum. No root: it never writes
# outside its own temp tree. CI runs it via tests/branch-gate.sh alongside
# the other root-using gates.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
INGOT="$REPO/iso/rootfs-overlay/usr/bin/ingot"
[ -f "$INGOT" ] || { echo "gates: $INGOT missing" >&2; exit 1; }

WORK=$(mktemp -d)
PORT=$(( 20000 + ($$ % 10000) ))
REPO_ROOT="$WORK/repo"        # the fake github-pages tree
ROOT="$WORK/root"             # INGOT_ROOT scratch target

pass=0; fail=0
note_ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
note_bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

SRV=
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# A stale /tmp from an earlier failed run would make the "cleaned" checks lie.
rm -f /tmp/pinwheel /tmp/cog /tmp/forged /tmp/cogwheel

mkdir -p "$REPO_ROOT/iso/copper/pkg/fun" "$REPO_ROOT/payloads" "$ROOT"

# ---- build the fake Pages repo -------------------------------------------
# index.json: name -> category, one entry per line (the shape ingot parses).
cat > "$REPO_ROOT/iso/copper/pkg/index.json" <<EOF
{
  "pinwheel": "fun",
  "cog": "fun",
  "forged": "fun"
}
EOF

# pinwheel-1.0: depends on cog; two payload files.
mkdir -p "$WORK/stage/usr/bin" "$WORK/stage/usr/share/pinwheel"
printf '#!/bin/sh\necho pinwheel-1.0\n' > "$WORK/stage/usr/bin/pinwheel"
printf 'pinwheel data\n' > "$WORK/stage/usr/share/pinwheel/data.txt"
( cd "$WORK/stage" && tar -czf "$REPO_ROOT/payloads/pinwheel-1.0.tar.gz" usr )
SHA_PIN=$(sha256sum "$REPO_ROOT/payloads/pinwheel-1.0.tar.gz" | awk '{print $1}')

# cog-1.0: no deps; dependency of pinwheel.
mkdir -p "$WORK/stage2/usr/lib"
printf 'cog lib\n' > "$WORK/stage2/usr/lib/libcog.so"
( cd "$WORK/stage2" && tar -czf "$REPO_ROOT/payloads/cog-1.0.tar.gz" usr )
SHA_COG=$(sha256sum "$REPO_ROOT/payloads/cog-1.0.tar.gz" | awk '{print $1}')

# forged-2.0: a real payload whose page JSON carries the WRONG sha256.
mkdir -p "$WORK/stage3/usr/bin"
printf 'forged binary\n' > "$WORK/stage3/usr/bin/forged"
( cd "$WORK/stage3" && tar -czf "$REPO_ROOT/payloads/forged-2.0.tar.gz" usr )
SHA_FORGED_WRONG=$(sha256sum "$REPO_ROOT/payloads/pinwheel-1.0.tar.gz" | awk '{print $1}')

cat > "$REPO_ROOT/iso/copper/pkg/fun/pinwheel" <<EOF
{
  "name": "pinwheel",
  "version": "1.0",
  "category": "fun",
  "url": "http://127.0.0.1:$PORT/payloads/pinwheel-1.0.tar.gz",
  "sha256": "$SHA_PIN",
  "depends": ["cog"]
}
EOF

cat > "$REPO_ROOT/iso/copper/pkg/fun/cog" <<EOF
{
  "name": "cog",
  "version": "1.0",
  "category": "fun",
  "url": "http://127.0.0.1:$PORT/payloads/cog-1.0.tar.gz",
  "sha256": "$SHA_COG"
}
EOF

cat > "$REPO_ROOT/iso/copper/pkg/fun/forged" <<EOF
{
  "name": "forged",
  "version": "2.0",
  "category": "fun",
  "url": "http://127.0.0.1:$PORT/payloads/forged-2.0.tar.gz",
  "sha256": "$SHA_FORGED_WRONG"
}
EOF

# ---- serve it, then point ingot at it ------------------------------------
( cd "$REPO_ROOT" \
  && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SRV=$!

up=
for i in $(seq 1 50); do
  if wget -q -O /dev/null "http://127.0.0.1:$PORT/iso/copper/pkg/index.json" 2>/dev/null; then
    up=1; break
  fi
  sleep 0.2
done
if [ -z "$up" ]; then
  note_bad "fake repo server never came up (need python3)"
  echo "    summary: pass=$pass fail=$fail"
  exit 1
fi

export INGOT_REPO="http://127.0.0.1:$PORT"
export INGOT_ROOT="$ROOT"

# ---- install: right files land, dep first --------------------------------
if out=$( sh "$INGOT" install pinwheel 2>&1 ); then
  note_ok "install pinwheel succeeded"
else
  note_bad "install pinwheel failed: $out"
fi
[ -f "$ROOT/usr/bin/pinwheel" ]                && note_ok "usr/bin/pinwheel landed"  || note_bad "usr/bin/pinwheel missing"
[ -f "$ROOT/usr/share/pinwheel/data.txt" ]     && note_ok "data.txt landed"           || note_bad "data.txt missing"
[ -f "$ROOT/usr/lib/libcog.so" ]               && note_ok "dependency cog installed"  || note_bad "dependency cog missing"
[ -f "$ROOT/var/lib/ingot/pinwheel.installed" ] && note_ok "manifest recorded"        || note_bad "manifest missing"
[ ! -e /tmp/pinwheel ]                         && note_ok "/tmp/pinwheel cleaned"     || note_bad "/tmp/pinwheel left behind"
[ ! -e /tmp/cog ]                              && note_ok "/tmp/cog cleaned"          || note_bad "/tmp/cog left behind"

# ---- sha256 mismatch: refuse, unpack nothing, clean /tmp ------------------
if out=$( sh "$INGOT" install forged 2>&1 ); then
  note_bad "forged (wrong sha256) installed!"
else
  note_ok "sha256 mismatch refused forged"
fi
[ ! -e "$ROOT/usr/bin/forged" ] && note_ok "forged was not unpacked" || note_bad "forged files landed!"
[ ! -e /tmp/forged ]            && note_ok "/tmp/forged cleaned"     || note_bad "/tmp/forged left behind"

# ---- already-installed guard ----------------------------------------------
if out=$( sh "$INGOT" install pinwheel 2>&1 ); then
  if printf '%s' "$out" | grep -q "already installed"; then
    note_ok "second install refused"
  else
    note_bad "second install behaved oddly: $out"
  fi
else
  note_bad "second install of an installed package failed"
fi

# ---- remove: exactly the recorded files, deps survive ---------------------
if out=$( sh "$INGOT" remove pinwheel 2>&1 ); then
  note_ok "remove pinwheel succeeded"
else
  note_bad "remove pinwheel failed: $out"
fi
[ ! -e "$ROOT/usr/bin/pinwheel" ]            && note_ok "pinwheel binary removed"  || note_bad "pinwheel binary remains"
[ ! -e "$ROOT/usr/share/pinwheel/data.txt" ] && note_ok "data.txt removed"          || note_bad "data.txt remains"
[ ! -e "$ROOT/var/lib/ingot/pinwheel.installed" ] && note_ok "manifest removed"     || note_bad "manifest remains"
[ -f "$ROOT/usr/lib/libcog.so" ]             && note_ok "dependency cog survived"   || note_bad "cog was removed too (remove must not recurse)"

# ---- unknown package, info, search ----------------------------------------
if out=$( sh "$INGOT" install no-such-pkg 2>&1 ); then
  note_bad "unknown package installed!"
else
  printf '%s' "$out" | grep -q "no package named" \
    && note_ok "unknown package refused by name" \
    || note_bad "unknown package message unexpected: $out"
fi

if out=$( sh "$INGOT" info cog 2>&1 ); then
  printf '%s' "$out" | grep -q '"name"' && note_ok "info prints the JSON" || note_bad "info JSON unexpected: $out"
  [ ! -e /tmp/cog ] && note_ok "info cleaned /tmp" || note_bad "/tmp/cog left by info"
else
  note_bad "info cog failed: $out"
fi

if out=$( sh "$INGOT" search cog 2>&1 ); then
  printf '%s' "$out" | grep -q "cog" && note_ok "search finds cog" || note_bad "search missed cog: $out"
else
  note_bad "search failed: $out"
fi

echo "    summary: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0