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
  pacman -Sy --noconfirm --needed hyprland fuzzel mako hypridle hyprlock >/dev/null 2>&1

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

  cp -r /tmp/repo/hypr /home/t/.config/hypr && chown -R t:t /home/t/.config
  # hyprland.lua reads /etc/hostname for the per-host seam.
  echo "'"$HOSTNAME_FOR_TEST"'" > /etc/hostname
  run() { su t -c "XDG_RUNTIME_DIR=/tmp/rt $*" 2>&1; }

  # Each of these parses its config BEFORE it tries to reach Wayland or the bus,
  # so the expected "cannot connect" failure comes AFTER any config error. That
  # is what makes them checkable without a compositor. waybar is the exception:
  # it bails on "cannot open display" before reading anything, so it is not
  # checked here -- its JSON is validated in test-arch-vm.sh instead.

  echo "@@hyprland"
  run "Hyprland --verify-config -c /home/t/.config/hypr/hyprland.lua" \
    | sed -n "/======== Config parsing result:/,\$p" \
    | grep -vE "^=+ Config parsing result:|^[[:space:]]*$|^config ok$" || true

  echo "@@fuzzel"
  run "fuzzel --config /tmp/repo/fuzzel/fuzzel.ini --check-config" || true

  echo "@@mako"
  run "timeout 5 mako --config /tmp/repo/mako/config" \
    | grep -iE "failed to parse|invalid" || true

  echo "@@hypridle"
  run "timeout 5 hypridle -c /tmp/repo/hypr/hypridle.conf" \
    | grep -iE "config error|does not exist|failed to parse" || true

  echo "@@hyprlock"
  run "timeout 5 hyprlock -c /home/t/.config/hypr/hyprlock.conf" \
    | grep -iE "config error|does not exist|Config has errors" || true

  echo "@@end"
' 2>&1) || true

rc=0
for tool in hyprland fuzzel mako hypridle hyprlock; do
  findings=$(printf '%s\n' "$out" | sed -n "/^@@$tool\$/,/^@@/p" | grep -vE '^@@' || true)
  if [ -z "$findings" ]; then
    printf '   ok   %s\n' "$tool"
  else
    printf '   FAIL %s rejected its config:\n' "$tool"
    printf '%s\n' "$findings" | sed 's|/home/t/.config/|  |; s/^/     /'
    rc=1
  fi
done

printf '\n   note: waybar is NOT checked here -- it exits on "cannot open display"\n'
printf '         before parsing. Its JSON and module list are checked in test-arch-vm.sh.\n'
exit $rc
