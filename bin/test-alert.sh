#!/usr/bin/env bash
# Exercise ergon-alert against a stub curl and a stub notify-send.
#
#   ./bin/test-alert.sh
#
# Seconds, no network, no Alertmanager. curl is a stub that records the URL it
# was given and the body it was handed on stdin, so the assertions are about
# exactly what WOULD have been posted -- including that the body is JSON, which
# is hand-built in the script and is the one part of it that a stray quote in a
# commit message could break.
#
# This test exists because the script it covers is the one that runs when
# everything else has already failed. A notifier nobody exercises is a notifier
# that is broken on the morning you need it, and it fails in the one place
# where no one is watching the output.
#
# COVERS: the posted labels and annotations, JSON validity under quotes,
# newlines and backslashes, the explicit endsAt, resolve asking before it
# speaks, the exit code when nothing took the alert, and the desktop fallback.
#
# DOES NOT COVER: that Alertmanager accepts the body, or that Telegram delivers
# it. Those were checked by hand against the live instance on chiki; there is
# no way to assert them here without sending a message to a person's phone.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
has()  { grep -qF -- "$2" "$1" 2>/dev/null; }
not()  { ! "$@"; }
eq()   { [ "$1" = "$2" ]; }
# `date -u -d "" +%s` succeeds and returns today's midnight, so any check that
# feeds an empty value to date compares two real numbers and passes -- which is
# how two assertions here reported ok with nothing posted at all.
rfc3339() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; }

mkdir -p "$T/stub" "$T/log"

# The stub curl. Two shapes reach it: a --get with repeated --data-urlencode
# that asks what is firing, and a --data-binary POST that states something.
cat > "$T/stub/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/curl"
case "$*" in
  *--data-binary*)
    cat > "$TEST_ROOT/log/body"
    : > "$TEST_ROOT/posted"
    printf '%s' "${STUB_CODE:-200}"
    exit 0 ;;
  *--get*)
    # curl is asked for the body with the status code appended after a
    # newline, and the script decides on that code -- so the stub has to
    # answer in the same shape or every query reads as unanswered.
    [ -z "${STUB_GET_UNREACHABLE:-}" ] || exit 7
    case "$*" in
      *filter=workflow=*)
        if [ -f "$TEST_ROOT/posted" ] && [ -n "${STUB_ACTIVE_AFTER:-}" ]; then
          printf '%s' "$STUB_ACTIVE_AFTER"
        else
          printf '%s' "${STUB_ACTIVE:-[]}"
        fi ;;
      *) printf '%s' "${STUB_ACTIVE_ANY:-[]}" ;;
    esac
    printf '\n%s' "${STUB_GET_CODE:-200}"
    exit 0 ;;
