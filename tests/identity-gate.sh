#!/bin/sh
# identity-gate.sh -- every shipped "what version is this" file comes from one source.
# Runs the real build helper on a synthetic os-release and a synthetic staged
# root, so a drifted version string fails here instead of at login.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d /tmp/copper-identity-gate.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src" "$TMP/dst/etc"
cp "$REPO/iso/rootfs-overlay/etc/os-release" "$TMP/src/os-release"
sed -i 's/^VERSION_ID=.*/VERSION_ID="9.8.7"/; s/^PRETTY_NAME=.*/PRETTY_NAME="Copper Linux 9.8.7"/; s/^VERSION_CODENAME=.*/VERSION_CODENAME=testcode/' "$TMP/src/os-release"
printf 'trixie/sid\n' > "$TMP/dst/etc/debian_version"
mkdir -p "$TMP/dst/etc/update-motd.d"
printf '#!/bin/sh\necho https://ubuntu.com\n' > "$TMP/dst/etc/update-motd.d/10-help-text"

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

sh "$REPO/iso/identity.sh" "$TMP/src" "$TMP/dst" || {
    bad "identity.sh ran successfully"
    exit 1
}
ok "identity.sh ran successfully"

if grep -qx 'DISTRIB_RELEASE=9.8.7' "$TMP/dst/etc/lsb-release" &&
   grep -qx 'DISTRIB_CODENAME=testcode' "$TMP/dst/etc/lsb-release" &&
   grep -qF 'DISTRIB_DESCRIPTION="Copper Linux 9.8.7"' "$TMP/dst/etc/lsb-release"; then
    ok "lsb-release is generated from that one version"
else
    bad "lsb-release is generated from that one version"
fi
if grep -qF 'Copper Linux 9.8.7 \n \l' "$TMP/dst/etc/issue"; then
    ok "issue carries the generated name and escape codes"
else
    bad "issue carries the generated name and escape codes"
fi
if [ "$(cat "$TMP/dst/etc/issue.net")" = 'Copper Linux 9.8.7' ] &&
   [ "$(cat "$TMP/dst/etc/motd")" = 'Copper Linux 9.8.7' ]; then
    ok "issue.net and motd carry the generated name"
else
    bad "issue.net and motd carry the generated name"
fi
if [ ! -e "$TMP/dst/etc/debian_version" ] && [ ! -e "$TMP/dst/etc/update-motd.d" ]; then
    ok "Debian's version file and Ubuntu's MOTD scripts are removed"
else
    bad "Debian's version file and Ubuntu's MOTD scripts are removed"
fi

exit "$fail"
