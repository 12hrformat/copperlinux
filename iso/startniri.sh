#!/bin/sh
# startniri -- start the niri session on the tty.
#
# The compositor and session tools are baked in from the praksharma PPA;
# apps on top are ingot packages installed before start from
# /etc/copper/niri-apps. A genuine absence gets a named exit code and
# sentence, not a bare "not found" that could mean a broken PATH or library.
#
# niri IS the session: unlike XFCE there is no display to hand over, but the
# seat, runtime dir and session bus are prepared in the same order as
# startxfce. No logind/systemd: seatd (started by PID 1) gives the seat,
# and this script starts the dbus daemon. Startup spawns live in config.kdl.
#
# POSIX sh: the image runs busybox ash and build.sh checks these as /bin/sh;
# a bashism works on the build host and fails on the machine.
#
# Exit codes (a contract): 0 ok, 20 no compositor, 21 no session config,
# 22 runtime not prepared, 23 niri died starting, 24 usage. There is no
# "cannot ask" code: components install by default and --no declines them.
#
# KNOWN LIMITS, recorded rather than left to be found on a machine:
#   - The console VT needs a seat and DRM master. Without logind that is
#     seatd; if PID 1 did not start it, niri has no other seat backend and
#     exits. Starting a daemon needs root, so this only checks and reports.
#   - No render node (a VM without 3D) forces software; VMware with a render
#     node keeps the hardware renderer, since niri refuses software EGL
#     renderers and would leave a live socket with nothing drawn.
#   - IPC has no device list, so input shown is what libinput accepts, not
#     proof niri claimed it; the udev records are the half that can be checked.
#   - "Came up" means one instance socket under $XDG_RUNTIME_DIR answered;
#     a compositor drawing without that socket proceeds anyway, not declared
#     dead just because a probe could not see it.

set -u

NIRI=${COPPER_NIRI:-/usr/bin/niri}
SKEL=${COPPER_NIRI_SKEL:-/usr/share/copper/niri-skel}
# mktemp makes a private 0600 file: a predictable /tmp/niri.log can be a
# symlink planted by another local user, and a shared name turns a log into a
# write primitive. Tests set COPPER_SESSIONLOG to their own private path.
SESSIONLOG=${COPPER_SESSIONLOG:-$(mktemp "${TMPDIR:-/tmp}/copper-niri-log.XXXXXX")} || exit 1
WAIT_TRIES=${WAIT_TRIES:-100}
# DRM nodes and seatd's socket default to real paths; overridable so the gate
# can exercise GPU/seatd branches without either on the test host.
DRM_DIR=${COPPER_DRM_DIR:-/dev/dri}
SEATD=${COPPER_SEATD_SOCK:-/run/seatd.sock}
# Input nodes and PID 1's libudev records are overridable for the same reason:
# the gate must be able to show a dropped device without real hardware.
INPUT_SYS=${COPPER_INPUT_SYS:-/sys/class/input}
UDEV_DATA=${COPPER_UDEV_DATA:-/run/udev/data}

# Components come from the manifest, not hardcoded here.
APPS=${COPPER_NIRI_APPS:-/etc/copper/niri-apps}
INGOT=${COPPER_INGOT:-ingot}
SUDO=${COPPER_SUDO-sudo}
# "-" not ":-": an empty COPPER_SUDO must disable sudo, not revive the default.
if [ "$(id -u)" = 0 ]; then SUDO=; fi

say() { printf 'startniri: %s\n' "$1"; }

# libseat serves only clients in _seatd. The niri stage creates the group,
# copper-init recreates it at boot, and both it and the wizard add the user;
# a session already logged in without it gets a dead pointer and no keyboard.
if ! id -nG 2>/dev/null | grep -qw _seatd; then
    say "warning: this account is not in the _seatd group, so input may not work"
    say "  fix: sudo addgroup $(id -un) _seatd   (then log out and back in)"
fi

