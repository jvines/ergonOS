# Interactive shell configuration for Ergon.
#
# Sourced from zsh/zshrc. Everything here is generic: there is deliberately
# nothing about any particular machine, network or account in this file, so it
# can be read by anyone installing this OS. Per-machine and private
# configuration belongs in your own dotfiles, which this is designed to sit
# underneath — see the tail of zsh/zshrc.

# ---------- oh-my-zsh ----------
# Guarded. Unguarded, a machine where it is not installed prints
#   common.zsh:source:N: no such file or directory: ~/.oh-my-zsh/oh-my-zsh.sh
# on EVERY shell start, including non-interactive `ssh host command`, where an
# unexpected line on stdout is not cosmetic — it corrupts whatever is parsing
# the output.
export ZSH="${ZSH:-$HOME/.oh-my-zsh}"
ZSH_THEME=""            # the prompt comes from pure, below
plugins=(git)
[ -f "$ZSH/oh-my-zsh.sh" ] && source "$ZSH/oh-my-zsh.sh"

# ---------- zplug ----------
export ZPLUG_HOME="${ZPLUG_HOME:-$HOME/.zplug}"
if [ -f "$ZPLUG_HOME/init.zsh" ]; then
  # zplug is loaded with the repo's bin/ off PATH, and this is load-bearing
  # rather than tidiness.
  #
  # zplug JSON-escapes every log line with `python` whenever one is on PATH, and
  # feeds that python's stderr straight back into its own error logger — which
  # escapes the message with python again (base/utils/shell.zsh, json_escape).
  # A python that writes ANYTHING to stderr at startup therefore recurses, each
  # round in a detached process substitution. A venv with a broken .pth file was
  # enough: every new shell forked ~2000 processes and took over a minute to
  # reach a prompt.
  #
  # bin/ is swapped for a path that does not exist rather than removed, and
  # swapped back after `zplug load`. zplug makes PATH unique and prepends its
  # own bin while loading, so a saved copy would be stale by then; the
  # placeholder holds the slot and PATH comes out exactly as it went in.
  _zplug_bin="${ERGON:-$HOME/ergonOS}/bin"
  _zplug_hidden="$_zplug_bin/.hidden-from-zplug"
  path=("${(@)path/#%${(b)_zplug_bin}/$_zplug_hidden}")

  source "$ZPLUG_HOME/init.zsh"
  zplug "mafredri/zsh-async", from:github
  # on: rather than declaring these as two independent plugins. pure needs
  # zsh-async loaded first; left implicit, zplug infers the dependency and
  # prints
  #   [zplug] WARNING: pipe syntax is deprecated! Please use 'on' tag instead.
  # on EVERY shell start -- three times over, including every non-interactive
  # `ssh host command`, where unexpected stdout corrupts whatever is parsing it.
  zplug "sindresorhus/pure", use:pure.zsh, from:github, as:theme, on:"mafredri/zsh-async"
  # zdharma-continuum, NOT zdharma: the original org was removed from GitHub in
  # 2021 and the old path fails to install on any fresh machine.
  zplug "zdharma-continuum/fast-syntax-highlighting", as:plugin, defer:2
  zplug "zsh-users/zsh-autosuggestions", as:plugin, defer:2

  # Only ever prompt in an INTERACTIVE shell. A missing plugin otherwise makes
  # zplug ask a question at a non-interactive ssh command, which then hangs
  # forever waiting for an answer nobody is there to give.
  if [[ -o interactive ]] && ! zplug check; then
    printf "Install missing zsh plugins? [y/N]: "
    if read -q; then echo; zplug install; fi
  fi
  zplug load

  path=("${(@)path/#%${(b)_zplug_hidden}/$_zplug_bin}")
  unset _zplug_bin _zplug_hidden
fi

# ---------- history ----------
setopt EXTENDED_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS SHARE_HISTORY

# ---------- no bell ----------
# zsh rings the terminal bell for any key the line editor cannot parse, and
# under tmux's mouse mode that includes stray mouse escape sequences — so a
# click landing somewhere the editor does not expect produces an audible beep.
# Under a terminal handling the mouse natively while tmux also reports it, this
# is constant.
#
# The bell carries no information here: nothing in this setup signals with it,
# and it only fires on input being discarded anyway.
unsetopt BEEP HIST_BEEP LIST_BEEP

# ---------- aliases ----------
alias e="${EDITOR:-emacs}"
alias ls='ls -lh --color=auto'
alias ll="ls -al"
alias ldir="ls -al | grep ^d"
alias clr="clear"
alias h="history"
alias ut="uptime"
alias grep="grep --color=auto"
alias df="df -h"
alias du="du -h"
alias ports="lsof -i -P -n"
alias o="xdg-open ."

# Copy stdin to the LOCAL clipboard through the terminal itself (OSC 52), which
# means it works over ssh — the bytes travel in the escape sequence rather than
# needing a clipboard daemon on the far end.
rcopy() { printf "\033]52;c;%s\a" "$(base64)"; }

# ---------- attach to tmux on inbound ssh ----------
# One persistent session named "main", attach-or-create in a single step.
#
# No clone-per-connection. That scheme relies on destroy-unattached cleaning up
# after itself, and that option does not apply the way it looks like it does:
# chaining `new-session -t main \; set-option destroy-unattached on` sets it
# against the client's CURRENT session, which is not reliably the clone just
# created. So no clone is ever destroyed, and they accumulate indefinitely —
# observed reaching twenty-two, with the oldest weeks old. The clones existed
# only so two terminals would not fight over the current window, which is a far
# smaller problem than an unbounded pile of sessions.
if [[ -o interactive && -t 0 && -n "$SSH_CONNECTION" && -z "$TMUX" ]]; then
  command -v tmux >/dev/null && exec tmux new-session -A -s main
fi

# ---------- Home / End ----------
# Bound explicitly rather than from terminfo, because terminfo is TERM-dependent
#   xterm-256color -> \EOH        tmux-256color -> \E[1~
# while a terminal's own key mapping usually sends ONE form regardless of what
# is running inside it. Outside tmux it matches and the keys work; inside tmux
# zsh has only the other form bound, the sequence lands unbound, and the
# keystroke silently does nothing. The mismatch travels with the keystroke, not
# with the machine.
#
# Binding every encoding costs nothing and holds in tmux, over ssh and under any
# TERM.
bindkey '^[[1~' beginning-of-line   # tmux/screen
bindkey '^[[4~' end-of-line
bindkey '^[OH'  beginning-of-line   # xterm application mode
bindkey '^[OF'  end-of-line
bindkey '^[[H'  beginning-of-line   # xterm normal cursor mode
bindkey '^[[F'  end-of-line

# ---------- reload ----------
# Re-source into a LIVE shell, so a config change reaches sessions already open
# without losing history or the working directory.
refresh() {
  source "${ERGON:-$HOME/ergonOS}/zsh/zshrc"
  print "reloaded from ${ERGON:-$HOME/ergonOS}"
}
