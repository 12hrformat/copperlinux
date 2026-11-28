#!/bin/sh
# startxfce -- start the X server, then XFCE on it.
#
# The desktop (Xorg, XFCE) is baked in; apps on top (firefox, mousepad,
# ristretto, xfce4-taskmanager, xarchiver) are ingot packages from
# /etc/copper/xfce-apps. A genuine absence gets a named exit code and
# sentence, not a bare "not found" that could mean a broken PATH or library.
#
# POSIX sh: the image runs busybox ash and build.sh checks these as /bin/sh;
# a bashism works on the build host and fails on the machine.
#
# Exit codes (a contract): 0 ok, 20 no X, 21 no XFCE, 22 no display socket,
# 23 X died starting, 24 usage, 25 no way to ask about components.
# Xorg's log is $COPPER_XLOG or a private mktemp file: with no screen it is the
# only evidence when startup fails.
# Known limits: only DISPLAY_NUM is checked; a slow probe stretches the
# bounded wait; the timeout is 10s with fractional sleep, 100s without.

set -u

XORG=${COPPER_XORG:-/usr/bin/Xorg}
STARTXFCE4=${COPPER_STARTXFCE4:-/usr/bin/startxfce4}
# Private mktemp files: fixed /tmp names are symlink targets for any other
# local user. The gates pass their own private paths, so they see what boots.
XLOG=${COPPER_XLOG:-$(mktemp "${TMPDIR:-/tmp}/copper-xorg-log.XXXXXX")} || exit 1
SESSIONLOG=${COPPER_SESSIONLOG:-$(mktemp "${TMPDIR:-/tmp}/copper-session-log.XXXXXX")} || exit 1
XSOCKDIR=${XSOCKDIR:-/tmp/.X11-unix}
DISPLAY_NUM=${DISPLAY_NUM:-0}
WAIT_TRIES=${WAIT_TRIES:-100}

# Set xfconf's default and the process environment: Xfce's settings daemon
# inherits one late, while Xcursor clients read theirs before that.
XCURSOR_THEME=${XCURSOR_THEME:-DMZ-White}
XCURSOR_SIZE=${XCURSOR_SIZE:-24}
export XCURSOR_THEME XCURSOR_SIZE

# Components come from the manifest, not hardcoded here.
APPS=${COPPER_XFCE_APPS:-/etc/copper/xfce-apps}
INGOT=${COPPER_INGOT:-ingot}
SUDO=${COPPER_SUDO-sudo}
# "-" not ":-": an empty COPPER_SUDO must disable sudo, not revive the default.
if [ "$(id -u)" = 0 ]; then SUDO=; fi

say() { printf 'startxfce: %s\n' "$1"; }

apply_xfce_theme() {
    _theme=$1
    _xfconf="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
    mkdir -p "$_xfconf" || {
        say "could not create XFCE settings in $HOME"
        return
    }

    case "$_theme" in
        default)
            _gtk=Adwaita
            _xfwm=Default
            _wall=/usr/share/copper/wallpapers/copper-default.png
            ;;
        *)
            _theme=backlight
            _gtk=Blacklight
            _xfwm=Blacklight
            _wall=/usr/share/copper/wallpapers/backlight-final.png
            ;;
    esac

    cat >"$_xfconf/xsettings.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="$_gtk"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="CursorThemeName" type="string" value="DMZ-White"/>
    <property name="CursorThemeSize" type="int" value="24"/>
  </property>
</channel>
EOF
    cat >"$_xfconf/xfwm4.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="$_xfwm"/>
  </property>
</channel>
EOF
    cat >"$_xfconf/xfce4-desktop.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="image-path" type="string" value="$_wall"/>
        <property name="image-style" type="int" value="5"/>
        <property name="image-show" type="bool" value="true"/>
      </property>
    </property>
  </property>
</channel>
EOF
    say "theme: $_theme"
}

choose_xfce_theme() {
    _choice=${COPPER_XFCE_THEME:-}
    if [ -z "$_choice" ] && [ -t 0 ]; then
        printf 'startxfce: choose theme: 1) default  2) backlight [2] '
        read -r _choice || _choice=
    fi
    case "$_choice" in
        1|default) apply_xfce_theme default ;;
        ''|2|backlight) apply_xfce_theme backlight ;;
        *) say "unknown theme '$_choice'; using backlight"; apply_xfce_theme backlight ;;
    esac
}

