#!/bin/sh
# hypr-defaults -- teach the pinned ML4W tree which programs Copper actually has.
#
# ML4W 2.17 is a lovely piece of work, written for the full ML4W installation:
# Quickshell draws the statusbar, the overview, the dock and the welcome window;
# Walker is the launcher; awww puts a picture on the wallpaper; matugen repaints
# everything it can reach. Copper has Hyprland, waybar, rofi, hyprpaper and the
# ordinary Noble furniture. Neither side is wrong. It is just that the tree's
# defaults point at programs this image does not have, and a session which
# starts cleanly and then has no bar, no launcher and a wallpaper that is
# technically loaded but visually absent is not "working" in any sense a person
# would use.
#
# So this script rewrites exactly those defaults, and nothing else. It runs in
# two places, because a home can be filled two ways and both should end up
# standing:
#
#   build.sh, build_hypr   over /usr/share/copper/hyprland-skel, so the tree the
#                          ISO ships is already coherent when someone opens it
#   starthyprland.sh       over $HOME after seeding, because the hypr-configs
#                          ingot payload is the untouched upstream tree and a
#                          home filled from it has exactly the defaults that
#                          do not work here
#
# It is idempotent, and it does not overrule a choice a user made:
#
#   statusbar     rewritten only when it is missing or still "quickshell", the
#                 ML4W default. waybar-disabled is removed only when that
#                 rewrite happens -- a user who asked for waybar and then
#                 decided against it gets to keep it switched off.
#   launcher      rewritten only when it is missing or still "walker". ML4W's
#                 own ml4w-launcher already treats anything that is not an
#                 installed walker as rofi, so this just makes the setting stop
#                 lying about what runs.
#   hyprpaper     its two paths are rewritten only while they still point at
#                 assets/blank.png, the transparent placeholder upstream
#                 ships. A wallpaper someone chose is not touched.
#   custom.lua    written only when absent. hyprland.lua require()s it when it
#                 exists, which makes it the documented place for Copper's
#                 additions: hyprpaper (baked) instead of awww/Quickshell (not),
#                 and hyprpolkitagent + xdg-desktop-portal-hyprland started
#                 directly because there is no systemd here to run their units.
#
# Usage: hypr-defaults.sh <home-or-skel-root>
#
# POSIX sh: the image's shell is busybox ash and build.sh parses this file with
# /bin/sh. Exit 0 means the tree is usable (or already was); 1 means the
# argument is not a config tree; 2 means no argument. Nothing here needs root.

set -u

root=${1:-}
if [ -z "$root" ]; then
    printf 'usage: hypr-defaults.sh <home-or-skel-root>\n' >&2
    exit 2
fi

settings=$root/.config/ml4w/settings
hypr=$root/.config/hypr

# A home that has never been seeded, or a path that is not a home at all. Do
# not invent a partially-populated tree: the caller has a specific "no config"
# exit code for that and this would hide it.
if [ ! -d "$hypr" ]; then
    printf 'hypr-defaults: %s has no .config/hypr\n' "$root" >&2
    exit 1
fi

mkdir -p "$settings" || {
    printf 'hypr-defaults: cannot create %s\n' "$settings" >&2
    exit 1
}

# The first non-empty line, stripped. ML4W writes one word and a newline. tr
# also eats a stray CR from an archive unpacked on a Windows host -- the sort of
# invisible passenger that turns "quickshell" into a value nothing recognises.
setting() {
    [ -f "$1" ] || return 1
    tr -d '[:space:]' <"$1"
}

# ---- statusbar ---------------------------------------------------------
# Quickshell is not in this image, so a tree still set to it draws no bar at
# all. Waybar is staged by the hypr build stage, and ML4W's autostart launches
# ~/.config/waybar/launch.sh unconditionally. waybar-disabled is the switch
# that makes that script exit without a bar -- and the upstream tree ships it
# sitting next to statusbar=quickshell and never clears it when the setting
# changes. Changing one without the other is how you get a bar that is "on" and
# invisible at the same time.
migrated_bar=0
bar=$(setting "$settings/statusbar" || :)
case "$bar" in
    ''|quickshell)
        printf 'waybar\n' >"$settings/statusbar" || exit 1
        migrated_bar=1
        ;;
