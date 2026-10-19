#!/usr/bin/env bash
# ERGON-82: timezone detection, the fallback picker and the env override.
#
#   ./bin/test-timezone.sh
#
# Seconds, no root, no network, no docker. The geo-IP lookup is stubbed by
# pointing ERGON_TZ_URLS at file:// URLs (curl reads those), and the pickers are
# driven by feeding answers on stdin.
set -uo pipefail
ERGON="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)"
. "$ERGON/lib/timezone.sh"
[ -f "$TZ_ZONEDIR/zone.tab" ] || { echo "SKIP: no zoneinfo here"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "   ok   $1"; }
bad() { echo "   FAIL $1"; fail=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', want '$3'"; fi; }

echo 'Europe/Madrid' > "$T/good"
printf '<html>Rate limited</html>\n' > "$T/junk"
echo 'Not/AZone' > "$T/fake"
gone="file://$T/missing"

echo "== detection"
export ERGON_TZ_URLS="file://$T/good"
eq "valid answer is used"              "$(tz_detect)" Europe/Madrid
ERGON_TZ_URLS="file://$T/junk"; tz_detect >/dev/null 2>&1; eq "html answer rejected" "$?" 1
ERGON_TZ_URLS="file://$T/fake"; tz_detect >/dev/null 2>&1; eq "unknown zone rejected" "$?" 1
ERGON_TZ_URLS="file://$T/junk file://$T/good"
eq "falls through to the second endpoint" "$(tz_detect)" Europe/Madrid
ERGON_TZ_URLS="$gone"; tz_detect >/dev/null 2>&1; eq "no connection fails" "$?" 1

echo "== unattended (never prompts)"
ERGON_TZ_URLS="file://$T/good"
eq "detected zone wins"                "$(tz_resolve 0 America/Santiago </dev/null)" Europe/Madrid
ERGON_TZ_URLS="$gone"
eq "no connection -> Santiago"         "$(tz_resolve 0 America/Santiago </dev/null)" America/Santiago

echo "== interactive, detected"
ERGON_TZ_URLS="file://$T/good"
eq "Enter accepts"                     "$(printf '\n' | tz_resolve 1 2>/dev/null)" Europe/Madrid
eq "typed zone replaces it"            "$(printf 'Asia/Tokyo\n' | tz_resolve 1 2>/dev/null)" Asia/Tokyo
eq "garbage re-asks, then Enter"       "$(printf 'xx\n\n' | tz_resolve 1 2>/dev/null)" Europe/Madrid
n=$(_tz_regions | grep -n '^Asia$' | cut -d: -f1)
eq "c opens the picker"                "$(printf 'c\n%s\n\n' "$n" | tz_resolve 1 2>/dev/null | head -1 | grep -c '^Asia/')" 1

echo "== interactive, no connection: picker"
ERGON_TZ_URLS="$gone"
eq "Enter, Enter = America/Santiago"   "$(printf '\n\n' | tz_resolve 1 America/Santiago 2>/dev/null)" America/Santiago
eq "region number then city number"    "$(printf '%s\n1\n' "$n" | tz_pick America/Santiago 2>/dev/null | grep -c '^Asia/')" 1
eq "full zone typed at region prompt"  "$(printf 'Europe/Paris\n' | tz_pick 2>/dev/null)" Europe/Paris
eq "UTC is a region"                   "$(u=$(_tz_regions | grep -n '^UTC$' | cut -d: -f1); printf '%s\n' "$u" | tz_pick 2>/dev/null)" UTC
eq "0 goes back to regions"            "$(printf '%s\n0\nEurope/Paris\n' "$n" | tz_pick 2>/dev/null)" Europe/Paris

echo "== installer wiring"
if grep -q 'TIMEZONE="${TIMEZONE:-America/Santiago}"' "$ERGON/bin/arch-bootstrap.sh"; then
  bad "arch-bootstrap.sh still hardcodes the Santiago default"; else ok "no hardcoded default in the installer"; fi
# Run the installer's own resolution block, with the env set and with it empty.
blk=$(sed -n '/^if \[ -z "\$TIMEZONE" \]; then$/,/^fi$/p' "$ERGON/bin/arch-bootstrap.sh")
[ -n "$blk" ] || bad "could not extract the installer's timezone block"
run() { ( UNATTENDED=1; TIMEZONE=$1; ERGON_TZ_URLS=$2; . "$ERGON/lib/timezone.sh"; eval "$blk"; echo "$TIMEZONE" ); }
eq "TIMEZONE env beats detection"      "$(run Asia/Tokyo "file://$T/good")" Asia/Tokyo
eq "unset: detected"                   "$(run '' "file://$T/good")" Europe/Madrid
eq "unset, offline: Santiago"          "$(run '' "$gone")" America/Santiago
# The regdom derivation reads the same zone.tab; a detected zone must feed it.
rd=$(awk -v tz=Europe/Madrid '$1 !~ /^#/ && $3 == tz { print $1; exit }' "$TZ_ZONEDIR/zone.tab" | cut -c1-2)
eq "regdom derives from the zone"      "$rd" ES

[ $fail -eq 0 ] && echo "=== ALL PASSED ===" || { echo "=== FAILURES ABOVE ==="; exit 1; }
