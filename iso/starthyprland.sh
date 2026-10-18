#!/bin/sh
# starthyprland -- start Hyprland on the tty.
#
# handcrafted by dragon
#
# The compositor and its session tools are in the image: the hypr stage bakes
# them from the cppiber PPA. The apps on top -- browsers, editors, media, the
# extra themes -- are ingot packages, and before anything starts this asks
# whether to install the missing ones (manifest at /etc/copper/hypr-apps). What
# is genuinely absent still gets its own exit code and its own sentence naming
# the piece, instead of a bare "not found" that is indistinguishable from a
# broken PATH or a missing library.
#
# Hyprland is a Wayland compositor, so there is no second process to hand a
# display to the way startxfce hands one to startxfce4: the compositor IS the
# session. What startxfce does for X -- find a display, prove it answers, export
# DISPLAY -- has no analogue here. What it does for the seat, the runtime
# directory and the session bus does, and this does the same, in the same order,
# so a reader who knows one launcher can read the other.
#
# No logind and no systemd: the seat comes from seatd (started by PID 1 before
# the session shell), the session bus is a dbus daemon this script starts, and
# ML4W's systemd units are not used -- its own hyprland.lua/conf/autostart.lua
# is the startup path, exactly as it is on a systemd distro.
#
# POSIX sh, not bash: the image's shell is busybox ash, and build.sh checks these
# scripts against /bin/sh. A bashism here is a script that works on the build
# host and fails on the machine.
#
# Exit codes, which are a contract rather than decoration:
#
#   0   Hyprland ran and exited cleanly
#   20  no Hyprland in the image
#   21  no session configuration for this user
#   22  the session runtime could not be prepared
#   23  Hyprland exited while starting up
#   24  usage error
#   25  a component is missing but there is no terminal to ask on, and
#       neither --yes nor --no was given, so nothing was decided
#
# KNOWN LIMITS, recorded rather than left to be found on a machine.
#
#   - The compositor runs on the console VT through the DRM backend, which needs
#     a seat and a DRM master. Without logind that seat is seatd; if PID 1 did
#     not start it, libseat's only remaining backend is logind, which is not
#     here, and Hyprland exits at start. The seat's presence is not something
#     this script can create -- starting a daemon needs root and this runs as
#     the session user -- so it checks, says so, and lets the compositor's own
#     log carry the rest.
#   - A machine whose framebuffer has a DRM node but no render node (a VM with no
#     3D) gets software rendering forced, because GL there fails in a way that
#     looks like a compositor bug. On real hardware nothing is forced.
#   - Only the instance socket under $XDG_RUNTIME_DIR/hypr is ever examined to
#     decide "it came up". If Hyprland starts but writes no socket there, the
#     wait expires and the launch proceeds anyway -- a compositor that is alive
#     and drawing is not something to declare dead because a probe could not see
#     it.

set -u

HYPRLAND=${COPPER_HYPRLAND:-/usr/bin/Hyprland}
SKEL=${COPPER_HYPR_SKEL:-/usr/share/copper/hyprland-skel}
SESSIONLOG=${COPPER_SESSIONLOG:-/tmp/hyprland.log}
WAIT_TRIES=${WAIT_TRIES:-100}
# Where the DRM devices live and where seatd listens. Both default to the real
# paths and exist only so the gate can exercise the branches that read them
# without a GPU or a running seatd; nothing here overrides them.
DRM_DIR=${COPPER_DRM_DIR:-/dev/dri}
SEATD=${COPPER_SEATD_SOCK:-/run/seatd.sock}

# The component manifest and the installer it drives. starthyprland only offers
# components; it does not hardcode which ones.
APPS=${COPPER_HYPR_APPS:-/etc/copper/hypr-apps}
INGOT=${COPPER_INGOT:-ingot}
SUDO=${COPPER_SUDO-sudo}
# Root needs no sudo, and the image may not even have it. "-" (not ":-") so an
# empty COPPER_SUDO really does disable sudo instead of reviving the default.
if [ "$(id -u)" = 0 ]; then SUDO=; fi

say() { printf 'starthyprland: %s\n' "$1"; }

# libseat opens the input devices through seatd, and seatd only serves a client
# whose account is in _seatd. The group is created by the hypr build stage,
# copper-init recreates it at boot, and both the first-boot wizard and
# copper-init put the user in it. None of that can help a session that is
# already logged in, so if this one is somehow missing the group the compositor
# comes up with a dead cursor and no keyboard -- say so instead of leaving the
# user to guess. A re-login (or reboot) picks up the membership.
if ! id -nG 2>/dev/null | grep -qw _seatd; then
    say "warning: this account is not in the _seatd group, so input may not work"
    say "  fix: sudo addgroup $(id -un) _seatd   (then log out and back in)"
