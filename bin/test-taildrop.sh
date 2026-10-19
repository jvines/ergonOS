#!/usr/bin/env bash
# ERGON-96: Taildrop send/receive, against stubs. No tailscale, no session.
#   ./bin/test-taildrop.sh
set -uo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w=$1; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
TD="$REPO/bin/ergon-taildrop"

cat > "$T/status.json" <<'J'
{"Self":{"UserID":1,"HostName":"me"},"Peer":{
 "a":{"HostName":"phone","DNSName":"phone.tail.ts.net.","UserID":1,"Online":true},
 "b":{"HostName":"asleep","DNSName":"asleep.tail.ts.net.","UserID":1,"Online":false},
 "c":{"HostName":"stranger","DNSName":"stranger.tail.ts.net.","UserID":2,"Online":true},
 "d":{"HostName":"shared","DNSName":"shared.tail.ts.net.","UserID":3,"Online":true,"CapMap":{"file-sharing-target":[]}}}}
J
got=$("$TD" peers < "$T/status.json")
check "peers: online, ours or file-sharing-target, nothing else" \
  test "$got" = "$(printf 'phone\tphone.tail.ts.net\nshared\tshared.tail.ts.net')"
check "peers: a tailnet with no peers is empty, not an error" \
  test -z "$("$TD" peers <<<'{"Self":{"UserID":1}}')"

mkdir -p "$T/stub" "$T/home/Downloads"
cat > "$T/stub/notify-send" <<S
#!/bin/sh
echo "\$*" >> "$T/notes"
S
cat > "$T/stub/fuzzel" <<'S'
#!/bin/sh
cat >/dev/null; echo phone
S
cat > "$T/stub/tailscale" <<S
#!/bin/sh
case "\$1 \$2" in
  "status --json") cat "$T/status.json" ;;
  "file cp") echo "\$*" >> "$T/cp" ;;
  "file get")
    n=\$(cat "$T/gets" 2>/dev/null || echo 0); echo \$((n+1)) > "$T/gets"
    [ \$n -eq 0 ] || exit 0
    for d; do :; done; echo x > "\$d/a.txt"; echo y > "\$d/b.txt" ;;
esac
S
chmod +x "$T/stub"/*
export HOME="$T/home" XDG_DOWNLOAD_DIR="$T/home/Downloads"

PATH="$T/stub:$PATH" "$TD" send /x/f.pdf
check "send: the picked device gets the files, by address" grep -q 'file cp .* -- /x/f.pdf phone.tail.ts.net:' "$T/cp"
check "send: announced under its own app name" grep -q '^-a ergon-taildrop Sent to phone' "$T/notes"

echo old > "$T/home/Downloads/a.txt"
( PATH="$T/stub:$PATH"; timeout 2 "$TD" receive >/dev/null 2>&1 )
check "receive: a file is saved" test -f "$T/home/Downloads/b.txt"
check "receive: a name that is taken is not overwritten" \
  test "$(cat "$T/home/Downloads/a.txt")" = old -a "$(cat "$T/home/Downloads/a-1.txt" 2>/dev/null)" = x
check "receive: one notification per file, own app name" \
  test "$(grep -c '^-a ergon-taildrop -u critical Received' "$T/notes")" = 2

# No tailscale at all: both do nothing and succeed.
mkdir -p "$T/bare"; for c in jq sort cut awk bash env; do ln -sf "$(command -v $c)" "$T/bare/$c"; done
check "tailscale absent: send exits 0 and says nothing" env PATH="$T/bare" "$TD" send f
check "tailscale absent: receive exits 0" env PATH="$T/bare" "$TD" receive
check "tailscale absent: nothing is written" test ! -e "$T/home/.config"
printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]
