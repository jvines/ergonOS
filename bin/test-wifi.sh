#!/usr/bin/env bash
# Exercise ergon-wifi's pure parts against nmcli -t fixtures.
#
#   ./bin/test-wifi.sh
#
# COVERS: terse parsing with '\:' and '\\' in SSIDs, hidden SSIDs dropped,
# one line per SSID (strongest wins), the in-use mark, order by signal, the
# SSID recoverable from a menu line at SSID_COL, and the WIFI: QR payload
# (escaping, open networks). DOES NOT COVER: real nmcli/fuzzel/imv; the VM
# suite owns those.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
W="$REPO/bin/ergon-wifi"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '   FAIL %s\n' "$*"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: got [$2] want [$3]"; }

out=$("$W" --format <<'FIX'
 :45:WPA2:Cafe\: Free
*:80:WPA2 WPA3:Home
 :30:WPA2:Home
 :90::Open\\Net
 :60:WPA2:
 :20:WPA2 802.1X:Eduroam
FIX
)
eq "strongest first, one per SSID, hidden dropped" "$(cut -c22- <<<"$out" | paste -sd'|')" 'Open\Net|Home|Cafe: Free|Eduroam'
eq "in-use mark" "$(grep -c '^\*' <<<"$out")" 1
grep -q " 90%  -- " <<<"$out" && ok "open network shows --" || bad "open network: $out"
eq "colon in SSID unescaped" "$(grep -c 'Cafe: Free$' <<<"$out")" 1

eq "WPA payload" "$("$W" --qr-payload Home wpa-psk 'pa;ss')" 'WIFI:T:WPA;S:Home;P:pa\;ss;;'
eq "payload escapes S" "$("$W" --qr-payload 'a:b,c' sae 'x')" 'WIFI:T:WPA;S:a\:b\,c;P:x;;'
eq "open payload" "$("$W" --qr-payload Cafe '' '')" 'WIFI:T:nopass;S:Cafe;;'


# --join: the password must never be in argv, and a failed join leaves no profile.
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
cat > "$S/nmcli" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$S/argv"
if [ "\$1 \$2" = "connection up" ]; then
  cat /dev/fd/3 > "$S/seen" 2>/dev/null; [ -f "$S/fail" ] && exit 4
fi
exit 0
STUB
chmod +x "$S/nmcli"
: > "$S/argv"; printf 'hunter2xyz\n' | PATH="$S:$PATH" "$W" --join Home; rc=$?
eq "join succeeds" "$rc" 0
grep -q hunter2xyz "$S/argv" && bad "password leaked into argv" || ok "password not in argv"
eq "password arrives as a passwd-file line" "$(cat "$S/seen")" '802-11-wireless-security.psk:hunter2xyz'
grep -q 'connection delete' "$S/argv" && bad "profile deleted on success" || ok "profile kept on success"
touch "$S/fail"; : > "$S/argv"; printf 'typo\n' | PATH="$S:$PATH" "$W" --join Home; rc=$?
eq "failed join returns non-zero" "$([ $rc -ne 0 ] && echo nonzero)" nonzero
grep -q "connection delete id Home" "$S/argv" && ok "half-made profile deleted on failure" || bad "profile left behind"
echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
