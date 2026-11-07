# Copper's system-wide Bash settings.
case $- in
    *i*) ;;
    *) return ;;
esac

# The live console is a Linux VT, and nothing else in the image sets TERM.
# Bash invents "dumb" when it finds none, and dumb-terminal redisplay is what
# loses the character at the right margin and leaves `clear` unable to repaint
# the prompt until another Enter. `linux` is the terminfo name for the VT.
# Upgrade only a real virtual console: a terminal emulator or a serial login
# brings its own TERM, and a pty that says "dumb" on purpose is left alone.
case "${TERM:-dumb}" in
    dumb)
        case "$(tty 2>/dev/null)" in
            /dev/tty[0-9]*|/dev/console) TERM=linux ;;
        esac
        ;;
esac
export TERM

HISTCONTROL=ignoredups:erasedups
HISTSIZE=1000
HISTFILESIZE=2000
export HISTCONTROL HISTSIZE HISTFILESIZE

# Re-read the console's size after each command, so readline's idea of the
# right margin cannot drift from the VT's.
shopt -s checkwinsize

# Who and where. The shell runs as the wizard's user; the old literal prompt
# only showed the machine.
PS1='\u@\h:\w\$ '
