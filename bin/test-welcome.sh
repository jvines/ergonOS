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

cat <<'XEOF' > /dev/null
XEOF
echo "== the notebook (ERGON-55 phase 2)"
NB="$REPO/marimo/welcome.py"
# No fact typed into it: a modifier+key string, a bundle name, a bind
# description. Everything must come from running a command.
leaks=$(grep -n -i -E 'super *\+|alt *\+|ctrl *\+|\bSUPER\b|ergon-bundle add' "$NB"; \
        for b in "$REPO"/packages/bundles/*/; do grep -n -w -F "$(basename "$b")" "$NB" | grep -v -E -i 'ergon bundle list|^[0-9]+: *#'; done)
[ -z "$leaks" ] && ok "notebook types no keybind or bundle name" || bad "typed facts in the notebook: $leaks"
for args in "keys --print" "bundle list" "doctor" "explain welcome"; do
  grep -q "\"$(sed 's/ /", "/g' <<<"$args")\"" "$NB" && ok "notebook runs ergon $args" || bad "notebook does not run ergon $args"
done

# A fake marimo that serves a page with busybox httpd on the port it is given,
# a venv for it, and a firefox that logs: the real ergon-browser and gui() run.
mkdir -p "$T/venv/bin" "$T/www"; echo ok > "$T/www/index.html"
cat > "$T/venv/bin/marimo" <<EOF
#!/usr/bin/env bash
echo "marimo \$*" >> $LOG
while [ \$# -gt 0 ]; do [ "\$1" = --port ] && port=\$2; shift; done
exec busybox httpd -f -p 127.0.0.1:\$port -h $T/www
EOF
chmod +x "$T/venv/bin/marimo"
stub firefox 'exit 0'; stub xdg-mime 'exit 1'
export PYFLEET_VENV="$T/venv" ERGON_WELCOME_PORT=29731
rm -rf "$XDG_STATE_HOME"; : > "$LOG"
t0=$EPOCHREALTIME; "$W" --first-run; rc=$?; took=$(ms "$t0"); settled
if [ "$rc" = 0 ] && [ "$took" -lt 1000 ] && grep -q '^marimo run .*--port 2973' "$LOG" && grep -q '^firefox .*127.0.0.1:2973' "$LOG" \
   && [ -e "$STAMP" ] && [ "$(logged ergon-term)" = 0 ]; then
  ok "marimo present: app-mode notebook served, browser given its URL, stamp written, no terminal window"
else bad "notebook path: rc=$rc ${took}ms stamp=$([ -e "$STAMP" ] && echo yes || echo no) log: $(tr '\n' ';' < "$LOG")"; fi
pkill -f "[b]usybox httpd -f -p 127.0.0.1:2973" 2>/dev/null

# Notebook broken (server never answers): falls back to the terminal page.
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/venv/bin/marimo"
rm -rf "$XDG_STATE_HOME"; : > "$LOG"; "$W" --first-run; settled
[ "$(logged ergon-term)" = 1 ] && [ -e "$STAMP" ] && ok "marimo dies: the terminal page opens instead, stamp written" \
  || bad "marimo dies: no fallback: $(tr '\n' ';' < "$LOG")"
rm -rf "$XDG_STATE_HOME"; : > "$LOG"; rm "$T/venv/bin/marimo"; "$W" --first-run; settled
[ "$(logged ergon-term)" = 1 ] && ok "marimo absent: the terminal page opens" || bad "marimo absent: no terminal page"
unset PYFLEET_VENV ERGON_WELCOME_PORT

"$W" --edit >/dev/null; cmp -s "$NB" "$HOME/notebooks/welcome.py" && ok "--edit copies the notebook out of the checkout" || bad "--edit did not copy"

# Proof it executes: marimo exports it to HTML in a container, with `ergon`
# stubbed so the output is a known string. Needs docker and network (pip).
if command -v docker >/dev/null && [ "${WELCOME_NO_DOCKER:-0}" != 1 ]; then
  mkdir -p "$T/ct/bin"; printf '#!/bin/sh\necho "STUB-OUT $*"\n' > "$T/ct/bin/ergon"; chmod +x "$T/ct/bin/ergon"
  if docker run --rm --label cl.jvines.owner=ergon-55 -v "$REPO/marimo:/nb:ro" -v "$T/ct:/ct" -e PATH=/ct/bin:/usr/local/bin:/usr/bin:/bin \
       python:3.12-slim sh -c 'pip install -q marimo >/dev/null 2>&1 && marimo export html /nb/welcome.py -o /ct/out.html >/ct/log 2>&1'; then
    n=$(grep -o 'STUB-OUT' "$T/ct/out.html" | wc -l)
    [ "$n" -ge 5 ] && ok "marimo export html ran the notebook; $n stubbed command outputs in it" || bad "export ran but carries $n stub outputs"
  else bad "marimo export html failed: $(tail -3 "$T/ct/log" 2>/dev/null)"; fi
else echo "   skip no docker"; fi

printf '\n   %d ok, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
