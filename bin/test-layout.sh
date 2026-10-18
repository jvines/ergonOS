#!/usr/bin/env bash
# ergon-layout (ERGON-85): cycling, the OSD, and the bar showing a layout only
# when there is more than one. hyprctl is a stub holding keyboard state in a
# file, so no compositor is needed; the VM suite owns the real hyprctl shape.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
mkdir -p "$T/stub"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/stub/$1"; chmod +x "$T/stub/$1"; }
# State: $T/layouts and $T/idx. Two keyboards, the second one main.
stub hyprctl 'case "$1" in
  -j) l=$(cat "$T/layouts"); i=$(cat "$T/idx"); IFS=, read -ra c <<<"$l"
      printf "{\"keyboards\":[{\"main\":false,\"layout\":\"%s\",\"active_layout_index\":%s,\"active_keymap\":\"x\"},{\"main\":true,\"layout\":\"%s\",\"active_layout_index\":%s,\"active_keymap\":\"Keymap %s\"}]}" "$l" "$i" "$l" "$i" "${c[$i]}" ;;
  switchxkblayout) echo "$*" >> "$T/log"; n=$(tr , "\n" < "$T/layouts" | wc -l); echo $(( ($(cat "$T/idx") + 1) % n )) > "$T/idx" ;;
esac'
stub notify-send 'echo "toast $*" >> "$T/log"'
stub pkill 'echo "pkill $*" >> "$T/log"'
export PATH="$T/stub:$PATH" T
L="$REPO/bin/ergon-layout"
set_state() { printf '%s\n' "$1" > "$T/layouts"; echo 0 > "$T/idx"; : > "$T/log"; }

set_state us
check "one layout: the bar module is empty"  test "$("$L" --waybar | jq -r .text)" = ""
check "one layout: cycling refuses, switches nothing" bash -c '! "$0" cycle 2>/dev/null && ! grep -q switchxkblayout "$1"' "$L" "$T/log"

set_state us,es
check "two layouts: the bar shows the active one" test "$("$L" --waybar | jq -r .text)" = "󰌌 us"
out=$("$L" cycle)
check "cycle switches every keyboard"       grep -qx 'switchxkblayout all next' "$T/log"
check "cycle reports the new layout"         test "$out" = es
check "cycle shows a replacing toast with it" grep -q 'synchronous:ergon-layout.*es' "$T/log"
check "cycle tells the bar"                  grep -qx 'pkill -RTMIN+9 -x waybar' "$T/log"
check "bar follows to es"                    test "$("$L" --waybar | jq -r .text)" = "󰌌 es"
"$L" cycle >/dev/null
check "cycle wraps to us"                    test "$("$L" --waybar | jq -r .text)" = "󰌌 us"

_mod=$(sed -E 's|^[[:space:]]*//.*||' "$REPO/waybar/config.jsonc" | jq -c '."custom/layout"' 2>/dev/null)
check "waybar's custom/layout listens on the signal sent" test "$(jq -r .signal <<<"$_mod")" = "$(sed -n 's/^SIGNAL=\([0-9]*\)$/\1/p' "$L")"
check "a key is bound to it"                 grep -q 'ergon-layout"' "$REPO/hypr/common/binds.lua"
printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