# seatd access alone is not enough: libinput drops devices libudev calls
# uninitialized, and drops ones whose only tag is ID_INPUT, not ID_INPUT_*.
# No udev daemon here, so PID 1 writes one record per input device at boot
# (seed_udev_input_db in copper-init.c); name which device and half failed.
if [ -d "$INPUT_SYS" ] && ! ls "$UDEV_DATA"/c* >/dev/null 2>&1; then
    say "warning: no libudev records under $UDEV_DATA, so libinput will"
    say "  take no input device and the session will have a dead pointer and no"
    say "  keyboard. PID 1 writes one record per input device at boot, so none"
    say "  here means it wrote none: no event node, or it could not write into"
    say "  the directory."
elif [ -d "$INPUT_SYS" ]; then
    # Check each device, not "does any record have a type": a pointer that
    # moves while nothing types is one specific device being dropped, and a
    # name makes the line actionable. List every device to tell "not here"
    # from "here, with no type".
    listed=""
    nl='
'
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
        say "warning: libinput will ignore at least one input device, and a"
        say "  dropped keyboard is a session where the pointer moves and nothing"
        say "  types. Every input device, and what its record says:"
        oldifs=$IFS
        IFS='
'
        for line in $listed; do say "$line"; done
        IFS=$oldifs
        say "  PID 1 writes each record from the device's sysfs capabilities"
        say "  (seed_udev_input_db in copper-init.c), so a line above with no"
        say "  ID_INPUT_* is a device it read no capabilities out of, and a"
        say "  device that is not listed at all had no event node to write."
    fi
fi

usage() {
    cat <<'EOF'
startniri -- start the niri compositor on the tty

  startniri            set up the session and start niri
  startniri --check    report what is installed and exit, starting nothing
  startniri --yes      install any missing components (now the default)
  startniri --no       do not install components, just start the session
  startniri --help     this text

Environment, all optional:
  COPPER_NIRI        path to the compositor       (default /usr/bin/niri)
  COPPER_NIRI_SKEL   the shipped config tree that seeds a user's home
                     (default /usr/share/copper/niri-skel)
  COPPER_SESSIONLOG  where the compositor logs    (default: a private
                     /tmp/copper-niri-log.XXXXXX made with mktemp)
  COPPER_NIRI_APPS   where the component manifest lives
                     (default /etc/copper/niri-apps; absence disables the
                     install entirely)
  COPPER_INGOT       installer for the components  (default ingot)
  COPPER_SUDO        how to gain root for the install (default sudo; empty
                     means already root or never use it)
  COPPER_DRM_DIR     where DRM nodes live        (default /dev/dri)
  COPPER_NIRI_VMWARE force VMware software path  (auto from DMI; 0 disables)
  COPPER_SEATD_SOCK  seatd's socket              (default /run/seatd.sock)
  COPPER_INPUT_SYS   where the input devices live (default /sys/class/input)
  COPPER_UDEV_DATA   the libudev records PID 1 writes (default /run/udev/data)
  COPPER_AUDIO       start the configured audio server (default 1; 0 skips)
  XDG_RUNTIME_DIR    the session's private runtime directory (default
                     /run/user/<uid>, made here when missing)

Exit codes: 0 ok, 20 no niri, 21 no session config, 22 no runtime,
23 niri exited while starting, 24 usage.
EOF
}

# One source of truth so --check and the launch path agree.
have_niri=0
[ -x "$NIRI" ] && have_niri=1

# Locate the user's config and the shipped tree that can seed it.
user_niri="$HOME/.config/niri"
user_config=0
[ -e "$user_niri/config.kdl" ] && user_config=1
skel_config=0
[ -e "$SKEL/.config/niri/config.kdl" ] && skel_config=1

