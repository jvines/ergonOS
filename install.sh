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
    # run. Thirteen of the nineteen rendered outputs are linked as part of a
    # whole directory, which always exists, so this guard never sees them; the
    # gtk files are linked file by file, so on a never-rendered clone --check
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
  # nineteen missing files and link() would happily point $HOME at every one of
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

  # ERGON-62: shared-mime-info already fully defines application/fits,
  # application/vnd.apache.parquet and application/x-hdf (*.hdf5), checked by
  # grepping it in ergon64-closure -- redefining any under a second name
  # would give `xdg-mime query filetype` two answers, worse than the blob
  # this fixes. The one real gap is NumPy's formats, user-level, no root.
  link mime/ergon-science.xml .local/share/mime/packages/ergon-science.xml
  if [ "$CHECK" != 1 ] && command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database "$HOME/.local/share/mime" >/dev/null \
      && ok "mime database updated (npy/npz)" \
      || warn "update-mime-database failed -- npy/npz stay unknown blobs"
  fi

  # FITS opens in Theia (ERGON-73), with a fallback for as long as the
  # astronomy bundle still ships ds9 and topcat. A Default Applications value
  # is a LIST, and xdg-mime returns its first entry that is installed --
  # measured DE-less, xdg-utils 1.2.1: with only ds9 present,
  # "cl.jvines.theia.desktop;ds9.desktop;" answers ds9.desktop and xdg-open
  # starts ds9. So a machine without Theia keeps exactly what it had.
  #
  # image/fits is what file(1) reports for a plain primary-HDU image. ds9's
  # own .desktop registers only image/x-fits, an ALIAS, and on Hyprland
  # `xdg-open` runs DE-less (no XDG_CURRENT_DESKTOP xdg-utils recognises), so
  # it reads mimeapps.list literally and never resolves an alias to ds9 --
  # hence ds9 is named here rather than left to its .desktop.
  #
  # application/fits is the hard one: file(1) reports it for a table-only
  # FITS (a light curve, a catalogue) AND for an image sitting in an
  # extension behind an empty primary HDU -- one mime, two right answers.
  # ERGON-62 kept it away from ds9, which sent table-only files to a viewer
  # that cannot show a table. Theia shows both, an image in any HDU and a
  # table as a paged grid, so it takes this key too (operator's call,
  # 2026-10-01), with topcat behind it. topcat's jar bundles a real Parquet
  # reader (uk.ac.starlink.parquet) but no HDF5 or NumPy one, so those get no
  # default because nothing installed by any bundle opens them.
  #
  # Parquet opens in Columna (ERGON-75), the same list-with-fallback shape:
  # Columna's installer puts com.columna.Columna.desktop in
  # ~/.local/share/applications, and until it is there topcat answers as
  # before. The Linux port is tested (feature/linux-port e1b53c9) but has no
  # public package yet, so nothing here installs it and visidata stays in
  # packages/pacman until one exists.
  #
  # An idempotent key-set, not a symlink: mimeapps.list is user-editable the
  # same way btop.conf is -- but unlike btop.conf, the key here can be the
  # USER's own choice, and Added/Removed Associations are separate sections a
  # naive `sed "s|^$1=|"` also matched (ERGON-62 review, reproduced: it
  # rewrote a stale Added Associations line and injected our key into Removed
  # Associations too). _mimedefault below is scoped to [Default Applications]
  # by awk and only writes a key that section does not already have, so a
  # user's pick -- or last run's -- survives the next provisioning run. A
  # stale entry naming a since-removed app still degrades on its own --
  # confirmed the same way, that xdg-open skips a Default Applications line
  # whose .desktop or Exec cannot be found.
  #
  # The one exception is a value THIS script wrote before and has since
  # changed: the optional third argument. Without it, every machine
  # provisioned before ERGON-73 would keep "image/fits=ds9.desktop;" for good,
  # because the key exists. Only that exact old value is replaced; anything
  # else in the key is the user's and is left alone.
  if [ "$CHECK" != 1 ]; then
    MIMEAPPS="$HOME/.config/mimeapps.list"
    mkdir -p "$(dirname "$MIMEAPPS")"
    [ -f "$MIMEAPPS" ] || : > "$MIMEAPPS"
    _mimedefault() {  # _mimedefault <mimetype> <desktop-list> [<value we used to write>]
      awk -v key="$1" -v val="$2" -v old="${3:-}" '
        BEGIN { insec = 0; has = 0; done = 0 }
        /^\[Default Applications\]/ { insec = 1; has = 1; print; next }
        /^\[/ { if (insec && !done) { print key "=" val ";"; done = 1 }; insec = 0; print; next }
        insec && old != "" && $0 == key "=" old ";" { print key "=" val ";"; done = 1; next }
        { if (insec && $0 ~ "^" key "=") done = 1; print }
        END {
          if (insec && !done) print key "=" val ";"
          else if (!has) { print "[Default Applications]"; print key "=" val ";" }
        }
      ' "$MIMEAPPS" > "$MIMEAPPS.new" && mv "$MIMEAPPS.new" "$MIMEAPPS"
    }
    _mimedefault image/fits "cl.jvines.theia.desktop;ds9.desktop" ds9.desktop
    _mimedefault application/fits "cl.jvines.theia.desktop;topcat.desktop"
    _mimedefault application/vnd.apache.parquet "com.columna.Columna.desktop;topcat.desktop" topcat.desktop
    unset -f _mimedefault
    ok "mimeapps.list: FITS -> Theia (then ds9 / topcat), parquet -> Columna (then topcat) (ignored where not installed)"
  fi

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
  link gtk/settings4.ini .config/gtk-4.0/settings.ini generated
  # The palette's colours, on top of Adwaita's widgets. Not the same file in
  # both: GTK4's carries a light and a dark palette so a running app follows a
  # palette switch, and GTK3 cannot parse that (gtk/gtk4.css.in).
  link gtk/gtk.css  .config/gtk-3.0/gtk.css generated
  link gtk/gtk4.css .config/gtk-4.0/gtk.css generated
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
  # Theia answers ds9's XPA names, on loopback only (ERGON-73; the file says
  # why both variables are needed).
  link environment.d/60-theia.conf .config/environment.d/60-theia.conf
  # ERGON-39: where screenshots go, from SCREENSHOT_DIR in host.env; empty is
  # ~/Pictures/Screenshots (hypr/common/screenshot.lua). Written, not linked:
  # the value is this host's. hypr/common/screenshot.lua puts it into a shell
  # pipeline unquoted, so only a plain absolute path is passed on.
  _sd="$HOME/.config/environment.d/50-ergon-screenshots.conf"
  if [ -z "${SCREENSHOT_DIR:-}" ]; then
    if [ -e "$_sd" ]; then
      if [ "$CHECK" = 1 ]; then printf '   would remove  .config/environment.d/50-ergon-screenshots.conf\n'
      else rm -f "$_sd"; ok "screenshots: ~/Pictures/Screenshots again (SCREENSHOT_DIR is empty)"; fi
    fi
  elif [[ ! $SCREENSHOT_DIR =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    warn "SCREENSHOT_DIR=$SCREENSHOT_DIR in $HOSTENV ignored: an absolute path of letters, digits, . _ - and / only"
  else
    _want=$(printf '# Written by install.sh from SCREENSHOT_DIR in hosts/%s/host.env (ERGON-39).\nERGON_SCREENSHOT_DIR=%s\n' "$HOST" "$SCREENSHOT_DIR")
    if [ "$(cat "$_sd" 2>/dev/null)" != "$_want" ]; then
      if [ "$CHECK" = 1 ]; then printf '   would write  .config/environment.d/50-ergon-screenshots.conf (%s)\n' "$SCREENSHOT_DIR"
      else
        mkdir -p "$(dirname "$_sd")"
        printf '%s\n' "$_want" > "$_sd"
        ok "screenshots: $SCREENSHOT_DIR, from the next login"
      fi
    fi
  fi
  # ERGON-64: what makes Electron apps keep their key in the keyring rather than
  # in plaintext. uwsm's own env, because environment.d drops the empty value it
  # needs (the file says why). A drop-in uwsm reads after env-hyprland, and not
  # env-hyprland itself: that is where uwsm has users put their own variables,
  # and linking over it replaced a stow symlink and stopped at a real file.
  link uwsm/env-hyprland.d/ergon-keyring .config/uwsm/env-hyprland.d/ergon-keyring

  # ERGON-79: fcitx5, which press-and-hold accents run inside. File by file,
  # into a directory that stays real, because fcitx5 writes into it itself --
  # measured, one Save on a fresh config created conf/cached_layouts and
  # conf/notifications.conf beside ours, so a linked directory would be fcitx5
  # writing into the checkout. The settings this repo owns are links; fcitx5
  # only rewrites those when someone changes a setting through it, and then
  # the link becomes that person's own file, which link() leaves alone.
  link fcitx5/config .config/fcitx5/config
  for _f in "$ERGON"/fcitx5/conf/*.conf; do
    [ -e "$_f" ] || continue
    link "fcitx5/conf/${_f##*/}" ".config/fcitx5/conf/${_f##*/}"
  done
  # Except the accent picker's, which is RENDERED (lib/accents.sh): the repo's
  # defaults in fcitx5/omacento.conf plus what `ergon accents` was told, kept
  # in ~/.config/ergon/accents. A link made turning the popup off an edit to
  # the checkout. Rendered here on every sync, so a change to the table still
  # arrives and a person's choices are never undone by one -- and the link an
  # earlier install made is replaced the first time, with a line saying so.
  # shellcheck source=lib/accents.sh
  if [ ! -f "$ERGON/lib/accents.sh" ] || [ ! -f "$ERGON/fcitx5/omacento.conf" ]; then
    warn "missing in the repo: lib/accents.sh or fcitx5/omacento.conf -- accents not rendered"
  elif ! . "$ERGON/lib/accents.sh"; then
    warn "lib/accents.sh did not load -- accents not rendered"
  elif [ "$CHECK" = 1 ]; then
    _acc=$(mktemp)
    ergon_accents_compose > "$_acc" 2>/dev/null || true
    if [ -L "$(ergon_accents_live)" ]; then
      printf '   would render  .config/fcitx5/conf/omacento.conf over the link into the checkout\n'
    elif ! cmp -s "$_acc" "$(ergon_accents_live)"; then
      printf '   would render  .config/fcitx5/conf/omacento.conf from fcitx5/omacento.conf and ~/.config/ergon/accents\n'
    fi
    rm -f "$_acc"
  else
    _rc=0; ergon_accents_render || _rc=$?
    case "$_rc/${ERGON_ACCENTS_DID:-}" in
      0/replaced-link) ok ".config/fcitx5/conf/omacento.conf is rendered now, not a link: accent choices go in ~/.config/ergon/accents (ergon accents)" ;;
      0/written)       ok ".config/fcitx5/conf/omacento.conf rendered from fcitx5/omacento.conf and ~/.config/ergon/accents" ;;
      0/unchanged)     ;;
      3/*)             warn ".config/fcitx5/conf/omacento.conf is not a render of ours; left alone. Move it aside, then: ergon accents" ;;
      *)               warn "could not render .config/fcitx5/conf/omacento.conf (above)" ;;
    esac
    # A running fcitx5 keeps what it read until it is told to read again; with
    # none running (a fresh install, a sync over ssh) there is nothing to tell,
    # and asking would START one by D-Bus activation, outside the session.
    if [ "$_rc" = 0 ] && [ "${ERGON_ACCENTS_DID:-}" != unchanged ]; then
      _rc=0; ergon_accents_apply || _rc=$?
      case "$_rc" in
        0) ok "  and the running fcitx5 has re-read it" ;;
        1) ;;
        *) warn "  the running fcitx5 did not take it; restart it: fcitx5 -d --replace" ;;
      esac
    fi
  fi
  # The profile is the exception: fcitx5 rewrites it on every exit and every
  # half-hour autosave (Instance::save), by renaming a new file over it. A link
  # there is a real file after the first logout, and install.sh then warns
  # about it forever. So it is SEEDED once, and fcitx5's from then on -- which
  # is right anyway, since adding an input method is a change to exactly it.
  if [ ! -e "$HOME/.config/fcitx5/profile" ]; then
    if [ "$CHECK" = 1 ]; then
      printf '   would seed  .config/fcitx5/profile from fcitx5/profile\n'
    else
      install -Dm644 "$ERGON/fcitx5/profile" "$HOME/.config/fcitx5/profile"
      ok ".config/fcitx5/profile seeded from fcitx5/profile (fcitx5 owns it now)"
    fi
  fi

  # ...and the Chromium half. A Chromium app talks to an input method on
  # Wayland only when started with --enable-wayland-ime. Every app that runs
  # on Arch's electron package -- code from the vscode bundle, and anything
  # else built on electronNN -- goes through /usr/lib/electronNN's launcher,
  # which reads ~/.config/electron-flags.conf one flag a line (unless an
  # electronNN-flags.conf exists, which then wins; read off electron42's
  # launcher, 2026-10-13). A line added, not a link: that file is where people
  # put their own flags. Discord bundles its own Chromium and reads no such
  # file; its flag is in its launcher entry, linked just below.
  _ef="$HOME/.config/electron-flags.conf"
  if ! grep -qxF -- --enable-wayland-ime "$_ef" 2>/dev/null; then
    if [ "$CHECK" = 1 ]; then
      printf '   would add  --enable-wayland-ime to .config/electron-flags.conf\n'
    else
      mkdir -p "$(dirname "$_ef")"
      # A last line with no newline would swallow the flag into itself.
      [ ! -s "$_ef" ] || [ -z "$(tail -c1 "$_ef")" ] || printf '\n' >> "$_ef"
      printf -- '--enable-wayland-ime\n' >> "$_ef"
      ok ".config/electron-flags.conf: --enable-wayland-ime (Electron apps reach the input method)"
    fi
  fi
  # Discord's entry with the same flag (applications/discord.desktop says why).
  # Linked whether or not the discord bundle is installed: TryExec hides it
  # until it is, so adding the bundle later needs no second sync.
  link applications/discord.desktop .local/share/applications/discord.desktop

  if [ "$CHECK" != 1 ]; then
    # ERGON-72: `su -`/`sudo -u` (provisioning, the VM harness) open no
    # logind session, so a bare `systemctl --user` below reached no manager
    # and still printed ok for the reap and battery timers -- the same
    # silent no-op ERGON-50 found and fixed for ergon-oom-notify alone. One
    # helper for all three, on lib/user-manager.sh's own reload: it is the
    # only thing that tells "no manager yet" (fine -- the wants symlink
    # starts the unit at the next login) apart from a reload that reached a
    # manager but a unit that then failed to start.
    # shellcheck source=lib/user-manager.sh
    . "$ERGON/lib/user-manager.sh"
    enable_user_unit() {  # <unit> <verb: start|restart> <label>
      # Shadowed empty, not left ambient: install.sh only ever configures ITS
      # OWN caller's manager, so its runtime dir is always /run/user/$(id -u)
      # -- never whatever $XDG_RUNTIME_DIR the invoking shell happened to
      # carry. Measured in ergon64-closure: a plain `su u -c` (no dash) from a
      # root shell with its OWN $XDG_RUNTIME_DIR set inherits that value, and
      # _ergon_user_runtime_dir's "prefer the caller's own" then asks the
      # WRONG uid's bus and reports a lingering, reachable manager as absent.
      local rc=0 XDG_RUNTIME_DIR=
      ergon_user_reload || rc=$?
      if [ "$rc" != 0 ]; then
        ok "$3 enabled; no user manager is running, it starts at the next login"
        return
      fi
      XDG_RUNTIME_DIR="$(_ergon_user_runtime_dir)" systemctl --user "$2" "$1" >/dev/null 2>&1
      # $2 returning 0 only means the manager accepted the job: a Type=simple
      # unit is "active" the instant it forks, before its exec is known to have
      # worked, so ergon-oom-notify crash-looping on a missing binary measured
      # as an immediate 0 here too. Settle, then ask what the manager actually
      # holds, the same question ergon_user_ensure_prop asks after a reload.
      sleep 0.2
      if XDG_RUNTIME_DIR="$(_ergon_user_runtime_dir)" systemctl --user is-active --quiet "$1"; then
        ok "$3 enabled and running"
      else
        warn "$3 did not start -- journalctl --user -u $1"
      fi
    }
  fi

  if [ "$CHECK" != 1 ]; then
    mkdir -p "$HOME/.config/systemd/user"
    cp "$ERGON/systemd/ergon-reap.service" "$ERGON/systemd/ergon-reap.timer" \
       "$HOME/.config/systemd/user/" 2>/dev/null || true
    # Enabling is a symlink; doing it directly needs no session bus, which a
    # machine being set up from a TTY does not have.
    mkdir -p "$HOME/.config/systemd/user/timers.target.wants"
    ln -sfn ../ergon-reap.timer "$HOME/.config/systemd/user/timers.target.wants/ergon-reap.timer"
    enable_user_unit ergon-reap.timer start ergon-reap.timer
  fi

  # Same pattern as ergon-reap.timer above: a user timer, not a session
  # service exec'd from Hyprland's autostart, so the low-battery warning still
  # fires even if the desktop config that would have started a monitor is
  # broken.
  if [ "$CHECK" != 1 ]; then
    mkdir -p "$HOME/.config/systemd/user"
    cp "$ERGON/systemd/ergon-battery.service" "$ERGON/systemd/ergon-battery.timer" \
       "$HOME/.config/systemd/user/" 2>/dev/null || true
    mkdir -p "$HOME/.config/systemd/user/timers.target.wants"
    ln -sfn ../ergon-battery.timer "$HOME/.config/systemd/user/timers.target.wants/ergon-battery.timer"
    enable_user_unit ergon-battery.timer start ergon-battery.timer
  fi

  # ERGON-50: the notification naming what oomd killed, for everything `ergon
  # watch` did not start. default.target, not graphical-session.target: only a
  # uwsm login reaches that one, and a session started any other way -- the VM
  # harness's -- would never run it. restart, not start: a follower already
  # running keeps the old script until it is.
  if [ "$CHECK" != 1 ]; then
    mkdir -p "$HOME/.config/systemd/user/default.target.wants"
    cp "$ERGON/systemd/ergon-oom-notify.service" "$HOME/.config/systemd/user/" 2>/dev/null || true
    ln -sfn ../ergon-oom-notify.service "$HOME/.config/systemd/user/default.target.wants/ergon-oom-notify.service"
    enable_user_unit ergon-oom-notify.service restart ergon-oom-notify.service
  fi

  # ERGON-86: the same follower, for core dumps. Same unit shape, same reasons.
  if [ "$CHECK" != 1 ]; then
    cp "$ERGON/systemd/ergon-crash-notify.service" "$HOME/.config/systemd/user/" 2>/dev/null || true
    ln -sfn ../ergon-crash-notify.service "$HOME/.config/systemd/user/default.target.wants/ergon-crash-notify.service"
    enable_user_unit ergon-crash-notify.service restart ergon-crash-notify.service
  fi

  # ERGON-96: Taildrop receiver. The unit's ConditionPathExists keeps it inert
  # where tailscale is not installed.
  if [ "$CHECK" != 1 ]; then
    cp "$ERGON/systemd/ergon-taildrop.service" "$HOME/.config/systemd/user/" 2>/dev/null || true
    ln -sfn ../ergon-taildrop.service "$HOME/.config/systemd/user/default.target.wants/ergon-taildrop.service"
    enable_user_unit ergon-taildrop.service restart ergon-taildrop.service
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

  # The approved backgrounds (ERGON-74): their fields, from the release the
  # manifest names, checked against its sha256s. Coloured at the next login,
  # once a compositor can say the panel's size. Not fatal: without the network
  # the desktop still has the gradient and every generator, and the next run --
  # every `ergon sync` is one -- fetches only what is still missing.
  # ERGON_BACKGROUNDS=0 skips it.
  if [ "${ERGON_BACKGROUNDS:-1}" != 0 ]; then
    _bglog=$(mktemp)
    if "$ERGON/bin/ergon-wallpaper-gen" --fetch >"$_bglog" 2>&1; then
      ok "$(grep -m1 'approved backgrounds' "$_bglog" | sed 's/^ *//')"
    else
      warn "$(grep -m1 'approved backgrounds\|no manifest\|no python' "$_bglog" | sed 's/^ *//') — run: ergon-wallpaper-gen --fetch"
    fi
    rm -f "$_bglog"
  fi
fi

printf '\n   %s on PATH?  ' "$ERGON/bin"
case ":$PATH:" in
  *":$ERGON/bin:"*) printf 'yes\n' ;;
  *) printf 'NO — add it:\n       export PATH="%s/bin:$PATH"\n' "$ERGON" ;;
esac