usage() {
    cat <<'EOF'
startxfce -- start the X server, then XFCE on it

  startxfce            start Xorg if it is not already running, then XFCE
  startxfce --check    report what is installed and exit, starting nothing
  startxfce --yes      install any missing components without asking
  startxfce --no       do not install components, just start the desktop
  startxfce --help     this text

Environment, all optional:
  COPPER_XORG        path to the X server        (default /usr/bin/Xorg)
  COPPER_STARTXFCE4  path to the XFCE session    (default /usr/bin/startxfce4)
  COPPER_XLOG        where the X server logs     (default: private mktemp file)
  COPPER_SESSIONLOG  where XFCE's output goes    (default: private mktemp file)
  COPPER_XPROBE      X client used to check whether a display really
                     answers     (default: the first of /usr/bin/xprobe and
                     /usr/bin/xdpyinfo; the kernel's socket table if neither)
  XPROBE_TIMEOUT     seconds xprobe waits for a display to answer before it
                     reports it unknown and the launcher moves on  (default 5)
  COPPER_XORGCONF    where the generated input config is written
                     (default /etc/X11/xorg.conf)
  COPPER_XORGCONF_FALLBACK  the second path tried when the first cannot be
                     written        (default: a private mktemp file; X is handed
                     whichever one won, with -config)
  COPPER_XFCE_APPS   where the component manifest lives
                     (default /etc/copper/xfce-apps; absence disables the
                     offer entirely)
  COPPER_INGOT       installer for the components   (default ingot)
  COPPER_SUDO        how to gain root for the install (default sudo; empty
                     means already root or never use it)
  DISPLAY_NUM        which display to use        (default 0)

Exit codes: 0 ok, 20 no X server, 21 no XFCE, 22 X gave no display,
23 X exited while starting, 24 usage, 25 no way to ask about components.
EOF
}

# One source of truth so --check and the launch path agree.
have_xorg=0
have_xfce=0
[ -x "$XORG" ] && have_xorg=1
[ -x "$STARTXFCE4" ] && have_xfce=1

report() {
    if [ "$have_xorg" = 1 ]; then
        say "found the X server: $XORG"
    else
        say "NO X SERVER at $XORG"
        say "  this is the glibc X stack, which is not in this image yet."
        say "  nothing can start until it is built and installed."
    fi
    if [ "$have_xfce" = 1 ]; then
        say "found XFCE: $STARTXFCE4"
    else
        say "NO XFCE at $STARTXFCE4"
        say "  XFCE needs the X server above, then glib, GTK3 and about thirty"
        say "  libraries, all built from source into a glibc rootfs."
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

# Quit a live splash before starting X: it holds the console (VT switch
# fails) and would hide any prompt below. Ping first, so a splashless build
# stays silent; --check exits above and never reaches here. copper-init
# normally quits the splash at hand-off, so this is only a safety net for
# hand-started or scripted sessions.
if command -v plymouth >/dev/null 2>&1 &&
   plymouth --ping >/dev/null 2>&1; then
    say "quitting the boot splash before starting the desktop"
    plymouth quit >/dev/null 2>&1 || :
fi

# Reuse a live display: two servers on one display either refuse the socket
# or replace each other, and the client ends up with whichever won.
# A socket file is not proof -- X leaves stale ones behind -- so ask the
# display with xprobe or xdpyinfo, both of which do a real X11 handshake
# with only libc; xdpyinfo costs another package to build and stage.
# COPPER_XPROBE overrides the search; the first executable found wins.
# With no probe, /proc/net/unix lists a socket only while its process lives;
# if even that is unreadable the answer is unknown, never live.
# xprobe's exit codes decide what is safe next (also in xprobe.c):
#   0 live -- reuse; 1 dead -- stale socket may be cleared;
#   2 usage -- never here; 3 unknown -- timeout, auth or malformed reply:
#   NOT proof of staleness, so nothing is removed on that answer.
XPROBE=${COPPER_XPROBE:-}
if [ -z "$XPROBE" ]; then
    for cand in /usr/bin/xprobe /usr/bin/xdpyinfo; do
        if [ -x "$cand" ]; then XPROBE=$cand; break; fi
    done
fi
XPROBE_TIMEOUT=${XPROBE_TIMEOUT:-5}

# 0 bound, 1 not bound, 2 cannot tell.
socket_bound() {
    [ -r /proc/net/unix ] || return 2
    _sock_want=$1
# The path is the eighth column of /proc/net/unix; an unbound line or the
# header leaves it empty and matches nothing, which is right.
    while read -r _f1 _f2 _f3 _f4 _f5 _f6 _f7 _f8; do
        [ "$_f8" = "$_sock_want" ] && return 0
    done < /proc/net/unix
    return 1
}

# One liveness decision for the reuse check and the wait loop, printing
# exactly one word (live/dead/unknown) so no diagnostic leaks into it.
display_state() {
    _ds_sock="$XSOCKDIR/X$DISPLAY_NUM"
    [ -S "$_ds_sock" ] || { echo dead; return 0; }
    if [ -n "$XPROBE" ] && [ -x "$XPROBE" ]; then
        DISPLAY=":$DISPLAY_NUM" XPROBE_SOCKET_DIR="$XSOCKDIR" \
            XPROBE_TIMEOUT="$XPROBE_TIMEOUT" "$XPROBE" >/dev/null 2>&1
        case "$?" in
            0) echo live ;;
            1) echo dead ;;
            *) echo unknown ;;
        esac
        return 0
    fi
    socket_bound "$_ds_sock"
    case "$?" in
        0) echo live ;;
        1) echo dead ;;
        *) echo unknown ;;
    esac
}

