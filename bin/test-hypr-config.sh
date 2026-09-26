#!/usr/bin/env bash
# Load every desktop config through the parser that will actually read it.
#
#   ./test-hypr-config.sh
#
# `luac -p` proves the Lua is syntactically valid and NOTHING else. It cannot
# tell you that hl.general{} is not a function, that misc:vfr moved to
# debug:vfr, or that no_blur is a window-rule field and not a layer-rule one.
# All of those load fine as Lua and are rejected by Hyprland.
#
# None of this needs a GPU, a seat or a VM -- which is why it is a two-second
# test and not a phase of test-arch-vm.sh. Everything runs in a container;
# none of these packages is ever installed on checo.
set -euo pipefail

ERGON="$(cd "${ERGON:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)"
HOSTNAME_FOR_TEST="${1:-testarch}"

command -v docker >/dev/null || { echo "docker required" >&2; exit 1; }

echo "== desktop configs, checked by their own parsers"

out=$(docker run --rm --label cl.jvines.owner=ergon-test-hypr-config -v "$ERGON:/df:ro" archlinux:latest bash -euo pipefail -c '
  # gtk3 AND gtk4, deliberately: waybar is a GTK3 app and swayosd-server links
  # libgtk-4, and the two CSS engines do not accept the same stylesheet. GTK4
  # rejects waybar/style.css outright over -gtk-icon-effect, which is a real
  # GTK3 vendor property doing real work on the tray icons. Each sheet is read
  # by the engine that will actually read it, which is the whole idea of this
  # file. They also cannot share a process: one python may load one Gtk
  # typelib, so the two checks below are two interpreters.
  pacman -Sy --noconfirm --needed hyprland fuzzel mako hypridle hyprlock foot \
    python-gobject gtk3 gtk4 uwsm wezterm newsboat >/dev/null 2>&1

  # Hyprland and hyprlock refuse to run as root without a flag whose name tells
  # you not to use it, so everything runs as a real user.
  useradd -m -u 1000 t 2>/dev/null || true
  install -d -o t -g t -m 700 /tmp/rt

  # Render first, into a writable copy, because the configs these parsers read
  # are generated and gitignored -- a fresh clone has none of them. Doing it
  # here rather than requiring the caller to have run `ergon theme` keeps this
  # script honest on any checkout, including CI, which clones and nothing more.
  #
  # XDG_CONFIG_HOME points at t: rendering also creates the user override files
  # the generated configs include, and mako and fuzzel FAIL when those are
  # missing rather than merely losing the override. They have to land in the
  # home of the user that will read them, not in root'"'"'s.
  cp -r /df /tmp/repo
  XDG_CONFIG_HOME=/home/t/.config XDG_STATE_HOME=/tmp/state \
    ERGON=/tmp/repo /tmp/repo/bin/ergon-theme --no-apply cool >/dev/null

  # Mirrored into XDG_CONFIG_HOME rather than read from the repo copy, because
  # that is where the paths inside them resolve. waybar/style.css ends with
  # @import url("../ergon/waybar.css"), which GTK pops lexically off the path
  # it was HANDED -- from /tmp/repo/waybar/style.css that is /tmp/repo/ergon/,
  # which does not exist, and the check would fail on every run against a
  # stylesheet that is perfectly correct on a real desktop, where
  # ~/.config/waybar is a link and ../ergon lands on the file in
  # ~/.config/ergon that lib/user-config.sh created.
  cp -r /tmp/repo/hypr    /home/t/.config/hypr
  cp -r /tmp/repo/waybar  /home/t/.config/waybar
  cp -r /tmp/repo/swayosd /home/t/.config/swayosd
  chown -R t:t /home/t/.config
  # hyprland.lua reads /etc/hostname for the per-host seam.
  echo "'"$HOSTNAME_FOR_TEST"'" > /etc/hostname
  run() { su t -c "XDG_RUNTIME_DIR=/tmp/rt $*" 2>&1; }

  # The stylesheets, through the GTK version that will parse them. No display
  # is needed and none is available: GtkCssProvider parses without ever
  # reaching a seat, which is why these belong in the fast gate and not in the
  # VM suite.
  #
  # The two are not the same program, and that is not a style choice. GTK3
  # RAISES a GLib.Error from load_from_path; GTK4 returns quietly and reports
  # only through the parsing-error signal, so the GTK3 shape applied to GTK4
  # passes every broken stylesheet there is. Measured on both, against a
  # missing brace, an unknown property and a bad hex colour.
  cat > /tmp/css3.py <<"PYEOF"
import sys, gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib
try:
    Gtk.CssProvider().load_from_path(sys.argv[1])
except GLib.Error as e:
    print(e.message)
    sys.exit(1)
PYEOF
  cat > /tmp/css4.py <<"PYEOF"
import sys, gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk
errs = []
p = Gtk.CssProvider()
p.connect("parsing-error", lambda prov, sec, err: errs.append(sec.to_string() + ": " + err.message))
p.load_from_path(sys.argv[1])
for e in errs:
    print(e)
sys.exit(1 if errs else 0)
PYEOF

  # Each of these parses its config BEFORE it tries to reach Wayland or the bus,
  # so the expected "cannot connect" failure comes AFTER any config error. That
  # is what makes them checkable without a compositor. waybar is the exception:
  # it bails on "cannot open display" before reading anything, so it is not
  # checked here -- its JSON is validated in test-arch-vm.sh instead.

  echo "@@hyprland"
  # The exit code AND the banner, not just the lines after it. An empty section
  # is what the reader below treats as "nothing to report", so a verify that
  # never reached its banner is otherwise indistinguishable from a clean config.
  #
  # Measured, in halves, because the composition is what matters: `Hyprland
  # --verify-config` with XDG_RUNTIME_DIR unset dies with `Critical error
  # thrown: XDG_RUNTIME_DIR is not set!` and never prints the banner; and the
  # reader below prints `ok` for an empty section. One env var, and this gate
  # passes a config it never read. The banner text is not API either.
  hlrc=0
  hlout=$(run "Hyprland --verify-config -c /home/t/.config/hypr/hyprland.lua") || hlrc=$?
  if [ "$hlrc" != 0 ] || ! printf "%s\n" "$hlout" | grep -q "Config parsing result:"; then
    printf "the verify did not report a parsing result (exit %s); last lines:\n" "$hlrc"
    printf "%s\n" "$hlout" | tail -6
  else
    printf "%s\n" "$hlout" \
      | sed -n "/======== Config parsing result:/,\$p" \
      | grep -vE "^=+ Config parsing result:|^[[:space:]]*$|^config ok$" || true
  fi

  # THE DEGRADED CASE, which is the one that cost a session on 2026-09-24.
  #
  # hypr/common/looknfeel.lua is generated and gitignored, so it is the one file
  # in the require chain of the compositor that can simply not be there -- mid-sync,
  # on a fresh clone, after a failed render. A Lua config is ONE CHUNK, so when
  # it was required without a guard its absence stopped every line after it and
  # Hyprland came up with zero keybindings and its own emergency mode. The fix
  # lives in hypr/hyprland.lua; this is what keeps it fixed.
  #
  # The assertion is not "it parses" -- it parsed perfectly all along. It is
  # that execution REACHED common.binds, and the only way to ask that from
  # outside is to make the last line of binds.lua produce an error of its own
  # and look for it.
  echo "@@hyprland-degraded"
  cp -r /home/t/.config/hypr /tmp/degraded
  rm -f /tmp/degraded/common/looknfeel.lua
  printf "\nhl.config({ general = { ergon_binds_reached = 1 } })\n" >> /tmp/degraded/common/binds.lua
  chown -R t:t /tmp/degraded
  dout=$(run "Hyprland --verify-config -c /tmp/degraded/hyprland.lua") || true
  printf "%s\n" "$dout" | grep -q "ergon_binds_reached" || {
    echo "common.binds was NOT reached with common.looknfeel missing:"
    echo "a session would come up with no keybindings at all (Hyprland emergency mode,"
    echo "SUPER+Q only). hypr/hyprland.lua must load its modules so that one missing"
    echo "generated file cannot take the binds down with it."
  }

  echo "@@fuzzel"
  run "fuzzel --config /tmp/repo/fuzzel/fuzzel.ini --check-config" || true

  # foot. Added after its config was found to have been silently ignored for
  # months: foot renamed two sections and moved a key, an unknown section takes
  # every colour in it with it, and foot drops what it does not recognise
  # without complaining. --check-config is the only thing that says so.
  echo "@@foot"
  run "foot --check-config -c /tmp/repo/foot/foot.ini" || true

  # wezterm. The build this repo ships is an AUR git checkout (see
  # wezterm/wezterm.lua.in) present on no machine this script runs on, but
  # Arch'"'"'s own [extra] carries a released wezterm -- a different build of the
  # SAME config schema, which is all a schema check needs. `ls-fonts` loads the
  # config before doing anything font-related, but it is NOT a --check-config:
  # measured against a Lua syntax error, an unknown field and a wrong-typed
  # value, all three exit 0 and print wezterm'"'"'s own defaults on stdout, exactly
  # like foot degraded silently before -c. Each one DOES log an ERROR line to
  # stderr, which is what this reads instead of $?.
  echo "@@wezterm"
  run "wezterm --config-file /tmp/repo/wezterm/wezterm.lua ls-fonts >/dev/null" \
    | grep -iE "error" || true

  # The waybar and swayosd stylesheets. Neither program can be asked to check
  # its own config: waybar exits on "cannot open display" before it reads
  # anything, and swayosd-server has no check flag and initialises GTK before
  # it parses argv. What CAN be checked is the thing that silently broke foot
  # -- whether the file the palette renders is still in the grammar that
  # parser accepts.
  echo "@@waybar-css"
  run "python3 /tmp/css3.py /home/t/.config/waybar/style.css" || true

  echo "@@swayosd-css"
  run "python3 /tmp/css4.py /home/t/.config/swayosd/style.css" || true

  echo "@@mako"
  run "timeout 5 mako --config /tmp/repo/mako/config" \
    | grep -iE "failed to parse|invalid" || true

  echo "@@hypridle"
  run "timeout 5 hypridle -c /tmp/repo/hypr/hypridle.conf" \
    | grep -iE "config error|does not exist|failed to parse" || true

  echo "@@hyprlock"
  run "timeout 5 hyprlock -c /home/t/.config/hypr/hyprlock.conf" \
    | grep -iE "config error|does not exist|Config has errors" || true

  # newsboat. Unlike wezterm it does NOT fall back silently: an unrecognised
  # directive (measured against a renamed `color` target) is a fatal parse
  # error on stderr, exit 1, before curses ever starts or a feed is touched --
  # so this is a real --check-config even without the flag. -u points at a
  # placeholder: only the config is under test, and reload is never invoked.
  echo "@@newsboat"
  echo "http://ergon52.invalid/feed" > /tmp/newsboat-urls
  chown t /tmp/newsboat-urls
  run "timeout 5 newsboat -C /tmp/repo/newsboat/config -u /tmp/newsboat-urls -x print-unread >/dev/null" || true

  # ERGON-64. uwsm/env-hyprland.d/ergon-keyring through uwsm'"'"'s own loader, which
  # picks env-hyprland.d/ for -D Hyprland and sources it (sh, `.`, then `env -0`, so
  # only what is EXPORTED survives). The aux file is what main.py hands the
  # loader; if that interface moves, the mark goes missing and this fails.
  echo "@@uwsm-env"
  install -d -o t -g t /home/t/.config/uwsm /home/t/.config/uwsm/env-hyprland.d
  install -o t -g t -m 644 /tmp/repo/uwsm/env-hyprland.d/ergon-keyring /home/t/.config/uwsm/env-hyprland.d/
  printf "%s\n" __SELF_NAME__=uwsm __WM_BIN_ID__=start_hyprland __WM_DESKTOP_NAMES__=Hyprland \
    __WM_FIRST_DESKTOP_NAME__=Hyprland __WM_DESKTOP_NAMES_EXCLUSIVE__=true __LOAD_PROFILE__=false \
    __RANDOM_MARK__=ergon64mark > /tmp/aux
  printf "__OIFS__=\" \t\n\"\n" >> /tmp/aux && chown t /tmp/aux   # a real tab and newline, as main.py writes
  uenv=$(su t -c "env -i HOME=/home/t PATH=/usr/bin XDG_RUNTIME_DIR=/tmp/rt sh /usr/lib/uwsm/prepare-env.sh /tmp/aux /usr/share/uwsm/plugins/start_hyprland.sh" 2>&1 \
         | tr "\0" "\n" | sed -n "/ergon64mark/,\$p" | sed "s/^.*ergon64mark//")
  case "$(printf "%s\n" "$uenv" | grep "^GNOME_DESKTOP_SESSION_ID=")" in
    GNOME_DESKTOP_SESSION_ID=) ;;
    "") echo "uwsm exports no GNOME_DESKTOP_SESSION_ID: Electron apps fall back to a plaintext password store" ;;
    *)  echo "GNOME_DESKTOP_SESSION_ID is not empty: every xdg-utils script then decides DE=gnome3, and xdg-open <dir> (zsh: o) fails rc=4" ;;
  esac

  echo "@@end"
