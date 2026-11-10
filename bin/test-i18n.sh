#!/usr/bin/env bash
# ERGON-158: the translation mechanism (lib/i18n.sh, i18n/<lang>.tsv,
# knowledge/<lang>/), English unchanged, Spanish where a catalog exists.
#
#   ./bin/test-i18n.sh
#
# Seconds, no session. fuzzel is a stub that logs what it was shown and picks
# from a script. DOES NOT COVER: how Spanish reads on the screen (the bar, mako
# and fuzzel wrapping a longer string): that is for a person to look at.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
unset ERGON_LANG LC_ALL LC_MESSAGES
tr_() { ( . "$REPO/lib/i18n.sh"; _t "$@" ) 2>/dev/null; }   # in a fresh shell: nothing carried over

# --- the language follows the locale, English otherwise ----------------------
eq "es_CL.UTF-8 -> Spanish"      "$(LANG=es_CL.UTF-8 tr_ Session)" "Sesión"
eq "es_ES@euro -> Spanish"       "$(LANG=es_ES@euro tr_ Session)" "Sesión"
eq "LC_ALL beats LANG"           "$(LC_ALL=es_CL.UTF-8 LANG=en_US.UTF-8 tr_ Session)" "Sesión"
eq "LC_ALL=C beats LANG"         "$(LC_ALL=C LANG=es_CL.UTF-8 tr_ Session)" "Session"
eq "LC_MESSAGES beats LANG"      "$(LC_MESSAGES=es_CL.UTF-8 LANG=en_US.UTF-8 tr_ Session)" "Sesión"
eq "ERGON_LANG beats them all"   "$(ERGON_LANG=es LC_ALL=en_US.UTF-8 tr_ Session)" "Sesión"
eq "ERGON_LANG=en forces English" "$(ERGON_LANG=en LANG=es_CL.UTF-8 tr_ Session)" "Session"
eq "en_US is English"            "$(LANG=en_US.UTF-8 tr_ Session)" "Session"
eq "C is English"                "$(LANG=C tr_ Session)" "Session"
eq "no locale at all is English" "$(unset LANG; tr_ Session)" "Session"
eq "a language without a catalog is English" "$(LANG=fr_FR.UTF-8 tr_ Session)" "Session"
eq "an untranslated string is itself" "$(LANG=es_CL.UTF-8 tr_ 'not in the catalog')" "not in the catalog"
eq "printf conversions are kept"  "$(LANG=es_CL.UTF-8 tr_ 'Battery low: %s%%' 15)" "Batería baja: 15%"
eq "English formats the same way" "$(LANG=C tr_ 'Battery low: %s%%' 15)" "Battery low: 15%"
eq "no args prints verbatim (a % stays a %)" "$(LANG=C tr_ '100% sure')" "100% sure"

# --- a catalog line that breaks a format, or names a string nobody uses ------
cat="$REPO/i18n/es.tsv"
conv() { grep -o '%[0-9]*[sdf%]' <<<"$1" | tr '\n' ' '; }
badfmt=0 stale=0
SRC=$(sed 's/\\`/`/g' "$REPO"/bin/ergon-*)
while IFS=$'\t' read -r k v; do
  case "$k" in ''|'#'*) continue ;; esac
  [ -n "$v" ] || { bad "empty translation for [$k]"; continue; }
  [ "$(conv "$k")" = "$(conv "$v")" ] || { bad "conversions differ: [$k] [$v]"; badfmt=1; }
  grep -qF -- "$k" <<<"$SRC" || { bad "no script uses [$k]"; stale=1; }
done < "$cat"
[ "$badfmt" = 0 ] && ok "every translation keeps its English's printf conversions"
[ "$stale" = 0 ] && ok "every catalog string is in a script"
# ...and the other way: every literal _t "..." in a script has an entry.
missing=0
while IFS= read -r s; do
  grep -qF -- "$s"$'\t' "$cat" || { bad "no Spanish for [$s]"; missing=1; }
