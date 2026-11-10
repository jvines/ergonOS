#!/usr/bin/env bash
# ergon-term --here (ERGON-133): the new terminal opens in the focused terminal's
# directory, and in $HOME when the focused window is anything else. hyprctl is a
# stub answering `activewindow -j`; the "terminal" is a real process whose child
# sits in a real directory, because the cwd is read from /proc.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); TERM_PID=; trap '[ -n "$TERM_PID" ] && { pkill -P "$TERM_PID"; kill "$TERM_PID"; } 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
mkdir -p "$T/stub" "$T/home" "$T/work dir"
printf '#!/usr/bin/env bash\ncat "$T/active"\n' > "$T/stub/hyprctl"
# The launched terminal reports where it started.
printf '#!/usr/bin/env bash\npwd -P > "$T/started"\n' > "$T/stub/wezterm"
chmod +x "$T/stub/hyprctl" "$T/stub/wezterm"
export PATH="$T/stub:$PATH" T HOME="$T/home"
# A terminal process (pid of the bash) whose shell child is in "work dir".
WORK=$(cd "$T/work dir" && pwd -P)
bash -c 'cd "$1"; sleep 60 & wait' _ "$WORK" & TERM_PID=$!
sleep 0.3
X="$REPO/bin/ergon-term"
started() { rm -f "$T/started"; "$X" "$@" >/dev/null 2>&1; cat "$T/started" 2>/dev/null; }

printf '{"class":"org.wezfurlong.wezterm","pid":%s}\n' "$TERM_PID" > "$T/active"
check "focused terminal: opens in its shell's directory (with a space in it)" test "$(started --here)" = "$WORK"
check "  also for the floating terminal" test "$(started --here --class ergon-float)" = "$WORK"
printf '{"class":"firefox","pid":%s}\n' "$TERM_PID" > "$T/active"
check "focused browser: home" test "$(started --here)" = "$(cd "$T/home" && pwd -P)"
echo '{}' > "$T/active"
check "nothing focused: home" test "$(started --here)" = "$(cd "$T/home" && pwd -P)"
echo 'not json' > "$T/active"
check "hyprctl garbage: home, still opens" test "$(started --here)" = "$(cd "$T/home" && pwd -P)"
printf '{"class":"foot","pid":999999}\n' > "$T/active"
check "terminal with no shell child: home" test "$(started --here)" = "$(cd "$T/home" && pwd -P)"
printf '{"class":"org.wezfurlong.wezterm","pid":%s}\n' "$TERM_PID" > "$T/active"
cd /
check "without --here the directory is inherited, not looked up" test "$(started)" = "/"
check "binds.lua passes --here on both terminal keys" \
  test "$(grep -c 'ergon-term --here\|term \.\. " --here"' "$REPO/hypr/common/binds.lua")" = 2
echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
