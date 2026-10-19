#!/usr/bin/env bash
# ERGON-107: ergon-remind's time parsing, list, clear and rejection, against stub
# systemd-run / systemctl / notify-send. The real user manager is a VM check.
#   ./bin/test-remind.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
R="$REPO/bin/ergon-remind"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
has() { if grep -qE -- "$2" <<<"$3"; then echo "ok   $1"; else echo "FAIL $1: [$3] !~ $2"; fail=1; fi; }

mkdir -p "$T/bin" "$T/state"
cat > "$T/bin/systemd-run" <<S
#!/bin/bash
echo "\$*" >> "$T/runs"
for a; do case \$a in --unit=*) u=\${a#--unit=};; --description=*) d=\${a#--description=};; --on-calendar=*) c=\${a#--on-calendar=};; esac; done
printf '%s\n%s\n' "\$d" "\$(date -d "\$c" +%s)" > "$T/state/\$u.timer"
S
cat > "$T/bin/systemctl" <<S
#!/bin/bash
case "\$2" in
  list-timers) for f in "$T"/state/*.timer; do [ -e "\$f" ] || continue
      jq -n --arg u "\$(basename "\$f")" --argjson n "\$(( \$(sed -n 2p "\$f") * 1000000 ))" '{unit:\$u,next:\$n}'; done | jq -s . ;;
  show) sed -n 1p "$T/state/\${@: -1}" ;;
  stop) shift 2; for u; do rm -f "$T/state/\$u"; done ;;
esac
S
printf '#!/bin/sh\nprintf "%%s|" "$@" >> "%s/notes"; echo >> "%s/notes"\n' "$T" "$T" > "$T/bin/notify-send"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
run() { "$R" "$@" 2>&1; }

out=$(run 25m "take flats"); has "duration accepted" '^reminder 1 at .*: take flats$' "$out"
has "the timer carries the message and a calendar time" 'on-calendar=20[0-9-]+ [0-9:]+ .*AccuracySec=1s' "$(cat "$T/runs")"
has "the unit is named ergon-remind-1" '--unit=ergon-remind-1 ' "$(cat "$T/runs")"
want=$(date -d '+25 min' +%s); got=$(sed -n 2p "$T/state/ergon-remind-1.timer")
chk "25m lands 25 minutes out" "$(( (got - want) / 3 ))" 0
run 1h30m "b" >/dev/null; d=$(( $(sed -n 2p "$T/state/ergon-remind-2.timer") - $(date +%s) ))
chk "1h30m is 5400s" "$(( (d + 2) / 5 ))" "$(( 5400 / 5 ))"
run 10 "bare number" >/dev/null; d=$(( $(sed -n 2p "$T/state/ergon-remind-3.timer") - $(date +%s) ))
chk "a bare number is minutes" "$(( (d + 2) / 5 ))" "$(( 600 / 5 ))"
run "tomorrow 9:00" "dated" >/dev/null
chk "date -d phrases work" "$(date -d "@$(sed -n 2p "$T/state/ergon-remind-4.timer")" +%H:%M)" "09:00"

past=$(date -d '-2 min' +%H:%M)
run "$past" "wrapped" >/dev/null
d=$(( $(sed -n 2p "$T/state/ergon-remind-5.timer") - $(date +%s) ))
chk "a clock time already past means tomorrow" "$(( d > 80000 && d < 87000 ))" 1

n=$(ls "$T/state" | wc -l)
out=$(run yesterday "x"); rc=$?; has "past time rejected" 'not in the future' "$out"
out=$(run "yesterday 10:00" "x"); has "explicit past day rejected" 'not in the future' "$out"
out=$(run 0s "x"); has "zero duration rejected" 'not in the future' "$out"
out=$(run blorp "x"); has "gibberish rejected with a hint" "cannot read 'blorp'" "$out"
out=$(run 25m); has "missing message rejected" 'need a time and a message' "$out"
chk "rejections create nothing" "$(ls "$T/state" | wc -l)" "$n"

out=$(run list); has "list shows id, time, message" $'^1\t[A-Z][a-z]{2} [0-9:]+\ttake flats' "$out"
chk "list has one line per reminder" "$(wc -l <<<"$out")" 5
run clear 2 >/dev/null; test ! -e "$T/state/ergon-remind-2.timer"; chk "clear <id> removes just that one" "$?:$(ls "$T/state" | wc -l)" "0:4"
out=$(run clear 99); has "clear of an unknown id is an error" 'no pending reminder with id' "$out"
run clear all >/dev/null; chk "clear all empties it" "$(ls "$T/state" | wc -l)" 0
chk "list when empty" "$(run list)" "no reminders pending"

: > "$T/notes"
"$R" fire 0 "boil eggs"; has "firing is a critical, non-expiring ergon-remind notification" '^-a\|ergon-remind\|-u\|critical\|-t\|0\|Reminder\|boil eggs\|$' "$(cat "$T/notes")"
run --alert 5m "alerted" >/dev/null; has "--alert reaches the fired command" 'ergon-remind fire 1 alerted' "$(tail -n1 "$T/runs")"

# Nothing may be left holding the caller's stdout: reading it to EOF must return.
timeout 10 bash -c '"$0" 5s "pipe" | cat >/dev/null' "$R"; chk "stdout is released (no lingering child)" "$?" 0
exit $fail
