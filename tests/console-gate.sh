#!/usr/bin/env bash
# Gate for the console session's environment: the prompt names the user, and
# the shell knows what terminal it is on.
#
# Why this exists
# ---------------
# Two defects shipped together on the live console and neither had a test.
#
#   1. The prompt was the literal `copper:\w\$ `, so every login -- root's
#      included -- looked like the machine with no user on it. The wizard has
#      always made a real account and copper-init has always dropped the shell
#      to it; only the prompt kept the fact to itself.
#
#   2. Nothing set TERM. Bash invents TERM=dumb when it finds none, and
#      readline then redraws a dumb terminal: it does not know the right
#      margin auto-wraps, so a command long enough to reach the edge loses the
#      character that should have started the next line, and `clear` cannot
#      repaint the prompt until another Enter. On the console the tell was
#      `wget -qO-` reaching the shell as `wget -q-`.
#
# Both live in startup files no other gate read, so this one reads them. The
# TERM check is not a grep: it extracts the real block from each file and runs
# it against a stubbed tty(1), so the "only upgrade a virtual console" rule is
# exercised rather than asserted in a comment.
#
# Run: bash tests/console-gate.sh   (no root, no network)

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
PROFILE="$REPO/iso/rootfs-overlay/etc/profile"
BASHRC="$REPO/iso/rootfs-overlay/etc/bash.bashrc"
SKEL="$REPO/iso/rootfs-overlay/etc/skel/.bashrc"
INIT="$REPO/iso/src-init/copper-init.c"
BUILD="$REPO/iso/build.sh"

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }

for f in "$PROFILE" "$BASHRC" "$SKEL" "$INIT" "$BUILD"; do
    [ -f "$f" ] || { bad "$(basename "$f") is missing" "$f"; exit 1; }
done

# prompt_in <file> -> the PS1='' value, comments ignored.
prompt_in() {
    sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}PS1='\(.*\)'[[:space:]]*$/\2/p" \
        "$1" | head -1
}

# ---- the prompt shows the account ------------------------------------------
for f in "$PROFILE" "$BASHRC"; do
    p=$(prompt_in "$f")
    if [ "$p" = '\u@\h:\w\$ ' ]; then
        ok "$(basename "$f") sets PS1 to user@host:path"
    else
        bad "$(basename "$f") sets the wrong PS1" "got '$p', want '\\u@\\h:\\w\\$ '"
    fi
done

# A literal is not enough: a real Bash has to expand it to something with a
# user, a host and a colon. PS1 is assigned inside the shell because Bash does
# not import PS1 from the environment. The trailing prompt character is Bash's
# own \$-or-# logic -- '#' for root, '$' for everyone else -- so the pattern
# has to take both; this gate runs under sudo, where the prompt is root's.
p=$(prompt_in "$BASHRC")
expanded=$(bash -c 'PS1=$1; printf "%s" "${PS1@P}"' _ "$p" 2>/dev/null || true)
if printf '%s' "$expanded" | grep -Eq '^[^@[:space:]]+@[^:[:space:]]+:.*[$#] $'; then
    ok "Bash expands the prompt to user@host:path (\"$expanded\")"
else
    bad "Bash does not expand the prompt to user@host:path" "got '$expanded'"
fi

# skel/.bashrc is what a new home gets; it must keep pointing at the system
# file, or the prompt fix would stop at the account the wizard just made.
if grep -q '/etc/bash.bashrc' "$SKEL"; then
    ok "the skel .bashrc still sources the system Bash settings"
else
    bad "skel/.bashrc no longer sources /etc/bash.bashrc"
fi

# ---- TERM: upgrade bash's invented "dumb" only on a real VT ----------------
# Extract the real block from the file: from the `case "${TERM:-dumb}"` line
# through `export TERM`. Running that text is the point; a grep would pass on
# any block that mentions the right words.
term_block() {
    awk 'index($0, "case \"${TERM:-dumb}\" in") == 1 { on = 1 }
         on { print }
         on && $0 == "export TERM" { exit }' "$1"
}

