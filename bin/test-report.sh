#!/usr/bin/env bash
# Exercise ergon-report's scrubber against a fixture full of FAKE secrets.
#
#   ./bin/test-report.sh
#
# Asserts both directions: every planted secret is gone from the output, and
# the diagnostic text around it survives (a scrubber that deletes the line
# passes the first and ruins the report). Then runs the whole report and checks
# the header, the output path, and that the planted values are absent.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '   FAIL %s\n' "$*"; }

export ERGON_SCRUB_USER=alicewonder ERGON_SCRUB_HOST=wonderbox
cat > "$T/in.txt" <<'FIX'
token ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 pushed
glpat-abcdefghij0123456789 and AKIAIOSFODNN7EXAMPLE and xoxb-1234-abcdefgh
curl -H "Authorization: Bearer abcdef0123456789.zzz" https://x.test
jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.sig_nature
password = hunter2hunter2
WIFI_PSK="correct horse battery staple"
api_key: 8f9e7d6c5b4a
git clone https://bob:s3cretpw@forge.test/r.git
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaFByaXZhdGVLZXlGYWtl
-----END OPENSSH PRIVATE KEY-----
wlan0: associated with SSID="CafeNetFake" on 192.168.7.42
nmcli connected to 'HomeWifiFake' gw 10.0.0.1 lo 127.0.0.1
link/ether de:ad:be:ef:12:34 fe80::1c2d:3eff:fe4f:5a6b%wlan0 2001:db8::1
machine-id 0123456789abcdef0123456789abcdef
/home/alicewonder/projects/x opened on wonderbox by alicewonder
Failed to start foo.service at 02:34:56 version 6.12.1 kernel
FIX
"$REPO/bin/ergon-report" --scrub < "$T/in.txt" > "$T/out.txt"

gone() { ! grep -qF -- "$2" "$T/out.txt" && ok "$1 removed" || bad "$1 leaked"; }
kept() { grep -qF -- "$2" "$T/out.txt" && ok "$1 kept" || bad "$1 lost"; }
gone "github token" AbCdEfGhIjKlMnOp;   gone "gitlab token" abcdefghij0123456789
gone "aws key" AKIAIOSFODNN7;           gone "slack token" abcdefgh
gone "bearer" abcdef0123456789;         gone "jwt" eyJhbGci
gone "password" hunter2;                gone "psk" "battery staple"
gone "api key" 8f9e7d6c;                gone "url credentials" s3cretpw
gone "private key" b3BlbnNz;            gone "ssid" CafeNetFake
gone "ssid (quoted)" HomeWifiFake;      gone "ipv4" 192.168.7.42
gone "gateway" 10.0.0.1;                gone "mac" de:ad:be:ef
gone "ipv6" 1c2d:3eff;                  gone "ipv6 short" 2001:db8
gone "machine-id" 0123456789abcdef;     gone "username" alicewonder
gone "hostname" wonderbox
kept "loopback" 127.0.0.1
kept "clock time" 02:34:56
kept "kernel version" 6.12.1
kept "failure text" "Failed to start foo.service"
kept "path shape" "/home/<user>/projects/x"
kept "host marker" "on <host> by <user>"

# The whole report: path printed, header, nothing planted, nothing uploaded.
out=$(HOME="$T" "$REPO/bin/ergon-report" 2>/dev/null)
[[ "$out" == "$T"/ergon-report-*.txt && -s "$out" ]] && ok "report written to \$HOME and path printed" || bad "report path: $out"
grep -q '^Collected:' "$out" && grep -q 'nothing was uploaded' "$out" && ok "header states contents and no upload" || bad "header"
grep -qE 'curl|wget|nc ' "$REPO/bin/ergon-report" && bad "report script has a network call" || ok "report script makes no network call"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
