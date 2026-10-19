#!/usr/bin/env bash
# ERGON-112: the keymap the initramfs gets must be able to type the LUKS
# passphrase; the desktop layout keeps the owner's choice.
#
#   ./bin/test-bootkeymap.sh
#
# Seconds, no root. loadkeys is stubbed on PATH with a keymap dump, and the
# no-loadkeys path is exercised by an empty PATH for it.
set -uo pipefail
ERGON="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)"
. "$ERGON/lib/bootkeymap.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "   ok   $1"; }
bad() { echo "   FAIL $1"; fail=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', want '$3'"; fi; }

# Stub: "latin" types +q on the letter keycodes, "cyr" types Cyrillic there,
# "gone" fails to load.
mkdir -p "$T/bin"
cat > "$T/bin/loadkeys" <<'STUB'
#!/bin/sh
case "$3" in
  gone) exit 1 ;;
  cyr) for k in 16 17 18 19 30 31 32 44 45 46; do echo "keycode  $k = cyrillic_small_letter_a +A"; done ;;
  *)   for k in 16 17 18 19 30 31 32 44 45 46; do echo "keycode  $k = +q +Q cyrillic_small_letter_a"; done ;;
esac
STUB
chmod +x "$T/bin/loadkeys"

echo "== with loadkeys"
export PATH="$T/bin:$PATH"
eq "latin plain level stays"         "$(bootkeymap_resolve latin)" latin
eq "dual-mode map (Latin plain) stays" "$(bootkeymap_resolve ru)"  ru
eq "non-Latin plain level falls back" "$(bootkeymap_resolve cyr)"  us
eq "unloadable name falls back"       "$(bootkeymap_resolve gone)" us
eq "junk name falls back"             "$(bootkeymap_resolve 'a b;rm')" us
eq "empty falls back"                 "$(bootkeymap_resolve '')"   us
BOOTKEYMAP_FALLBACK=de-latin1
eq "fallback is configurable"         "$(bootkeymap_resolve cyr)"  de-latin1
unset BOOTKEYMAP_FALLBACK

echo "== without loadkeys (static list)"
( PATH=$(printf '%s' "$PATH" | sed "s|$T/bin:||")
  command -v loadkeys >/dev/null 2>&1 && exit 0
  [ "$(bootkeymap_resolve fa)" = us ] && [ "$(bootkeymap_resolve es)" = es ] ) \
  && ok "fa falls back, es stays" || bad "static list"

echo "== the real kbd maps (if loadkeys exists)"
PATH=$(printf '%s' "$PATH" | sed "s|$T/bin:||")
if command -v loadkeys >/dev/null 2>&1 && loadkeys -u -t es >/dev/null 2>&1; then
  for k in us es la-latin1 ru ua gr il bg_bds-utf8 jp106; do
    eq "real $k stays" "$(bootkeymap_resolve $k)" "$k"
  done
  eq "real fa falls back" "$(bootkeymap_resolve fa)" us
else echo "   SKIP: no loadkeys with kbd keymaps on this host"; fi

echo "== wiring"
grep -q 'bootkeymap_resolve' "$ERGON/bin/arch-bootstrap.sh" && grep -q 'ERGON_KEYMAP' "$ERGON/bin/arch-bootstrap.sh" \
  && ok "bootstrap writes the boot keymap and records the choice" || bad "bootstrap wiring"
exit $fail
