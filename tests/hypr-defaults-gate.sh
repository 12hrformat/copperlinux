#!/bin/sh
# Prove hypr-defaults leaves the pinned ML4W tree usable, and keeps its hands
# off everything that is not one of its defaults.
#
# This is the gate for the little bit of glue that decides whether the desktop
# arrives with a bar, a launcher and a wallpaper, or just a very confident
# cursor on a black screen. The script runs twice in a real image -- once over
# the shipped skeleton during the build, once over a user's home on every start
# -- so the interesting cases are the ones a second run could ruin:
#
#   * the three defaults move to the tools Copper actually bakes (waybar, rofi,
#     hyprpaper), and hyprpaper's placeholder path becomes the shipped picture
#   * waybar-disabled gets out of the way at the same time, or the bar is "on"
#     and invisible
#   * custom.lua appears with the startup commands this image needs
#   * a second run changes nothing, because users meet it on every login
#   * a choice the user made survives -- a different bar, a different launcher,
#     a wallpaper they picked, a custom.lua they wrote, or a waybar-disabled
#     they set after choosing waybar themselves
#   * a path that is not a config tree is refused outright rather than
#     half-populated and left to confuse the next reader
#
# The build and the launcher both have to call it, or the defaults exist in the
# image and nowhere else; those calls are asserted statically at the end.
#
# Run: sh tests/hypr-defaults-gate.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SUT="$REPO/iso/rootfs-overlay/usr/lib/copper/hypr-defaults.sh"
TMP=$(mktemp -d /tmp/hypr-defaults-gate.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }

eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted '$2', got '$3'"; fi; }

[ -f "$SUT" ] || { echo "  FAIL  $SUT does not exist"; exit 1; }

# The image's shell is busybox ash. Parse it the way the build will.
if sh -n "$SUT" 2>"$TMP/parse.log"; then
    ok "hypr-defaults parses under /bin/sh"
else
    bad "hypr-defaults parses under /bin/sh" "$(cat "$TMP/parse.log")"
fi

# make_tree <name> -- the parts of the upstream tree this script reads, with
# ML4W's own defaults in place: Quickshell bar (and waybar-disabled beside it),
# Walker launcher, the blank.png wallpaper paths, no custom.lua.
make_tree() {
    tree=$TMP/$1
    mkdir -p "$tree/.config/hypr" "$tree/.config/ml4w/settings"
    printf 'require("custom")\n' >"$tree/.config/hypr/hyprland.lua"
    {
        printf 'preload = $HOME/.config/hypr/assets/blank.png\n'
        printf 'wallpaper = ,$HOME/.config/hypr/assets/blank.png\n'
        printf 'splash = false\n'
    } >"$tree/.config/hypr/hyprpaper.conf"
    printf 'quickshell\n' >"$tree/.config/ml4w/settings/statusbar"
    printf 'walker\n' >"$tree/.config/ml4w/settings/launcher"
    : >"$tree/.config/ml4w/settings/waybar-disabled"
    printf '%s\n' "$tree"
}

read_setting() { tr -d '[:space:]' <"$1" 2>/dev/null; }

# ---- the defaults ---------------------------------------------------------
tree=$(make_tree fresh)
if sh "$SUT" "$tree" >"$TMP/fresh.log" 2>&1; then
    ok "runs on a freshly seeded tree"
else
    bad "runs on a freshly seeded tree" "exit $?: $(cat "$TMP/fresh.log")"
fi

eq "statusbar moves from quickshell to waybar" \
   waybar "$(read_setting "$tree/.config/ml4w/settings/statusbar")"
eq "launcher moves from walker to rofi" \
   rofi "$(read_setting "$tree/.config/ml4w/settings/launcher")"

if grep -q '^wallpaper = ,/usr/share/copper/wallpapers/copper-default.png$' \
        "$tree/.config/hypr/hyprpaper.conf" 2>/dev/null \
   && ! grep -q 'assets/blank\.png' "$tree/.config/hypr/hyprpaper.conf"; then
    ok "the wallpaper paths move off the blank.png placeholder"
else
    bad "the wallpaper paths move off the blank.png placeholder" \
        "$(cat "$tree/.config/hypr/hyprpaper.conf" 2>/dev/null)"
