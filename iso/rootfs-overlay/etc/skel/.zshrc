# Copper's per-user Zsh startup file.
#
# zsh does not read /etc/bash.bashrc, so the pieces a Copper shell needs are
# repeated here rather than sourced from Bash. Keep this file small: the
# system-wide defaults live in /etc/zsh/ and /etc/profile.

# The same PATH /etc/profile exports, so an interactive zsh is not a shell
# with a different set of commands depending on which one the user chose.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.opencode/bin:$HOME/.local/bin:$HOME/bin

# The live console is a Linux VT; nothing else sets TERM for a zsh that did
# not come through /etc/profile. Upgrade only a real virtual console.
case "${TERM:-dumb}" in
    dumb)
        case "$(tty 2>/dev/null)" in
            /dev/tty[0-9]*|/dev/console) TERM=linux ;;
        esac
        ;;
esac
export TERM

HISTFILE=$HOME/.zsh_history
HISTSIZE=1000
SAVEHIST=2000
setopt hist_ignore_dups share_history

# Who and where, matching the Bash prompt Copper ships.
PROMPT='%n@%m:%~%# '
