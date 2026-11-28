#!/bin/sh
# identity.sh -- one source for every file that says which Copper this is.
#
# Usage: identity.sh <dir-with-os-release> <staged-root>
#
# os-release is authoritative. lsb-release, /etc/issue, /etc/issue.net and
# /etc/motd used to carry hand-copied release strings and had already drifted
# (0.1 against 1.2.0-alpha.1). Generate them instead, so a version bump is one
# edit. Also remove base-files' Ubuntu MOTD scripts and its Debian leftover:
# neither describes this image.
set -eu

src=${1:?identity.sh needs the directory holding os-release}
dst=${2:?identity.sh needs the staged root}

value() { # value KEY -> the unquoted value, or empty
    v=$(sed -n "s/^$1=//p" "$src/os-release" | head -n1)
    v=${v#\"}; v=${v%\"}
    printf '%s' "$v"
}

version=$(value VERSION_ID)
pretty=$(value PRETTY_NAME)
codename=$(value VERSION_CODENAME)

if [ -z "$version" ] || [ -z "$pretty" ]; then
    echo "identity: $src/os-release has no VERSION_ID/PRETTY_NAME" >&2
    exit 1
fi
[ -n "$codename" ] || codename=ingot

mkdir -p "$dst/etc"
{
    printf 'DISTRIB_ID=Copper\n'
    printf 'DISTRIB_RELEASE=%s\n' "$version"
    printf 'DISTRIB_CODENAME=%s\n' "$codename"
    printf 'DISTRIB_DESCRIPTION="%s"\n' "$pretty"
} > "$dst/etc/lsb-release"

printf '%s \\n \\l\n' "$pretty" > "$dst/etc/issue"
printf '%s\n' "$pretty" > "$dst/etc/issue.net"
printf '%s\n' "$pretty" > "$dst/etc/motd"

# Ubuntu's update-motd.d prints help.ubuntu.com and can phone motd.ubuntu.com.
# A static /etc/motd is enough, and says Copper.
rm -rf "$dst/etc/update-motd.d"
rm -f "$dst/etc/debian_version"
