#!/bin/sh
# The focused window's title, for waybar's custom/window module.
#
# niri answers null when nothing is focused (an empty workspace, or right after
# a window closes). That is not an error: print nothing and let waybar hide the
# module instead of drawing the word "null".
#
# Same shape as workspaces.sh: the bar used to start this script every
# second; now it runs once, prints the title right away, and follows the
# niri event stream -- printing again only when an event that can change
# the focused window or its title arrives, with config.jsonc setting no
# "interval" for this module. A burst of events is one update: the inner
# read -t swallows whatever else arrives within a fifth of a second first.

set -u

print_title() {
    msg=$(niri msg --json focused-window 2>/dev/null) || return 1
    [ -n "$msg" ] || return 1

    printf '%s\n' "$msg" | jq -r '
    if . == null then "" else (.title // .app_id // "") end'
}

print_title || exit 0

# The stream names each event after itself: {"WindowFocusChanged":{...}},
# and everything but these is dropped without a single fork -- a window
# opened or changed (a title change counts), focus moving, a window closing,
# and the workspace switch that moves focus with it. The --unbuffered
# matters: jq holds its output back when it is piped, and the bar updates
# on each line as it arrives.
niri msg --json event-stream 2>/dev/null | jq -c --unbuffered 'select(
    .WindowOpenedOrChanged or
    .WindowFocusChanged or
    .WindowClosed or
    .WorkspaceActivated
)' | while IFS= read -r _event; do
    while IFS= read -t 0.2 _rest; do :; done
    print_title || true
done