report() {
    if [ "$have_niri" = 1 ]; then
        say "found niri: $NIRI"
    else
        say "NO niri at $NIRI"
        say "  this is the compositor, staged from the praksharma PPA by the niri"
        say "  stage of the image build. Nothing can start until it is staged."
    fi
    if [ "$user_config" = 1 ]; then
        say "found a session config: $user_niri"
    elif [ "$skel_config" = 1 ]; then
        say "no config in $user_niri; will seed it from $SKEL on launch"
    else
        say "NO session config in $user_niri, and none to seed from at $SKEL"
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

# Quit a live splash before the compositor takes the VT: it would fail the
# takeover and hide any prompt below. Ping first, so a splashless machine
# stays silent and does nothing; --check exits above and never gets here.
if command -v plymouth >/dev/null 2>&1 &&
   plymouth --ping >/dev/null 2>&1; then
    say "quitting the boot splash before starting the session"
    plymouth quit >/dev/null 2>&1 || :
fi

# Check the compositor outside any session branch: config without niri must
# exit 20, not die on a bare exec failure.
if [ "$have_niri" != 1 ]; then
    report
    say "cannot start the session: there is no compositor at $NIRI"
    say "the niri stage of the image build stages it; see HANDOFF.md, niri."
    exit 20
fi

# Seed a shipped config into homes made another way (second user, wiped home,
# wizard that skipped the copy), or the compositor starts with a black screen.
# With neither user config nor shipped tree, 21 names the real failure.

# Copy missing files and symlinks, making directories: user edits survive and
# a half-seeded home can be repaired instead of staying broken.
#
# This is not `cp -a -n`: busybox reads -n as "skip an existing *anything*",
# so an existing ~/.config skips the whole subtree and reports success. That
# left pre-bug-26 homes broken: the config file there suppressed seeding,
# and seeding could not have repaired the zero-byte stubs the old config
# require()d anyway. Walking the tree costs a few stat() calls and no surprises.
seed_added=0
seed_config() {
    seed_added=0
    seed_dir=$(mktemp -d "${TMPDIR:-/tmp}/startniri-seed.XXXXXX") || return 1
    seed_list=$seed_dir/list
    if [ ! -d "$SKEL" ]; then
        rm -rf "$seed_dir"
        return 1
    fi
    if ! ( cd "$SKEL" && find . \( -type f -o -type l \) ) > "$seed_list" 2>/dev/null; then
        rm -rf "$seed_dir"
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
    rm -rf "$seed_dir"
    return 0
}

if [ "$user_config" != 1 ]; then
    if [ "$skel_config" = 1 ]; then
        say "seeding the session config from $SKEL into $HOME"
        # Seed the whole home: it also carries the waybar config the session reads.
        if ! seed_config; then
            say "the shipped config tree at $SKEL is not readable"
        fi
        if [ -e "$user_niri/config.kdl" ]; then
            say "session config seeded"
        else
            say "could not seed the session config from $SKEL"
            say "  (nothing was written; check that $HOME is writable)"
            exit 21
        fi
    else
        report
        say "cannot start the session: no config in $user_niri"
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

# Only missing ingot apps are installed before the compositor takes the
# console; the manifest owns presence and install method, so those change
# independently. 'image' components belong to the ISO: report a missing one.
# No Y/n question and no exit 25: the manifest is the session's own package
# list, a session without terminal/editor/browser is useless, and stopping
# on an unasked question looks like a broken machine. --no says no once.
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
        no) say "not installing components (--no)" ;;
        *)  do_install=1 ;;
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
            say "components installed, running niri now"
        fi
    fi
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
# so portals pick the niri backend instead of GTK and toolkits choose Wayland;
# niri --session only covers its own children and the bus.
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=niri
XDG_SESSION_DESKTOP=niri
DESKTOP_SESSION=niri
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

# Portals, swaync, keyring and polkit all want a bus, with no session manager
# to start one. Prefer dbus-launch, fall back to dbus-daemon; without either,
# start anyway and let the consumers complain. --print-address gives the one
# value we need: --sh-syntax plus eval executes a command's output, which is a
# needless injection surface even when that output is generated locally.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    if command -v dbus-launch >/dev/null 2>&1; then
        addr=$(dbus-launch --print-address=1 2>/dev/null) || addr=
        if [ -n "$addr" ]; then
            DBUS_SESSION_BUS_ADDRESS=$addr
            export DBUS_SESSION_BUS_ADDRESS
        fi
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
if [ -z "${SEATD_SOCK:-}" ] && [ -S "$SEATD" ]; then
    SEATD_SOCK=$SEATD
    export SEATD_SOCK