# Decide installed state before any server branch: a running server is not
# a desktop, so the reuse path must still refuse a missing startxfce4 rather
# than exec it and die with an unnamed "not found" / exit 127.
if [ "$have_xfce" != 1 ]; then
    if [ "$have_xorg" != 1 ]; then
        # Name both paths: "not there" leaves the reader guessing where it looked.
        report
        say "no X server at $XORG"
        say "the X stack is not in this image yet."
        say "build and install the glibc userspace first; see HANDOFF.md, XFCE."
        exit 20
    fi
    say "cannot start XFCE: there is no XFCE session at $STARTXFCE4"
    say "the X server alone is not a desktop."
    exit 21
fi

# Only missing ingot apps are offered; the manifest defines what marks a
# component present and how it is installed, so those change independently.
# 'image' components belong to the ISO: report a missing one, never install it.
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
                printf 'startxfce: before running xfce do you want to install its main components? (ex- firefox and thunar) (Y/n) '
                answer=
                read -r answer || answer=
                case "$answer" in
                    [Nn]*) say "not installing components" ;;
                    *)     do_install=1 ;;
                esac
            else
                say "a component is missing and there is no way to ask: stdin is not a terminal."
                say "  startxfce --yes   install the missing components first"
                say "  startxfce --no    start the desktop without them"
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
        # ingot runs no maintainer scripts, so rebuild desktop and mime databases or
        # newly installed .desktop files never appear and launchers stay dead.
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database /usr/share/applications >/dev/null 2>&1 || :
        fi
        if command -v update-mime-database >/dev/null 2>&1; then
            update-mime-database /usr/share/mime >/dev/null 2>&1 || :
        fi
        if [ -n "$failed" ]; then
            say "some components could not be installed; starting the desktop anyway"
        else
            say "components installed, running xfce now"
        fi
    fi
fi

# Say once when no liveness probe exists; otherwise the weaker socket-table
# fallback passes silently for the life of the image.
if [ -z "$XPROBE" ] || [ ! -x "$XPROBE" ]; then
    say "no X liveness probe (looked for \$COPPER_XPROBE, /usr/bin/xprobe,"
    say "  /usr/bin/xdpyinfo); checking the kernel's socket table instead."
fi