fi

# The other half of "input works". The group above lets the compositor reach
# seatd and open the devices; libinput then has to accept each one, and it
# discards every device libudev calls uninitialized. Only a record under
# /run/udev/data clears that flag, there is no udev daemon in this image, and
# PID 1 writes those records at boot (seed_udev_input_db in copper-init.c).
# Clearing the flag is not enough on its own: the record also has to say what
# the device is, because libinput reads udev's ID_INPUT_* tags and drops any
# device whose only tag is ID_INPUT. Both mistakes end in the same place --
# the compositor still starts, seat, config and DRM master all fine, with a
# pointer that does not move and a keyboard that types nowhere -- so say which
# half is missing rather than leave the user to guess.
if [ -d /sys/class/input ] && ! ls /run/udev/data/c* >/dev/null 2>&1; then
    say "warning: no libudev records under /run/udev/data, so libinput will"
    say "  take no input device and the session will have a dead pointer and no"
    say "  keyboard. PID 1 writes one record per input device at boot, so none"
    say "  here means it wrote none: no event node, or it could not write into"
    say "  the directory."
elif [ -d /sys/class/input ]; then
    typed=no
    for rec in /run/udev/data/c*; do
        [ -f "$rec" ] || continue
        if grep -q 'E:ID_INPUT_' "$rec" 2>/dev/null; then
            typed=yes
            break
        fi
    done
    if [ "$typed" = no ]; then
        say "warning: the libudev records under /run/udev/data name no device"
        say "  type, and libinput drops every device whose only tag is ID_INPUT:"
        say "  dead pointer, no keyboard, session up as if all were well. PID 1"
        say "  writes the type from the device's sysfs capabilities"
        say "  (seed_udev_input_db in copper-init.c), so none here means it read"
        say "  no capabilities out of /sys/class/input/input*."
    fi
fi

usage() {
    cat <<'EOF'
starthyprland -- start the Hyprland compositor on the tty

  starthyprland            set up the session and start Hyprland
  starthyprland --check    report what is installed and exit, starting nothing
  starthyprland --yes      install any missing components without asking
  starthyprland --no       do not install components, just start the session
  starthyprland --help     this text

Environment, all optional:
  COPPER_HYPRLAND    path to the compositor       (default /usr/bin/Hyprland)
  COPPER_HYPR_SKEL   the shipped config tree that seeds a user's home
                     (default /usr/share/copper/hyprland-skel)
  COPPER_SESSIONLOG  where the compositor logs    (default /tmp/hyprland.log)
  COPPER_HYPR_APPS   where the component manifest lives
                     (default /etc/copper/hypr-apps; absence disables the
                     offer entirely)
  COPPER_INGOT       installer for the components  (default ingot)
  COPPER_SUDO        how to gain root for the install (default sudo; empty
                     means already root or never use it)
  XDG_RUNTIME_DIR    the session's private runtime directory (default
                     /run/user/<uid>, made here when missing)

Exit codes: 0 ok, 20 no Hyprland, 21 no session config, 22 no runtime,
23 Hyprland exited while starting, 24 usage, 25 no way to ask about components.
EOF
}

# What is installed. Echoed as words so --check and the launch path agree, and so
# there is exactly one place that knows what the image contains.
have_hypr=0
[ -x "$HYPRLAND" ] && have_hypr=1

# Where this user's configuration lives, and whether the shipped tree is there
# to seed it from.
user_hypr="$HOME/.config/hypr"
user_config=0
[ -e "$user_hypr/hyprland.lua" ] && user_config=1
skel_config=0
[ -e "$SKEL/.config/hypr/hyprland.lua" ] && skel_config=1

report() {
    if [ "$have_hypr" = 1 ]; then
        say "found Hyprland: $HYPRLAND"
    else
        say "NO Hyprland at $HYPRLAND"
        say "  this is the compositor, built from the cppiber PPA by the hypr"
        say "  stage of the image build. Nothing can start until it is staged."
    fi
    if [ "$user_config" = 1 ]; then
        say "found a session config: $user_hypr"
    elif [ "$skel_config" = 1 ]; then
        say "no config in $user_hypr; will seed it from $SKEL on launch"
    else
        say "NO session config in $user_hypr, and none to seed from at $SKEL"
    fi
}

choice=
while [ $# -gt 0 ]; do
    case "$1" in
    --help|-h)  usage; exit 0 ;;
    --check)    report; exit 0 ;;
    --yes|-y)   choice=yes ;;
    --no|-n)    choice=no ;;
    -*)         say "unknown option: $1"; usage >&2; exit 24 ;;
    *)          say "unexpected argument: $1"; usage >&2; exit 24 ;;
    esac
    shift
