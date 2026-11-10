# Install-media presets (ERGON-157): an optional file that says how this
# install should be localised, so a stick prepared for a lab or an observatory
# does not ask the same five questions on every machine. Sourced by
# bin/arch-bootstrap.sh; not a command.
#
# The file is `ergon-preset`, DATA in KEY=value lines (never sourced), looked
# for on the ISO's boot medium and beside the repo:
#
#   LOCALE=es_CL.UTF-8
#   KEYMAP=la-latin1
#   TIMEZONE=America/Santiago
#   MIRROR_COUNTRY=CL            reflector --country; codes, comma separated
#   NTP=cl.pool.ntp.org          space separated, up to four servers
#
# The environment wins over the file, the file over detection. A line whose
# value does not pass its pattern is ignored with a warning, never half-used:
# these values end up in locale.gen, a sed expression and a unit drop-in.
# Nothing here is asked about; the interactive prompts still run, with the
# preset as their default.

ERGON_PRESET_NAME=ergon-preset

# The first preset file that exists: $ERGON_PRESET, the ISO's boot medium, the
# root's home, the repo checkout the installer runs from.
ergon_preset_find() {
  local f
  for f in "${ERGON_PRESET:-}" /run/archiso/bootmnt/$ERGON_PRESET_NAME /root/$ERGON_PRESET_NAME "${ERGON:-.}/$ERGON_PRESET_NAME"; do
    [ -n "$f" ] && [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

_preset_ok() {  # _preset_ok KEY VALUE
  case $1 in
    LOCALE)         [[ $2 =~ ^[a-z]{2,3}_[A-Z]{2}(\.[A-Za-z0-9-]+)?(@[a-z]+)?$ ]] ;;
    KEYMAP)         [[ $2 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$ ]] ;;
    TIMEZONE)       [[ $2 =~ ^[A-Za-z0-9_+/-]+$ ]] ;;
    MIRROR_COUNTRY) [[ $2 =~ ^[A-Za-z]{2}(,[A-Za-z]{2}){0,9}$ ]] ;;
    NTP)            [[ $2 =~ ^[A-Za-z0-9.-]+( [A-Za-z0-9.-]+){0,3}$ ]] ;;
    *)              return 1 ;;
  esac
}

# ergon_preset_apply FILE: set LOCALE, KEYMAP, TIMEZONE, MIRROR_COUNTRY and NTP
# from FILE, each only if it is empty or unset (so the environment wins).
ergon_preset_apply() {
  local k v n=0
  while IFS='=' read -r k v || [ -n "$k" ]; do
    n=$((n + 1))
    case $k in ''|'#'*) continue ;; esac
    v=${v%\"}; v=${v#\"}
    if ! _preset_ok "$k" "$v"; then
      printf '   !!  %s line %d: %s=%s ignored (not a valid value)\n' "$1" "$n" "$k" "$v" >&2
      continue
    fi
    [ -n "${!k:-}" ] || printf -v "$k" '%s' "$v"
  done < "$1"
}

# ergon_mirrors COUNTRY: rank the live mirrorlist for those countries. The
# installed system copies this list, so it is what pacman there starts from.
# Never fatal: no network, an unknown country or no reflector leaves the list
# the ISO came with.
ergon_mirrors() {
  command -v reflector >/dev/null 2>&1 || { echo "   !!  reflector is not on this ISO; mirrors left as they are" >&2; return 0; }
  if reflector --country "$1" --protocol https --latest 10 --sort rate --save /etc/pacman.d/mirrorlist.ergon >/dev/null 2>&1 \
     && grep -q '^Server' /etc/pacman.d/mirrorlist.ergon; then
    mv -f /etc/pacman.d/mirrorlist.ergon /etc/pacman.d/mirrorlist
    echo "   ok  mirrors: $1"
  else
    rm -f /etc/pacman.d/mirrorlist.ergon
    echo "   !!  reflector found no mirrors for $1; mirrors left as they are" >&2
  fi
}
