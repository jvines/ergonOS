#!/usr/bin/env bash
# ERGON-102: ergon-language enables, generates and sets locales; numeric stays '.'.
#
#   ./bin/test-language.sh
#
# Seconds, no root, no docker. SUPPORTED, locale.gen and locale.conf are temp
# files; localectl, locale-gen, sudo, systemctl and dbus-update-activation-
# environment are stubs on PATH that log their arguments.
set -uo pipefail
ERGON="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "   ok   $1"; }
bad() { echo "   FAIL $1"; fail=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', want '$3'"; fi; }

mkdir "$T/bin"
for c in localectl locale-gen systemctl dbus-update-activation-environment; do
  printf '#!/bin/sh\necho "%s $*" >> "$STUBLOG"\n' "$c" > "$T/bin/$c"
done
printf '#!/bin/sh\nexec "$@"\n' > "$T/bin/sudo"   # sudo runs the command; the files are temp
chmod +x "$T"/bin/*
export PATH="$T/bin:$PATH" STUBLOG="$T/log"
export ERGON_LOCALE_SUPPORTED="$T/SUPPORTED" ERGON_LOCALE_GEN="$T/locale.gen" ERGON_LOCALE_CONF="$T/locale.conf"
printf '%s\n' 'en_US.UTF-8 UTF-8' 'en_US ISO-8859-1' 'en_DK.UTF-8 UTF-8' 'es_CL.UTF-8 UTF-8' 'de_DE.UTF-8 UTF-8' 'C.UTF-8 UTF-8' > "$T/SUPPORTED"
printf '%s\n' '#en_DK.UTF-8 UTF-8' '#en_US.UTF-8 UTF-8' '#es_CL.UTF-8 UTF-8' > "$T/locale.gen"
printf 'LANG=en_US.UTF-8\n' > "$T/locale.conf"
L="$ERGON/bin/ergon-language"

echo "== list / show"
eq "list is UTF-8 only"        "$("$L" --list | grep -c ISO)" 0
eq "list has es_CL"            "$("$L" --list | grep -c '^es_CL.UTF-8$')" 1
eq "show reads locale.conf"    "$("$L" --show)" "LANG=en_US.UTF-8"

echo "== validation"
"$L" xx_YY.UTF-8 >/dev/null 2>&1; eq "unknown locale refused" "$?" 1
"$L" en_US --formats en_DK.UTF-8 >/dev/null 2>&1; eq "non-UTF-8 name refused" "$?" 1
eq "nothing was run on refusal" "$(cat "$T/log" 2>/dev/null | wc -l)" 0

echo "== language only: numeric pinned to '.'"
out=$("$L" es_CL.UTF-8 2>&1)
eq "es_CL uncommented"         "$(grep -c '^es_CL.UTF-8 UTF-8' "$T/locale.gen")" 1
eq "en_US left commented"      "$(grep -c '^#en_US' "$T/locale.gen")" 1
grep -q '^locale-gen' "$T/log" && ok "locale-gen ran" || bad "locale-gen did not run"
eq "localectl args"            "$(grep ^localectl "$T/log")" "localectl set-locale LANG=es_CL.UTF-8 LC_NUMERIC=C.UTF-8"
grep -q 'set-environment LANG=es_CL.UTF-8' "$T/log" && ok "user manager updated" || bad "user manager not updated"
grep -q 'unset-environment .*LC_TIME' "$T/log" && ok "stale LC_TIME unset" || bad "stale LC_TIME not unset"
grep -q 'dbus-update-activation-environment --systemd LANG=es_CL' "$T/log" && ok "dbus env updated" || bad "dbus env not updated"
grep -q 're-login' <<<"$out" && ok "says apps need restart / re-login" || bad "no restart notice"

echo "== split: English UI, ISO formats"
: > "$T/log"
"$L" en_US.UTF-8 --formats en_DK.UTF-8 >/dev/null 2>&1
eq "localectl args" "$(grep ^localectl "$T/log")" \
  "localectl set-locale LANG=en_US.UTF-8 LC_TIME=en_DK.UTF-8 LC_MONETARY=en_DK.UTF-8 LC_PAPER=en_DK.UTF-8 LC_MEASUREMENT=en_DK.UTF-8 LC_NUMERIC=C.UTF-8"
eq "en_DK enabled" "$(grep -c '^en_DK.UTF-8 UTF-8' "$T/locale.gen")" 1

echo "== explicit numeric, and a locale missing from locale.gen is appended"
: > "$T/log"
"$L" de_DE.UTF-8 --numeric de_DE.UTF-8 >/dev/null 2>&1
eq "numeric honoured" "$(grep ^localectl "$T/log")" "localectl set-locale LANG=de_DE.UTF-8 LC_NUMERIC=de_DE.UTF-8"
eq "de_DE appended"   "$(grep -c '^de_DE.UTF-8 UTF-8' "$T/locale.gen")" 1

echo "== interactive"
: > "$T/log"
printf 'es_CL\n\n' | script -qec "$L" /dev/null >/dev/null 2>&1 || true
[ -s "$T/log" ] && eq "typed substring picks the single match" "$(grep ^localectl "$T/log" | cut -d' ' -f3)" "LANG=es_CL.UTF-8" || echo "   skip interactive (no tty helper)"

[ $fail = 0 ] && echo "PASS" || { echo "FAILED"; exit 1; }
