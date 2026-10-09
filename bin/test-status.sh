#!/usr/bin/env bash
# ergon-status: each mode shows while it is on, and only then (ERGON-32).
#
#   ./bin/test-status.sh
#
# Seconds, no compositor, no mako, no network. Every probe ergon-status makes
# -- wf-recorder's process, mako's mode, hyprsunset's temperature, the user
# manager's scopes, checkupdates, informant -- is a stub that answers from an
# environment variable, so each state can be turned on alone.
#
# COVERS: an idle session emits empty text (waybar hides the module); each mode
# alone, with its class and tooltip; neutral 6500K is not a tint; the JSON
# parses; --click stops a recording before it ends do-not-disturb; --refresh
# counts updates and unread news into the cache the bar reads.
#
# DOES NOT COVER: that hyprsunset's real IPC answers in the shape stubbed here,
# or that waybar draws the glyphs. The VM session suite owns both.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

mkdir -p "$T/stub" "$T/cache"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/stub/$1"; chmod +x "$T/stub/$1"; }
stub pgrep        '[ "${S_REC:-0}" = 1 ]'
stub makoctl      'case "$1" in mode) [ "$#" -gt 1 ] && echo "$*" >> "$S_LOG"; printf "default\n"; [ "${S_DND:-0}" = 1 ] && echo do-not-disturb ;; esac; exit 0'
stub hyprctl      '[ -n "${S_TEMP:-}" ] && echo "$S_TEMP"; exit 0'
stub systemctl    'for i in $(seq "${S_WATCH:-0}"); do echo "ergon-watch-x-$i.scope loaded active running"; done'
stub checkupdates 'for i in $(seq "${S_UPD:-0}"); do echo "pkg$i 1-1 -> 1-2"; done'
stub informant    '[ "${S_NEWS:-0}" = 0 ]'
stub ergon-record 'echo record >> "$S_LOG"'
export PATH="$T/stub:$PATH" XDG_CACHE_HOME="$T/cache" S_LOG="$T/log"
: > "$T/log"

# A cache that is fresh and empty, so no run below starts a background count.
mkdir -p "$T/cache/ergon"; printf '0 0\n' > "$T/cache/ergon/updates"
st() { env "$@" "$REPO/bin/ergon-status" --waybar; }
has() { grep -qF -- "$2" <<<"$1"; }
no_mode_r() { ! grep -q 'mode -r' "$T/log"; }

echo "== an idle session"
out=$(st)
check "emits empty text, so waybar hides the module" has "$out" '"text":""'
check "  and no classes"                               has "$out" '"class":[]'
if command -v jq >/dev/null 2>&1; then
  check "  and parses as JSON" jq -e . <<<"$out" >/dev/null
fi

echo "== each mode alone"
out=$(st S_REC=1)
check "a recording shows, classed recording" has "$out" '"recording"'
check "  and says a click stops it"          has "$out" 'click to stop'
out=$(st S_DND=1)
check "do-not-disturb shows"                 has "$out" '"dnd"'
out=$(st S_TEMP=3500)
check "a 3500K tint shows"                   has "$out" '"tint"'
check "  with its temperature"               has "$out" '3500K'
out=$(st S_TEMP=6500)
check "6500K is neutral, not a tint"         has "$out" '"text":""'
out=$(st S_WATCH=2)
check "two ergon watch runs show, counted"   has "$out" '󰔟 2'
printf '5 0\n' > "$T/cache/ergon/updates"; out=$(st)
check "pending updates show, from the cache" has "$out" '5 package update(s) pending'
printf '0 1\n' > "$T/cache/ergon/updates"; out=$(st)
check "unread news shows"                    has "$out" 'unread Arch news'
printf '0 0\n' > "$T/cache/ergon/updates"
out=$(st S_REC=1 S_DND=1 S_TEMP=3000 S_WATCH=1)
check "all at once: four classes" has "$out" '"class":["recording","dnd","tint","watch"]'
if command -v jq >/dev/null 2>&1; then
  check "  and still parses as JSON, tooltip newlines included" jq -e '.tooltip | contains("\n")' <<<"$out" >/dev/null
fi

echo "== a click"
: > "$T/log"; S_REC=1 S_DND=1 "$REPO/bin/ergon-status" --click
check "stops the recording first"            grep -qx record "$T/log"
check "  and leaves do-not-disturb alone"    no_mode_r
: > "$T/log"; S_DND=1 "$REPO/bin/ergon-status" --click
check "with no recording, ends do-not-disturb" grep -qx 'mode -r do-not-disturb' "$T/log"

echo "== the hourly count"
S_UPD=3 S_NEWS=1 "$REPO/bin/ergon-status" --refresh
check "--refresh writes updates and news to the cache" test "$(cat "$T/cache/ergon/updates")" = "3 1"

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