done < <(grep -ho '_t "[^"$]*"' "$REPO"/bin/ergon-* | sed 's/^_t "//; s/"$//; s/\\`/`/g' | sort -u)
[ "$missing" = 0 ] && ok "every literal _t string in bin/ has a Spanish entry"
for w in System Style Commands Help Session Wi-Fi "Web app" Timezone Language Channel Add Remove List Palette Background Keybindings; do
  grep -q "^$w	" "$cat" || { bad "menu label [$w] has no Spanish"; missing=1; }
done

# --- the menu shows Spanish and still acts on the English choice --------------
mkdir -p "$T/stub"
cat > "$T/stub/fuzzel" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$TEST_ROOT/n" 2>/dev/null || echo 0); echo $((n + 1)) > "$TEST_ROOT/n"
printf '%s\n' "$*" >> "$TEST_ROOT/prompts"; cat >> "$TEST_ROOT/shown"
[ "$n" = 0 ] && echo "Sistema" && exit 0
exit 1
STUB
chmod +x "$T/stub/fuzzel"
TEST_ROOT=$T PATH="$T/stub:$PATH" ERGON_LANG=es "$REPO/bin/ergon-menu" >/dev/null 2>&1
eq "the top menu is shown in Spanish" "$(head -4 "$T/shown" | tr '\n' ',')" "Sistema,Estilo,Comandos,Ayuda,"
grep -q -- '--prompt ergon' "$T/prompts" && ok "  with its prompt" || bad "  prompt: $(head -1 "$T/prompts")"
grep -qx "Zona horaria" "$T/shown" && ok "  and choosing 'Sistema' opened the System menu" || bad "  'Sistema' did not reach system_menu"
grep -q -- '--prompt sistema' "$T/prompts" && ok "  whose prompt is translated" || bad "  system prompt: $(sed -n 2p "$T/prompts")"
rm -f "$T/n" "$T/shown" "$T/prompts"
TEST_ROOT=$T PATH="$T/stub:$PATH" ERGON_LANG=en "$REPO/bin/ergon-menu" >/dev/null 2>&1
eq "English menu is unchanged" "$(head -4 "$T/shown" | tr '\n' ',')" "System,Style,Commands,Help,"

# --- ergon explain picks a translated topic when there is one ----------------
E="$REPO/bin/ergon-explain"
eq "English explain is the English file"  "$(ERGON_LANG=en "$E" welcome | cmp - "$REPO/knowledge/welcome.md" && echo same)" "same"
eq "  and so is any locale without a translation" "$(LANG=fr_FR.UTF-8 "$E" welcome | cmp - "$REPO/knowledge/welcome.md" && echo same)" "same"
eq "Spanish explain welcome is the Spanish file" "$(ERGON_LANG=es "$E" welcome | cmp - "$REPO/knowledge/es/welcome.md" && echo same)" "same"
eq "a topic with no translation falls back to English" "$(ERGON_LANG=es "$E" security | cmp - "$REPO/knowledge/security.md" && echo same)" "same"
eq "every translated topic has an English original" "$(cd "$REPO/knowledge/es" && for f in *.md; do [ -f "../$f" ] || echo "$f"; done)" ""
lst=$(ERGON_LANG=es "$E" --list)
case "$lst" in "Temas (ergon explain <tema>):"*) ok "the topic list is headed in Spanish" ;; *) bad "topic list header: $(head -1 <<<"$lst")" ;; esac
case "$lst" in *"welcome "*"La página que abre"*) ok "  and welcome's gist is the Spanish one" ;; *) bad "welcome gist not Spanish: $(grep welcome <<<"$lst")" ;; esac

# --- the welcome page ---------------------------------------------------------
w=$(ERGON_LANG=es "$REPO/bin/ergon-welcome" 2>&1 </dev/null)
case "$w" in *"Bienvenida a Ergon"*"Atajos"*"Paquetes"*"Comandos"*) ok "the welcome page is Spanish, section titles included" ;; *) bad "welcome page: $(head -3 <<<"$w")" ;; esac
w=$(ERGON_LANG=en "$REPO/bin/ergon-welcome" 2>&1 </dev/null)
case "$w" in "# Welcome to Ergon"*"## Keys: "*"## Bundles: "*"## Commands: "*) ok "the English welcome page is unchanged" ;; *) bad "English welcome: $(head -3 <<<"$w")" ;; esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
