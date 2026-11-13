#!/bin/sh
# waybar window/task-list script: prints the list of open windows for
# waybar's window module.
#
# Copper's Copper-init runs a bare shell on tty1 and never starts a display
# manager, so there is no session manager to enumerate windows. This script
# falls back to an empty list rather than failing or printing a stale menu.
# waybar prints the last successful output when this exits non-zero, so a
# missing menu is visible, not silent.

exit 0
