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

link() {  # link <repo path> <path under $HOME> [generated]
  local src="$ERGON/$1" dst="$HOME/$2"
  if [ ! -e "$src" ]; then
    # "generated" marks a file that does not exist until the render above has
    # run. Thirteen of the seventeen rendered outputs are linked as part of a
    # whole directory, which always exists, so this guard never sees them; the
    # gtk pair is linked file by file, so on a never-rendered clone --check
    # reported them as "missing in the repo". They are not missing from the
    # repository, they are unrendered, and saying the first about the second
    # sends someone looking for a broken checkout.
    if [ "$CHECK" = 1 ] && [ "${3:-}" = generated ]; then
      printf '   would link  %s -> %s (once rendered)\n' "$2" "$1"; return
    fi
    warn "missing in the repo: $1"; return
  fi
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
  # Render BEFORE linking anything, and treat a failure as fatal.
  #
  # The themed configs are generated and not committed, so a fresh clone has
  # seventeen missing files and link() would happily point $HOME at every one of
  # them. Two of those are not cosmetic:
  #
  #   hypr/common/looknfeel.lua  hyprland.lua requires it WITHOUT a pcall, and a
  #                              Lua config is a single chunk -- so the requires
  #                              after it never run. No keybinds, no autostart,
  #                              no waybar, no notifications. Not an unthemed
  #                              desktop: no desktop.
  #   hypr/hyprlock.conf         hyprlock exits 1 before drawing anything, and
  #                              hypridle's lock_cmd does not check that, so the
  #                              machine silently stops locking.
  #
  # Both were measured against the real binaries rather than reasoned about.
  # There is no degraded-but-usable state here the way there is for a missing
  # wallpaper, so this is the one step in this script that aborts the install.
  #
  # Before the links, not after, for a second reason: a render that fails then
  # leaves $HOME untouched instead of half-linked to a broken checkout.
  if [ "$CHECK" != 1 ]; then
    "$ERGON/bin/ergon-theme" --no-apply >/dev/null || {
      warn "the palette did not render — stopping before linking anything."
      warn "the desktop would not start. Run for the error:  ergon theme"
      exit 1
    }
    ok "themed configs rendered from $("$ERGON/bin/ergon-theme" --current)"
  else
    # Counted, not typed. A seventeenth template is exactly the kind of thing
    # that gets added without anyone remembering a number in a dry-run message.
    "$ERGON/bin/ergon-theme" --check >/dev/null 2>&1 \
      || printf '   would render  %s themed configs from the palette\n' \
           "$(find -L "$ERGON" -name '*.in' -not -path '*/.git/*' | wc -l)"
  fi

  # The whole directory, not a file: Hyprland's Lua `require` resolves relative
  # to hyprland.lua, so a single-file symlink breaks every include.
  link hypr   .config/hypr
  link waybar .config/waybar
  link mako   .config/mako
  link fuzzel .config/fuzzel
  link wezterm .config/wezterm
  # btop, which cannot be linked like the others for two reasons:
  #
  #   * it REWRITES btop.conf on exit, so a symlinked config would have btop
  #     editing the repo every time someone quits it;
  #   * it creates ~/.config/btop itself the first time it runs, so by the time
  #     install.sh gets there the directory is real and link() rightly refuses
  #     to replace it. That is exactly what happened -- btop was themed,
  #     rendered and linked, and still drew its own red meters.
  #
  # So: the theme is a symlink (btop only reads it) and the setting is edited
  # into whatever btop.conf is already there.
  # TUI apps that carry their own palette. Every one of these is a working
  # tool rather than a glance, and every one shipped with a scheme built for a
  # different desktop -- yazi blue-and-yellow, lazygit green-and-red.
  # foot had no config at all. It is the escape hatch when wezterm is missing
  # AND the only terminal in the test VM (wezterm is an AUR build the VM skips),
  # so every TUI there ran on foot's stock palette. It also sets the floor for
  # the tools that cannot be themed individually -- jless, dust, gping -- which
  # follow the terminal's ANSI slots or follow nothing.
  link foot       .config/foot
  link lnav       .config/lnav
  link newsboat   .config/newsboat
  link yazi       .config/yazi
  link lazygit    .config/lazygit
  link lazydocker .config/lazydocker

  # bat's theme has to be COMPILED into its cache before it is selectable, so
  # the directory is linked and the cache rebuilt below. delta reads the same
  # theme, which is why every git diff and every lazygit hunk follows from this
  # one file.
  link bat .config/bat
  if [ "$CHECK" != 1 ] && command -v bat >/dev/null 2>&1; then
    if bat cache --build >/dev/null 2>&1; then
      ok "bat cache rebuilt (theme: cool)"
    else
      warn "bat cache --build failed; bat and delta keep their default theme"
    fi
  fi

  if [ "$CHECK" != 1 ]; then
    mkdir -p "$HOME/.config/btop/themes"
    ln -sfn "$ERGON/btop/themes/ergon.theme" "$HOME/.config/btop/themes/ergon.theme"
    if [ -f "$HOME/.config/btop/btop.conf" ]; then
      if grep -q '^color_theme' "$HOME/.config/btop/btop.conf"; then
        sed -i 's|^color_theme.*|color_theme = "ergon"|' "$HOME/.config/btop/btop.conf"
      else
        printf 'color_theme = "ergon"\n' >> "$HOME/.config/btop/btop.conf"
      fi
    else
      cp "$ERGON/btop/btop.conf" "$HOME/.config/btop/btop.conf"
    fi
    ok "btop themed (cool)"
  fi
  link gtk/settings.ini .config/gtk-3.0/settings.ini generated
  link gtk/settings.ini .config/gtk-4.0/settings.ini generated
  # The palette's colours, on top of Adwaita-dark's widgets. Both directories
  # get the same file: GTK3 and libadwaita name the roles differently and
  # gtk.css defines both sets, so one rendered file serves both.
  link gtk/gtk.css .config/gtk-3.0/gtk.css generated
  link gtk/gtk.css .config/gtk-4.0/gtk.css generated
  # The OSD. swayosd-server searches $XDG_CONFIG_HOME/swayosd/style.css itself
  # and loads it over the package's own sheet, so this needs no --style flag in
  # autostart.lua -- the file simply has to be at that path. One file rather
  # than the directory: linking swayosd/ whole would put style.css.in in
  # ~/.config too, and the template is not something the OSD should ever read.
  link swayosd/style.css .config/swayosd/style.css generated
  [ -f "$ERGON/hosts/$HOST/hyprland.lua" ] && link "hosts/$HOST/hyprland.lua" ".config/hypr/hosts/$HOST.lua"

  # PATH for the systemd user manager, which is what launches the session under
  # uwsm. Without it every ergon-* in the bar and the keybinds is not found:
  # the module fires, the command is missing, and nothing surfaces it.
  link environment.d/10-ergon-path.conf .config/environment.d/10-ergon-path.conf
  # ERGON-64: what makes Electron apps keep their key in the keyring rather than
  # in plaintext. uwsm's own env, because environment.d drops the empty value it
  # needs (the file says why). A drop-in uwsm reads after env-hyprland, and not
  # env-hyprland itself: that is where uwsm has users put their own variables,
  # and linking over it replaced a stow symlink and stopped at a real file.
  link uwsm/env-hyprland.d/ergon-keyring .config/uwsm/env-hyprland.d/ergon-keyring

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

  # Same pattern as ergon-reap.timer above: a user timer, not a session
  # service exec'd from Hyprland's autostart, so the low-battery warning still
  # fires even if the desktop config that would have started a monitor is
  # broken.
  if [ "$CHECK" != 1 ]; then
    mkdir -p "$HOME/.config/systemd/user"
    cp "$ERGON/systemd/ergon-battery.service" "$ERGON/systemd/ergon-battery.timer" \
       "$HOME/.config/systemd/user/" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    mkdir -p "$HOME/.config/systemd/user/timers.target.wants"
    ln -sfn ../ergon-battery.timer "$HOME/.config/systemd/user/timers.target.wants/ergon-battery.timer"
    systemctl --user start ergon-battery.timer >/dev/null 2>&1 || true
    ok "ergon-battery.timer enabled"
  fi
fi

# The shell. link() refuses to replace a real file, which is the behaviour
# wanted here: an existing ~/.zshrc is YOURS, and zsh/zshrc documents how to
# source the OS's shell from it instead.
#
# With one exception, and it is not a loophole. `zsh-newuser-install` runs the
# first time anyone starts zsh without a config, and answering "q" makes it
# write an EMPTY ~/.zshrc purely so it stops asking. That file is not
# configuration — it is a marker — but it is a real file, so it blocks this link
# permanently and silently. Every fresh Arch user who opens a shell before
# provisioning finishes hits it.
#
# A zero-byte ~/.zshrc is therefore treated as absent. Anything with a single
# byte in it is left alone.
if [ "$CHECK" != 1 ] && [ -f "$HOME/.zshrc" ] && [ ! -L "$HOME/.zshrc" ] && [ ! -s "$HOME/.zshrc" ]; then
  rm -f "$HOME/.zshrc"
  ok "removed an empty ~/.zshrc (zsh-newuser-install's marker, not config)"
fi
if [ -f "$HOME/.zshrc" ] && [ ! -L "$HOME/.zshrc" ]; then
  warn "~/.zshrc is yours — to use the OS shell, add near the top:"
  warn "    source \"$ERGON/zsh/zshrc\""
fi
link zsh/zshrc  .zshrc
link zsh/zshenv .zshenv

# Emacs: the FILES, not the directory, and that distinction is the whole point.
#
# ~/.emacs.d must stay a real directory so elpa/, eln-cache/ and custom.el land
# there rather than in the repo. Linking the directory instead would make
# `M-x customize' write straight into git -- which has happened: two machines
# independently grew a custom-set-variables block nobody typed, leaving both
# working trees dirty and any sync that refuses a dirty tree silently stuck.
#
# provision-arch.sh already calls emacs --batch -l ~/.emacs.d/init.el to build
# the tree-sitter grammars, so it expected this file to be here.
if [ "$CHECK" != 1 ]; then mkdir -p "$HOME/.emacs.d"; fi
link emacs/init.el       .emacs.d/init.el
link emacs/early-init.el .emacs.d/early-init.el

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

# Every ergon-* on the system PATH.
#
# Provisioning does this too, but provisioning runs rarely and install.sh runs
# whenever the repo changes -- so a command added since the last provision was
# invisible to waybar and to autostart, which exec ergon-* BY NAME. That is not
# hypothetical: ergon-power was added, linked into the bar, and reported as
# "the button does nothing" because the session could not resolve it.
#
# sudo -n: no password prompt from a script that may be running unattended at
# session start. When it is unavailable this says what to run rather than
# failing, since everything else install.sh does still applies.
if [ "$CHECK" != 1 ]; then
  # Prompt when there is a terminal to prompt at; never prompt when there is
  # not. Run by hand this asks for a password once; run from a session start it
  # uses a cached credential or skips.
  if [ -t 0 ] && sudo true 2>/dev/null; then
    _sudo="sudo"
  elif sudo -n true 2>/dev/null; then
    _sudo="sudo -n"
  else
    _sudo=""
  fi
  if [ -n "$_sudo" ]; then
    n=0
    # `ergon` itself first: the ergon-* glob does not match it, which left the
    # dispatcher off the system PATH and made every `ergon <sub>` invocation
    # from waybar or a keybind a silent no-op.
    for c in "$ERGON"/bin/ergon "$ERGON"/bin/ergon-* "$ERGON"/bin/erg-*; do
      [ -x "$c" ] || continue
      $_sudo ln -sfn "$c" "/usr/local/bin/$(basename "$c")" 2>/dev/null && n=$((n+1))
    done
    [ "$n" -gt 0 ] && ok "$n commands on /usr/local/bin"
  elif [ -n "$(find -L "$ERGON/bin" -maxdepth 1 -name 'ergon-*' -newer /usr/local/bin/ergon 2>/dev/null | head -1)" ]; then
    warn "new ergon-* commands are not on the system PATH yet — run: sudo true && ./install.sh"
  fi
fi

# The machine's own AGENTS.md. Every current coding agent reads AGENTS.md, so
# one file describes Ergon to all of them instead of one per vendor format --
# but each looks in a different global location, and none of them may have
# theirs clobbered: a hand-written global instruction file is the user's.
#
# Points at the system copy when the machine is provisioned, and at the
# checkout otherwise, so this works on a box that only has a clone.
if [ "$CHECK" != 1 ]; then
  a_src=/usr/share/ergon/AGENTS.md
  [ -f "$a_src" ] || a_src="$ERGON/AGENTS.system.md"
  a_dst="${CODEX_HOME:-$HOME/.codex}/AGENTS.md"
  mkdir -p "$(dirname "$a_dst")"
  if [ -e "$a_dst" ] && [ ! -L "$a_dst" ]; then
    warn "$a_dst is a real file, so it is left alone — to use Ergon's, add a line: @$a_src"
  else
    ln -sfn "$a_src" "$a_dst" && ok "codex: global AGENTS.md -> $a_src"
  fi
fi

if [ "$CHECK" != 1 ]; then
  "$ERGON/bin/pyfleet" ensure || warn "the base python did not build, or lacks something packages/python lists"
  # The themed configs used to be checked here and warned about. They are
  # rendered outright now, up in the graphical branch and before anything is
  # linked -- which is the only ordering that works, since what they are stale
  # RELATIVE TO on a fresh clone is a file that does not exist yet. Warning
  # about it here would also have fired forever on a headless machine, which
  # renders nothing and needs nothing.

  # The wallpaper is generated, not committed -- and until now NOTHING ever
  # generated it. hyprpaper.conf points at ~/.local/share/ergon/wallpaper.png,
  # hyprpaper logs that it is missing and exits, and the desktop falls back to
  # the compositor's background_color. That degradation is deliberate and it
  # works, which is exactly why nobody noticed that every Ergon machine ever
  # built has had a flat colour instead of the wallpaper it ships.
  #
  # Only when missing: it is a multi-megapixel render, and install.sh runs on
  # every boot under bin/hypr-vm.
  WALL="${ERGON_WALLPAPER_OUT:-$HOME/.local/share/ergon/wallpaper.png}"
  if [ -f "$WALL" ]; then
    :
  elif ! command -v magick >/dev/null 2>&1; then
    warn "no imagemagick, so no wallpaper — the desktop falls back to a flat background"
  elif "$ERGON/bin/ergon-wallpaper" >/dev/null 2>&1; then
    ok "wallpaper generated ($(basename "$WALL"))"
  else
    warn "could not generate the wallpaper — run: ergon wallpaper"
  fi
fi

printf '\n   %s on PATH?  ' "$ERGON/bin"
case ":$PATH:" in
  *":$ERGON/bin:"*) printf 'yes\n' ;;
  *) printf 'NO — add it:\n       export PATH="%s/bin:$PATH"\n' "$ERGON" ;;
esac
