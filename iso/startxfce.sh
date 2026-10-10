#!/bin/sh
# startxfce -- start the X server, then XFCE on it.
#
# The desktop lives in the image: Xorg and XFCE (thunar, xfce4-terminal) are
# baked by the gui stage. The apps on top -- firefox, mousepad, ristretto,
# xfce4-taskmanager, xarchiver -- are ingot packages, and before anything
# starts this asks whether to install the missing ones (manifest at
# /etc/copper/xfce-apps). What is genuinely absent still gets its own exit
# code and its own sentence naming the piece, instead of a bare "not found"
# that is indistinguishable from a broken PATH or missing library.
#
# POSIX sh, not bash: the image's shell is busybox ash, and build.sh checks these
# scripts against /bin/sh. A bashism here is a script that works on the build
# host and fails on the machine.
#
# Exit codes, which are a contract rather than decoration:
#
#   0   startxfce4 ran and exited cleanly
#   20  no X server in the image
#   21  XFCE is not in the image
#   22  the X server started but never opened its display socket
#   23  the X server exited while starting up
#   24  usage error
#   25  a component is missing but there is no terminal to ask on, and
#       neither --yes nor --no was given, so nothing was decided
#
# The X server's log goes to $COPPER_XLOG, else /tmp/xorg.log. When this fails
# there is nothing on the screen to read, so the log is the only evidence.
#
# KNOWN LIMITS. None of these can be observed until the X server is in the
# image, so they are recorded here rather than left to be found on a machine
# that has it.
#
#   - Only DISPLAY_NUM is ever examined. If Xorg declines :0 because something
#     else holds it and silently takes :1, the wait below expires and reports
#     "never opened the display" about a server that is working. Learning which
#     display the server chose means parsing its log or querying it, and POSIX
#     sh can do neither.
#   - Once xdpyinfo exists, the wait loop runs it every iteration, so a slow
#     probe multiplies the timeout by its own runtime. Harmless now -- with no
#     probe the loop only stats a socket -- and worth tightening when it lands.
#   - The timeout is 10s where sleep accepts fractions and 100s where it does
#     not, because of the fallback in the wait loop. Same image, a tenfold
#     difference in how long a failure appears to hang.

set -u

XORG=${COPPER_XORG:-/usr/bin/Xorg}
STARTXFCE4=${COPPER_STARTXFCE4:-/usr/bin/startxfce4}
XLOG=${COPPER_XLOG:-/tmp/xorg.log}
SESSIONLOG=${COPPER_SESSIONLOG:-/tmp/session.log}
XSOCKDIR=${XSOCKDIR:-/tmp/.X11-unix}
DISPLAY_NUM=${DISPLAY_NUM:-0}
WAIT_TRIES=${WAIT_TRIES:-100}

# The component manifest and the installer it drives. startxfce only offers
# components; it does not hardcode which ones.
APPS=${COPPER_XFCE_APPS:-/etc/copper/xfce-apps}
INGOT=${COPPER_INGOT:-ingot}
SUDO=${COPPER_SUDO-sudo}
# Root needs no sudo, and the image may not even have it. "-" (not ":-") so
# an empty COPPER_SUDO really does disable sudo instead of reviving the default.
if [ "$(id -u)" = 0 ]; then SUDO=; fi

say() { printf 'startxfce: %s\n' "$1"; }

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
  COPPER_XLOG        where the X server logs     (default /tmp/xorg.log)
  COPPER_SESSIONLOG  where XFCE's output goes    (default /tmp/session.log)
  COPPER_XPROBE      X client used to check whether a display really
                     answers                         (default /usr/bin/xdpyinfo)
  COPPER_XORGCONF    where the generated input config is written
                     (default /etc/X11/xorg.conf; falls back to /tmp/xorg.conf
                     when the login cannot write there)
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

# What is installed. Echoed as words so --check and the launch path agree, and
# so there is exactly one place that knows what the image contains.
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

# An X server already on this display is reused rather than replaced. Two
# servers on one display is a confusing failure: the second refuses the socket,
# or replaces the first, and the client ends up talking to whichever won.
#
# The socket's existence is not sufficient evidence. /tmp/.X11-unix/X0 is left
# behind by any session that did not exit cleanly, and X does not remove it. A
# startxfce that trusts the file alone reuses a dead display: XFCE starts,
# connects to a server that is gone, and hangs with nothing to report. The file
# records that a display number was once used, not that anything is listening.
#
# So ask the display, when there is something that can ask.
#
# xprobe is ours: a static musl binary that completes the X11 handshake over the
# socket and reads the geometry back, needing nothing but libc. xdpyinfo would do
# the same job but arrives as part of x11-utils, which is another package to
# build and stage before the display can be checked. Either is accepted, and the
# probe found first is the one used; the socket test is the fallback when neither
# is installed, and that fallback is the weaker of the three.
XPROBE=${COPPER_XPROBE:-}
if [ -z "$XPROBE" ]; then
    for cand in /usr/bin/xprobe /usr/bin/xdpyinfo; do
        if [ -x "$cand" ]; then XPROBE=$cand; break; fi
    done