# The wizard's account owns the session; `sudo startxfce` makes *this* root,
# so XFCE, its settings and every file it writes would land in /root.
# Once root-only work is done (splash, ingot installs), become that account:
# read /etc/copper-firstboot.done the way copper-init does (first line only,
# and only if it names a real account). No marker means first boot: stay root.
# COPPER_USER names the account explicitly; COPPER_USER=root keeps a root
# desktop on purpose.
if [ "$(id -u)" = 0 ]; then
    _as=${COPPER_USER:-}
    if [ -z "$_as" ] && [ -r "${COPPER_USER_MARKER:-/etc/copper-firstboot.done}" ]; then
        _as=$(head -n1 "${COPPER_USER_MARKER:-/etc/copper-firstboot.done}" 2>/dev/null)
        # Strip whitespace: the marker's first line must be a plain login name.
        _as=$(printf '%s' "$_as" | tr -d '[:space:]')
    fi
    if [ -n "$_as" ] && [ "$_as" != root ] && id "$_as" >/dev/null 2>&1; then
        _sudo=$(command -v sudo 2>/dev/null) || _sudo=
        if [ -n "$_sudo" ]; then
            # Resolve $0 through PATH so sudo re-runs this script, not a relative-path guess.
            _self=$(command -v "$0" 2>/dev/null) || _self=$0
            [ -n "$_self" ] || _self=$0
            say "starting the desktop as $_as, not as root"
            say "  root's HOME is /root; a desktop running as root puts"
            say "  every setting it writes there instead of in $_as's"
            say "  COPPER_USER=root starts it as root anyway"
            COPPER_SESSION_AS=$_as exec "$_sudo" -u "$_as" -H -- "$_self" "$@"
        else
            say "this desktop is root's: no sudo to become $_as with"
        fi
    fi
fi

# Apply the choice after any sudo hand-off, so it belongs to the session's owner.
choose_xfce_theme

disp_state=$(display_state)
if [ "$disp_state" = live ]; then
    say "an X server is already on :$DISPLAY_NUM, using it"
