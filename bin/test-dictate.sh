#!/usr/bin/env bash
# ERGON-100: ergon-dictate's model management and its toggle state machine.
#
#   ./bin/test-dictate.sh
#
# Seconds, no audio, no compositor, no network. pw-record, whisper-cli, wtype,
# wl-copy, fuzzel, notify-send and ergon-status are stubs; the download is curl
# against a file:// "mirror" with a catalog of small fake models whose sha256
# are computed here, so a corrupted download is a real hash mismatch.
#
# COVERS: model list/get/use/rm/verify; a corrupted download is refused and
# leaves nothing; an interrupted download resumes; start with no model
# notifies and opens the picker instead of recording; toggle start -> stop ->
# typed text; the language reaching whisper-cli (auto, a code, .en forced to
# en); wtype failing falls back to the clipboard; a too-short recording is
# dropped; the maximum length stops a forgotten recording; a second toggle
# while transcribing does not start another; the caller's pipe is not held.
#
# DOES NOT COVER: that pw-record on PipeWire writes a 16 kHz wav (the real run
# of whisper-cli on speech was done once, by hand, in an Arch container), that
# wtype types into a real window, or the fuzzel picker's layout. The VM does.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }

mkdir -p "$T/stub" "$T/mirror" "$T/rt" "$T/data"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/stub/$1"; chmod +x "$T/stub/$1"; }
stub notify-send 'printf "%s\n" "$*" >> "$S_DIR/notes"'
stub ergon-status 'exit 0'
stub fuzzel 'echo picker >> "$S_DIR/picker"; exit 1'
stub pw-record 'trap "exit 0" INT
echo recorder >> "$S_DIR/recorded"
f="${@: -1}"
head -c "${S_BYTES:-40000}" /dev/zero > "$f"
while :; do sleep 0.1; done'
stub whisper-cli 'printf "%s\n" "$*" >> "$S_DIR/whisper-args"
[ -z "${S_SLOW:-}" ] || sleep "$S_SLOW"
[ -z "${S_WFAIL:-}" ] || { echo "boom" >&2; exit 1; }
printf " %s\n[BLANK_AUDIO]\n" "${S_TEXT:-Hello there.}"'
stub wtype '[ -z "${S_NOTYPE:-}" ] || exit 1
printf "%s" "$2" > "$S_DIR/typed"'
stub wl-copy 'cat > "$S_DIR/clip"; [ -z "${S_LINGER:-}" ] || sleep "$S_LINGER"'
export PATH="$T/stub:$PATH" S_DIR="$T" XDG_RUNTIME_DIR="$T/rt" ERGON_WHISPER_DIR="$T/data" \
       ERGON_DICTATE_QUIET=1 ERGON_WHISPER_BASE="file://$T/mirror" ERGON_DICTATE_THREADS=3
D="$REPO/bin/ergon-dictate"

# ---- a fake catalog: one good model, one whose mirror copy is corrupted ----
head -c 300000 /dev/urandom > "$T/mirror/ggml-tiny.en.bin"
head -c 200000 /dev/urandom > "$T/mirror/ggml-base.bin"
head -c 150000 /dev/urandom > "$T/mirror/ggml-small.bin"
h() { sha256sum "$1" | awk '{print $1}'; }
{
  echo "tiny.en 300000 $(h "$T/mirror/ggml-tiny.en.bin")"
  echo "base 200000 $(h "$T/mirror/ggml-base.bin")"
  echo "small 150000 $(h "$T/mirror/ggml-small.bin")"
} > "$T/catalog"
export ERGON_WHISPER_CATALOG="$T/catalog"
# The mirror's small is then damaged: same name, same size, other bytes.
head -c 150000 /dev/urandom > "$T/mirror/ggml-small.bin"

echo "== models"
out=$("$D" model list)
check "list names each model with its size and language kind" bash -c '
  grep -E "^tiny.en +[0-9]+ MB +English only" <<<"$1" && grep -E "^base +[0-9]+ MB +multilingual" <<<"$1"' _ "$out" >/dev/null
check "nothing is installed or active at first" bash -c '! grep -q installed <<<"$1"' _ "$out"

"$D" model get tiny.en >/dev/null 2>&1
check "get installs it, byte for byte" cmp -s "$T/mirror/ggml-tiny.en.bin" "$T/data/ggml-tiny.en.bin"
check "the first model becomes the active one" test "$(cat "$T/data/active")" = tiny.en
check "no .part is left behind" test -z "$(ls "$T"/data/*.part 2>/dev/null)"
check "list marks it installed, active" has "$("$D" model list)" "installed, active"

err=$("$D" model get small 2>&1); rc=$?
check "a corrupted download is refused" test "$rc" -ne 0
check "... saying why" has "$err" sha256
check "... and leaves neither a model nor a .part" test ! -e "$T/data/ggml-small.bin" -a ! -e "$T/data/ggml-small.bin.part"

# An interrupted download: half the bytes are there already.
head -c 90000 "$T/mirror/ggml-base.bin" > "$T/data/ggml-base.bin.part"
"$D" model get base >/dev/null 2>&1
check "an interrupted download resumes and verifies" cmp -s "$T/mirror/ggml-base.bin" "$T/data/ggml-base.bin"
check "a model already there is not downloaded again" has "$("$D" model get base)" "already installed"