fi

display_live() {
    [ -S "$XSOCKDIR/X$DISPLAY_NUM" ] || return 1
    if [ -n "$XPROBE" ] && [ -x "$XPROBE" ]; then
        DISPLAY=":$DISPLAY_NUM" "$XPROBE" >/dev/null 2>&1 && return 0
        # The socket is there and nothing answers it: a stale socket from a
        # session that did not clean up. Treated as no display, so a fresh
        # server gets a chance to replace it.
        return 1
    fi
    return 0
}

# What is installed decides this before anything else, and independently of
# whether a server is already running. The checks cannot live inside the branch
# that starts a server: a running server is not a desktop, so that path would
# exec startxfce4 without ever asking whether it exists. Xorg up and XFCE absent
# then gives
#
#     sh: /usr/bin/startxfce4: not found
#
# and exit 127, which names no missing piece. That combination is the state of
# the image as soon as anyone starts a server by hand, and the state of every
# machine once the X server lands and XFCE has not.
if [ "$have_xfce" != 1 ]; then
    if [ "$have_xorg" != 1 ]; then
        # Name both paths. "It is not there" leaves the reader guessing where it
        # looked; "it is not at /usr/bin/Xorg" does not.
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

# Components. The desktop is in the image; the apps on top of it are ingot
# packages, and only the missing ones are offered. The list lives in the
# manifest, not here: what is offered, what marks it present, and how it is
# installed change independently of this script. Components whose 'how' is
# "image" are expected in the ISO already -- a missing one is a broken image,
# so it is reported and never turned into an install attempt.
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
        # ingot unpacks .debs but no maintainer script runs, so nothing
        # regenerates the databases the desktop reads. Rebuild them by hand
        # or the new .desktop files never show up and launchers stay dead.
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

if display_live; then
    say "an X server is already on :$DISPLAY_NUM, using it"
else
    if [ "$have_xorg" != 1 ]; then
        say "cannot start XFCE: there is no X server at $XORG"
        exit 20
    fi

    say "starting $XORG on :$DISPLAY_NUM, log in $XLOG"
    # display_live() rejected this socket, so nothing is listening on it. Some
    # servers refuse to bind over a socket file that already exists, so clear
    # it before starting.
    if [ -S "$XSOCKDIR/X$DISPLAY_NUM" ] && [ -w "$XSOCKDIR" ]; then
        rm -f "$XSOCKDIR/X$DISPLAY_NUM" 2>/dev/null
    fi

    # Input devices, and the config that names them.
    #
    # This image has no udev, which decides how the server gets its keyboard
    # and mouse. libinput cannot work here even with a device path handed to
    # it: it builds its view of a device from udev's, and says so ("udev
    # device never initialized"). evdev opens the node and asks the kernel
    # what the device can do with plain ioctls, which needs no daemon -- but
    # neither driver can find the node, so which event node is the keyboard
    # and which is the mouse is answered here, by name, out of sysfs.
    #
    # The config must also declare the two devices the CORE keyboard and
    # pointer. Without that the server treats them as mere additions and goes
    # hunting for core devices itself, which ends with it closing the devices
    # it was just handed while the screen keeps working. AutoAddDevices off
    # goes with it: hotplug would send it down the same udev path that does
    # not exist here.
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
    # The pointer is chosen by how VMware feeds its virtual mice, which was
    # measured with a blocking read on the machine, not guessed:
    #
    #   - ImPS/2 / Explorer / *PS/2* is the emulated PS/2 mouse. VMware feeds
    #     it relative motion on every Linux guest, tools or not.
    #   - The "VMware Virtual USB Mouse" is an absolute-pointer tablet. It is
    #     only fed when the guest speaks the vmmouse protocol, whose X driver
    #     package was retired from Ubuntu in 2018 (xenial) -- so it will never
    #     report here. Sorting later in sysfs, its generic "*mouse" name used
    #     to beat the real mouse under last-match-wins.
    #
    # So the PS/2-named device wins the pointer, and a plain USB "*mouse" is
    # only the answer when no PS/2 device exists. Either way the first match
    # in its class wins, no matter where it sorts in sysfs.
    pt=${pt_ps2:-$pt}
    # The config is written even when nothing was found. An empty config is
    # still load-bearing: it pins AutoAddDevices off so the server does not
    # wander down the udev path that does not exist here, and it makes "I
    # found nothing" a visible file rather than an absent one that looks like
    # a bug in the writing code. And the summary line is printed either way:
    # mouse-dead-on-VMware was diagnosed by reading this exact line, and it
    # simply never printed on a machine where nothing matched.
    #
    # Where it goes needs care. The default /etc/X11/xorg.conf is owned by
    # root, and the login that starts a desktop is not root by design. A
    # config that cannot be written is the same failure as no devices: X
    # runs, draws a cursor, and hunts for input through udev, which is not
    # there. So the write tries the requested path and falls back to /tmp,
    # and says which one won. X is then handed the file explicitly with
    # -config, so it uses what was written instead of hoping the default
    # search path found it.
    cfg=
    for cand in "$xorgconf" /tmp/xorg.conf; do
        if mkdir -p "${cand%/*}" 2>/dev/null && { : > "$cand" 2>/dev/null; }; then
            cfg=$cand
            break
        fi
    done
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

    # Where the drivers live is a packaging detail that differs between
    # distributions, so ask the image instead of assuming: -modulepath is
    # passed only when evdev is actually found in the directory, and the
    # server's own compiled-in default is the answer when it is not.
    modpath=
    for d in /usr/lib/x86_64-linux-gnu/xorg/modules /usr/lib/xorg/modules; do
        if [ -e "$d/input/evdev_drv.so" ]; then
            modpath=$d
            break
        fi
    done

    # -noreset: without it the server resets itself when the last client
    # disconnects, and that reset closes every input device in the process.
    # Any gap with no clients -- between sessions, after a probe -- would
    # leave the next login with no keyboard and no mouse.
    if [ -n "$modpath" ]; then
        "$XORG" ":$DISPLAY_NUM" -noreset -modulepath "$modpath" \
            ${cfg:+-config "$cfg"} > "$XLOG" 2>&1 &
    else
        "$XORG" ":$DISPLAY_NUM" -noreset \
            ${cfg:+-config "$cfg"} > "$XLOG" 2>&1 &
    fi
    xpid=$!

    # Wait for the socket, which is the only thing that can be checked without
    # an X client in the image. Bounded, so a server that starts and then
    # wedges does not leave this hanging forever -- and it checks whether the
    # process is still alive, because "still starting" and "already died" look
    # identical if all you do is count to a limit.
    i=0
    while [ "$i" -lt "$WAIT_TRIES" ]; do
        if display_live; then
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

    if ! display_live; then
        say "the X server is running but never opened :$DISPLAY_NUM."
        say "its log says:"
        sed 's/^/  /' "$XLOG" 2>/dev/null
        exit 22
    fi
    say "X server is up on :$DISPLAY_NUM"