else
    if [ "$have_xorg" != 1 ]; then
        say "cannot start XFCE: there is no X server at $XORG"
        exit 20
    fi

    say "starting $XORG on :$DISPLAY_NUM, log in $XLOG"
    # Clear the socket only on known death (no socket or refused connection);
    # "unknown" may be a starting or forbidden server -- leave its socket alone.
    case "$disp_state" in
        dead)
            # Some servers refuse to bind over an existing stale socket.
            if [ -S "$XSOCKDIR/X$DISPLAY_NUM" ] && [ -w "$XSOCKDIR" ]; then
                rm -f "$XSOCKDIR/X$DISPLAY_NUM" 2>/dev/null
            fi
            ;;
        unknown)
            say "a socket exists on :$DISPLAY_NUM but the display did not answer;"
            say "  leaving it in place in case a server is still starting."
            ;;
    esac

    # No udev here: evdev opens event nodes with plain ioctls, but libinput
    # builds its device view from udev and says "udev device never initialized";
    # sysfs names decide which node is keyboard and which is pointer.
    # Declare both as core devices, or X treats them as additions and closes
    # them while hunting for core devices itself. AutoAddDevices off keeps it
    # from going down the same nonexistent udev path on hotplug.
    # The config is written even with nothing found: it pins AutoAddDevices
    # off and makes "found nothing" a visible file, not a missing one.
    xorgconf=${COPPER_XORGCONF:-/etc/X11/xorg.conf}
    sysinput=${COPPER_SYSINPUT:-/sys/class/input}
    kb=
    pt=
    pt_ps2=
    for e in "$sysinput"/event*; do
        [ -e "$e" ] || continue
        n=${e##*/}
        name=$(cat "$e/device/name" 2>/dev/null) || name=
        case "$name" in
            *Keyboard*|*keyboard*|*kbd*|*AT\ Translated*) kb=$n ;;
            *ImPS/2*|*ImExPS*|*Explorer*|*PS/2*)          [ -z "$pt_ps2" ] && pt_ps2=$n ;;
            *Mouse*|*mouse*)                              [ -z "$pt" ] && pt=$n ;;
        esac
    done
    # The pointer is chosen by how VMware feeds virtual mice, measured with a
    # blocking read: ImPS/2/Explorer/*PS/2* is the emulated PS/2 mouse (always
    # fed), while "VMware Virtual USB Mouse" is an absolute tablet whose vmmouse
    # driver was retired in 2018 and used to win by sysfs sort order.
    # Prefer the PS/2-named device, then the first plain mouse; first match wins.
    # Sorting in sysfs is not a reliable tie-breaker, so names decide.
    pt=${pt_ps2:-$pt}
    # Always write a config, even empty: it pins AutoAddDevices off and makes
    # "found nothing" a file rather than a missing file that looks like a bug.
    # /etc/X11 is root-owned while the login that starts a desktop is not, so
    # try the requested path, fall back to $COPPER_XORGCONF_FALLBACK (/tmp by
    # default), say which won, and pass it explicitly with -config.
    # Probe writability in a SUBSHELL. `: > file` runs the `:` special builtin,
    # and POSIX makes a non-interactive shell exit when its redirection fails;
    # a plain `{ : > "$cand"; }` killed the launcher at the first unwritable
    # candidate (bug 42/44, seen as "can't create /etc/X11/xorg.conf"), so the
    # fallback was never reached. Hang `2>/dev/null` on the subshell: the
    # builtin's `>` is set up first and fails before its own stderr redirect.
    # The probe that decides writability is a SUBSHELL, and that is not
    # decoration. `: > file` runs the `:` special builtin, and POSIX says a
    # non-interactive shell shall exit when a special builtin's redirection
    # fails -- dash and busybox ash both do. So the obvious test
    #
    #     { : > "$cand" 2>/dev/null; }        # WRONG: aborts the launcher
    #
    # killed the whole script on the first unwritable candidate, and the
    # fallback below it was never reached. `sudo startxfce` (bug 42's drop)
    # runs this as the session user, where /etc/X11 is root's, so every
    # non-root launch died there -- seen on a real boot as
    #
    #     /usr/bin/startxfce: line 487: can't create /etc/X11/xorg.conf: Permission denied
    #
    # with no desktop and no further output (bug 44). The subshell confines
    # the exit to the probe, so a failed candidate costs a status and the
    # loop moves on. `2>/dev/null` hangs on the subshell, not the builtin,
    # because the builtin's own redirects are set up in order -- `>` first,
    # and it fails before `2>/dev/null` is ever applied, which is why the
    # error was leaking to the console too.
    # A private mktemp file is safe to hand to Xorg: a fixed /tmp/xorg.conf
    # could be a symlink planted by another user. When an explicit fallback is
    # supplied (the gates do), honour it exactly as before.
    fallback_made=
    if [ -n "${COPPER_XORGCONF_FALLBACK:-}" ]; then
        xorgconf2=$COPPER_XORGCONF_FALLBACK
    else
        xorgconf2=$(mktemp "${TMPDIR:-/tmp}/copper-xorg-conf.XXXXXX") || exit 1
        fallback_made=1
    fi
    cfg=
    for cand in "$xorgconf" "$xorgconf2"; do
        if mkdir -p "${cand%/*}" 2>/dev/null && ( : > "$cand" ) 2>/dev/null; then
            cfg=$cand
            break
        fi
    done
    if [ "$cfg" != "$xorgconf2" ] && [ -n "$fallback_made" ]; then
        rm -f "$xorgconf2"
    fi
    if [ -n "$cfg" ]; then
        {
            echo 'Section "ServerFlags"'
            echo '    Option "AutoAddDevices"    "false"'
            echo '    Option "AutoEnableDevices" "false"'
            echo 'EndSection'
            if [ -n "$kb" ]; then
                echo ''
                echo 'Section "InputDevice"'
                echo '    Identifier  "Keyboard0"'
                echo '    Driver      "evdev"'
                printf '    Option      "Device"       "/dev/input/%s"\n' "$kb"
                echo '    Option      "CoreKeyboard" "on"'
                echo 'EndSection'
            fi
            if [ -n "$pt" ]; then
                echo ''
                echo 'Section "InputDevice"'
                echo '    Identifier  "Pointer0"'
                echo '    Driver      "evdev"'
                printf '    Option      "Device"       "/dev/input/%s"\n' "$pt"
                echo '    Option      "CorePointer"  "on"'
                echo 'EndSection'
            fi
            echo ''
            echo 'Section "ServerLayout"'
            echo '    Identifier "Default"'
            [ -n "$kb" ] && echo '    InputDevice "Keyboard0"'
            [ -n "$pt" ] && echo '    InputDevice "Pointer0"'
            echo 'EndSection'
        } > "$cfg"
        say "input config written: $cfg"
    else
        say "no writable xorg.conf path; X will hunt its own input (no udev here)"
    fi
    say "input devices: keyboard=${kb:-none} pointer=${pt:-none}"

    # Module paths differ by distro: pass -modulepath only when evdev is really
    # in that directory, otherwise keep the server's compiled-in default.
    modpath=
    for d in /usr/lib/x86_64-linux-gnu/xorg/modules /usr/lib/xorg/modules; do
        if [ -e "$d/input/evdev_drv.so" ]; then
            modpath=$d
            break
        fi
    done

    # Non-root cannot grab the console VT: VT_ACTIVATE needs CAP_SYS_TTY_CONFIG,
    # so xf86OpenConsole() dies with "Switching VT failed" at startup.
    # -sharevts sets ShareVTs and skips that switch (the active VT is adopted via
    # VT_GETSTATE); -novtswitch is NOT enough -- it only suppresses reset-time
    # switches, and a real boot with -keeptty -novtswitch still died here.
    # -keeptty keeps the server from setsid()ing away from the controlling tty
    # it needs to open that shared VT. These flags are only for non-root; the
    # root path already has the permission and is left exactly as it was.
    # The quoted block below is xf86OpenConsole()'s actual guard, kept as the
    # reason -sharevts, not -novtswitch, is the fix for the non-root launch.
    xflags=
    if [ "$(id -u)" != 0 ]; then
        xflags="-keeptty -sharevts -novtswitch"
    fi

    # -noreset keeps the server from resetting (and closing every input device)
    # when the last client disconnects, which would leave the next login dead.
    if [ -n "$modpath" ]; then
        "$XORG" ":$DISPLAY_NUM" -noreset $xflags -modulepath "$modpath" \
            ${cfg:+-config "$cfg"} > "$XLOG" 2>&1 &
    else
        "$XORG" ":$DISPLAY_NUM" -noreset $xflags \
            ${cfg:+-config "$cfg"} > "$XLOG" 2>&1 &
    fi
    xpid=$!

    # Bounded socket wait, with a process check: "still starting" and "already
    # died" look identical if all you do is count to a limit.
    i=0
    while [ "$i" -lt "$WAIT_TRIES" ]; do
        if [ "$(display_state)" = live ]; then
            break
        fi
        if ! kill -0 "$xpid" 2>/dev/null; then
            say "the X server exited while starting up. Its log says:"
            sed 's/^/  /' "$XLOG" 2>/dev/null
            exit 23
        fi
        i=$((i + 1))
        sleep 0.1 2>/dev/null || sleep 1
    done

    if [ "$(display_state)" != live ]; then
        say "the X server is running but never opened :$DISPLAY_NUM."
        say "its log says:"
        sed 's/^/  /' "$XLOG" 2>/dev/null
        exit 22
    fi
    say "X server is up on :$DISPLAY_NUM"
