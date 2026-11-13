#!/bin/sh
# Print the workspace strip for waybar as one JSON object.
#
# The bar shipped in noble (waybar 0.9.24) has no hyprland/* modules -- only
# sway/*, wlr/* and river/* -- so the strip is assembled here from hyprctl and
# handed over as what waybar's `custom` module expects on stdout:
# {"text": "...", "class": "...", "tooltip": "..."}.
#
# Nothing is printed when the compositor is unreachable or either tool is
# missing. An empty custom module is hidden by waybar, which is exactly right
# before the session starts and after it exits.

if ! command -v hyprctl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

all=$(hyprctl workspaces -j 2>/dev/null) || exit 0
[ -n "$all" ] || exit 0

active=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // empty') || exit 0

printf '%s\n' "$all" | jq -sr --argjson active "${active:-0}" '
    def lbl: if . == 10 then "0" else (. | tostring) end;

    # hyprctl prints one array; slurp makes a stream of objects an array too,
    # so both shapes take the same path below.
    (if (.[0] | type) == "array" then .[0] else . end)
      | map(select(.id >= 0))
      | sort_by(.id)
      | {
            text: ( map(
                       if .id == $active
                       then "<span foreground=\"#B87333\">\(.id | lbl)</span>"
                       else (.id | lbl) end
                     ) | join("   ") ),
            class: "workspaces",
            tooltip: ( map("\((.id | lbl))\t\(.name // "-")") | join("\n") )
        }
'

exit 0