' 2>&1) || true

rc=0
# Every section below reads "no findings" as ok, so a container script that died
# early -- a mirror, a package that failed to install under set -e -- would pass
# all of them. It has to have reached the end.
grep -qx '@@end' <<<"$out" || {
  printf '   FAIL the container script stopped before the end; last lines:\n'
  printf '%s\n' "$out" | tail -8 | sed 's/^/     /'; rc=1; }
for tool in hyprland hyprland-degraded fuzzel foot wezterm waybar-css swayosd-css mako hypridle hyprlock newsboat uwsm-env; do
  findings=$(printf '%s\n' "$out" | sed -n "/^@@$tool\$/,/^@@/p" | grep -vE '^@@' || true)
  if [ -z "$findings" ]; then
    printf '   ok   %s\n' "$tool"
  else
    printf '   FAIL %s rejected its config:\n' "$tool"
    printf '%s\n' "$findings" | sed 's|/home/t/.config/|  |; s/^/     /'
    rc=1
  fi
done

printf '\n   note: waybar and swayosd are checked here only as far as their\n'
printf '         STYLESHEETS parse. Neither program runs: waybar exits on "cannot\n'
printf '         open display" before reading anything and swayosd-server needs a\n'
printf '         GTK display to start at all, so what runs above is GTK own CSS\n'
printf '         parser on the rendered file -- which catches a syntax error, an\n'
printf '         unknown property and a bad colour, and is what would have caught\n'
printf '         foot. It does NOT catch a selector that matches nothing: #workspaces\n'
printf '         misspelt parses clean under both GTK3 and GTK4. Only the VM session\n'
printf '         suite (test-hypr-session.sh) proves the bar maps a layer surface,\n'
printf '         and only a palette switch in that suite proves the OSD is coloured.\n'
exit $rc
