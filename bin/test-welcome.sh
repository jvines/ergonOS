#!/usr/bin/env bash
# ERGON-15/55: the first-login welcome shows real output, once, and never
# blocks the login it runs in.
#
#   ./bin/test-welcome.sh
#
# Seconds, no root, no session. hyprctl, glow, fuzzel, notify-send, systemctl
# and ergon-term are stubs on PATH that log their argv. hyprctl serves two canned
# binds, so `ergon keys` has something real to print; ergon-term runs what it
# is handed on a pty from script(1), which is what a terminal window is to the
# program inside it. Everything else -- ergon, ergon-bundle, ergon-explain,
# ergon-launch-tui -- is the real thing, and every section is checked against
# what the real command prints here, never against a typed string.
#
# NOT COVERED: --first-run without glow (a notification and no window). glow is
# in packages/pacman; hiding /usr/bin/glow here takes a symlink farm of /usr/bin.
# Whether the window really maps is the VM suite's (guest-desktop.sh).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
W="$REPO/bin/ergon-welcome"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
ms()  { echo $(( (${EPOCHREALTIME/./} - ${1/./}) / 1000 )); }
# until_ <seconds> <command...>: poll; true once the command is.
until_() { local end=$((SECONDS + $1)); shift; until "$@"; do [ "$SECONDS" -lt "$end" ] || return 1; sleep 0.1; done; }

mkdir -p "$T/stub" "$T/home"
LOG="$T/log"; : > "$LOG"
stub() { printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %q "$*" >> %q\n%s\n' "$1" "$LOG" "$2" > "$T/stub/$1"; chmod +x "$T/stub/$1"; }
stub hyprctl "[ -e $T/hang ] && [ \"\$1\" = binds ] && exec sleep 60
case \"\$*\" in
  'clients -j') echo '[]' ;;
  'binds -j')   echo '[{\"modmask\":64,\"key\":\"RETURN\",\"keycode\":0,\"description\":\"Terminal\"},{\"modmask\":64,\"key\":\"SPACE\",\"keycode\":0,\"description\":\"Launcher\"}]' ;;
  binds)        ;;
  'devices -j') echo '{\"keyboards\":[]}' ;;
  *)            exit 1 ;;
