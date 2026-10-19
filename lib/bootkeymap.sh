# The console keymap the initramfs carries (sd-vconsole copies /etc/vconsole.conf
# into the image), so it is what types the LUKS passphrase (ERGON-112).
# Sourced by bin/arch-bootstrap.sh; no side effects.
#
# Measured on kbd with `loadkeys -u -t` over every shipped keymap: the Russian,
# Ukrainian, Greek, Hebrew, Bulgarian, Belarusian, Macedonian, Serbian and
# Georgian maps all type Latin letters at the plain level and reach their own
# script through a toggle, so they unlock fine. What does not is a map whose
# plain letter keys are not Latin: `fa` (empty plain level), or a name from
# another vocabulary (an xkb layout like "ara" is no kbd map at all). Those fall
# back to BOOTKEYMAP_FALLBACK. The desktop layout is untouched: the chosen name
# is kept as ERGON_KEYMAP in vconsole.conf, which systemd ignores and the
# provisioner and layout.lua read first.

BOOTKEYMAP_FALLBACK="${BOOTKEYMAP_FALLBACK:-us}"

# 0 if the keymap's plain letter keys type Latin letters. With loadkeys we ask
# it; without it (or for a name it cannot load) a static list of the maps that
# measured non-Latin decides, and an unknown name is refused: it cannot be
# trusted to type anything.
bootkeymap_latin() {
  local k=${1:-} dump
  [[ $k =~ ^[A-Za-z0-9_.+-]+$ ]] || return 1
  if command -v loadkeys >/dev/null 2>&1; then
    dump=$(loadkeys -u -t "$k" 2>/dev/null) || return 1
    printf '%s\n' "$dump" | awk '
      $1 == "keycode" && $2 ~ /^(1[6-9]|2[0-5]|3[0-8]|4[4-9]|50)$/ { t++; if ($4 ~ /^\+?[A-Za-z]$/) l++ }
      END { exit !(t > 0 && l * 2 >= t) }'
    return
  fi
  case $k in
    fa|euro|euro1|euro2|unicode) return 1 ;;
  esac
  return 0
}

# Print the keymap to put in vconsole.conf for the initramfs.
bootkeymap_resolve() {
  if bootkeymap_latin "${1:-}"; then printf '%s\n' "$1"; else printf '%s\n' "${BOOTKEYMAP_FALLBACK:-us}"; fi
}
