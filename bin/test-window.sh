#!/usr/bin/env bash
# ergon-window (ERGON-89): pop out and close-all, against a hyprctl stub that
# serves a fixed layout and records every dispatch. The VM suite owns the real
# compositor; this proves which windows are touched and with which Lua forms.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
mkdir -p "$T/stub"
cat > "$T/stub/hyprctl" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "activewindow -j") cat "$T/active" ;;
  "monitors -j")     echo '[{"id":0,"width":1000,"height":500,"scale":1},{"id":1,"width":3840,"height":2160,"scale":2}]' ;;
  "activeworkspace -j") echo '{"id":2}' ;;
  "clients -j")      echo '[{"address":"0xa","workspace":{"id":2}},{"address":"0xb","workspace":{"id":3}},{"address":"0xc","workspace":{"id":2}}]' ;;
  "dispatch "*)      echo "$2" >> "$T/log" ;;
esac
STUB
chmod +x "$T/stub/hyprctl"
export PATH="$T/stub:$PATH" T
W="$REPO/bin/ergon-window"
state() { echo "{\"address\":\"0xa\",\"monitor\":$1,\"floating\":$2,\"pinned\":$3}" > "$T/active"; : > "$T/log"; }

state 1 false false; "$W" pop
check "pop floats a tiled window"        grep -q 'float({ window = "address:0xa", action = "toggle" })' "$T/log"
check "pop sizes to 60% x 70% of the scaled monitor" grep -q 'resize({ window = "address:0xa", x = 1152, y = 756 })' "$T/log"
check "pop centres and pins"             bash -c 'grep -q "center(" "$1" && grep -q "pin(" "$1"' _ "$T/log"
state 0 true false; "$W" pop
check "pop leaves an already-floating window's float alone" bash -c '! grep -q "float(" "$1" && grep -q "pin(" "$1"' _ "$T/log"
state 0 true true; "$W" pop
check "pop on a popped window unpins and tiles it again" bash -c 'grep -q "pin(" "$1" && grep -q "float(" "$1" && ! grep -q resize "$1"' _ "$T/log"
echo '{}' > "$T/active"; : > "$T/log"; "$W" pop
check "pop with no window does nothing"  test ! -s "$T/log"

: > "$T/log"; "$W" close-all
check "close-all closes this workspace's windows only" bash -c 'test "$(wc -l < "$1")" = 2 && grep -q 0xa "$1" && grep -q 0xc "$1" && ! grep -q 0xb "$1"' _ "$T/log"
check "an unknown action is refused"     bash -c '! "$0" nope 2>/dev/null' "$W"

b="$REPO/hypr/common/binds.lua"
check "close-all is on a three-modifier chord" grep -q 'bind("SUPER + CTRL + SHIFT + Q".*close-all' "$b"
check "pop and cycling are bound"        bash -c 'grep -q "ergon-window pop" "$1" && grep -q "ALT + SHIFT + TAB" "$1"' _ "$b"
printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