check "an unknown model is refused" bash -c '! "$1" model get nope 2>/dev/null' _ "$D"
check "use refuses a model that is not installed" bash -c '! "$1" model use small 2>/dev/null' _ "$D"
"$D" model use base >/dev/null
check "use selects an installed one" test "$(cat "$T/data/active")" = base

check "verify passes intact models" bash -c '"$1" model verify >/dev/null' _ "$D"
printf x >> "$T/data/ggml-base.bin"
check "verify catches a model that changed on disk" bash -c '! "$1" model verify base >/dev/null' _ "$D"
"$D" model rm base >/dev/null
check "rm removes it and, being active, clears the selection" test ! -e "$T/data/ggml-base.bin" -a ! -e "$T/data/active"

echo "== language"
check "default is auto" test "$("$D" lang)" = auto
"$D" lang ES >/dev/null
check "a code is stored lower-cased" test "$("$D" lang)" = es
check "nonsense is refused" bash -c '! "$1" lang "e n;x" 2>/dev/null' _ "$D"

echo "== no model: start opens the picker, does not record"
rm -f "$T/data/active" "$T/notes" "$T/recorded" "$T/picker"
"$D" start 2>/dev/null; rc=$?
for _ in $(seq 40); do [ -e "$T/picker" ] && break; sleep 0.05; done
check "start fails" test "$rc" -ne 0
check "it tells the person" has "$(cat "$T/notes")" "no speech model"
check "the picker opened" test -e "$T/picker"
check "nothing was recorded" test ! -e "$T/recorded"
check "status is idle" test "$("$D" status)" = idle

# ---- the state machine -----------------------------------------------------
"$D" model use tiny.en >/dev/null
wait_idle() { for _ in $(seq 100); do [ "$("$D" status 2>/dev/null)" = idle ] && return 0; sleep 0.1; done; return 1; }
reset() { rm -f "$T/notes" "$T/recorded" "$T/whisper-args" "$T/typed" "$T/clip"; }

echo "== toggle: record, stop, type"
reset
"$D" lang auto >/dev/null
"$D" toggle; rc=$?
check "the first toggle starts recording" test "$rc" -eq 0 -a "$("$D" status)" = recording
"$D" toggle
wait_idle
check "the second stops it and the text is typed, cleaned" test "$(cat "$T/typed" 2>/dev/null)" = "Hello there."
args=$(cat "$T/whisper-args")
check "whisper-cli gets the model, no timestamps, threads" bash -c 'grep -q -- "-m $1/ggml-tiny.en.bin" <<<"$2" && grep -q -- " -nt " <<<"$2" && grep -q -- "-t 3" <<<"$2"' _ "$T/data" "$args"
check "an English-only model is always told en" has "$args" "-l en"
check "the recording is deleted afterwards" test ! -e "$T/rt/ergon-dictate-$(id -u)/rec.wav"
check "lock and state are released" test "$("$D" status)" = idle

echo "== language reaches whisper-cli"
# A multilingual model: reuse the catalog entry, installed by hand.
cp "$T/data/ggml-tiny.en.bin" "$T/data/ggml-base.bin"; "$D" model use base >/dev/null
reset; "$D" lang auto >/dev/null; "$D" toggle; "$D" toggle; wait_idle
check "auto" has "$(cat "$T/whisper-args")" "-l auto"
reset; "$D" lang es >/dev/null; "$D" toggle; "$D" toggle; wait_idle
check "a chosen language" has "$(cat "$T/whisper-args")" "-l es"

echo "== failures and edges"
reset; S_NOTYPE=1 "$D" toggle; S_NOTYPE=1 "$D" toggle; wait_idle
check "wtype failing leaves the text on the clipboard" test "$(cat "$T/clip" 2>/dev/null)" = "Hello there."
check "... and says so" has "$(cat "$T/notes")" "clipboard"

reset; S_BYTES=100 "$D" toggle; "$D" toggle; wait_idle
check "a mis-press is dropped without calling whisper" test ! -e "$T/whisper-args"
check "... and says so" has "$(cat "$T/notes")" "nothing recorded"

reset; S_TEXT="[BLANK_AUDIO]" "$D" toggle; "$D" toggle; wait_idle
check "silence types nothing" test ! -e "$T/typed"

reset; S_WFAIL=1 "$D" toggle; "$D" toggle; wait_idle
check "a failing whisper-cli is reported, not typed" bash -c 'grep -q "whisper-cli failed" "$1/notes" && [ ! -e "$1/typed" ]' _ "$T"

reset; ERGON_DICTATE_MAX=1 "$D" toggle
sleep 3.5; wait_idle
check "a forgotten recording stops at the maximum and is typed" test "$(cat "$T/typed" 2>/dev/null)" = "Hello there."

reset; S_SLOW=2 "$D" toggle; "$D" toggle
sleep 0.6
check "while transcribing the status says so" test "$("$D" status)" = transcribing
"$D" toggle
check "a toggle then does not start a second recording" test "$(wc -l < "$T/recorded")" -eq 1
wait_idle

echo "== the caller's pipe"
reset
start=$SECONDS
S_LINGER=6 S_NOTYPE=1 timeout 15 bash -c '{ "$1" toggle; sleep 0.3; "$1" toggle; sleep 1.5; } | cat' _ "$D" >/dev/null
check "a lingering wl-copy does not hold the caller's stdout" test $((SECONDS - start)) -lt 5
wait_idle

echo
printf '   %d ok, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