fi

if [ -e "$tree/.config/ml4w/settings/waybar-disabled" ]; then
    bad "the bar's off switch leaves with the migration" \
        "the file is still there, so waybar/launch.sh would exit without a bar"
else
    ok "the bar's off switch leaves with the migration"
fi

if [ -s "$tree/.config/hypr/custom.lua" ]; then
    ok "custom.lua is created"
else
    bad "custom.lua is created" "missing or empty"
fi

for want in 'hl.on("hyprland.start"' 'hyprpaper' 'hyprpolkitagent' \
            'xdg-desktop-portal-hyprland'; do
    if grep -qF "$want" "$tree/.config/hypr/custom.lua" 2>/dev/null; then
        ok "custom.lua carries $want"
    else
        bad "custom.lua carries $want" "$(cat "$tree/.config/hypr/custom.lua" 2>/dev/null)"
    fi
done

# The loader in hyprland.lua require()s this exact name. Spelling it
# differently here would be a file nothing ever reads.
if grep -q 'require("custom")' "$tree/.config/hypr/hyprland.lua" 2>/dev/null; then
    ok "the tree's hyprland.lua loads custom.lua"
else
    bad "the tree's hyprland.lua loads custom.lua" \
        "the real tree's loader was not found"
fi

# ---- idempotence ----------------------------------------------------------
cp "$tree/.config/hypr/custom.lua" "$TMP/custom.first"
cp "$tree/.config/hypr/hyprpaper.conf" "$TMP/hyprpaper.first"
if sh "$SUT" "$tree" >"$TMP/second.log" 2>&1 \
   && cmp -s "$TMP/custom.first" "$tree/.config/hypr/custom.lua" \
   && cmp -s "$TMP/hyprpaper.first" "$tree/.config/hypr/hyprpaper.conf"; then
    ok "a second run is a no-op (users meet it on every login)"
else
    bad "a second run is a no-op (users meet it on every login)" \
        "exit $?: $(cat "$TMP/second.log")"
fi

# ---- a user's choices survive ---------------------------------------------
tree=$(make_tree chosen)
printf 'mybar\n' >"$tree/.config/ml4w/settings/statusbar"
printf 'myrun\n' >"$tree/.config/ml4w/settings/launcher"
: >"$tree/.config/ml4w/settings/waybar-disabled"
echo "-- the user's own startup line" >"$tree/.config/hypr/custom.lua"
printf 'preload = /home/me/holiday.jpg\nwallpaper = ,/home/me/holiday.jpg\n' \
    >"$tree/.config/hypr/hyprpaper.conf"
cp "$tree/.config/hypr/custom.lua" "$TMP/custom.chosen"
cp "$tree/.config/hypr/hyprpaper.conf" "$TMP/hyprpaper.chosen"

sh "$SUT" "$tree" >"$TMP/chosen.log" 2>&1
eq "a chosen statusbar is not overwritten" \
   mybar "$(read_setting "$tree/.config/ml4w/settings/statusbar")"
eq "a chosen launcher is not overwritten" \
   myrun "$(read_setting "$tree/.config/ml4w/settings/launcher")"

if [ -e "$tree/.config/ml4w/settings/waybar-disabled" ]; then
    ok "waybar-disabled survives when the user chose waybar themselves"
else
    bad "waybar-disabled survives when the user chose waybar themselves" \
        "the script removed a switch it did not create"
fi

if cmp -s "$TMP/custom.chosen" "$tree/.config/hypr/custom.lua"; then
    ok "a user's custom.lua is not overwritten"
else
    bad "a user's custom.lua is not overwritten" "$(cat "$tree/.config/hypr/custom.lua")"
fi

if cmp -s "$TMP/hyprpaper.chosen" "$tree/.config/hypr/hyprpaper.conf"; then
    ok "a wallpaper the user picked is not overwritten"
else
    bad "a wallpaper the user picked is not overwritten" \
        "$(cat "$tree/.config/hypr/hyprpaper.conf")"
fi

