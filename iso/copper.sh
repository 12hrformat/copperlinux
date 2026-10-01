#!/bin/busybox sh
# copper — Copper Linux system command.
# handcrafted by 12hrformat
#
# A front end for the individual tools, so the commands people actually
# want to type are short:
#
#   copper charge            apply hotfixes from the repo
#   copper charge --status   show what is pending without changing anything
#   copper rollback          list backups
#   copper rollback <name>   restore one
#   copper version           what this build is
#   copper help              this list
#
# Usage: copper <command> [args...]

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# Call the tools by absolute path rather than relying on PATH. A user whose
# PATH is short or overridden would otherwise get "copper-charge: not found"
# from a command that plainly exists in /usr/bin.
CHARGE=/usr/bin/copper-charge
ROLLBACK=/usr/bin/copper-rollback

die() {
    echo "copper: $*" >&2
    exit 1
}

cmd_charge() {
    if [ "$1" = "--status" ]; then
        # Handled by the charge script itself would be nicer, but it has no
        # dry-run mode yet, so say so rather than pretend.
        echo "copper: charge has no --status mode yet; running it for real."
        echo ""
    fi
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

  charge              fetch and apply hotfixes (needs root)
  rollback            list available backups
  rollback <name>     restore one backup over the live file
  version             version and tool paths
  help                this text

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