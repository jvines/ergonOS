#!/usr/bin/env bash
# ERGON-38: ergon-record's argument handling -- the two --audio values this
# card supports, and the third ("both") it deliberately does not.
#
#   ./bin/test-record.sh
#
# wf-recorder is a stub that logs its own argv and exits 0, so each assertion
# below is "wf-recorder's argv held the right --audio=@DEFAULT_...@ token",
# not "the script did not crash". slurp fails on purpose, matching what an
# Escape'd region selection looks like.
#
# pgrep is left real, not stubbed: nothing here starts an actual wf-recorder
# process, so it correctly reports "not recording" throughout -- which means
# this only covers the START half of the toggle. The STOP half (the
# notification whose action opens the file) needs a live recording to
# interrupt and is exercised by hand, not here.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RECORD="$REPO/bin/ergon-record"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }

mkdir -p "$T/stub" "$T/home" "$T/rec"
LOG="$T/log"
cat > "$T/stub/wf-recorder" <<EOF
#!/usr/bin/env bash
printf 'wf-recorder %s\n' "\$*" >> "$LOG"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/stub/notify-send"
# Escape: slurp exits non-zero, and ergon-record must read that as "nothing
# to record", not as a failure -- the comment by its `geom=$(slurp)` line says
# so; this is what proves it.
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/stub/slurp"
chmod +x "$T/stub/wf-recorder" "$T/stub/notify-send" "$T/stub/slurp"

export PATH="$T/stub:$PATH" HOME="$T/home" ERGON_RECORD_DIR="$T/rec" \
       XDG_STATE_HOME="$T/home/.local/state"
STATEFILE="$T/home/.local/state/ergon/recording"

# Runs ergon-record "$@" from a clean slate. Sets $rc to its exit code and
# $ran to wf-recorder's own argv (empty if wf-recorder never ran).
run() {
  rm -f "$STATEFILE"; : > "$LOG"
  "$RECORD" "$@" >"$T/out" 2>&1; rc=$?
  ran=$(sed -n 's/^wf-recorder //p' "$LOG")
}

run --audio desktop
if [ "$rc" -eq 0 ] && [[ "$ran" == *"--audio=@DEFAULT_MONITOR@"* ]]; then
  ok "--audio desktop asks wf-recorder for the default sink's monitor"
else
  bad "--audio desktop: rc=$rc argv='$ran'"
fi

run --audio mic
if [ "$rc" -eq 0 ] && [[ "$ran" == *"--audio=@DEFAULT_SOURCE@"* ]]; then
  ok "--audio mic asks wf-recorder for the default source"
else
  bad "--audio mic: rc=$rc argv='$ran'"
fi

run --audio both
if [ "$rc" -ne 0 ] && [ -z "$ran" ] && grep -qi "not supported" "$T/out"; then
  ok "--audio both refuses, with a reason, and never starts wf-recorder"
else
  bad "--audio both: rc=$rc argv='$ran' out='$(cat "$T/out")'"
fi

run --audio nonsense
if [ "$rc" -ne 0 ] && [ -z "$ran" ]; then
  ok "--audio nonsense is rejected before wf-recorder ever runs"
else
  bad "--audio nonsense: rc=$rc argv='$ran'"
fi

run --bogus
if [ "$rc" -ne 0 ] && [ -z "$ran" ]; then
  ok "an unknown argument is rejected before wf-recorder ever runs"
else
  bad "--bogus: rc=$rc argv='$ran'"
fi

run region
if [ "$rc" -eq 0 ] && [ -z "$ran" ]; then
  ok "region + a cancelled slurp records nothing (not an error)"
else
  bad "region (slurp cancelled): rc=$rc argv='$ran'"
fi

run
if [ "$rc" -eq 0 ] && [[ "$ran" == *"-f "* ]] && [[ "$ran" != *"--audio"* ]]; then
  ok "plain 'ergon record' still records video with no --audio flag"
else
  bad "plain record: rc=$rc argv='$ran'"
fi

printf '\n   %d ok, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
