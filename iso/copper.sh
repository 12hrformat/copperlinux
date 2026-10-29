#!/bin/busybox sh
# copper — Copper Linux system command.
#
#   copper version   what this build is
#   copper help      this list
#
# Usage: copper <command> [args...]
#
# This used to front the charge/rollback hotfix tools. Both were removed from
# the tree in 258b24c, so their commands went with them: `copper charge`
# answering "copper-charge is missing" is worse than not existing.

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

cmd_version() {
    # The image's own identity, not a second copy of the version to keep in
    # step with os-release. It used to be hardcoded and had already drifted
    # (v0.1.0-dev against VERSION_ID=0.1). ID gates it: run from a build host
    # or a checkout, this must not report that machine's distribution.
    version_name="Copper Linux"
    if [ -r /etc/os-release ]; then
        ID= PRETTY_NAME=
        . /etc/os-release
        if [ "${ID}" = copper ] && [ -n "${PRETTY_NAME}" ]; then
            version_name=$PRETTY_NAME
        fi
    fi
    echo "$version_name"
    echo "  shell   /usr/bin/copper-sh"
}

cmd_help() {
    cat <<'EOF'
usage: copper <command> [args...]

  version   version and the shell path
  help      this text
EOF
}

[ $# -ge 1 ] || { cmd_help; exit 0; }

case "$1" in
    version|--version|-v) cmd_version ;;
    help|--help|-h)       cmd_help ;;
    *)
        echo "copper: unknown command '$1' (try: copper help)" >&2
        exit 1
        ;;
esac
