#!/bin/sh
# build-app-pkg.sh <name> [deb-version]
#
# Build an ingot payload for a GUI app out of the distro's own binary
# packages: the app .deb plus its whole dependency closure, unpacked into one
# staging tree and tarballed with only relative paths, exactly the mix the gui
# stage ships into the image.
#
# Runs against the host apt; on Ubuntu that is all there is to it. To build
# against a different distro, point APT / APTCACHE at wrappers (the "noble
# sandbox" in HANDOFF.md is one: PATH=/tmp/noble-bin:$PATH with those two
# files in place). ATTENTION about versions:
#
#   mousepad   0.6.1-1build2        ristretto  0.13.1-1build2
#   xfce4-taskmanager 1.5.7-1build1 xarchiver  1:0.5.4.22-1build2 (epoch 1)
#
# The tarball name is <name>-<version>.tar.gz with ':' turned into '_', so
# the URL is filesystem and comment friendly. The package page JSON is
# printed to stdout, ready to paste into copper-ingot-repo.
set -eu

name=$1
version=${2:-}
outdir=${OUTDIR:-.}

APT=${APT:-apt-get}
APTCACHE=${APTCACHE:-apt-cache}
DPKG=${DPKG:-dpkg-deb}

if [ -z "$version" ]; then
    version=$($APTCACHE policy "$name" 2>/dev/null | awk '$1 == "Candidate:" { print $2; exit }')
fi
[ -n "$version" ] || { echo "build-app-pkg.sh: no candidate version for '$name' (pass one)" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/apppkg.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
DG="$work/debs"; STAGE="$work/stage"; status="$work/status"
mkdir -p "$DG" "$STAGE"
: > "$status"

# Download the app and fetch every dependency it has. An empty dpkg status
# tells apt that nothing is installed, so nothing counts as "already there".
"$APT" update -qq >/dev/null 2>&1 || true
"$APT" \
    -o "Dir::State::status=$status" \
    -o "Dir::Cache::archives=$DG" \
    -o "APT::Sandbox::User=root" \
    --download-only --no-install-recommends -y install "$name" >/dev/null

n=$(find "$DG" -maxdepth 1 -name '*.deb' | wc -l)
[ "$n" -gt 0 ] || { echo "build-app-pkg.sh: apt downloaded no .debs for '$name'" >&2; exit 1; }
echo "closure for $name: $n packages" >&2

for deb in "$DG"/*.deb; do
    "$DPKG" -x "$deb" "$STAGE"
done

# Some .debs legitimate empty marker files; drop them so no payload ships a
# 0-byte file (rootfs overlay policy is no-empty-file; keep it here too).
find "$STAGE" -type f -size 0 -delete

echo "payload layers for $name:" >&2
( cd "$STAGE" && ls -1A ) | sed 's/^/  /' >&2

tarball=$(printf '%s' "$name-$version.tar.gz" | tr ':' '_')
tarball="$outdir/$tarball"
set -- $(cd "$STAGE" && ls -1A)
[ "$#" -gt 0 ] || { echo "build-app-pkg.sh: empty staging tree" >&2; exit 1; }
( cd "$STAGE" && tar -czf "$tarball" "$@" )
sha=$(sha256sum "$tarball" | awk '{print $1}')
echo "wrote $tarball ($(wc -c <"$tarball") bytes, sha256 $sha)" >&2

printf '{\n  "name": "%s",\n  "version": "%s",\n  "category": "tools",\n  "url": "https://github.com/12hrformat/copper-ingot-repo/releases/download/payloads-v1/%s",\n  "sha256": "%s",\n  "depends": []\n}\n' \
    "$name" "$version" "$(basename "$tarball")" "$sha"