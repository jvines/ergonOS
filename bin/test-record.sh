#!/usr/bin/env bash
# ERGON-38: ergon-record's argument handling (all three --audio values, now
# that "both" is built rather than refused) and the STOP half of the toggle --
# the notification action mako actually invokes, and that it frees the
# PipeWire mix sink --audio both built.
#
#   ./bin/test-record.sh
#
# wf-recorder is a stub that logs its own argv and exits 0, so each START
# assertion below is "wf-recorder's argv held the right --audio token", not
# "the script did not crash". slurp fails on purpose, matching what an
# Escape'd region selection looks like -- the comment by its `geom=$(slurp)`
# line in ergon-record says so; this is what proves it. pactl is a stub too:
# it logs its argv and hands back a fresh fake module id per load-module
# call, the way a real one prints the index of the module it just loaded.
#
# pgrep and pkill are ALSO stubs, gated on a marker file this script alone
# controls ($T/recording) -- the real ones enumerate actual processes on the
# box regardless of $PATH, so leaving them real meant a run of this file sent
# a genuine SIGINT to anything already named wf-recorder, recording or not.
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
PACTLLOG="$T/pactl-log"
PACTLCOUNTER="$T/pactl-counter"
cat > "$T/stub/wf-recorder" <<EOF
#!/usr/bin/env bash
printf 'wf-recorder %s\n' "\$*" >> "$LOG"
EOF
cat > "$T/stub/mpv" <<EOF
#!/usr/bin/env bash
printf 'mpv %s\n' "\$*" >> "$LOG"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/stub/notify-send"
# Escape: slurp exits non-zero, and ergon-record must read that as "nothing
# to record", not as a failure.
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/stub/slurp"
# pgrep/pkill: "recording" is whatever this test says it is, via $T/recording
# -- never the real process table.
cat > "$T/stub/pgrep" <<EOF
#!/usr/bin/env bash
[ -e "$T/recording" ]
EOF
cat > "$T/stub/pkill" <<EOF
#!/usr/bin/env bash
printf 'pkill %s\n' "\$*" >> "$LOG"
rm -f "$T/recording"
EOF
cat > "$T/stub/pactl" <<EOF
#!/usr/bin/env bash
printf 'pactl %s\n' "\$*" >> "$PACTLLOG"
if [ "\$1" = load-module ]; then
  n=\$(( \$(cat "$PACTLCOUNTER" 2>/dev/null || echo 0) + 1 ))
  echo "\$n" > "$PACTLCOUNTER"
  echo "\$n"
fi
EOF
chmod +x "$T/stub/wf-recorder" "$T/stub/mpv" "$T/stub/notify-send" \
         "$T/stub/slurp" "$T/stub/pgrep" "$T/stub/pkill" "$T/stub/pactl"

export PATH="$T/stub:$PATH" HOME="$T/home" ERGON_RECORD_DIR="$T/rec" \
       XDG_STATE_HOME="$T/home/.local/state"
STATEDIR="$T/home/.local/state/ergon"
STATEFILE="$STATEDIR/recording"

# Runs ergon-record "$@" from a clean slate, START side: not recording, no
# pactl history yet. Sets $rc to its exit code and $ran to wf-recorder's own
# argv (empty if wf-recorder never ran).
run() {
  rm -f "$STATEFILE" "$T/recording"; : > "$LOG"; : > "$PACTLLOG"
  rm -f "$PACTLCOUNTER"
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
if [ "$rc" -eq 0 ] && [[ "$ran" == *"--audio=ergon-rec.monitor"* ]] \
   && grep -qx "pactl load-module module-null-sink sink_name=ergon-rec" "$PACTLLOG" \
   && grep -qx "pactl load-module module-loopback source=@DEFAULT_MONITOR@ sink=ergon-rec" "$PACTLLOG" \
   && grep -qx "pactl load-module module-loopback source=@DEFAULT_SOURCE@ sink=ergon-rec" "$PACTLLOG"; then
  ok "--audio both builds a PipeWire mix sink and loops the monitor and mic into it"
else
  bad "--audio both: rc=$rc argv='$ran' pactl='$(cat "$PACTLLOG")'"
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

# --- stop path ---------------------------------------------------------
# mako's own left-click binding invokes only the action keyed "default"
# (mako 1.11.0's config.c sets that as the default left-button binding's
# action_name, and notification.c's try_invoke_action matches a key exactly,
# no fallback or menu); this repo's mako config sets no on-button-left
# override and draws no buttons of its own. A stub notify-send that prints
# "default" is what a real click on this notification does.
printf '#!/usr/bin/env bash\necho default\n' > "$T/stub/notify-send"
chmod +x "$T/stub/notify-send"

: > "$T/recording"
mkdir -p "$STATEDIR"
recorded="$T/rec/fake.mp4"; : > "$recorded"
printf '%s' "$recorded" > "$STATEFILE"
# As if --audio both were running when this recording was stopped.
printf '21\n22\n23\n' > "$STATEDIR/audio-modules"
: > "$LOG"; : > "$PACTLLOG"
"$RECORD" >"$T/out" 2>&1; rc=$?
# The open action is backgrounded and disowned on purpose -- neither the
# keybind nor someone typing the command by hand should block on the
# notification -- so poll briefly for mpv's log line instead of assuming.
for _ in $(seq 1 50); do
  grep -q '^mpv ' "$LOG" 2>/dev/null && break
  sleep 0.1
done
if [ "$rc" -eq 0 ] \
   && grep -qx "pkill -INT -x wf-recorder" "$LOG" \
   && grep -qF "mpv $recorded" "$LOG" \
   && grep -qx "pactl unload-module 21" "$PACTLLOG" \
   && grep -qx "pactl unload-module 22" "$PACTLLOG" \
   && grep -qx "pactl unload-module 23" "$PACTLLOG" \
   && [ ! -f "$STATEDIR/audio-modules" ]; then
  ok "stop: the action mako's click actually invokes opens the file in mpv, and the mix sink is freed"
else
  bad "stop: rc=$rc log='$(cat "$LOG")' pactl='$(cat "$PACTLLOG")'"
fi

printf '\n   %d ok, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
