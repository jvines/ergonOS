#!/usr/bin/env bash
# Link the desktop into $HOME.
#
# ergonOS owns the desktop and the science tooling; your shell, editor and
# per-fleet configuration are a separate concern and a separate repo. This only
# touches what the OS is responsible for, so it can sit underneath any dotfiles
# without fighting them.
#
#   ./install.sh            link everything
#   ./install.sh --check    say what would change, touch nothing
set -euo pipefail

ERGON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOST="$(hostname -s)"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1

ok()   { printf '   ok  %s\n' "$*"; }
skip() { printf '   ·   %s\n' "$*"; }
warn() { printf '   !!  %s\n' "$*" >&2; }

# host.env says what this machine IS -- GRAPHICAL, PROFILE, BUNDLES. Read it
# before deciding anything, rather than probing the environment: the graphical
# branch used to key on WAYLAND_DISPLAY, so a machine configured itself
# differently depending on whether a human or cron invoked this.
HOSTENV="$ERGON/hosts/$HOST/host.env"
GRAPHICAL=0
# shellcheck disable=SC1090
[ -f "$HOSTENV" ] && . "$HOSTENV"

link() {  # link <repo path> <path under $HOME>
  local src="$ERGON/$1" dst="$HOME/$2"
  [ -e "$src" ] || { warn "missing in the repo: $1"; return; }
  if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
    return
  fi
  if [ "$CHECK" = 1 ]; then
    printf '   would link  %s -> %s\n' "$2" "$1"; return
  fi
  mkdir -p "$(dirname "$dst")"
  # A real directory in the way is the user's, not ours to delete.
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    warn "$2 exists and is not a symlink — leaving it alone"; return
  fi
  ln -sfn "$src" "$dst"
  ok "$2 -> $1"
}

if [ "${GRAPHICAL:-0}" != 1 ]; then
  skip "GRAPHICAL is not 1 in $HOSTENV — desktop not linked"
else
  # The whole directory, not a file: Hyprland's Lua `require` resolves relative
  # to hyprland.lua, so a single-file symlink breaks every include.
  link hypr   .config/hypr
  link waybar .config/waybar
  link mako   .config/mako
  link fuzzel .config/fuzzel
  link wezterm .config/wezterm
  link gtk/settings.ini .config/gtk-3.0/settings.ini
  link gtk/settings.ini .config/gtk-4.0/settings.ini
  [ -f "$ERGON/hosts/$HOST/hyprland.lua" ] && link "hosts/$HOST/hyprland.lua" ".config/hypr/hosts/$HOST.lua"

  # PATH for the systemd user manager, which is what launches the session under
  # uwsm. Without it every ergon-* in the bar and the keybinds is not found:
  # the module fires, the command is missing, and nothing surfaces it.
  link environment.d/10-ergon-path.conf .config/environment.d/10-ergon-path.conf

  if [ "$CHECK" != 1 ]; then
    mkdir -p "$HOME/.config/systemd/user"
    cp "$ERGON/systemd/ergon-reap.service" "$ERGON/systemd/ergon-reap.timer" \
       "$HOME/.config/systemd/user/" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    # Enabling is a symlink; doing it directly needs no session bus, which a
    # machine being set up from a TTY does not have.
    mkdir -p "$HOME/.config/systemd/user/timers.target.wants"
    ln -sfn ../ergon-reap.timer "$HOME/.config/systemd/user/timers.target.wants/ergon-reap.timer"
    systemctl --user start ergon-reap.timer >/dev/null 2>&1 || true
    ok "ergon-reap.timer enabled"
  fi
fi

link matplotlib/matplotlibrc .config/matplotlib/matplotlibrc

# Agent knowledge. This OS ships two coding agents, and one SKILL.md serves
# both: Claude Code reads ~/.claude/skills, Codex reads $CODEX_HOME/skills
# (~/.codex/skills when CODEX_HOME is unset). Both want a directory per skill
# whose SKILL.md opens with YAML frontmatter carrying name and description.
# Codex also allows license, allowed-tools and metadata; ours use only the two
# every harness accepts, so there is one file and nothing to keep in sync.
#
# Namespaced ergon-*, so nothing the user wrote is shadowed. Symlinked rather
# than copied, so updating the repo updates the skill.
if [ "$CHECK" != 1 ]; then
  n=0
  for dest in "$HOME/.claude/skills" "${CODEX_HOME:-$HOME/.codex}/skills"; do
    mkdir -p "$dest" || continue
    for s in "$ERGON"/skills/ergon-*; do
      [ -d "$s" ] || continue
      ln -sfn "$s" "$dest/$(basename "$s")" && n=$((n+1))
    done
  done
  ok "$n agent skills linked, for Claude Code and Codex (see: ergon explain --list)"
fi

if [ "$CHECK" != 1 ]; then
  "$ERGON/bin/pyfleet" ensure || warn "the base python did not build"
  if ! "$ERGON/bin/ergon-theme" --check >/dev/null 2>&1; then
    warn "themed configs are stale — run: ergon theme"
  fi
fi

printf '\n   %s on PATH?  ' "$ERGON/bin"
case ":$PATH:" in
  *":$ERGON/bin:"*) printf 'yes\n' ;;
  *) printf 'NO — add it:\n       export PATH="%s/bin:$PATH"\n' "$ERGON" ;;
esac
