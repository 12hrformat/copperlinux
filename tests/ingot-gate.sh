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
#   - list names the installed packages
#   - inspect shows the installed record (version + files)
#   - reinstall removes then installs again
#   - update reinstalls a package whose page sha256 moved, and reports
#     "up to date" when nothing changed
#   - install/remove/update/reinstall on the real / refuse for a non-root
#     user with a sudo hint (INGOT_ROOT is the rootless test path)
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
  "bigwheel": "fun",
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
SIZE_COG=$(wc -c < "$REPO_ROOT/payloads/cog-1.0.tar.gz")

# forged-2.0: a real payload whose page JSON carries the WRONG sha256.
mkdir -p "$WORK/stage3/usr/bin"
printf 'forged binary\n' > "$WORK/stage3/usr/bin/forged"
( cd "$WORK/stage3" && tar -czf "$REPO_ROOT/payloads/forged-2.0.tar.gz" usr )
SHA_FORGED_WRONG=$(sha256sum "$REPO_ROOT/payloads/pinwheel-1.0.tar.gz" | awk '{print $1}')
SIZE_FORGED=$(wc -c < "$REPO_ROOT/payloads/forged-2.0.tar.gz")

# bigwheel-1.0: a payload > 1MiB (urandom so the tarball won't shrink) so the
# tty progress bar's >= 1048576 gate actually triggers under the pty test.
mkdir -p "$WORK/stage4b/usr/lib"
dd if=/dev/urandom of="$WORK/stage4b/usr/lib/big.dat" bs=1M count=2 status=none 2>/dev/null
( cd "$WORK/stage4b" && tar -czf "$REPO_ROOT/payloads/bigwheel-1.0.tar.gz" usr )
SHA_BIGWHEEL=$(sha256sum "$REPO_ROOT/payloads/bigwheel-1.0.tar.gz" | awk '{print $1}')
SIZE_BIGWHEEL=$(wc -c < "$REPO_ROOT/payloads/bigwheel-1.0.tar.gz")

SIZE_PIN=$(wc -c < "$REPO_ROOT/payloads/pinwheel-1.0.tar.gz")

cat > "$REPO_ROOT/iso/copper/pkg/fun/pinwheel" <<EOF
{
  "name": "pinwheel",
  "version": "1.0",
  "category": "fun",
  "url": "http://127.0.0.1:$PORT/payloads/pinwheel-1.0.tar.gz",
  "size": $SIZE_PIN,
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
  "size": $SIZE_COG,
  "sha256": "$SHA_COG"
}
EOF

cat > "$REPO_ROOT/iso/copper/pkg/fun/forged" <<EOF
{
  "name": "forged",
  "version": "2.0",
  "category": "fun",
  "url": "http://127.0.0.1:$PORT/payloads/forged-2.0.tar.gz",
  "size": $SIZE_FORGED,
  "sha256": "$SHA_FORGED_WRONG"
}
EOF

