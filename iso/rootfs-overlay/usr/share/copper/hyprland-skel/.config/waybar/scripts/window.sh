#!/bin/sh
# Print the active window's title for waybar as one JSON object.
#
# Same reason as workspaces.sh: this bar has no hyprland window module, so the
# title comes from hyprctl.
#
# Empty output when no window is focused or the compositor is gone -- waybar
# hides an empty custom module instead of leaving a stale title on screen.

if ! command -v hyprctl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

win=$(hyprctl activewindow -j 2>/dev/null) || exit 0
[ -n "$win" ] || exit 0

printf '%s\n' "$win" | jq -r '
    if (.title // "") == "" then
        empty
    else
        {
            text: .title,
            class: "window",
            tooltip: ((.class // "?") + " -- " + .title)
        }
    end
'

exit 0