# term_probe <file> <starting TERM> <fake tty(1) output> -> resulting TERM
term_probe() {
    block=$(term_block "$1")
    [ -n "$block" ] || return 1
    TERM=$2 TTYDEV=$3 bash -c '
        tty() { printf "%s\n" "$TTYDEV"; }
        eval "$1"
        printf "%s" "${TERM-<unset>}"
    ' _ "$block"
}

for f in "$PROFILE" "$BASHRC"; do
    name=$(basename "$f")
    [ -n "$(term_block "$f")" ] \
        && ok "$name has a TERM fallback block" \
        || bad "$name has no TERM fallback block" "readline stays on a dumb terminal"

    got=$(term_probe "$f" dumb /dev/tty1 || true)
    [ "$got" = linux ] \
        && ok "$name upgrades TERM=dumb to linux on /dev/tty1" \
        || bad "$name does not upgrade TERM=dumb on a VT" "got '$got'"

    got=$(term_probe "$f" dumb /dev/console || true)
    [ "$got" = linux ] \
        && ok "$name upgrades TERM=dumb to linux on /dev/console" \
        || bad "$name does not upgrade TERM=dumb on /dev/console" "got '$got'"

    got=$(term_probe "$f" dumb /dev/pts/3 || true)
    [ "$got" = dumb ] \
        && ok "$name leaves a pty that says dumb alone" \
        || bad "$name rewrites TERM on a pty" "got '$got'"

    got=$(term_probe "$f" xterm-256color /dev/tty1 || true)
    [ "$got" = xterm-256color ] \
        && ok "$name keeps an inherited TERM" \
        || bad "$name overwrites an inherited TERM" "got '$got'"
done

# ---- readline keeps the console's width current ----------------------------
if grep -q 'shopt -s checkwinsize' "$BASHRC"; then
    ok "bash.bashrc keeps readline's idea of the screen size current"
else
    bad "bash.bashrc does not enable checkwinsize" \
        "a resize or a font change can leave the right margin wrong"
fi

# ---- copper-init sets it before anything can spawn a shell -----------------
term_line=$(grep -n 'getenv("TERM")' "$INIT" | head -1 | cut -d: -f1)
dumb_line=$(grep -n 'strcmp(term, "dumb")' "$INIT" | head -1 | cut -d: -f1)
set_line=$(grep -n 'setenv("TERM", "linux", 1)' "$INIT" | head -1 | cut -d: -f1)
spawn_line=$(grep -n 'spawn_tty(1)' "$INIT" | head -1 | cut -d: -f1)
if [ -n "$term_line" ] && [ -n "$dumb_line" ] && [ -n "$set_line" ] \
   && [ -n "$spawn_line" ] && [ "$term_line" -lt "$spawn_line" ]; then
    ok "copper-init fixes TERM (dumb included) before it spawns the shell"
else
    bad "copper-init does not set TERM before spawning the shell" \
        "term ${term_line:-?}, dumb ${dumb_line:-?}, set ${set_line:-?}, spawn ${spawn_line:-?}"
fi

# ---- the applets the startup files reach for are in busybox ----------------
for sym in CLEAR TTY; do
    if grep -q "set_bb_config $sym" "$BUILD"; then
        ok "build.sh enables CONFIG_$sym"
    else
        bad "build.sh does not enable CONFIG_$sym" "the applet may not exist in the image"
    fi
done
if grep -q 'SETFONT CLEAR TTY' "$BUILD"; then
    ok "build.sh asserts the clear and tty applets are really configured"
else
    bad "build.sh does not assert CLEAR and TTY" "require_bb_config can drift"
fi

# terminfo is what turns TERM=linux into the capabilities readline and every
# full-screen tool actually use. ncurses-base owns /usr/share/terminfo/l/linux;
# it is Essential on paper, and that is exactly why apt's empty-status closure
# never downloaded it -- the image would ship bash and nano with no entries.
if grep -q '\bncurses-base\b' "$BUILD"; then
    ok "build.sh stages ncurses-base (the linux terminfo entry)"
else
    bad "build.sh does not stage ncurses-base" \
        "nano, less and readline have no terminal capabilities"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "console-gate: all checks passed"
    exit 0
fi
echo "console-gate: $fails check(s) FAILED"
exit 1
