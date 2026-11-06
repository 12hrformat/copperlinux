# Copper's system-wide Bash settings.
case $- in
    *i*) ;;
    *) return ;;
esac

HISTCONTROL=ignoredups:erasedups
HISTSIZE=1000
HISTFILESIZE=2000
export HISTCONTROL HISTSIZE HISTFILESIZE

PS1='copper:\w\$ '
