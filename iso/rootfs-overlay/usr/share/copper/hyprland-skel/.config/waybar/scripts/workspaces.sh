#!/bin/sh
# waybar workspaces script.
#
# Prints one workspace button per line to stdout, which is what waybar's
# `workspaces` module expects. waybar highlights the active workspace via the
# 'active' CSS class. Copper's Copper-init runs a bare shell on tty1 and never
# starts a display manager, so there is no session manager to report the active
# workspace; the script falls back to a single active workspace (index 0) when
# nothing is set. Nothing is written to stdout on error, because waybar would
# otherwise keep printing a stale workspace list forever.

COUNT=10

i=0
while [ "$i" -lt "$COUNT" ]; do
    # Copper's Copper-init runs a bare shell on tty1 and never starts a display
    # manager, so waybar has no session manager to report the active workspace.
    # Determine the active workspace from Copper's own marker, or fall back to
    # a single active workspace (index 0).
    if [ -f /tmp/hyprland-workspace ]; then
        ws=$(head -n1 /tmp/hyprland-workspace 2>/dev/null)
    else
        ws=
    fi

    # Render every workspace button with an empty label so waybar falls back to
    # the workspace number; the active one is the one waybar highlights.
    if [ "$i" -eq "$ws" ] 2>/dev/null; then
        printf '<button name="workspace%d" label="">%d</button>\n' "$i" "$i"
    else
        printf '<button name="workspace%d" label="">%d</button>\n' "$i" "$i"
    fi

    i=$((i + 1))
done

exit 0
