#!/bin/sh
# starthyprland -- start the Hyprland session on the tty.
#
# The compositor, session tools and config tree are an ingot payload:
# `sudo ingot install hyprland`; nothing Hyprland-specific is baked in.
# Apps on top come from the manifest beside the launcher
# (/usr/share/copper/hyprland-apps), and each genuine absence gets its own
# exit code and sentence, not a bare "not found" that could mean a broken
# PATH or missing library.
#
# Hyprland IS the session: unlike XFCE there is no display to hand over,
# but the seat, runtime dir and session bus are prepared in the same order
# as startxfce. No logind/systemd: seatd (started by PID 1) gives the seat,
# and this script starts the dbus daemon. Startup spawns live in config.
#
# POSIX sh: the image runs busybox ash and build.sh checks these as /bin/sh;
# a bashism works on the build host and fails on the machine.
#
# Exit codes (a contract): 0 ok, 20 no compositor, 21 no session config,
# 22 runtime not prepared, 23 Hyprland died starting, 24 usage,
# 25 no way to ask about components, 26 library still missing after restore.
# KNOWN LIMITS: seatd's presence cannot be guaranteed here (needs root);
# no render node forces software, real hardware is left alone; IPC has no
# device list, so input shown is what libinput accepts, not what Hyprland
# claimed; "came up" means one instance dir under $XDG_RUNTIME_DIR exists.

set -u

HYPRLAND=${COPPER_HYPRLAND:-/usr/bin/Hyprland}
WAYBAR=${COPPER_WAYBAR:-/usr/bin/waybar}
SKEL=${COPPER_HYPRLAND_SKEL:-/usr/share/copper/hyprland-skel}
SESSIONLOG=${COPPER_SESSIONLOG:-/tmp/hyprland.log}
WAIT_TRIES=${WAIT_TRIES:-100}
# DRM nodes and seatd's socket default to the real paths; overridable so the
# gate can exercise GPU/seatd branches without either on the test host.
DRM_DIR=${COPPER_DRM_DIR:-/dev/dri}
SEATD_SOCK=${COPPER_SEATD_SOCK:-/run/seatd.sock}
# Input nodes and PID 1's libudev records are overridable for the same reason:
# the gate must be able to show a dropped device without real hardware.
INPUT_SYS=${COPPER_INPUT_SYS:-/sys/class/input}
UDEV_DATA=${COPPER_UDEV_DATA:-/run/udev/data}
# The user's config tree defaults to $HOME/.config/hypr; overridable for the gate.
USER_HYPR_CONF=${COPPER_USER_HYPR_CONF:-$HOME/.config/hypr}

# Components come from the manifest, not hardcoded. /usr/share ships it;
# /etc is the fallback for installs from an older image.
if [ -n "${COPPER_HYPRLAND_APPS:-}" ]; then
    APPS=$COPPER_HYPRLAND_APPS
elif [ -f /usr/share/copper/hyprland-apps ]; then
    APPS=/usr/share/copper/hyprland-apps
else
    APPS=/etc/copper/hyprland-apps
fi
INGOT=${COPPER_INGOT:-ingot}
SUDO=${COPPER_SUDO-sudo}
# "-" not ":-": an empty COPPER_SUDO must disable sudo, not revive the default.
if [ "$(id -u)" = 0 ]; then SUDO=; fi

say() { printf 'starthyprland: %s\n' "$1"; }

