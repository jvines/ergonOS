#!/usr/bin/env bash
# ergon-db: add/list/rm against a stub docker (ERGON-114).
#
#   ./bin/test-db.sh
#
# Seconds, no root, no real docker. COVERS: pinned images, 127.0.0.1-only port
# publishing, the label and named volume on every container, list and rm only
# seeing labelled containers, rm needing the typed name and keeping the volume,
# --purge asking a second time. DOES NOT COVER: real images or the daemon.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

mkdir -p "$T/stub"
# State: $T/state holds one labelled container name per line; $T/other is a
# container this command must never touch.
cat > "$T/stub/docker" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$S_LOG"
case "$1" in
  info) exit 0 ;;
  run) n=""; while [ $# -gt 0 ]; do [ "$1" = --name ] && n="$2"; shift; done; echo "$n" >> "$S_STATE"; echo cid ;;
  ps) while read -r n; do printf '%s\tx\tUp 1s\t127.0.0.1:1->1/tcp\n' "$n"; done < "$S_STATE" | { if [[ "$*" == *Names* ]]; then cut -f1; else cat; fi; } ;;
  inspect) n="${@: -1}"; echo "${n#ergon-}" ;;
  rm) n="${@: -1}"; grep -vx "$n" "$S_STATE" > "$S_STATE.new"; mv "$S_STATE.new" "$S_STATE" ;;
  volume) [ "$2" = inspect ] && exit 1; exit 0 ;;
esac
S
chmod +x "$T/stub/docker"
export PATH="$T/stub:$PATH" S_LOG="$T/log" S_STATE="$T/state"
: > "$T/log"; : > "$T/state"
D="$REPO/bin/ergon-db"

for e in postgres mysql mariadb redis mongodb mssql; do
  out=$("$D" add "$e" 2>&1); rc=$?
  check "add $e succeeds and prints a connection string" bash -c '[ $1 = 0 ] && grep -q "connect:.*127.0.0.1" <<<"$2"' _ "$rc" "$out"
  line=$(grep "^run .*--name ergon-$e " "$T/log")
  check "$e publishes on 127.0.0.1 only" bash -c 'grep -qE -- "-p 127\.0\.0\.1:[0-9]+:[0-9]+" <<<"$1" && ! grep -qE -- "-p [0-9]+:|0\.0\.0\.0" <<<"$1"' _ "$line"
  check "$e is labelled, restarting and on a named volume" bash -c 'grep -q -- "--label ergon.db=$2" <<<"$1" && grep -q -- "--restart unless-stopped" <<<"$1" && grep -q -- "-v ergon-$2-data:" <<<"$1"' _ "$line" "$e"
done
check "images are pinned to a version" bash -c '! grep "^run" "$1" | grep -E " (postgres|mysql|mariadb|redis|mongo)( |$)"' _ "$T/log"
check "postgres does not use trust auth" bash -c '! grep -q trust "$1"' _ "$T/log"
check "a second add of the same engine is refused" bash -c '! "$1" add redis >/dev/null 2>&1' _ "$D"
check "an unknown engine is refused" bash -c '! "$1" add oracle >/dev/null 2>&1' _ "$D"
check "list shows the six" test "$("$D" list | wc -l)" -eq 6

: > "$T/log"
printf 'wrong\n' | "$D" rm redis >/dev/null 2>&1
check "rm with a wrong confirmation aborts and removes nothing" bash -c '! grep -q "^rm" "$1" && grep -qx ergon-redis "$2"' _ "$T/log" "$T/state"
check "rm refuses a container that is not ours" bash -c '! echo ergon-redis | "$1" rm nginx >/dev/null 2>&1 && ! grep -q "^rm" "$2"' _ "$D" "$T/log"
printf 'ergon-redis\n' | "$D" rm redis >/dev/null 2>&1
check "rm with the typed name removes the container only" bash -c 'grep -q "^rm -f ergon-redis" "$1" && ! grep -q "^volume rm" "$1"' _ "$T/log"
printf 'ergon-mysql\nwrong\n' | "$D" rm mysql --purge >/dev/null 2>&1
check "--purge with a wrong second answer keeps the volume" bash -c 'grep -q "^rm -f ergon-mysql" "$1" && ! grep -q "^volume rm" "$1"' _ "$T/log"
printf 'ergon-postgres\nergon-postgres-data\n' | "$D" rm postgres --purge >/dev/null 2>&1
check "--purge with both confirmations deletes exactly that volume" grep -q "^volume rm ergon-postgres-data" "$T/log"
check "rm never touches an unlabelled name (no kill/stop/prune)" bash -c '! grep -qE "^(kill|stop|prune|system)" "$1"' _ "$T/log"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]