esac
exit 0
EOF
cat > "$T/stub/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/notify-send"
EOF
chmod +x "$T/stub"/*
export TEST_ROOT="$T" PATH="$T/stub:$PATH"

[ "$(command -v curl)" = "$T/stub/curl" ] \
  || { echo "stubs are not first on PATH; refusing to run anything"; exit 1; }
export -f rfc3339

cat > "$T/field.py" <<'EOF'
import json, sys
a = json.load(open(sys.argv[1]))
if not isinstance(a, list) or len(a) != 1:
    sys.exit("body is not a one-element array")
cur = a[0]
for k in sys.argv[2].split("."):
    cur = cur[k]
print(cur)
EOF
# No 2>&1: a failed extraction that returns its own traceback as a "value"
# makes any two field() calls compare equal, and a check that compares two of
# them then passes with nothing posted at all.
field() { python3 "$T/field.py" "$T/log/body" "$1" 2>/dev/null; }
reset() { rm -f "$T/log"/* "$T/posted"; }

A="$REPO/bin/ergon-alert"
URL=http://alertmanager.invalid:9093

# --- a plain alert ---------------------------------------------------------
reset
ERGON_ALERT_URL="$URL" "$A" --label workflow=vm --url "https://ci.invalid/runs/3" \
  ErgonCI "the weekly VM suite is red" "commit deadbeef" >"$T/out" 2>"$T/err"
rc=$?
check "an alert exits 0 when the endpoint took it" eq "$rc" 0
check "  posted to the v2 alerts endpoint" has "$T/log/curl" "$URL/api/v2/alerts"
check "  the body is JSON, and one alert"   eq "$(field labels.alertname)" "ErgonCI"
check "  carrying the severity"             eq "$(field labels.severity)" "warning"
check "  the host it happened on"           eq "$(field labels.instance)" "$(uname -n)"
check "  and the label it was given"        eq "$(field labels.workflow)" "vm"
check "  the summary is the annotation the telegram template prints" \
  eq "$(field annotations.summary)" "the weekly VM suite is red"
check "  the description comes with it"     eq "$(field annotations.description)" "commit deadbeef"
check "  the run is linked"                 eq "$(field generatorURL)" "https://ci.invalid/runs/3"
check "  and it says so on stderr as well, where a CI log will keep it" \
  has "$T/err" "ErgonCI: the weekly VM suite is red"

# endsAt is the difference between an alert and an alert that says RESOLVED
# five minutes later with nothing fixed: Alertmanager defaults a missing one to
# now + resolve_timeout.
s=$(field startsAt); e=$(field endsAt)
check "  startsAt is RFC3339 with a T and a Z, which is what Go accepts" \
  bash -c '[[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]' _ "$s"
check "  endsAt is explicit, and weeks out rather than the five-minute default" \
  bash -c '[ $(( $(date -u -d "$2" +%s) - $(date -u -d "$1" +%s) )) -gt 1209600 ]' _ "$s" "$e"

# --- a description that would break hand-built JSON ------------------------
reset
ERGON_ALERT_URL="$URL" "$A" ErgonCI 'a "quoted" summary' \
  "$(printf 'line one\nline "two" with \\ a backslash\tand a tab')" >/dev/null 2>&1
check "a quote in the summary survives as a quote" \
  eq "$(field annotations.summary)" 'a "quoted" summary'
check "  a newline, a quote and a backslash in the description keep the body parseable" \
  bash -c 'python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1"' _ "$T/log/body"
check "  and the newline is still a newline after the round trip" \
  bash -c '[ "$(printf "%s" "$1" | wc -l)" = 1 ]' _ "$(field annotations.description)"

# --- severity ---------------------------------------------------------------
reset
ERGON_ALERT_URL="$URL" "$A" --severity critical ErgonCI "the machine is on fire" >/dev/null 2>&1
check "the severity asked for is the severity sent" eq "$(field labels.severity)" "critical"

# --- resolve -----------------------------------------------------------------
reset
ERGON_ALERT_URL="$URL" STUB_ACTIVE='[]' "$A" --resolve --label workflow=vm ErgonCI >"$T/out" 2>&1
check "a resolve with nothing firing exits 0" eq "$?" 0
check "  and posts nothing at all, so a green run is silent" not test -f "$T/log/body"
check "  having asked what was firing, filtered by the same labels" \
  has "$T/log/curl" 'filter=workflow="vm"'
check "  says which state it found nothing for" has "$T/out" "nothing to resolve"

reset
ERGON_ALERT_URL="$URL" STUB_ACTIVE='[{"fingerprint":"abc","labels":{"alertname":"ErgonCI"}}]' \
  "$A" --resolve --label workflow=vm ErgonCI >/dev/null 2>&1
check "a resolve with something firing posts" test -f "$T/log/body"
check "  the same labelset, which is how Alertmanager matches it" \
  eq "$(field labels.workflow)" "vm"
# Backdated on purpose: Alertmanager compares endsAt with its OWN clock, so a
# sender a few seconds fast would post a state that is not over yet and the
# merge would keep the month-long endsAt while taking the empty annotations --
# a re-fire wearing a resolve's clothes.
check "  carrying timestamps, not the empty strings a missing body returns" \
  bash -c 'rfc3339 "$1" && rfc3339 "$2"' _ "$(field startsAt)" "$(field endsAt)"
check "  with endsAt already in the past, so a fast clock cannot un-resolve it" \
  bash -c 'rfc3339 "$1" && [ $(( $(date -u +%s) - $(date -u -d "$1" +%s) )) -ge 60 ]' _ "$(field endsAt)"
check "  and startsAt no later than endsAt, which Alertmanager requires" \
  bash -c 'rfc3339 "$1" && rfc3339 "$2" && [ $(date -u -d "$1" +%s) -le $(date -u -d "$2" +%s) ]' \
  _ "$(field startsAt)" "$(field endsAt)"
check "  carrying words, so the RESOLVED message is not blank" \
  bash -c '[ -n "$1" ]' _ "$(field annotations.summary)"

# A resolve is matched on the WHOLE label set, so one that names labels the
# alert did not fire with clears nothing at all -- and the phone goes on being
# told every six hours that a green CI is red. Both halves of that are checked:
# the call notices it resolved nothing, and it notices that something else is
# firing under the same name. That second line states a fact rather than
# accusing the caller, because the two workflows share this alertname: on a
# green push while the weekly suite is red, naming the right labels and
# matching nothing is the ORDINARY case.
reset
FIRING='[{"fingerprint":"abc","labels":{"alertname":"ErgonCI","workflow":"vm"}}]'
ERGON_ALERT_URL="$URL" STUB_ACTIVE="$FIRING" STUB_ACTIVE_AFTER="$FIRING" \
  "$A" --resolve --label workflow=vm ErgonCI >/dev/null 2>"$T/err"
check "a resolve that did not clear the alert exits non-zero" eq "$?" 1
check "  and says that is what happened" has "$T/err" "STILL firing after the resolve"

reset
ERGON_ALERT_URL="$URL" STUB_ACTIVE="$FIRING" STUB_ACTIVE_AFTER='[]' \
  "$A" --resolve --label workflow=vm ErgonCI >/dev/null 2>&1
check "a resolve that did clear it exits 0" eq "$?" 0

reset
ERGON_ALERT_URL="$URL" STUB_ACTIVE='[]' STUB_ACTIVE_ANY="$FIRING" \
  "$A" --resolve --label workflow=checks ErgonCI >"$T/out" 2>&1
rc=$?
check "a resolve that matches nothing while something else fires says so" \
  has "$T/out" "are firing under different labels"
check "  without failing the green run that asked" eq "$rc" 0

# An Alertmanager that cannot be reached is not an Alertmanager saying nothing
# is firing. Reading it as the second is how a green run leaves a phone being
# told every six hours for a month that CI is red.
reset
ERGON_ALERT_URL="$URL" STUB_GET_UNREACHABLE=1 \
  "$A" --resolve --label workflow=vm ErgonCI >"$T/out" 2>&1
rc=$?
check "a resolve that cannot ask posts the resolve anyway" test -f "$T/log/body"
check "  and says it could not ask" has "$T/out" "could not ask"
check "  rather than reporting nothing to resolve" not has "$T/out" "nothing to resolve"
check "  and does not fail the green run" eq "$rc" 0

reset
ERGON_ALERT_URL="$URL" STUB_GET_CODE=502 \
  "$A" --resolve --label workflow=vm ErgonCI >"$T/out" 2>&1
check "an error page is not an empty alert list either" test -f "$T/log/body"

# --- arguments that would be swallowed ----------------------------------------
reset
"$A" ErgonCI "the gate is red" --url https://ci.invalid/1 >/dev/null 2>"$T/err"
check "an option after the summary is an error, not a description" eq "$?" 2
check "  and nothing is posted" not test -f "$T/log/body"

reset
"$A" --label alertname=other ErgonCI "x" >/dev/null 2>"$T/err"
check "a --label that would overwrite the alertname is refused" eq "$?" 2
check "  naming the reason" has "$T/err" "set by this command"

reset
"$A" --label 'branch=fea"ture' ErgonCI "x" >/dev/null 2>"$T/err"
check "a label value that cannot survive a matcher is refused at the door" eq "$?" 2
check "  rather than firing something no resolve can match" not test -f "$T/log/body"

reset
"$A" --severity >/dev/null 2>"$T/err"
check "a missing option value exits like every other misuse" eq "$?" 2

# --- the endpoint refusing ---------------------------------------------------
reset
ERGON_ALERT_URL="$URL" STUB_CODE=500 "$A" ErgonCI "something" >/dev/null 2>"$T/err"
check "a refused alert exits non-zero" eq "$?" 1
check "  naming the endpoint and the code" has "$T/err" "refused the alert (HTTP 500)"

# --- no channel at all -------------------------------------------------------
reset
( unset ERGON_ALERT_URL WAYLAND_DISPLAY DISPLAY; "$A" ErgonCI "nowhere to go" ) >/dev/null 2>"$T/err"
check "an alert nobody could take exits non-zero" eq "$?" 1
check "  and says why, rather than looking delivered" has "$T/err" "ERGON_ALERT_URL is unset"

# --- the desktop, when there is one ------------------------------------------
reset
( unset ERGON_ALERT_URL; WAYLAND_DISPLAY=wayland-1 "$A" --severity critical \
    ErgonCI "a notification" "body" ) >/dev/null 2>&1
rc=$?
check "a desktop session gets a notification instead" has "$T/log/notify-send" "a notification"
check "  at critical urgency when the alert is critical" has "$T/log/notify-send" "-u critical"
check "  and exits 0, because something took it" eq "$rc" 0

# --- what must never be sent --------------------------------------------------
reset
"$A" 'Ergon CI; rm -rf' "summary" >/dev/null 2>"$T/err"
check "a name that is not a label value is refused" eq "$?" 2
check "  before anything is posted" not test -f "$T/log/body"

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