done

# The boot splash, defensively and for the same reason startxfce quits it: a
# splash still holding the console is what makes a compositor's VT takeover
# fail, and an interactive prompt down this script would be invisible. The test
# is a ping, not a blind quit, so a machine built without the splash says nothing
# and does nothing; --check, which exits above, never reaches here.
if command -v plymouth >/dev/null 2>&1 &&
   plymouth --ping >/dev/null 2>&1; then
    say "quitting the boot splash before starting the session"
    plymouth quit >/dev/null 2>&1 || :
fi

# The compositor. Checked before anything else, and outside any branch that
# starts a session: a machine with the config but no compositor must say so with
# exit 20, not die on a bare exec failure.
if [ "$have_hypr" != 1 ]; then
    report
    say "cannot start the session: there is no compositor at $HYPRLAND"
    say "the hypr stage of the image build stages it; see HANDOFF.md, Hyprland."
    exit 20
fi

# The configuration. ML4W's tree is shipped in the image and copied into the home
# on first boot, but a home that was made another way -- a second user, a home
# wiped by hand, a wizard path that skipped the copy -- should still get a
# working session rather than an empty compositor and a black screen. So when
# the user has no config and the image has one to give, seed it. When neither is
# true there is nothing to start: an unconfigured Hyprland is not the session
# anyone asked for, and 21 names that.
if [ "$user_config" != 1 ]; then
    if [ "$skel_config" = 1 ]; then
        do_cfg=
        case "$choice" in
            yes) do_cfg=1 ;;
            no)  say "not installing the config files (--no)" ;;
            *)
                if [ -t 0 ]; then
                    printf 'starthyprland: would you like your hyprland config files? (Y/n) '
                    read -r answer || answer=
                    case "$answer" in
                        [Nn]*) printf '...\n'
                               sleep 2
                               printf 'its now l-like i wanted you to u-use my config anyways b-baka! humph~! (,,>﹏<,,)\n'
                               printf '\n\n\n' ;;
                        *) do_cfg=1 ;;
                    esac
                else
                    say "no terminal to ask about the config files; using the shipped config"
                fi
                ;;
        esac
        if [ -n "$do_cfg" ]; then
            say "installing the hyprland config files (hypr-configs)"
            if $SUDO $INGOT install hypr-configs; then
                say "hyprland config files installed"
            else
                say "could not install hypr-configs; using the shipped config"
            fi
        fi
        say "seeding the session config from $SKEL into $HOME"
        # The whole shipped home, not just .config/hypr: the tree carries the
        # ml4w/, waybar/, quickshell/ and gtk configuration the session reads
        # from the same place. -n so a partial home keeps whatever it already
        # has; the missing hyprland.lua is what brought us here.
        if cp -a -n "$SKEL"/. "$HOME"/ 2>/dev/null; then
            :
        fi
        if [ -e "$user_hypr/hyprland.lua" ]; then
            say "session config seeded"
        else
            say "could not seed the session config from $SKEL"
            say "  (the copy failed; check that $HOME is writable)"
            exit 21
        fi
    else
        report
        say "cannot start the session: no config in $user_hypr"
        say "  and the image has no shipped tree to seed it from."
        exit 21
    fi
fi

# Components. The session is in the image; the apps on top of it are ingot
# packages, and only the missing ones are offered. The list lives in the
# manifest, not here: what is offered, what marks it present, and how it is
# installed change independently of this script. Components whose 'how' is
# "image" are expected in the ISO already -- a missing one is a broken image, so
# it is reported and never turned into an install attempt.
missing=
if [ -r "$APPS" ]; then
    while read -r cname cprobe corigin; do
        case "$cname" in ''|\#*) continue ;;
        esac
        [ -n "$cprobe" ] || continue
        [ -e "$cprobe" ] && continue
        case "$corigin" in
            image) say "component '$cname' is missing from the image (looked for $cprobe)" ;;
            *)     missing="$missing $cname" ;;
        esac
    done < "$APPS"
fi

if [ -n "$missing" ]; then
    do_install=
    case "$choice" in
        yes) do_install=1 ;;
        no)  say "not installing components (--no)" ;;
        *)
            if [ -t 0 ]; then
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
            ;;
    esac

    if [ -n "$do_install" ]; then
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
        # ingot unpacks .debs but no maintainer script runs, so nothing
        # regenerates the databases the desktop reads. Rebuild them by hand or
        # the new .desktop files never show up and launchers stay dead.
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

