# Timezone detection and a picker, shared by bin/arch-bootstrap.sh (Arch ISO
# console) and bin/ergon-timezone (running machine). Sourced, not executed.
#
# Only bash, curl and zoneinfo are used: that is what the ISO has. No dialog,
# no fzf, no whiptail. The picker is two numbered lists (region, then city) and
# every prompt takes Enter for its default. Prompts and lists go to stderr so a
# caller can capture the chosen zone from stdout.
#
# ERGON_TZ_URLS (space separated) replaces the lookup endpoints; the tests point
# it at file:// URLs so nothing touches the network.

TZ_ZONEDIR="${TZ_ZONEDIR:-/usr/share/zoneinfo}"
TZ_DEFAULT="${TZ_DEFAULT:-America/Santiago}"

# A real IANA zone: a file (not a directory) under zoneinfo, a plain name.
tz_valid() {
  [[ ${1:-} =~ ^[A-Za-z0-9_+/-]+$ ]] && [ -f "$TZ_ZONEDIR/$1" ]
}

# Print the zone the internet connection says we are in, or fail. Each endpoint
# answers with the bare zone name; an answer that is not a zone on this system
# (an error page, a rate-limit message) is discarded, not trusted.
tz_detect() {
  command -v curl >/dev/null 2>&1 || return 1
  local url z
  for url in ${ERGON_TZ_URLS:-https://ipapi.co/timezone https://ipinfo.io/timezone}; do
    z=$(curl -fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | head -c 100 | tr -d '[:space:]') || continue
    if tz_valid "$z"; then printf '%s\n' "$z"; return 0; fi
  done
  return 1
}

_tz_regions() { awk '$1 !~ /^#/ { split($3, p, "/"); print p[1] }' "$TZ_ZONEDIR/zone.tab" | sort -u; echo UTC; }
_tz_cities()  { awk -v r="$1" '$1 !~ /^#/ && index($3, r "/") == 1 { print $3 }' "$TZ_ZONEDIR/zone.tab" | sort -u; }

# Print a numbered list in columns when `column` exists.
_tz_list() {
  local n=0 i
  for i in "$@"; do n=$((n + 1)); printf '%3d) %s\n' "$n" "$i"; done \
    | { column -c "${COLUMNS:-80}" 2>/dev/null || cat; } >&2
}

# tz_pick [DEFAULT]: region, then city. Enter keeps the default at each step; a
# full zone name typed at either prompt is accepted as is.
tz_pick() {
  local def=${1:-$TZ_DEFAULT} dreg reg a regions=() cities=()
  tz_valid "$def" || def=UTC
  dreg=${def%%/*}
  [ "$def" = "${def#*/}" ] && dreg=$def
  while :; do
    mapfile -t regions < <(_tz_regions)
    _tz_list "${regions[@]}"
    printf 'region [number, Enter = %s]: ' "$dreg" >&2
    read -r a || return 1
    if [ -z "$a" ]; then reg=$dreg
    elif tz_valid "$a"; then printf '%s\n' "$a"; return 0
    elif [[ $a =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#regions[@]}" ]; then reg=${regions[a-1]}
    else echo "   not a region" >&2; continue; fi
    [ "$reg" = UTC ] && { echo UTC; return 0; }
    mapfile -t cities < <(_tz_cities "$reg")
    _tz_list "${cities[@]}"
    local cdef=${cities[0]}
    [ "${def%%/*}" = "$reg" ] && tz_valid "$def" && cdef=$def
    printf 'city [number, Enter = %s, 0 = back]: ' "$cdef" >&2
    read -r a || return 1
    if [ -z "$a" ]; then printf '%s\n' "$cdef"; return 0
    elif [ "$a" = 0 ]; then continue
    elif tz_valid "$a"; then printf '%s\n' "$a"; return 0
    elif [[ $a =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#cities[@]}" ]; then
      printf '%s\n' "${cities[a-1]}"; return 0
    else echo "   not a city" >&2; fi
  done
}

# tz_resolve INTERACTIVE [DEFAULT]: print the zone to use.
#   detected + interactive : show it; Enter accepts, a zone name or "c" changes
#   detection failed + interactive : the picker, defaulting to DEFAULT
#   not interactive : the detected zone, else DEFAULT, never a prompt
tz_resolve() {
  local interactive=${1:-0} def=${2:-$TZ_DEFAULT} z a
  if z=$(tz_detect); then
    [ "$interactive" = 1 ] || { printf '%s\n' "$z"; return 0; }
    while :; do
      printf 'timezone detected from your connection: %s\n  Enter = accept, c = choose another, or type a zone: ' "$z" >&2
      read -r a || { printf '%s\n' "$z"; return 0; }
      case $a in
        '') printf '%s\n' "$z"; return 0 ;;
        c|C) tz_pick "$z"; return ;;
        *) if tz_valid "$a"; then printf '%s\n' "$a"; return 0; fi; echo "   not a timezone" >&2 ;;
      esac
    done
  fi
  [ "$interactive" = 1 ] || { printf '%s\n' "$def"; return 0; }
  echo "could not detect the timezone (no connection?); pick one" >&2
  tz_pick "$def"
}