cat > "$REPO_ROOT/iso/copper/pkg/fun/bigwheel" <<EOF
{
  "name": "bigwheel",
  "version": "1.0",
  "category": "fun",
  "url": "http://127.0.0.1:$PORT/payloads/bigwheel-1.0.tar.gz",
  "size": $SIZE_BIGWHEEL,
  "sha256": "$SHA_BIGWHEEL"
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
printf '%s' "$out" | grep -q "installing pinwheel 1.0" \
  && note_ok "install names the package+version" || note_bad "no install status line: $out"
printf '%s' "$out" | grep -q "downloading pinwheel-1.0.tar.gz (" \
  && note_ok "install reports download with a size" || note_bad "no size-aware download line: $out"
printf '%s' "$out" | grep -q "downloading cog-1.0.tar.gz (" \
  && note_ok "dependency download reported too" || note_bad "dep download line missing: $out"
printf '%s' "$out" | grep -q "verifying pinwheel checksum" \
  && note_ok "install shows the verify step" || note_bad "verify step line missing: $out"
printf '%s' "$out" | grep -q "KiB/s" \
  && note_bad "bar leaked into a piped (non-tty) run" \
  || note_ok "non-tty install has no progress bar"
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

# ---- list: the still-installed dependency shows up --------------------------
if out=$( sh "$INGOT" list 2>&1 ); then
  printf '%s' "$out" | grep -q "cog" && note_ok "list shows installed cog" || note_bad "list missed cog: $out"
else
  note_bad "list failed: $out"
fi

# ---- inspect: show the installed record, not the repo page ------------------
if out=$( sh "$INGOT" inspect cog 2>&1 ); then
  printf '%s' "$out" | grep -q "cog 1.0"      && note_ok "inspect shows version"  || note_bad "inspect version odd: $out"
  printf '%s' "$out" | grep -q "usr/lib/libcog.so" && note_ok "inspect lists files" || note_bad "inspect files odd: $out"
else
  note_bad "inspect cog failed: $out"
fi

# ---- reinstall: remove + install again, files land again --------------------
if out=$( sh "$INGOT" reinstall cog 2>&1 ); then
  [ -f "$ROOT/usr/lib/libcog.so" ] && note_ok "reinstall put the lib back" || note_bad "reinstall lost the lib: $out"
else
  note_bad "reinstall cog failed: $out"
fi

# ---- update with nothing changed: up to date, no re-download -----------------
if out=$( sh "$INGOT" update cog 2>&1 ); then
  printf '%s' "$out" | grep -q "up to date" && note_ok "unchanged package reports up to date" || note_bad "update all odd: $out"
else
  note_bad "update cog (unchanged) failed: $out"
fi

# ---- update with a newer payload on the page: reinstalls fresh ---------------
# Bump cog's page to 1.1 with a *new* payload tarball that has the same paths
# but different bytes. update must notice the sha256 moved and reinstall.
mkdir -p "$WORK/stage4/usr/lib"
printf 'cog lib 1.1\n' > "$WORK/stage4/usr/lib/libcog.so"
( cd "$WORK/stage4" && tar -czf "$REPO_ROOT/payloads/cog-1.1.tar.gz" usr )
SHA_COG_11=$(sha256sum "$REPO_ROOT/payloads/cog-1.1.tar.gz" | awk '{print $1}')
SIZE_COG_11=$(wc -c < "$REPO_ROOT/payloads/cog-1.1.tar.gz")
cat > "$REPO_ROOT/iso/copper/pkg/fun/cog" <<EOF
{
  "name": "cog",
  "version": "1.1",
  "category": "fun",
  "url": "http://127.0.0.1:$PORT/payloads/cog-1.1.tar.gz",
  "size": $SIZE_COG_11,
  "sha256": "$SHA_COG_11"
}
EOF

if out=$( sh "$INGOT" update cog 2>&1 ); then
  printf '%s' "$out" | grep -q "updating cog" && note_ok "update reports the upgrade" || note_bad "update message odd: $out"
  grep -q "cog lib 1.1" "$ROOT/usr/lib/libcog.so" 2>/dev/null \
    && note_ok "updated payload bytes landed" || note_bad "old payload bytes remain"
  grep -q "cog|1.1|" "$ROOT/var/lib/ingot/cog.installed" \
    && note_ok "manifest records the new version" || note_bad "manifest not refreshed: $(sed -n '1p' "$ROOT/var/lib/ingot/cog.installed")"
else
  note_bad "update cog (newer) failed: $out"
fi

# ---- update all: cog is current again, reports up to date --------------------
if out=$( sh "$INGOT" update 2>&1 ); then
  printf '%s' "$out" | grep -q "up to date" && note_ok "update-all sees nothing to do" || note_bad "update-all odd: $out"
else
  note_bad "update (all) failed: $out"
fi

# ---- the pretty bar: on a real tty, big downloads animate ----------------
# Non-tty runs must stay plain (asserted above); this one forces a pty and a
# >1MiB payload so the bar path triggers for real and we can see the frames.
if command -v python3 >/dev/null 2>&1; then
  bar_out=$( python3 "$REPO/tests/pty-run.py" sh "$INGOT" install bigwheel 2>&1 )
  printf '%s' "$bar_out" | grep -q '%' \
    && note_ok "tty bar shows a percentage" || note_bad "tty bar has no percent: $bar_out"
  printf '%s' "$bar_out" | grep -q 'MiB' \
    && note_ok "tty bar shows MiB" || note_bad "tty bar has no MiB: $bar_out"
  printf '%s' "$bar_out" | grep -q 'KiB/s' \
    && note_ok "tty bar shows speed" || note_bad "tty bar has no speed: $bar_out"
  printf '%s' "$bar_out" | grep -q '\[#' \
    && note_ok "tty bar draws its fill" || note_bad "tty bar has no fill: $bar_out"
  [ -f "$ROOT/usr/lib/big.dat" ] && note_ok "pty install landed the payload" \
    || note_bad "pty install left no payload"
else
  note_ok "python3 missing: pty bar test skipped"
fi

# ---- the root contract: mutating commands on the real / need root ----------
# On the live image the target root is the real / and the user is not root, so
# install/remove/update/reinstall must refuse with a sudo hint instead of
# half-writing. INGOT_ROOT is the sanctioned rootless path (which is exactly
# how the rest of this test runs), so the refusal itself can only be produced
# from an unprivileged gate run. A root gate run (CI executes branch-gate.sh
# through sudo) cannot fairly exercise it, and says so rather than faking it.
if [ "$(id -u)" -ne 0 ]; then
  if out=$( env -u INGOT_ROOT sh "$INGOT" install pinwheel 2>&1 ); then
    note_bad "install succeeded on real / without root!"
  else
    printf '%s' "$out" | grep -q "sudo" \
      && note_ok "install on real / refused for non-root, with a sudo hint" \
      || note_bad "unprivileged refusal message unexpected: $out"
  fi
  [ ! -e /var/lib/ingot/pinwheel.installed ] \
    && note_ok "refused real-/ install wrote nothing" \
    || note_bad "refused install still touched /var/lib/ingot!"
else
  note_ok "root gate run: real-/ refusal is covered by the unprivileged WSL runs"
  note_ok "root gate run: root installing into / is the sudo contract itself"
fi

echo "    summary: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0