fi
if [ -S "${SEATD_SOCK:-$SEATD}" ]; then
    say "seat: ${SEATD_SOCK:-$SEATD}"
else
    say "no seatd socket at ${SEATD_SOCK:-$SEATD}."
    say "  with no logind, niri needs seatd to take the DRM master; if PID 1 did"
    say "  not start it the compositor will exit and its log will say so."
fi

# No render node means a VM without 3D: GL fails like a compositor bug, so
# force Mesa's software GBM there. VMware with 3D does advertise renderD*,
# but the old rule forced llvmpipe there too -- backwards, because niri
# skips software EGL renderers, then has no allocator for the card and
# leaves a live Wayland socket with nothing drawn (a frozen-looking session).
# So a VMware render node keeps its hardware renderer; only the debug config
# below is applied. COPPER_NIRI_SOFTWARE=1/-0 override the automatic choice;
# COPPER_NIRI_VMWARE controls the wrapper, defaulting to DMI detection.
vmware=0
case "${COPPER_NIRI_VMWARE:-auto}" in
    1) vmware=1 ;;
    0) vmware=0 ;;
    *)
        for dmi in /sys/class/dmi/id/product_name /sys/class/dmi/id/sys_vendor; do
            if [ -r "$dmi" ] && grep -qi 'vmware' "$dmi" 2>/dev/null; then
                vmware=1
                break
            fi
        done
        ;;
esac
soft=0
case "${COPPER_NIRI_SOFTWARE:-auto}" in
    1) soft=1 ;;
    0) soft=0 ;;
    *)
        if [ -e "$DRM_DIR" ] && ! ls "$DRM_DIR"/renderD* >/dev/null 2>&1; then
            soft=1
        fi
        ;;
esac
if [ "$soft" = 1 ]; then
    LIBGL_ALWAYS_SOFTWARE=1
    GBM_ALWAYS_SOFTWARE=1
    GALLIUM_DRIVER=llvmpipe
    export LIBGL_ALWAYS_SOFTWARE GBM_ALWAYS_SOFTWARE GALLIUM_DRIVER
    say "no render node; forcing software rendering"
elif [ "$vmware" = 1 ]; then
    say "VMware virtual GPU: keeping the 3D render node (niri ignores llvmpipe)"
fi

# A virtual GPU's overlay and cursor planes can also stall before the socket
# appears. niri's top-level `include` adds a generated wrapper with two debug
# options under $XDG_RUNTIME_DIR; NIRI_CONFIG is stripped from children, and
# an explicit caller value wins.
if [ "$vmware" = 1 ] && [ -z "${NIRI_CONFIG:-}" ]; then
    vmconfig="$XDG_RUNTIME_DIR/niri-vmware-config.kdl"
    vm_include=$(printf '%s\n' "$user_niri/config.kdl" |
        sed 's/\\/\\\\/g; s/"/\\"/g' 2>/dev/null)
    if [ -n "$vm_include" ] &&
       { printf 'include "%s"\n' "$vm_include"
         printf 'debug {\n'
         printf '    disable-direct-scanout\n'
         printf '    disable-cursor-plane\n'
         printf '}\n'
       } > "$vmconfig" 2>/dev/null; then
        NIRI_CONFIG=$vmconfig
        export NIRI_CONFIG
        say "VMware niri config: $vmconfig (direct scanout and cursor plane off)"
    else
        say "could not write the VMware niri config; starting with the user's own"
    fi
fi

# /etc/copper.conf is the wizard's audio switch, editable by the user;
# missing, unreadable or unknown means pulseaudio, the image's default.
copper_audio_backend() {
    _conf=${COPPER_CONF:-/etc/copper.conf}
    _word=
    if [ -r "$_conf" ]; then
        _word=$(sed -n 's/^[[:space:]]*audio[[:space:]]*=[[:space:]]*\([a-z]*\).*$/\1/p' \
                    "$_conf" 2>/dev/null | tail -n 1)
    fi
    case "$_word" in
        pipewire) printf '%s\n' pipewire ;;
        *)        printf '%s\n' pulseaudio ;;
    esac
}

