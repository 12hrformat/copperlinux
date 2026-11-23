#!/bin/sh
# bootloader-gate.sh -- the boot menu is data, and the bootloader is a provider.
#
# The old build.sh carried GRUB's menu syntax inline. Adding an init entry meant
# editing a grub.cfg, and replacing GRUB meant rewriting the packaging stage.
# Now the kernel arguments live once in iso/boot/entries and build.sh sources a
# provider that renders those arguments and packages the media. This gate
# proves both halves:
#
#   1. the shared entry list is well formed and the two init paths are distinct;
#   2. the shipped GRUB provider actually renders that list into a menu;
#   3. build.sh selects a provider by name, validates its hooks, and lets the
#      provider do the packaging;
#   4. the live init does not name any particular bootloader.
#
# Rootless and buildless: it renders the provider with a scratch $ROOT and reads
# the shipped text. Run: tests/bootloader-gate.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
ENTRIES="$REPO/iso/boot/entries"
PROVIDER="$REPO/iso/bootloaders/grub/provider.sh"
BUILD="$REPO/iso/build.sh"
INIT="$REPO/iso/live/init"

fail=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1${2:+: $2}"; fail=1; }

[ -f "$ENTRIES" ]   || { bad "iso/boot/entries exists"; exit 1; }
[ -f "$PROVIDER" ]  || { bad "the GRUB provider exists"; exit 1; }

echo "bootloader: the shared entry list"
# Every non-comment line is id|title|kernel-args, exactly two separators.
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    n=$(printf '%s\n' "$line" | awk -F'|' '{ print NF }')
    [ "$n" -eq 3 ] || bad "entry has three fields" "$line"
done < "$ENTRIES"
[ "$fail" -eq 0 ] && ok "every entry is id|title|kernel-args"

if grep -q '^default|' "$ENTRIES"; then
    ok "there is a default entry"
else
    bad "there is a default entry"
fi
if grep -q '^systemd|.*copper\.init=systemd' "$ENTRIES"; then
    ok "the systemd entry selects systemd"
else
    bad "the systemd entry selects systemd"
fi
if grep '^default|' "$ENTRIES" | grep -q 'copper\.init='; then
    bad "the default entry leaves init to /etc/copper-init"
else
    ok "the default entry leaves init to /etc/copper-init"
fi
for sw in splash plymouth.ignore-udev plymouth.ignore-serial-consoles \
          quiet loglevel=3 systemd.show_status=1 console=ttyS0,115200 \
          console=tty0; do
    if grep '^default|' "$ENTRIES" | grep -q "$sw"; then
        ok "the default entry passes $sw"
    else
        bad "the default entry passes $sw"
    fi
done
# tty0 must come last: /dev/console follows the final console=.
last=$(grep '^default|' "$ENTRIES" | sed 's/.*|//' | tr ' ' '\n' | grep '^console=' | tail -n1)
[ "$last" = console=tty0 ] && ok "tty0 is the last console" \
                           || bad "tty0 is the last console" "$last"

echo
echo "bootloader: the GRUB provider renders the list"
TMP=$(mktemp -d /tmp/bootloader-gate.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT
# The provider reads "$ROOT/boot/entries"; point that at the real file with a
# scratch root, then render into a scratch tree.
ROOT="$REPO/iso" sh -c '
    . "$1"
    bootloader_configure "$2"
' sh "$PROVIDER" "$TMP/tree" > "$TMP/render.log" 2>&1 \
  || { bad "the provider renders the menu" "$(cat "$TMP/render.log")"; }
MENU="$TMP/tree/boot/grub/grub.cfg"
if [ -f "$MENU" ]; then
    ok "the provider wrote boot/grub/grub.cfg"
else
    bad "the provider wrote boot/grub/grub.cfg"
fi
if [ -f "$MENU" ]; then
    for title in "Copper Linux" "Copper Linux (systemd init)" \
                 "Copper Linux (verbose)" "Copper Linux (debug)" \
                 "Copper Linux (initramfs shell)"; do
        if grep -qF "menuentry \"$title\"" "$MENU"; then
            ok "the menu carries '$title'"
        else
            bad "the menu carries '$title'"
        fi
    done
    if grep -q 'linux /boot/vmlinuz .*copper.init=systemd' "$MENU"; then
        ok "the menu's systemd entry passes the switch"
    else
        bad "the menu's systemd entry passes the switch"
    fi
    if grep -q 'search --set=root --file /boot/grub/grub.cfg' "$MENU"; then
        ok "the menu finds its own medium"
    else
        bad "the menu finds its own medium"
    fi
fi

echo
echo "bootloader: build.sh delegates instead of hardcoding"
if grep -q 'BOOTLOADER=${COPPER_BOOTLOADER:-grub}' "$BUILD"; then
    ok "the provider is an override with a GRUB default"
else
    bad "the provider is an override with a GRUB default"
fi
if grep -q '. "$BOOTLOADER_DIR/provider.sh"' "$BUILD"; then
    ok "build.sh sources the selected provider"
else
    bad "build.sh sources the selected provider"
fi
if grep -q 'bootloader_configure "$TGT"' "$BUILD" \
   && grep -q 'bootloader_make_iso "$TGT" "$OUT/copper.iso" "$WORK"' "$BUILD"; then
    ok "build.sh calls the two documented hooks"
else
    bad "build.sh calls the two documented hooks"
fi
if grep -q 'if declare -F bootloader_check >/dev/null' "$BUILD"; then
    ok "the read-back check is optional for other providers"
else
    bad "the read-back check is optional for other providers"
fi
if grep -q 'cp "$ROOT/boot/grub.cfg"' "$BUILD" \
   || grep -q 'grub-mkrescue -o "\$OUT/copper.iso"' "$BUILD"; then
    bad "build.sh no longer embeds GRUB's menu or packaging"
else
    ok "build.sh no longer embeds GRUB's menu or packaging"
fi
if grep -q '/boot/copper-media' "$INIT" && grep -q 'printf .*copper live media' "$BUILD"; then
    ok "the live init finds its medium via the build-time marker"
else
    bad "the live init finds its medium via the build-time marker"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "bootloader gate: all good"
else
    echo "bootloader gate: FAILED" >&2
    exit 1
fi