usage() {
    cat <<'EOF'
starthyprland -- start the Hyprland compositor on the tty

  starthyprland            set up the session and start hyprland
  starthyprland --check    report what is installed and exit, starting nothing
  starthyprland --yes      install any missing components without asking
  starthyprland --no       do not install components, just start the session
  starthyprland --help     this text

Environment, all optional:
  COPPER_HYPRLAND          path to the compositor       (default /usr/bin/Hyprland)
  COPPER_WAYBAR            path to the waybar binary    (default /usr/bin/waybar)
  COPPER_HYPRLAND_SKEL     the shipped config tree that seeds a user's home
                           (default /usr/share/copper/hyprland-skel)
  COPPER_SESSIONLOG        where the compositor logs    (default /tmp/hyprland.log)
  COPPER_HYPRLAND_APPS     component manifest           (default /usr/share/copper/hyprland-apps)
  COPPER_INGOT             installer for the components (default ingot)
  COPPER_SUDO              how to gain root for the install (default sudo; empty means already root or never use it)
  COPPER_DRM_DIR           where DRM nodes live         (default /dev/dri)
  COPPER_SEATD_SOCK        seatd's socket               (default /run/seatd.sock)
  COPPER_INPUT_SYS         where the input devices live (default /sys/class/input)
  COPPER_UDEV_DATA         the libudev records PID 1 writes (default /run/udev/data)
  COPPER_RUNTIME_DIR       force the runtime directory; must be an existing
                           directory. Only for the gate -- a real session lets
                           the launcher make its own.
  XDG_RUNTIME_DIR          the session's private runtime directory (default /run/user/<uid>, made here when missing)

Exit codes: 0 ok, 20 no hyprland, 21 no session config, 22 no runtime,
23 hyprland exited while starting, 24 usage, 25 no way to ask about components.
EOF
}

# A user that will not even get a seat is a user with a dead pointer -- say so
# before Hyprland starts.
if ! id -nG 2>/dev/null | grep -qw _seatd; then
    say "warning: this account is not in the _seatd group, so input may not work"
    say "  fix: sudo addgroup $(id -un) _seatd   (then log out and back in)"
fi

# seatd access alone is not enough: libinput drops devices libudev calls
# uninitialized, and drops ones whose only tag is ID_INPUT, not ID_INPUT_*.
# No udev daemon here, so PID 1 writes one record per input device at boot
# (seed_udev_input_db in copper-init.c); say which half is missing.
if [ -d "$INPUT_SYS" ] && ! ls "$UDEV_DATA"/c* >/dev/null 2>&1; then
    say "warning: no libudev records under $UDEV_DATA, so libinput will take no"
    say "  input device and the session will have a dead pointer and no keyboard."
    say "  PID 1 writes one record per input device at boot, so none here means"
    say "  it wrote none: no event node, or it could not write into the directory."
elif [ -d "$INPUT_SYS" ]; then
    listed=""
    nl=$(printf '\n')
    dropped=no
    for dev in "$INPUT_SYS"/input*; do
        [ -d "$dev" ] || continue
        devname=$(cat "$dev/name" 2>/dev/null)
        for node in "$dev"/event*; do
            [ -d "$node" ] || continue
            num=$(cat "$node/dev" 2>/dev/null)
            rec="$UDEV_DATA/c$num"
            tags=$(grep 'E:ID_INPUT_' "$rec" 2>/dev/null)
            what=""
            for t in $tags; do what="$what $t"; done
            if [ -z "$what" ]; then
                what=" (no ID_INPUT_* line, libinput drops it)"
                dropped=yes
            fi
            listed="$listed$nl  $node \"$devname\" ->$what"
        done
    done
    if [ "$dropped" = yes ]; then
        say "warning: libinput will ignore at least one input device, and a dropped"
        say "  keyboard is a session where the pointer moves and nothing types."
        say "  Every input device, and what its record says:"
        oldifs=$IFS
        IFS=$nl
        for line in $listed; do say "$line"; done
        IFS=$oldifs
        say "  PID 1 writes each record from the device's sysfs capabilities (seed_udev_input_db in copper-init.c), so a line above with no ID_INPUT_* is a device it read no capabilities out of, and a device that is not listed at all had no event node to write."
    fi
fi

# One source of truth so --check and the launch path agree.
have_hyprland=0
[ -x "$HYPRLAND" ] && have_hyprland=1

# Locate the user's config and the shipped tree that can seed it.
user_conf="$USER_HYPR_CONF"
user_config=0
[ -e "$user_conf/hyprland.lua" ] && user_config=1
skel_config=0
[ -e "$SKEL/.config/hypr/hyprland.lua" ] && skel_config=1

report() {
    if [ "$have_hyprland" = 1 ]; then
        say "found hyprland: $HYPRLAND"
    else
        say "NO hyprland at $HYPRLAND"
        say "  the compositor is an ingot package: run 'sudo ingot install hyprland'."
    fi
    if [ "$user_config" = 1 ]; then
        say "found a session config: $user_conf"
    elif [ "$skel_config" = 1 ]; then
        say "no config in $user_conf; will seed it from $SKEL on launch"
    else
        say "NO session config in $user_conf, and none to seed from at $SKEL"
    fi
}