# Audio is a per-user daemon (PulseAudio refuses root without --system); cava,
# mpv and firefox speak its protocol. Start it once here, COPPER_AUDIO=0 lets
# the gate avoid a daemon on the test host; a missing binary is only silence.
if [ "${COPPER_AUDIO:-1}" = 1 ]; then
    case "$(copper_audio_backend)" in
    pipewire)
# Start the graph server, session manager and Pulse front end: pipewire-pulse
# does not pull in wireplumber; the graph socket is the readiness signal.
        _rt=${XDG_RUNTIME_DIR:-/tmp}
        if command -v pipewire >/dev/null 2>&1; then
            if [ ! -S "$_rt/pipewire-0" ]; then
                pipewire >/dev/null 2>&1 &
            fi
            if command -v wireplumber >/dev/null 2>&1; then
                wireplumber >/dev/null 2>&1 &
            fi
            if command -v pipewire-pulse >/dev/null 2>&1; then
                pipewire-pulse >/dev/null 2>&1 &
            fi
            i=0
            while [ "$i" -lt 5 ] && [ ! -S "$_rt/pipewire-0" ]; do
                sleep 1
                i=$((i + 1))
            done
            if [ -S "$_rt/pipewire-0" ]; then
                say "audio: pipewire is running"
            else
                say "audio: pipewire is installed but did not start"
            fi
        else
            say "audio: pipewire is selected but not installed"
        fi
        ;;
    *)
        if command -v pulseaudio >/dev/null 2>&1; then
            if ! pulseaudio --check >/dev/null 2>&1; then
                pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || :
            fi
            if pulseaudio --check >/dev/null 2>&1; then
                say "audio: pulseaudio is running"
            else
                say "audio: pulseaudio is installed but did not start"
            fi
        fi
        ;;
    esac

# A codec can come out of reset muted and a live image keeps no mixer state,
# so raise the controls once after the server starts (see copper-audio).
    if command -v copper-audio >/dev/null 2>&1; then
        copper-audio init >/dev/null 2>&1 || :
    fi
fi

# Launch in the background so a compositor that dies in the first second
# (no seat, no DRM master, bad config) prints its reason before we read the
# log. The bounded wait also checks liveness: "starting" and "died" look
# identical if you only count to a limit.
#
# Pass --session directly: niri needs it to be the main instance (desktop
# identity, bus imports, D-Bus services); niri-session wants systemd/dinit.
say "starting niri, log in $SESSIONLOG"
"$NIRI" --session > "$SESSIONLOG" 2>&1 &
niripid=$!

# The IPC socket is $XDG_RUNTIME_DIR/niri.<wayland socket>.<pid>.sock; NIRI_SOCKET
# is only set for children, so find it by pid and prove it answers with
# `niri msg`, since a stale socket from an earlier instance could read live.
up=0
i=0
nirisock=
while [ "$i" -lt "$WAIT_TRIES" ]; do
    nirisock=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 \
        -name "niri.*.$niripid.sock" -print -quit 2>/dev/null)
    if [ -n "$nirisock" ] &&
       NIRI_SOCKET=$nirisock "$NIRI" msg --json version >/dev/null 2>&1; then
        up=1
        break
    fi
    if ! kill -0 "$niripid" 2>/dev/null; then
        wait "$niripid" 2>/dev/null || :
        say "niri exited while starting up. Its log says:"
        sed 's/^/  /' "$SESSIONLOG" 2>/dev/null
        exit 23
    fi
    i=$((i + 1))
    sleep 0.1 2>/dev/null || sleep 1
done

if [ "$up" = 1 ]; then
    say "niri is up"
else
    # Alive but no answering socket: a compositor that is drawing is not dead.
    # Say what was missing and keep waiting rather than fail a working session.
    say "no answering IPC socket appeared under $XDG_RUNTIME_DIR; waiting for niri anyway"
fi

wait "$niripid"
rc=$?
say "niri exited (status $rc)"
exit "$rc"