esac"
stub glow 't=0; [ -t 1 ] && t=1; echo "glow tty=$t" >> '"$LOG"'; cat >/dev/null'
stub notify-send 'exit 0'
stub systemctl 'exit 1'
# A picker that never closes, and (below) a display for it: bare `ergon`, and
# `ergon keys` without --print, open fuzzel when stdout is not a terminal and
# WAYLAND_DISPLAY is set (ERGON-56) -- the page, in a session. Without both, a
# page calling bare `ergon` got usage(), the same text as --help, and stayed green.
stub fuzzel 'exec sleep 60'
stub ergon-term "[ -e $T/noterm ] && exit 1
[ \"\$1\" = --class ] && shift 2
script -qec \"\$(printf '%q ' \"\$@\")\" /dev/null </dev/null >/dev/null 2>&1"

export PATH="$T/stub:$PATH" HOME="$T/home" WAYLAND_DISPLAY=wayland-ergon-test
export XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state" \
       XDG_DATA_HOME="$HOME/.local/share" XDG_CONFIG_HOME="$HOME/.config"
unset ERGON_WELCOME ERGON
STAMP="$XDG_STATE_HOME/ergon/welcome-shown"
logged() { grep -c "^$1 " "$LOG"; }
# --first-run's work happens in a background copy of itself; wait for it to end.
settled() { until_ 20 bash -c '! pgrep -f -- "$1 --first-run" >/dev/null' _ "$W"; }

echo "== the page, to a pipe"
t0=$EPOCHREALTIME; out=$("$W" </dev/null 2>&1); rc=$?; took=$(ms "$t0")
[ "$rc" = 0 ] && [ "$took" -lt 5000 ] && ok "plain markdown, exit 0, in ${took}ms" \
  || bad "exit $rc after ${took}ms"
for args in "keys --print" "bundle list" "explain --list" "--help"; do
  # shellcheck disable=SC2086 # word-split on purpose
  want=$("$REPO/bin/ergon" $args </dev/null 2>/dev/null)
  if [ -z "$want" ]; then bad "harness: ergon $args printed nothing here, so there is nothing to compare"
  elif [[ $out == *"$want"* ]]; then ok "carries what ergon $args prints ($(wc -l <<<"$want") lines)"
  else bad "does not carry what ergon $args prints"; fi
done
want=$("$REPO/bin/ergon-explain" welcome)
[[ -n $want && $out == *"$want"* ]] && ok "carries ergon explain welcome, the prose" || bad "the prose is not ergon explain welcome"
add=$(sed -n 's/^To add one: `\(.*\)`$/\1/p' <<<"$out")
[ -n "$add" ] && grep -qF "\"usage: $add\"" "$REPO/bin/ergon-bundle" \
  && ok "how to add a bundle is ergon-bundle's own usage line: $add" \
  || bad "how to add a bundle is not ergon-bundle's usage line: '${add}'"
[ ! -e "$STAMP" ] && [ "$(logged glow)$(logged fuzzel)" = 00 ] && ok "a pipe gets no glow, opens no picker, burns no stamp" \
  || bad "a pipe ran glow or fuzzel, or wrote the stamp: $(grep -E '^(glow|fuzzel) ' "$LOG" | tr '\n' ';')"

echo "== a hung section"
touch "$T/hang"
t0=$EPOCHREALTIME; out=$("$W" </dev/null 2>&1); took=$(ms "$t0")
rm -f "$T/hang"
keys=$(sed -n '/^## Keys/,/^## /p' <<<"$out")
if [[ $keys == *"No answer within"* ]] && [ "$took" -lt 8000 ] && [[ $out == *"## Commands"* ]]; then
  ok "cut off by its timeout, the rest still drawn, in ${took}ms"
else
  bad "a hung ergon keys was not cut off (${took}ms): $(tr '\n' ' ' <<<"$keys")"
fi

echo "== --first-run"
mkdir -p "${STAMP%/*}"; touch "$STAMP"; : > "$LOG"
t0=$EPOCHREALTIME; "$W" --first-run; rc=$?; took=$(ms "$t0"); settled
[ "$rc" = 0 ] && [ "$(logged ergon-term)$(logged notify-send)" = 00 ] \
  && ok "stamp present: nothing launched, nothing sent (${took}ms)" || bad "stamp present, and it still ran: $(tr '\n' ';' < "$LOG")"

rm -rf "$XDG_STATE_HOME"; : > "$LOG"
ERGON_WELCOME=0 "$W" --first-run; rc=$?; settled
[ "$rc" = 0 ] && [ ! -s "$LOG" ] && [ ! -e "$XDG_STATE_HOME" ] \
  && ok "ERGON_WELCOME=0: nothing launched, nothing written" || bad "ERGON_WELCOME=0 still acted: $(tr '\n' ';' < "$LOG")"

: > "$LOG"
t0=$EPOCHREALTIME; "$W" --first-run; rc=$?; took=$(ms "$t0")
[ "$rc" = 0 ] && [ "$took" -lt 1000 ] && ok "fresh state: returns at once (${took}ms)" || bad "fresh state: exit $rc after ${took}ms"
settled
[ "$(logged ergon-term)" = 1 ] && [ -e "$STAMP" ] && grep -q '^glow tty=1' "$LOG" && grep -q '^glow .*-p' "$LOG" \
  && [ "$(logged notify-send)" = 0 ] \
  && ok "fresh state: one window, glow with a pager on its tty, stamp written, no notification" \
  || bad "fresh state: $(tr '\n' ';' < "$LOG") stamp=$([ -e "$STAMP" ] && echo yes || echo no)"
: > "$LOG"; "$W" --first-run; settled
[ "$(logged ergon-term)" = 0 ] && ok "the second login opens nothing" || bad "the second login opened another window"

rm -rf "$XDG_STATE_HOME"; : > "$LOG"; touch "$T/noterm"
"$W" --first-run; settled
rm -f "$T/noterm"
[ ! -e "$STAMP" ] && [ "$(logged notify-send)" = 1 ] && grep -q '^notify-send .*ergon welcome' "$LOG" \
  && ok "launcher fails: stamp kept for next login, one notification naming ergon welcome" \
  || bad "launcher fails: stamp=$([ -e "$STAMP" ] && echo burned || echo kept), log: $(tr '\n' ';' < "$LOG")"

printf '\n   %d ok, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
