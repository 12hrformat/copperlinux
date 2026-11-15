#!/bin/sh
# One chip per niri workspace, for waybar's custom/workspaces module.
#
# niri only lists workspaces that exist, so a short list is normal. When niri
# is not running, or the reply is not an array, nothing is printed and waybar
# hides the module rather than showing a broken chip.
#
# Markup is emitted as Pango because the module runs with escape=false; the
# focused workspace is the blue one, urgent ones are red.
#
# The bar used to start this script every second, window.sh with it: two fork
# chains a second, each one starting the whole niri binary for a single IPC
# roundtrip and piping it through jq, whether anything had changed or not.
# On a machine whose rendering goes through a paravirtual graphics pipe -- a
# VM, say -- that steady churn is felt as stutter, and the compositor is made
# to serialize its state twice a second for a bar that did not change.
#
# So this script runs once and stays alive instead. It prints the chips right
# away, then follows the niri event stream and prints again only when an
# event that can change the chips arrives. config.jsonc sets no "interval"
# for this module on purpose: with waybar, a line on stdout is an update,
# and a still desktop costs nothing.
#
# A burst of events -- a handful of terminals opened at once, a workspace
# switch -- is one update, not one per event: the inner read -t swallows
# whatever else arrives within a fifth of a second, then the state is
# queried and printed once.

set -u

print_chips() {
    msg=$(niri msg --json workspaces 2>/dev/null) || return 1
    [ -n "$msg" ] || return 1

    printf '%s\n' "$msg" | jq -r '
    if type != "array" or length == 0 then empty
    else
      sort_by(.idx)
      | map(
          if .is_urgent then
            "<span foreground=\"#f7768e\" weight=\"bold\"> \(.idx) </span>"
          elif .is_focused then
            "<span foreground=\"#7aa2f7\" weight=\"bold\"> \(.idx) </span>"
          elif .is_active then
            "<span foreground=\"#a9b1d6\"> \(.idx) </span>"
          else
            "<span foreground=\"#565f89\"> \(.idx) </span>"
          end
        )
      | join("")
    end'
}

print_chips || exit 0

# The stream names each event after itself: {"WorkspacesChanged":{...}},
# and everything but these three is dropped without a single fork -- which
# workspaces exist, which is active or focused, and which is urgent. The
# --unbuffered matters: jq holds its output back when it is piped, and the
# bar updates on each line as it arrives.
niri msg --json event-stream 2>/dev/null | jq -c --unbuffered 'select(
    .WorkspacesChanged or
    .WorkspaceActivated or
    .WorkspaceUrgencyChanged
)' | while IFS= read -r _event; do
    while IFS= read -t 0.2 _rest; do :; done
    print_chips || true
done