# The runtime directory. Wayland keeps its sockets in $XDG_RUNTIME_DIR and
# refuses to start the compositor without one; on a normal system the login
# stack makes it, but nothing here logs in through pam. PID 1 makes
# /run/user/<uid> and hands ownership over before this runs -- a user cannot
# mkdir under root-owned /run -- so this only has to confirm it and export it,
# and fall back to a directory of the user's own when PID 1 did not get there.
uid=$(id -u 2>/dev/null) || uid=
if [ -z "$uid" ]; then
    say "cannot determine this login's uid"
    exit 22
fi
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ ! -d "$XDG_RUNTIME_DIR" ]; then
    # Set to something that is not a directory -- a stale path, a regular file.
    # Adopting it silently is how a session ends up writing its sockets into a
    # file and failing several layers down.
    say "XDG_RUNTIME_DIR is set to $XDG_RUNTIME_DIR, which is not a directory"
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

# The session bus. Quickshell, the portals, swaync and the polkit agent all want
# one, and there is no session manager to have started it. Prefer dbus-launch,
# which sets both the address and the pid; fall back to dbus-daemon directly,
# which only prints the address. Either way it is exported into the compositor's
# environment, and a machine that turns out to have neither still starts -- the
# compositor runs without a bus, the pieces that want one say so, and that is a
# degraded session rather than no session.
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

# The seat. Without logind, libseat talks to seatd, and seatd is PID 1's to
# start -- a daemon needs root and this runs as the session user. Its socket
# path is what libseat reads; make sure the variable points at the default
# unless the machine says otherwise, so a libseat built for /run/seatd.sock and
# a seatd started there agree.
if [ -z "${SEATD_SOCK:-}" ] && [ -S "$SEATD" ]; then
    SEATD_SOCK=$SEATD
    export SEATD_SOCK
fi
if [ -S "${SEATD_SOCK:-$SEATD}" ]; then
    say "seat: ${SEATD_SOCK:-$SEATD}"
else
    say "no seatd socket at ${SEATD_SOCK:-$SEATD}."
    say "  with no logind, Hyprland needs seatd to take the DRM master; if PID 1"
    say "  did not start it the compositor will exit and its log will say so."
fi

# The renderer. A framebuffer with a DRM node but no render node is a VM with no
# 3D, where GL fails in a way that reads as a compositor bug rather than a
# missing GPU. Force the software path there, and only there: on a machine with
# a render node nothing is overridden, and COPPER_HYPR_SOFTWARE=1 forces it by
# hand for a machine the heuristic gets wrong.
soft=0
if [ "${COPPER_HYPR_SOFTWARE:-0}" = 1 ]; then
    soft=1
elif [ -e "$DRM_DIR" ] && ! ls "$DRM_DIR"/renderD* >/dev/null 2>&1; then
    soft=1
fi
if [ "$soft" = 1 ]; then
    WLR_RENDERER=pixman
    LIBGL_ALWAYS_SOFTWARE=1
    export WLR_RENDERER LIBGL_ALWAYS_SOFTWARE
    say "no render node; forcing software rendering (pixman)"
fi

# Hand the session over. Background first so the launch can be watched: a
# compositor that dies in the first second -- no seat, no DRM master, a broken
# config -- prints its reason and exits, and a launcher that only waited on the
# process would hand back a bare nonzero status with the reason already gone
# from the screen. The wait is bounded and checks whether the process is still
# alive, because "still starting" and "already died" look identical if all you
# do is count to a limit. The live/up test is the instance socket under the
# runtime directory's hypr/ subtree.
say "starting Hyprland, log in $SESSIONLOG"
"$HYPRLAND" > "$SESSIONLOG" 2>&1 &
hypid=$!

# Where Hyprland keeps its per-instance sockets. The signature is not known
# ahead of time, so the test is for any .socket.sock below this directory.
hyprrt="$XDG_RUNTIME_DIR/hypr"
up=0
i=0
while [ "$i" -lt "$WAIT_TRIES" ]; do
    if [ -n "$(find "$hyprrt" -name .socket.sock -print -quit 2>/dev/null)" ]; then
        up=1
        break
    fi
    if ! kill -0 "$hypid" 2>/dev/null; then
        wait "$hypid" 2>/dev/null || :
        say "Hyprland exited while starting up. Its log says:"
        sed 's/^/  /' "$SESSIONLOG" 2>/dev/null
        exit 23
    fi
    i=$((i + 1))
    sleep 0.1 2>/dev/null || sleep 1
done

if [ "$up" = 1 ]; then
    say "Hyprland is up"
else
    # Alive but no socket seen. A compositor that is running and drawing is not
    # something to declare dead, so say what was not found and keep waiting
    # rather than fail a session that may be perfectly well on screen.
    say "no instance socket appeared under $hyprrt; waiting for Hyprland anyway"
fi

wait "$hypid"
rc=$?
say "Hyprland exited (status $rc)"
exit "$rc"
