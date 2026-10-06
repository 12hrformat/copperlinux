#!/bin/busybox sh
# copper — Copper Linux system command.
#
# A front end for the individual tools, so the commands people actually
# want to type are short:
#
#   copper charge            back up, then apply hotfixes from the repo
#   copper charge --status   show what is pending without changing anything
#   copper charge --backup   take a restore point and stop
#   copper rollback          show what can be restored
#   copper rollback --latest put the last restore point back
#   copper version           what this build is
#   copper help              this list
#
# Usage: copper <command> [args...]

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# Same override the tools use, so "COPPER_CONFIG=... copper charge" points at
# one config rather than two different ones.
COPPER_CONFIG="${COPPER_CONFIG:-/etc/copper/config}"
export COPPER_CONFIG

# Call the tools by absolute path rather than relying on PATH. A user whose
# PATH is short or overridden would otherwise get "copper-charge: not found"
# from a command that plainly exists in /usr/bin.
SELF_DIR=$(dirname "$0")
CHARGE="$SELF_DIR/copper-charge"
ROLLBACK="$SELF_DIR/copper-rollback"

# Fall back to the installed location when the tools are not beside this one,
# which is the case when copper itself has been copied somewhere else.
[ -x "$CHARGE" ]   || CHARGE=/usr/bin/copper-charge
[ -x "$ROLLBACK" ] || ROLLBACK=/usr/bin/copper-rollback

die() {
    echo "copper: $*" >&2
    exit 1
}

cmd_charge() {
    [ -x "$CHARGE" ] || die "copper-charge is missing from $CHARGE"
    exec "$CHARGE" "$@"
}

cmd_rollback() {
    [ -x "$ROLLBACK" ] || die "copper-rollback is missing from $ROLLBACK"
    exec "$ROLLBACK" "$@"
}

cmd_version() {
    echo "Copper Linux v0.1.0-dev"
    echo "  charge   /usr/bin/copper-charge"
    echo "  rollback /usr/bin/copper-rollback"
    echo "  shell    /usr/bin/copper-sh"
}

cmd_help() {
    cat <<'EOF'
usage: copper <command> [args...]

  charge                back up, then apply hotfixes (needs root)
  charge --status       say what would change, change nothing
  charge --backup       take a restore point and stop
  rollback              list restore points and the files in them
  rollback --latest     restore the most recent one
  rollback <name>       restore a named one
  version               version and tool paths
  help                  this text

every charge takes a restore point first, so rollback works even when
there was nothing to patch.

config lives in /etc/copper/config
EOF
}

[ $# -ge 1 ] || { cmd_help; exit 0; }

case "$1" in
    charge)            shift; cmd_charge "$@" ;;
    rollback|undo)     shift; cmd_rollback "$@" ;;
    version|--version|-v) cmd_version ;;
    help|--help|-h)    cmd_help ;;
    *)                 die "unknown command '$1' (try: copper help)" ;;
esac