esac

if [ "$migrated_bar" = 1 ]; then
    rm -f "$settings/waybar-disabled"
fi

# ---- launcher ----------------------------------------------------------
# ML4W's launcher helper falls back to rofi, but only after reading this file,
# and the fallback is silent. Silent fallbacks are how a keybind ends up
# "doing nothing" in a bug report when it is really doing something sensible.
# Make the file say what will happen.
launcher=$(setting "$settings/launcher" || :)
case "$launcher" in
    ''|walker)
        printf 'rofi\n' >"$settings/launcher" || exit 1
        ;;
esac

# ---- wallpaper ---------------------------------------------------------
# Upstream's hyprpaper.conf points at assets/blank.png: a 569-byte transparent
# placeholder. hyprpaper will happily "load" it, draw nothing, and leave the
# desktop the colour the compositor felt like. The path is also written as
# $HOME/... in a config hyprpaper does not expand, so on a strict reading it is
# not even a wallpaper. If the file still says blank.png, give it the real one
# the image ships. If someone has already picked their own picture, that is
# their business and this leaves it alone.
WALLPAPER=/usr/share/copper/wallpapers/copper-default.png
if [ -f "$hypr/hyprpaper.conf" ] \
   && grep -q 'hypr/assets/blank\.png' "$hypr/hyprpaper.conf"; then
    tmp=$hypr/hyprpaper.conf.copper-new
    if sed "s|[$]HOME/.config/hypr/assets/blank.png|$WALLPAPER|g" \
           "$hypr/hyprpaper.conf" >"$tmp"; then
        mv "$tmp" "$hypr/hyprpaper.conf" || exit 1
    else
        rm -f "$tmp"
        exit 1
    fi
fi

# ---- custom.lua --------------------------------------------------------
# hyprland.lua loads this when it exists, just before it finishes. The commands
# below are one-shot startup work, so the handler is the same event ML4W's own
# conf/autostart.lua uses.
#
# hyprpaper reads ~/.config/hypr/hyprpaper.conf, which the tree already ships.
# ML4W's autostart never launches it: its wallpaper path belongs to
# Quickshell/awww, and neither is installed here.
#
# hyprpolkitagent is a normal binary under /usr/libexec. ML4W starts it with
# `systemctl --user start hyprpolkitagent.service` and falls back to
# polkit-gnome, which this image does not carry either. Without an agent the
# authentication dialogs never appear, so the session looks perfectly alive
# until the first moment it needs a password and then quietly cannot.
if [ ! -e "$hypr/custom.lua" ]; then
    cat >"$hypr/custom.lua" <<'CUSTOM_LUA'
-- Copper Linux additions to the pinned ML4W configuration.
--
-- Loaded automatically by hyprland.lua when this file exists. Keep Copper's own
-- startup work here rather than editing the vendored tree: that tree is pinned
-- and hashed by the image build, and an edit in there is a pin change wearing a
-- disguise.

hl.on("hyprland.start", function ()
    local HOME = os.getenv("HOME")

    -- The wallpaper belongs to hyprpaper here. This image does not carry awww
    -- or Quickshell, which is what the ML4W tree's wallpaper path expects.
    hl.exec_cmd("hyprpaper")

    -- No systemd, so ML4W's `systemctl --user start
    -- hyprpolkitagent.service` cannot start the agent. Run it directly. The
    -- test keeps a missing binary from complaining on every single start.
    hl.exec_cmd("[ -x /usr/libexec/hyprpolkitagent ] && " ..
                "exec /usr/libexec/hyprpolkitagent")

    -- No systemd, so ML4W's user units cannot start the portal either. The
    -- compositor's global shortcuts and screencopy read through it, and the
    -- image stages xdg-desktop-portal-hyprland in the hypr stage -- so start
    -- it here, the same way the agent is started. The -x guard keeps a machine
    -- without it from logging a complaint on every single start.
    hl.exec_cmd("[ -x /usr/bin/xdg-desktop-portal-hyprland ] && " ..
                "exec /usr/bin/xdg-desktop-portal-hyprland")
end)
CUSTOM_LUA
    [ -s "$hypr/custom.lua" ] || exit 1
fi

exit 0