fi

# /dev/shm: shm_open() puts files here, and devtmpfs does not make the
# directory itself (a normal init mounts tmpfs on it), so create it.
# Both are directories only; plain files on devtmpfs are fine for shm.
# XDG runtime dir: the session bus and settings daemons want a private 0700
# directory, but nothing here logs in through pam, so /run/user was never
# made. Create it when possible; both steps are best effort, since a test
# run may have no /run to write to and a missing runtime dir is only a
# warning inside the session, not a reason to refuse to start it.
mkdir -p /dev/shm 2>/dev/null || :
uid=$(id -u 2>/dev/null) || uid=
if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -n "$uid" ]; then
    if mkdir -p "/run/user/$uid" 2>/dev/null &&
       chmod 700 "/run/user/$uid" 2>/dev/null; then
        XDG_RUNTIME_DIR=/run/user/$uid
        export XDG_RUNTIME_DIR
    fi
fi

# No maintainer scripts run here, so build missing font and pixbuf caches
# once; without them glyph lookup is slow and icons never load. Keep quiet:
# cache builders print progress nobody asking for a desktop wants.
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

# exec makes XFCE this process, so its exit status is ours and there is one
# process between the keystrokes and the desktop.
# Session output goes to $SESSIONLOG: the X server owns the console VT, so
# anything printed there is invisible to the user looking at the screen --
# exactly when a diagnosis is needed. Redirecting costs no process and
# does not change the exit status. The log is the only evidence when the
# screen is the broken thing.
DISPLAY=":$DISPLAY_NUM"
export DISPLAY
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

# Audio is a per-user daemon (PulseAudio refuses root without --system), so
# start it once here before the desktop; COPPER_AUDIO=0 lets the gate avoid
# launching a daemon on the machine running the tests.
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
say "starting XFCE on $DISPLAY"
say "session output goes to $SESSIONLOG"
exec "$STARTXFCE4" "$@" >"$SESSIONLOG" 2>&1
