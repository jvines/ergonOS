# Translation for the strings a person reads on the desktop: the menu,
# notifications, the welcome. Source it; it defines _t and ergon_lang.
#
#   _t "Battery low: %s%%" 12      the translation of the format, then printf
#   _t "Plug in soon."             the translation, verbatim (no printf)
#   _t Session                     a menu label
#
# The English text IS the key, so English needs no catalog, an untranslated
# string falls back to itself, and a string in the source reads as itself.
# Catalogs are i18n/<lang>.tsv: "English<TAB>translation" per line, `#` starts a
# comment, \n in either column is a newline. Keep the printf conversions (%s,
# %d, %%) of the English in the translation, in the same order.
#
# The language is ERGON_LANG, else the first of LC_ALL, LC_MESSAGES, LANG that
# is set and not empty (the usual precedence), cut to its language code:
# es_CL.UTF-8 -> es. C, POSIX, en and any language without a catalog are
# English. ERGON_I18N_DIR overrides where catalogs are looked for (tests).

ergon_lang() {
  local l=${ERGON_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}
  l=${l%%[_.@]*}
  case "$l" in ''|C|POSIX|en) return 1 ;; esac
  printf '%s' "$l"
}

_ERGON_I18N_DIR=${ERGON_I18N_DIR:-$(dirname "${BASH_SOURCE[0]}")/../i18n}
declare -gA _ERGON_T=()
_ERGON_T_LOADED=0
_ergon_t_load() {
  local lang k v
  _ERGON_T_LOADED=1
  lang=$(ergon_lang) || return 0
  [ -r "$_ERGON_I18N_DIR/$lang.tsv" ] || return 0
  while IFS=$'\t' read -r k v || [ -n "$k" ]; do
    case "$k" in ''|'#'*) continue ;; esac
    [ -n "$v" ] || continue
    k=${k//\\n/$'\n'}; v=${v//\\n/$'\n'}
    _ERGON_T["$k"]=$v
  done < "$_ERGON_I18N_DIR/$lang.tsv"
}

_t() {
  local f=$1; shift
  [ "$_ERGON_T_LOADED" = 1 ] || _ergon_t_load
  f=${_ERGON_T["$f"]:-$f}
  if [ $# -gt 0 ]; then printf -- "$f" "$@"; else printf '%s' "$f"; fi
}

# _t_menu <English label>... -> the labels translated, one per line, for a
# picker. The choice comes back translated: _t_back maps it to the English the
# caller's `case` matches on, so a menu's logic never sees a translation.
_t_menu() { local x; for x in "$@"; do _t "$x"; printf '\n'; done; }
_t_back() {  # _t_back <chosen> <English label>...
  local c=$1 x; shift
  for x in "$@"; do [ "$(_t "$x")" = "$c" ] && { printf '%s' "$x"; return 0; }; done
  printf '%s' "$c"
}
_ergon_t_load