# A user who already chose waybar and then disabled it keeps it disabled: the
# migration flag must come from the rewrite, not from the bar's final value.
tree=$(make_tree waybar_disabled)
printf 'waybar\n' >"$tree/.config/ml4w/settings/statusbar"
sh "$SUT" "$tree" >/dev/null 2>&1
if [ -e "$tree/.config/ml4w/settings/waybar-disabled" ]; then
    ok "an already-waybar tree keeps its waybar-disabled switch"
else
    bad "an already-waybar tree keeps its waybar-disabled switch" \
        "the script removed it although nothing was migrated"
fi

# A settings file with no value is the same as absent.
tree=$(make_tree empty_statusbar)
: >"$tree/.config/ml4w/settings/statusbar"
sh "$SUT" "$tree" >/dev/null 2>&1
eq "an empty statusbar is filled in" \
   waybar "$(read_setting "$tree/.config/ml4w/settings/statusbar")"

# A CR left by an archive unpacked on Windows must not become part of the
# value the shell script compares against.
tree=$(make_tree crlf)
printf 'quickshell\r\n' >"$tree/.config/ml4w/settings/statusbar"
sh "$SUT" "$tree" >/dev/null 2>&1
eq "a CR in statusbar is tolerated" \
   waybar "$(read_setting "$tree/.config/ml4w/settings/statusbar")"

# ---- refusals -------------------------------------------------------------
mkdir -p "$TMP/naked/.config"
if sh "$SUT" "$TMP/naked" >"$TMP/naked.log" 2>&1; then
    bad "a tree without .config/hypr is refused" "it exited 0"
else
    eq "a tree without .config/hypr is refused" 1 "$?"
    if [ -e "$TMP/naked/.config/ml4w/settings/statusbar" ]; then
        bad "a refused tree is not half-populated" \
            "the script wrote settings under .config/ml4w anyway"
    else
        ok "a refused tree is not half-populated"
    fi
fi

if sh "$SUT" >"$TMP/noarg.log" 2>&1; then
    bad "no argument is a usage error" "it exited 0"
else
    eq "no argument is a usage error" 2 "$?"
fi

# ---- the callers ----------------------------------------------------------
# The script is only worth anything if the image uses it. Both routes into a
# home have to name it.
if grep -q 'hypr-defaults\.sh' "$REPO/iso/build.sh" 2>/dev/null \
   && grep -q 'hypr-defaults' "$REPO/iso/build.sh" 2>/dev/null; then
    ok "build.sh applies the defaults to the shipped tree"
else
    bad "build.sh applies the defaults to the shipped tree" \
        "no reference to hypr-defaults.sh"
fi

if grep -q 'COPPER_HYPR_DEFAULTS' "$REPO/iso/starthyprland.sh" 2>/dev/null \
   && grep -q 'hypr-defaults\.sh' "$REPO/iso/starthyprland.sh" 2>/dev/null; then
    ok "starthyprland applies the defaults to a user's home"
else
    bad "starthyprland applies the defaults to a user's home" \
        "no COPPER_HYPR_DEFAULTS call"
fi

# rofi is the launcher the defaults choose; if it is not in the manifest the
# "image component missing" report would never mention it.
if grep -q '^rofi[[:space:]]' "$REPO/iso/rootfs-overlay/etc/copper/hypr-apps" 2>/dev/null; then
    ok "the component manifest knows rofi is in the image"
else
    bad "the component manifest knows rofi is in the image" \
        "io/rootfs-overlay/etc/copper/hypr-apps has no rofi line"
fi

# The wallpaper path the script writes has to exist in the image, or the first
# login gets a correct-looking config and a hyprpaper error. Check the file is
# present and is actually a PNG.
wp="$REPO/iso/rootfs-overlay/usr/share/copper/wallpapers/copper-default.png"
if [ -f "$wp" ] && [ "$(dd if="$wp" bs=8 count=1 2>/dev/null)" = "$(printf '\211PNG\r\n\032\n')" ]; then
    ok "the default wallpaper ships a real PNG"
else
    bad "the default wallpaper ships a real PNG" "$wp is missing or not a PNG"
fi

# ---- summary --------------------------------------------------------------
echo
if [ "$fails" -ne 0 ]; then
    echo "FAILED: $fails check(s) failed"
    exit 1
fi
echo "PASSED"
exit 0
