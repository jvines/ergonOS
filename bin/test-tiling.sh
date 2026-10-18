#!/usr/bin/env bash
# ergon-tiling (ERGON-90): the cycle order, the workspace rule it sets, floating
# giving back only what it floated, and refusal of named workspaces. hyprctl is
# a stub holding one workspace's state in files; the VM suite owns the real shape.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
mkdir -p "$T/stub" "$T/run"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/stub/$1"; chmod +x "$T/stub/$1"; }
# Workspace $T/ws (id), its Hyprland layout $T/layout; clients: 0xa tiled, 0xb
# floating on its own, 0xc fullscreen, 0xd on another workspace.
stub hyprctl 'echo "$*" >> "$T/log"
case "$1" in
  activeworkspace) printf "{\"id\":%s,\"tiledLayout\":\"%s\"}" "$(cat "$T/ws")" "$(cat "$T/layout")" ;;
  clients) cat "$T/clients" ;;
  eval) sed -n "s/.*layout = \\\\\"\\([a-z]*\\)\\\\\".*/\\1/p;s/.*layout = \"\\([a-z]*\\)\".*/\\1/p" <<<"$2" > "$T/layout" ;;
  dispatch) case "$2" in
      *"action = \"on\""*"address:0xa"*) sed -i "s/\"0xa\",\"floating\":false/\"0xa\",\"floating\":true/" "$T/clients" ;;
      *"action = \"off\""*"address:0xa"*) sed -i "s/\"0xa\",\"floating\":true/\"0xa\",\"floating\":false/" "$T/clients" ;;
    esac ;;
esac'
stub notify-send 'echo "toast $*" >> "$T/log"'
export PATH="$T/stub:$PATH" T XDG_RUNTIME_DIR="$T/run"
X="$REPO/bin/ergon-tiling"
echo 3 > "$T/ws"; echo dwindle > "$T/layout"
echo '[{"address":"0xa","floating":false,"fullscreen":0,"workspace":{"id":3}},{"address":"0xb","floating":true,"fullscreen":0,"workspace":{"id":3}},{"address":"0xc","floating":false,"fullscreen":2,"workspace":{"id":3}},{"address":"0xd","floating":false,"fullscreen":0,"workspace":{"id":4}}]' > "$T/clients"

check "starts from Hyprland's own layout" test "$("$X" show)" = dwindle
check "next: master"    test "$("$X" next)" = master
check "master is set by a workspace rule for workspace 3" test "$(cat "$T/layout")" = master
check "next: scrolling" test "$("$X" next)" = scrolling
: > "$T/log"
check "next: floating"  test "$("$X" next)" = floating
check "floating floats the tiled window"        grep -q 'address:0xa' "$T/log"
check "floating leaves the user's own float, the fullscreen and the other workspace" bash -c '! grep -E "address:0x[bcd]" "$0"' "$T/log"
check "the toast names the layout"              grep -q 'toast.*synchronous:ergon-tiling.*floating' "$T/log"
check "scrolling stays the tiled layout beneath" test "$(cat "$T/layout")" = scrolling
: > "$T/log"
check "next wraps to dwindle" test "$("$X" next)" = dwindle
check "leaving floating tiles what it floated"  grep -q 'action = "off".*0xa' "$T/log"
check "leaving floating does not touch 0xb"     bash -c '! grep -q 0xb "$0"' "$T/log"
check "back goes to floating" test "$("$X" back)" = floating
check "back again: scrolling" test "$("$X" back)" = scrolling
echo -1 > "$T/ws"
check "a named workspace is refused" bash -c '! "$0" next 2>/dev/null' "$X"
check "a key is bound to it" grep -q 'ergon-tiling"' "$REPO/hypr/common/binds.lua"
printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