fi

# What the session needs prepared around it. Two directories, neither of
# which exists on this image until something makes them:
#
#   /dev/shm  glibc's shm_open() puts its files here. devtmpfs does not
#             create the directory on its own -- on a normal system the init
#             that mounts tmpfs on top of it makes it -- and without it,
#             shared memory users fall back or fail. It only has to be a
#             directory; the files are plain files on devtmpfs.
#
#   XDG runtime dir  the session bus and the settings daemons expect a
#             private 0700 directory of the user's own. Nothing here has
#             logged in through pam, so /run/user was never made for
#             anybody.
#
# Both are best effort: a test run as oneself may find no /run to write to,
# and a missing runtime directory is a warning inside the session rather
# than a reason not to start it.
mkdir -p /dev/shm 2>/dev/null || :
uid=$(id -u 2>/dev/null) || uid=
if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -n "$uid" ]; then
    if mkdir -p "/run/user/$uid" 2>/dev/null &&
       chmod 700 "/run/user/$uid" 2>/dev/null; then
        XDG_RUNTIME_DIR=/run/user/$uid
        export XDG_RUNTIME_DIR
    fi
fi

# Caches that a package manager's postinst would have built, but no
# maintainer script runs on this image, so they are built here instead --
# once, when absent. Missing they do not stop the session: fonts are looked
# up slowly and repeatedly, and pixbuf loaders are simply never found, which
# is how a desktop ends up drawing boxes where icons should be. Both tools
# are quiet by force: a cache build prints progress that has nothing to say
# to whoever just asked for a desktop.
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

# Hand the display over and become XFCE, so that when XFCE exits this command
# exits with the same status. exec rather than run, so there is one process
# between the user's keystrokes and the desktop rather than two.
#
# The session's output goes to $SESSIONLOG, not to the console. The console
# is the VT the X server just took over -- anything the session prints there
# is invisible to a user looking at the screen, and the screen is exactly the
# thing that is broken when a diagnosis is needed. Inside the X server's VT
# nothing a session says reaches a human; on the log it does. Redirecting
# does not cost a process (it is a file descriptor, not a pipe) and it does
# not touch the exit status.
DISPLAY=":$DISPLAY_NUM"
export DISPLAY
say "starting XFCE on $DISPLAY"
say "session output goes to $SESSIONLOG"
exec "$STARTXFCE4" "$@" >"$SESSIONLOG" 2>&1