# --check must name every category that can stop a session: a bare "not found"
# is indistinguishable from a broken PATH or a library from the wrong suite.
report_check() {
    # The compositor.
    if [ "$have_hyprland" = 1 ]; then
        say "hyprland: present at $HYPRLAND"
    else
        say "hyprland: NOT INSTALLED at $HYPRLAND"
        say "  install it with 'sudo ingot install hyprland'; nothing can start until it is"
    fi

    # Runtime libraries. ldd is the honest check: a compositor that starts and
    # dies on a missing .so says so here instead of after the user has logged in.
    if [ "$have_hyprland" != 1 ]; then
        say "runtime libraries: cannot check (no compositor)"
    elif ! command -v ldd >/dev/null 2>&1; then
        say "runtime libraries: cannot check (no ldd on this host)"
    else
        missing_libs=$(ldd "$HYPRLAND" 2>/dev/null | awk '/not found/{print $1}')
        if [ -z "$missing_libs" ]; then
            say "runtime libraries: all resolve"
        else
            say "runtime libraries: MISSING:"
            for lib in $missing_libs; do say "  $lib"; done
        fi
    fi

    # Seat management. Without logind the seat is seatd's to give; a compositor
    # that cannot take the DRM master exits before it draws anything.
    if [ -S "$SEATD_SOCK" ]; then
        say "seat: seatd socket present at $SEATD_SOCK"
    elif [ -d /run/systemd/seats ]; then
        say "seat: logind present (no seatd socket at $SEATD_SOCK)"
    else
        say "seat: NO seatd socket at $SEATD_SOCK and no logind"
        say "  PID 1 starts seatd on the Copper-init image; if it did not, the compositor will exit"
    fi

    # Configuration.
    if [ "$user_config" = 1 ]; then
        say "config: present at $user_conf/hyprland.lua"
    elif [ "$skel_config" = 1 ]; then
        say "config: none in $user_conf, but $SKEL can seed it"
    else
        say "config: NONE (no $user_conf/hyprland.lua and no $SKEL/.config/hypr/hyprland.lua)"
    fi

    # Wayland utilities the session starts or binds keys to.
    for u in waybar fuzzel kitty hyprlock dunst; do
        p=$(command -v "$u" 2>/dev/null) || p=
        if [ -n "$p" ]; then
            say "utility $u: $p"
        else
            say "utility $u: not installed"
        fi
    done

    # Runtime environment.
    uid=$(id -u 2>/dev/null) || uid=
    if [ -z "$uid" ]; then
        say "runtime: no uid for this login"
    elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        if [ -d "$XDG_RUNTIME_DIR" ]; then
            say "runtime: XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR (present)"
        else
            say "runtime: XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR is not a directory"
        fi
    else
        say "runtime: XDG_RUNTIME_DIR unset (launcher makes /run/user/$uid or /tmp/copper-runtime-$uid)"
    fi
    if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        say "session bus: $DBUS_SESSION_BUS_ADDRESS"
    else
        say "session bus: not set (the launcher starts one)"
    fi
}

# Every flag changes startup, so none may be ignored silently: --check
# reports, --yes/--no decide installs, anything else is a usage error.
use_install=
check=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)     check=1; shift ;;
        --help|-h)   usage; exit 0 ;;
        --yes|-y)    use_install=1; shift ;;
        --no|-n)     use_install=0; shift ;;
        -*)          say "unknown option: $1" >&2; usage >&2; exit 24 ;;
        *)           say "unexpected argument: $1" >&2; usage >&2; exit 24 ;;
    esac
done

if [ "$check" = 1 ]; then
    report_check
    exit 0
fi

# Quit a live splash before the compositor takes the VT: it would fail the
# takeover and hide any prompt below. Ping first, so a splashless machine
# stays silent and does nothing; --check exits above and never gets here.
if command -v plymouth >/dev/null 2>&1 &&
   plymouth --ping >/dev/null 2>&1; then
    say "quitting the boot splash before starting the session"
    plymouth quit >/dev/null 2>&1 || :
fi

