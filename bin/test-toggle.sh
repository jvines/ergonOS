#!/usr/bin/env bash
# ergon-toggle and ergon-screensaver (ERGON-109, 140, 150, 151, 155): the state
# file, the Lua it renders, what is sent to the compositor, that the "on" values
# still match the themed look, and the wiring (key, menu, autostart, hypridle).
# hyprctl, pkill, pgrep and foot are stubs; the VM suite owns the real shape.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
mkdir -p "$T/stub" "$T/run" "$T/state"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/stub/$1"; chmod +x "$T/stub/$1"; }
stub hyprctl 'echo "$*" >> "$T/log"; echo ok'
stub pkill 'echo "pkill $*" >> "$T/log"'
stub pgrep 'exit 1'
stub notify-send 'true'
stub foot 'echo "foot $*" >> "$T/log"; exec sleep 30'
export PATH="$T/stub:$PATH" T XDG_RUNTIME_DIR="$T/run" XDG_STATE_HOME="$T/state" HYPRLAND_INSTANCE_SIGNATURE=x
X="$REPO/bin/ergon-toggle"; S="$REPO/bin/ergon-screensaver"
LUA="$T/state/ergon/toggles.lua"

check "a clean state lists every toggle at its default" test "$("$X" list | tr -s ' ' | tr '\n' ';')" = "animations on;gaps on;opacity on;rounding on;bar on;widescreen off;screensaver on;"
check "toggle flips on to off" test "$("$X" animations)" = "animations off"
check "it reached the compositor as Lua" grep -q 'eval hl.config({ animations = { enabled = false } })' "$T/log"
check "and is persisted" grep -qx 'animations=off' "$T/state/ergon/toggles"
check "toggles.lua carries it" grep -q 'enabled = false' "$LUA"
"$X" gaps off >/dev/null; "$X" rounding off >/dev/null; "$X" opacity off >/dev/null
check "gaps, rounding, opacity off render their own lines" bash -c 'grep -q "gaps_in = 0" "$0" && grep -q "rounding = 0" "$0" && grep -q "inactive_opacity = 1.0" "$0"' "$LUA"
check "back on sends the themed value, not zero" bash -c '"$0" gaps on >/dev/null; grep -q "gaps_in = 4, gaps_out = 8" "$1"' "$X" "$T/log"
check "and leaves no gaps line in toggles.lua" bash -c '! grep -q gaps "$0"' "$LUA"
check "widescreen is off by default and costs nothing" bash -c '! grep -q single_window "$0"' "$LUA"
check "widescreen on sets a 16:9 single-window ratio" bash -c '"$0" widescreen on >/dev/null; grep -q "layout = { single_window_aspect_ratio = { 16, 9 }" "$1"' "$X" "$LUA"
check "widescreen off returns to the default" bash -c '"$0" widescreen off >/dev/null; ! grep -q single_window "$1"' "$X" "$LUA"
: > "$T/log"
check "bar off kills waybar" bash -c '"$0" bar off >/dev/null; grep -q "pkill.*-x waybar" "$1"' "$X" "$T/log"
check "bar off is read back" test "$("$X" get bar)" = off
check "bar on starts it again" bash -c '"$0" bar on >/dev/null; grep -q "exec_raw(\"waybar\")" "$1"' "$X" "$T/log"
check "bar is not config: nothing in toggles.lua" bash -c '! grep -qi bar "$0"' "$LUA"
check "an unknown toggle is refused" bash -c '! "$0" nonsense 2>/dev/null' "$X"
check "an unknown action is refused" bash -c '! "$0" gaps maybe 2>/dev/null' "$X"
check "a toggle is applied nowhere without a session, but still saved" bash -c 'env -u HYPRLAND_INSTANCE_SIGNATURE "$0" opacity on >/dev/null && grep -qx "opacity=on" "$1"' "$X" "$T/state/ergon/toggles"

# The "on" values are copies of the themed look; this is what stops them drifting.
L="$REPO/hypr/common/looknfeel.lua.in"
check "gaps_in default matches looknfeel"  grep -q 'gaps_in = 4,' "$L"
check "gaps_out default matches looknfeel" grep -q 'gaps_out = 8,' "$L"
check "rounding default matches looknfeel" grep -q 'rounding = 4,' "$L"
check "inactive_opacity default matches looknfeel" grep -q 'inactive_opacity = 0.96,' "$L"

# Wiring.
check "the bar has a key" grep -q '"ergon-toggle bar"' "$REPO/hypr/common/binds.lua"
check "the key collides with no other"  test "$(grep -c 'SUPER + ALT + B"' "$REPO/hypr/common/binds.lua")" = 1
check "hyprland.lua loads toggles.lua"  grep -q 'ergon/toggles.lua' "$REPO/hypr/hyprland.lua"
check "autostart honours bar=off"       grep -q 'bar=off' "$REPO/hypr/common/autostart.lua"
check "ergon-theme honours the bar toggle" grep -q 'ergon-toggle" get bar' "$REPO/bin/ergon-theme"
check "the menu reaches the toggles"    bash -c '"$0" --dump | grep -q "^    widescreen"' "$REPO/bin/ergon-menu"
check "hypridle starts the screensaver" grep -q 'on-timeout = ergon-screensaver start' "$REPO/hypr/hypridle.conf"
check "and stops it on input"           grep -q 'on-resume  = ergon-screensaver stop' "$REPO/hypr/hypridle.conf"

# Screensaver.
check "a frame draws block digits"      bash -c '"$0" frame 12:34 1 1 | grep -q "██"' "$S"
check "a frame places itself by column and row" bash -c '"$0" frame 00:00 7 4 | grep -q "\[4;7H"' "$S"
: > "$T/log"
"$S" start
sleep 0.3
check "start opens a fullscreen foot with the screensaver app-id" grep -q 'foot --fullscreen --app-id=ergon-screensaver' "$T/log"
"$S" stop
check "stop forgets it" test ! -e "$T/run/ergon-screensaver.pid"
"$X" screensaver off >/dev/null; : > "$T/log"
"$S" start; sleep 0.2
check "start does nothing when the screensaver is toggled off" test ! -s "$T/log"
printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
