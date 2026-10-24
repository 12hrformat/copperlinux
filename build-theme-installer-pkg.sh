#!/bin/sh
# build-theme-installer-pkg.sh [version]
#
# Build a real Ingot payload for copper-theme-installer: the app, its desktop
# entry, icon, documentation, and the libarchive/GTK runtime pieces the base
# image does not already ship.  The package page JSON is printed to stdout,
# ready to paste into copper-ingot-repo once the tarball has actually been
# uploaded as a Release asset.
#
# This script refuses to build on a foreign distribution by default.  Copper's
# GUI ABI is Ubuntu noble (24.04); a payload compiled against a newer glibc
# links but will not start on the image.  ALLOW_FOREIGN=1 is for experiments
# only and must never be used for a published package.
#
#   ./build-theme-installer-pkg.sh 0.1.0
#   OUTDIR=/tmp payload ./build-theme-installer-pkg.sh 0.1.0
set -eu

name=copper-theme-installer
version=${1:-0.1.0}
outdir=${OUTDIR:-.}
app=apps/copper-theme-installer

# ---------------------------------------------------------------------------
# Refuse to produce an ABI-incompatible payload.
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "24.04" ]; then
        if [ "${ALLOW_FOREIGN:-0}" != "1" ]; then
            echo "build-theme-installer-pkg.sh: build on Ubuntu 24.04 (noble);" >&2
            echo "this host is ${PRETTY_NAME:-unknown}. ALLOW_FOREIGN=1 overrides," >&2
            echo "but such a payload must not be published." >&2
            exit 1
        fi
        echo "build-theme-installer-pkg.sh: ALLOW_FOREIGN=1: payload is NOT publishable" >&2
    fi
fi

for tool in make pkg-config ldd dpkg dpkg-deb apt-get sha256sum tar; do
    command -v "$tool" >/dev/null || {
        echo "build-theme-installer-pkg.sh: missing $tool" >&2; exit 1;
    }
done
pkg-config --exists gtk+-3.0 libarchive || {
    echo "build-theme-installer-pkg.sh: install libgtk-3-dev libarchive-dev" >&2
    exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/copper-theme-pkg.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
stage="$work/stage"
debs="$work/debs"
mkdir -p "$stage" "$debs"

echo "==> building $name $version" >&2
make -C "$app" clean all VERSION="$version" >/dev/null

# ---------------------------------------------------------------------------
# Runtime closure.  GTK/GLib/X11 are part of Copper's base GUI stage, so they
# are deliberately not duplicated in this payload.  Everything else ldd names
# is included, which keeps the payload usable on a fresh Copper image while
# avoiding a second copy of the whole desktop stack.
base_prefixes='libgtk-3|libgdk-3|libglib2.0|libgio-2.0|libgobject-2.0|libgmodule-2.0|libatk|libatspi|libpango|libcairo|libgdk-pixbuf|libharfbuzz|libfreetype|libfontconfig|libX11|libXau|libXdmcp|libxcb|libXcomposite|libXcursor|libXdamage|libXext|libXfixes|libXi|libXinerama|libXrandr|libXrender|libwayland|libepoxy|libfribidi|libpixman|libpcre2-8|libffi|libmount|libblkid|libselinux|libpng16|libjpeg|libtiff|libwebp|libexpat|libuuid|zlib1g'

pkgs=""
for lib in $(ldd "$app/$name" | awk '/=> \// {print $3}'); do
    # On usrmerged Ubuntu, ldd names /lib/... while the dpkg database records
    # /usr/lib/...; ask about the resolved path too, or every library looks
    # unowned and the payload comes out empty.
    real=$(readlink -f "$lib" 2>/dev/null || printf '%s' "$lib")
    owner=""
    for path in "$lib" "$real"; do
        owner=$(dpkg -S "$path" 2>/dev/null | head -1 | cut -d: -f1) || owner=""
        [ -n "$owner" ] && break
    done
    [ -n "$owner" ] || continue
    case "$owner" in
        libc6|libc6-dev|gcc-*-base|libgcc-s1) continue ;;
        *base-files*) continue ;;
    esac
    if echo "$owner" | grep -Eqi "^($base_prefixes)"; then
        continue
    fi
    case " $pkgs " in
        *" $owner "*) ;;
        *) pkgs="$pkgs $owner" ;;
    esac
done
if [ -z "$pkgs" ]; then
    echo "build-theme-installer-pkg.sh: no runtime packages found; refusing to ship a likely-broken payload" >&2
    exit 1
fi
echo "==> runtime packages:$pkgs" >&2

apt-get update -qq >/dev/null 2>&1 || true
# shellcheck disable=SC2086
( cd "$debs" && apt-get download $pkgs ) >/dev/null 2>"$work/apt.err" || {
    echo "build-theme-installer-pkg.sh: apt-get download failed:" >&2
    cat "$work/apt.err" >&2
    exit 1
}

for deb in "$debs"/*.deb; do
    [ -f "$deb" ] || continue
    dpkg-deb -x "$deb" "$stage"
done

# Package docs are not needed at runtime and would make the payload larger
# than the image needs.  Zero-byte files are pruned for the same reason the
# GUI stage prunes them: later image checks reject empty regular files.
rm -rf "$stage/usr/share/doc" "$stage/usr/share/man" "$stage/usr/share/lintian" \
       "$stage/usr/share/bug" "$stage/var"
find "$stage" -type f -size 0 -delete

# Install the app after pruning the package docs, so its own README survives.
make -C "$app" install DESTDIR="$stage" PREFIX=/usr VERSION="$version" >/dev/null

[ -x "$stage/usr/bin/$name" ] || {
    echo "build-theme-installer-pkg.sh: app binary missing from payload" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Tar only real paths, relative to /.  Ingot extracts at / and refuses `..`.
tarball="$outdir/$name-$version.tar.gz"
( cd "$stage" && tar -czf "$tarball" $(ls -1A) )
sha=$(sha256sum "$tarball" | awk '{print $1}')
size=$(wc -c <"$tarball")
echo "==> wrote $tarball ($size bytes, sha256 $sha)" >&2

# Real page JSON.  Upload the tarball as a GitHub Release asset first, then
# this block is the page body.  The URL below is the same release the other
# repo payloads use; change it if the asset is published elsewhere.
cat <<EOF
{
  "name": "$name",
  "version": "$version",
  "category": "desktop",
  "url": "https://github.com/12hrformat/copper-ingot-repo/releases/download/payloads-v1/$(basename "$tarball")",
  "size": $size,
  "sha256": "$sha",
  "depends": []
}
EOF