# Check the compositor outside any session branch: a machine with config but
# no Hyprland must exit 20, not die on exec. Offer ingot install when asked
# or on a tty; --no, scripted calls and hosts without ingot skip it.
if [ "$have_hyprland" != 1 ]; then
    want_install=0
    if command -v "$INGOT" >/dev/null 2>&1; then
        if [ "$use_install" = 1 ]; then
            want_install=1
        elif [ "$use_install" = "" ] && [ -t 0 ] && [ -t 1 ]; then
            printf 'starthyprland: hyprland is not installed. install it with ingot? (Y/n) '
            answer=
            read -r answer || answer=
            case "$answer" in
                ''|[Yy]|[Yy][Ee][Ss]) want_install=1 ;;
            esac
        fi
    fi
    if [ "$want_install" = 1 ]; then
        say "installing hyprland with ingot"
        # $SUDO is unquoted on purpose: empty for root or opt-out, else "sudo".
        if $SUDO "$INGOT" install hyprland && [ -x "$HYPRLAND" ]; then
            have_hyprland=1
        else
            say "the ingot install did not put a compositor at $HYPRLAND"
        fi
    fi
fi
if [ "$have_hyprland" != 1 ]; then
    report
    say "cannot start the session: there is no compositor at $HYPRLAND"
    say "install it with 'sudo ingot install hyprland', then run starthyprland again."
    exit 20
fi

# Seed a shipped config into homes made another way (second user, wiped home,
# wizard that skipped the copy), or the compositor starts with a black screen.
# With neither user config nor shipped tree, 21 names the real failure.

# Copy only missing files and symlinks, making their directories: user edits
# survive, and a home seeded (or half-seeded) by an older image is repaired.
# This is not `cp -a -n`: busybox reads -n as "skip an existing *anything*",
# so an existing ~/.config skips the whole subtree and reports success.
# Walking the tree costs a few hundred stat() calls and no surprises;
# seed_added counts writes so the caller can say whether anything changed.
seed_added=0
seed_config() {
    seed_added=0
    seed_list=${TMPDIR:-/tmp}/starthyprland-seed.$$
    if [ ! -d "$SKEL" ]; then
        return 1
    fi
    if ! ( cd "$SKEL" && find . \( -type f -o -type l \) ) > "$seed_list" 2>/dev/null; then
        rm -f "$seed_list"
        return 1
    fi
    while IFS= read -r seed_f; do
        seed_rel=${seed_f#./}
        [ -n "$seed_rel" ] || continue
        if [ -e "$HOME/$seed_rel" ] || [ -L "$HOME/$seed_rel" ]; then
            continue
        fi
        seed_dir=${seed_rel%/*}
        if [ "$seed_dir" != "$seed_rel" ]; then
            mkdir -p "$HOME/$seed_dir" 2>/dev/null || :
        fi
        if cp -a "$SKEL/$seed_rel" "$HOME/$seed_rel" 2>/dev/null; then
            seed_added=$((seed_added + 1))
        else
            say "  could not copy $seed_rel into $HOME"
        fi
    done < "$seed_list"
    rm -f "$seed_list"
    return 0
}

if [ "$user_config" != 1 ]; then
    if [ "$skel_config" = 1 ]; then
        say "seeding the session config from $SKEL into $HOME"
        # Seed the whole shipped home: it also carries the waybar config and
        # wallpaper the session starts from, not just .config/hypr.
        if ! seed_config; then
            say "the shipped config tree at $SKEL is not readable"
        fi
        if [ -e "$user_conf/hyprland.lua" ]; then
            say "session config seeded"
        else
            say "could not seed the session config from $SKEL"
            say "  (nothing was written; check that $HOME is writable)"
            exit 21
        fi
    else
        report
        say "cannot start the session: no config in $user_conf"
        say "  and the image has no shipped tree to seed it from."
        exit 21
    fi
else
    # An older image's home may lack files the config refers to; repair in
    # place on every start. Only absent files are written, so a whole tree
    # costs a few stat() calls and says nothing when nothing changed.
    if [ "$skel_config" = 1 ]; then
        if seed_config && [ "$seed_added" -gt 0 ]; then
            say "repaired the session config: added $seed_added missing file(s) from $SKEL"
            say "  (a home seeded by an older image can be missing files the config"
            say "  refers to; the shipped tree has them, and the session now does)"
        fi
    fi
fi

# Only missing ingot apps are offered; the manifest owns presence and install
# method, which change independently. 'image' components belong to the ISO:
# report a missing one, never try to install it.
missing=
if [ -r "$APPS" ]; then
    while read -r cname cprobe corigin; do
        case "$cname" in ''|\\#*) continue ;; esac
        [ -n "$cprobe" ] || continue
        [ -e "$cprobe" ] && continue
        case "$corigin" in
            image) say "component '$cname' is missing from the image (looked for $cprobe)" ;;
            *)     missing="$missing $cname" ;;
        esac
    done < "$APPS"
fi

if [ -n "$missing" ]; then
    # --yes/--no decide; with neither, ask on a tty or stop with 25.
    if [ "$use_install" = "1" ]; then
        do_install=1
    elif [ "$use_install" = "0" ]; then
        say "not installing components (--no)"
    elif [ -t 0 ]; then
        printf 'starthyprland: before running hyprland do you want to install its suggested apps? (Y/n) '
        answer=
        read -r answer || answer=
        case "$answer" in
            [Nn]*) say "not installing components" ;;
            *)     do_install=1 ;;
        esac
    else
        say "a component is missing and there is no way to ask: stdin is not a terminal."
        say "  starthyprland --yes   install the missing components first"
        say "  starthyprland --no    start the session without them"
        exit 25
    fi

    if [ "${do_install:-}" = "1" ]; then
        say "installing the missing components:$missing"
        failed=
        for c in $missing; do
            say "  $c ..."
            if $SUDO $INGOT install "$c"; then
                :
            else
                say "  could not install $c, continuing without it"
                failed=1
            fi
        done
        # ingot runs no maintainer scripts, so rebuild desktop and mime databases
        # or new launchers never appear and stay dead.
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database /usr/share/applications >/dev/null 2>&1 || :
        fi
        if command -v update-mime-database >/dev/null 2>&1; then
            update-mime-database /usr/share/mime >/dev/null 2>&1 || :
        fi
        if [ -n "$failed" ]; then
            say "some components could not be installed; starting the session anyway"
        else
            say "components installed, running hyprland now"
        fi
    fi
fi

# ingot's plain tar -xzf lets bundled libs replace the image's newer ones
# (xarchiver carries noble's libxkbcommon), and Hyprland then dies with
# "version `V_1.11.0' not found". Re-assert the linked libs from the staged
# copies and prove the needed symbol versions landed.
LIBSTASH=${COPPER_LIBSTASH:-/usr/share/copper/hyprland-runtime}
LIBDIR=${COPPER_LIBDIR:-/usr/lib/x86_64-linux-gnu}
if [ -d "$LIBSTASH" ]; then
    say "restoring hyprland's input libraries"
    $SUDO cp -a "$LIBSTASH"/. "$LIBDIR"/
    $SUDO ldconfig || true
    for need in "libinput.so.10:LIBINPUT_1.30" "libxkbcommon.so.0:V_1.11.0"; do
        nf=${need%%:*}; sym=${need##*:}
        if ! grep -qa -e "$sym" "$LIBDIR/$nf" 2>/dev/null; then
            say "  $nf still does not provide $sym after restoring it;"
            say "  hyprland would die with \"version '$sym' not found\"."
            exit 26
        fi
    done
fi

# Wayland needs $XDG_RUNTIME_DIR for its sockets. No pam login here, so PID 1
# makes /run/user/<uid> and hands it over before this runs; just confirm and
# export it, falling back to /tmp/copper-runtime-<uid> if PID 1 did not.
uid=$(id -u 2>/dev/null) || uid=
if [ -z "$uid" ]; then
    say "cannot determine this login's uid"
    exit 22
fi
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ ! -d "$XDG_RUNTIME_DIR" ]; then
    # A stale path or regular file here would make the session write sockets
    # into a file and fail several layers down, so refuse it now.
    say "XDG_RUNTIME_DIR is set to $XDG_RUNTIME_DIR, which is not a directory"
    exit 22
fi
# COPPER_RUNTIME_DIR is the gate's override for the untestable "no writable
# runtime" branch: a non-directory makes the launcher report "runtime
# directory" directly. Do not set it on a real machine.
if [ -n "${COPPER_RUNTIME_DIR:-}" ] && [ ! -d "$COPPER_RUNTIME_DIR" ]; then
    say "runtime directory is set to $COPPER_RUNTIME_DIR, which is not a directory"
    exit 22
fi
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    for cand in "/run/user/$uid" "/tmp/copper-runtime-$uid"; do
        if mkdir -p "$cand" 2>/dev/null && chmod 700 "$cand" 2>/dev/null; then
            XDG_RUNTIME_DIR=$cand
            break
        fi
    done
    if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
        say "no writable runtime directory: looked for /run/user/$uid and"
        say "  /tmp/copper-runtime-$uid, made neither."
        exit 22
    fi
fi
export XDG_RUNTIME_DIR
say "runtime directory: $XDG_RUNTIME_DIR"
mkdir -p /dev/shm 2>/dev/null || :

# No display manager stamps a bare tty session. Export the desktop identity
# so portals pick the Hyprland backend instead of GTK and toolkits choose
# Wayland; hyprland --session only covers its own children.
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=hyprland
XDG_SESSION_DESKTOP=hyprland
DESKTOP_SESSION=hyprland
export XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP DESKTOP_SESSION

# Give libxkbcommon an explicit installed rules tree and US layout, so an
# inherited desktop setting cannot leave a keyboard without a usable keymap.
XKB_CONFIG_ROOT=${XKB_CONFIG_ROOT:-/usr/share/X11/xkb}
XKB_DEFAULT_LAYOUT=${XKB_DEFAULT_LAYOUT:-us}
export XKB_CONFIG_ROOT XKB_DEFAULT_LAYOUT

# No maintainer scripts run here, so build missing font/pixbuf caches once:
# otherwise glyph lookups rescan directories and GTK shows holes for images.
# Keep it quiet -- this is a session starting, not a build log.
if command -v gdk-pixbuf-query-loaders >/dev/null 2>&1; then
    if [ -z "$(find /usr/lib -name loaders.cache -print -quit 2>/dev/null)" ]; then
        gdk-pixbuf-query-loaders --update-cache >/dev/null 2>&1 || :
    fi
fi
if command -v fc-cache >/dev/null 2>&1; then
    if [ -z "$(find /var/cache/fontconfig -name '*.cache' -print -quit 2>/dev/null)" ]; then
        fc-cache -f >/dev/null 2>&1 || :
    fi
fi

# Portals, dunst, keyring and polkit all want a bus, with no session manager
# to start one. Prefer dbus-launch (address + pid), fall back to dbus-daemon
# (address only); without either, start anyway and let the consumers complain.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    if command -v dbus-launch >/dev/null 2>&1; then
        bus=$(dbus-launch --sh-syntax 2>/dev/null) || bus=
        [ -n "$bus" ] && eval "$bus"
    fi
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] &&
       command -v dbus-daemon >/dev/null 2>&1; then
        addr=$(dbus-daemon --session --fork --print-address=1 2>/dev/null) || addr=
        if [ -n "$addr" ]; then
            DBUS_SESSION_BUS_ADDRESS=$addr
            export DBUS_SESSION_BUS_ADDRESS
        fi
    fi
    if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        say "session bus: $DBUS_SESSION_BUS_ADDRESS"
    else
        say "no session bus (no dbus-launch, no dbus-daemon); starting anyway"
    fi
fi

# A bus started above inherits this process's session identity; an inherited
# bus may not, and D-Bus-activated services read the daemon's environment.
# Push the identity in with dbus-update-activation-environment, no --systemd.
if command -v dbus-update-activation-environment >/dev/null 2>&1; then
    dbus-update-activation-environment XDG_SESSION_TYPE XDG_CURRENT_DESKTOP \
        XDG_SESSION_DESKTOP DESKTOP_SESSION >/dev/null 2>&1 || :
fi

# Without logind, libseat reads seatd's socket path; keep the variable at
# its default unless the machine says otherwise, so libseat and seatd agree.
if [ -S "$SEATD_SOCK" ]; then
    say "seat: $SEATD_SOCK"
else
    say "no seatd socket at $SEATD_SOCK."
    say "  with no logind, hyprland needs seatd to take the DRM master; if PID 1"
    say "  did not start it the compositor will exit and its log will say so."
fi

# A DRM node with no render node is a VM with no 3D: force software rendering
# there, since GL failure looks like a compositor bug. Leave machines with a
# render node alone; COPPER_HYPRLAND_SOFTWARE=1 forces it by hand for a
# machine the heuristic gets wrong.
soft=0
if [ "${COPPER_HYPRLAND_SOFTWARE:-0}" = 1 ]; then
    soft=1
elif [ -e "$DRM_DIR" ] && ! ls "$DRM_DIR"/renderD* >/dev/null 2>&1; then
    soft=1
fi
if [ "$soft" = 1 ]; then
    LIBGL_ALWAYS_SOFTWARE=1
    export LIBGL_ALWAYS_SOFTWARE
    say "no render node; forcing software rendering"
fi

# Hyprland's DRM backend opens /dev/dri/card0. With no udev, kernel-created
# nodes carry only their own group bits; root:render 0600 is the standard,
# and this script does not rewrite permissions (that is udev/polkit's job).
# Check and report rather than guess.
if [ -e "$DRM_DIR/card0" ]; then
    _cr=$(stat -c '%U %G %a' "$DRM_DIR/card0" 2>/dev/null)
    _cg=$(id -nG 2>/dev/null)
    case " $_cg " in
        *" render "*) : ;;
        *) say "note: /dev/dri/card0 is not world-readable and this account is not in the render group;"
           say "  the session may fail to open the rendering device. Re-run with a render-capable user,"
           say "  or ensure the node carries group 'render' permissions (e.g. 0660 root:render)."
           ;;
    esac
fi

# Launch in the background so a compositor that dies in the first second
# (no seat, no DRM master, bad config) prints its reason before we read the
# log. The bounded wait also checks liveness: "starting" and "died" look
# identical if you only count to a limit.
#
# Pass no --session: Hyprland rejects it with "Unknown option", and the
# start-hyprland wrapper wants a systemd --user this image does not run.
# Everything the wrapper arranged is set above, so exec the binary directly.
say "starting hyprland, log in $SESSIONLOG"

# hyprland reads $XDG_CONFIG_HOME/hypr; point it at the user's home so a
# fresh login reads the seeded config, not a root-owned or missing tree.
XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
export XDG_CONFIG_HOME

"$HYPRLAND" > "$SESSIONLOG" 2>&1 &
hyprlandpid=$!

# The instance dir under $XDG_RUNTIME_DIR/hypr is named by
# HYPRLAND_INSTANCE_SIGNATURE (random hex, start time, pid); hyprctl is the
# only IPC client, and the socket left by a crashed instance must not read
# as a live one. Find the newest dir, then prove it answers via hyprctl.
up=0
i=0
ipc_dir=
ipc_sig=
while [ "$i" -lt "$WAIT_TRIES" ]; do
    ipc_dir=$(find "$XDG_RUNTIME_DIR/hypr" -mindepth 1 -maxdepth 1 -type d \
                  -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    if [ -n "$ipc_dir" ]; then
        ipc_sig=${ipc_dir##*/}
        if command -v hyprctl >/dev/null 2>&1 &&
           HYPRLAND_INSTANCE_SIGNATURE=$ipc_sig XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
               hyprctl -j version >/dev/null 2>&1; then
            up=1
            break
        fi
    fi
    if ! kill -0 "$hyprlandpid" 2>/dev/null; then
        wait "$hyprlandpid" 2>/dev/null || :
        say "hyprland exited while starting up. Its log says:"
        sed 's/^/  /' "$SESSIONLOG" 2>/dev/null
        exit 23
    fi
    i=$((i + 1))
    sleep 0.1 2>/dev/null || sleep 1
done

if [ "$up" = 1 ]; then
    say "hyprland is up"
else
    # Alive but no answering socket: a compositor that is drawing is not dead.
    # Say what was missing and keep waiting rather than fail a working session.
    say "no answering IPC socket appeared under $XDG_RUNTIME_DIR; waiting for hyprland anyway"
fi

wait "$hyprlandpid"
rc=$?
say "hyprland exited (status $rc)"
exit "$rc"
