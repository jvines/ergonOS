#!/usr/bin/env bash
# Install-media presets (ERGON-157): parsing and precedence of lib/preset.sh,
# the reflector call, and that arch-bootstrap.sh wires the pieces in.
# Seconds, no root, no network. DOES NOT COVER an install; the VM suite does.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
eq() { [ "$1" = "$2" ]; }
# shellcheck source=../lib/preset.sh
. "$REPO/lib/preset.sh"

cat > "$T/p" <<'EOS'
# a comment
LOCALE=es_CL.UTF-8
KEYMAP=la-latin1
TIMEZONE="America/Santiago"
MIRROR_COUNTRY=CL,AR
NTP=cl.pool.ntp.org 0.cl.pool.ntp.org
EOS
unset LOCALE KEYMAP TIMEZONE MIRROR_COUNTRY NTP
ergon_preset_apply "$T/p"
check "locale"   eq "$LOCALE" es_CL.UTF-8
check "keymap"   eq "$KEYMAP" la-latin1
check "timezone, quotes stripped" eq "$TIMEZONE" America/Santiago
check "mirror countries" eq "$MIRROR_COUNTRY" CL,AR
check "ntp servers" eq "$NTP" "cl.pool.ntp.org 0.cl.pool.ntp.org"

KEYMAP=us; TIMEZONE=""; ergon_preset_apply "$T/p"
check "the environment wins over the file" eq "$KEYMAP" us
check "  an empty variable takes the file's value" eq "$TIMEZONE" America/Santiago

unset LOCALE KEYMAP TIMEZONE MIRROR_COUNTRY NTP
cat > "$T/bad" <<'EOS'
LOCALE=en_US.UTF-8; rm -rf /
KEYMAP=$(id)
TIMEZONE=../../etc/passwd x
MIRROR_COUNTRY=Chile
NTP=a.example.org; reboot
EVIL=1
LOCALE=de_DE.UTF-8
EOS
ergon_preset_apply "$T/bad" 2>"$T/err"
check "injection and bad values are ignored" bash -c "[ -z '${KEYMAP:-}' ] && [ -z '${MIRROR_COUNTRY:-}' ] && [ -z '${NTP:-}' ] && [ -z '${EVIL:-}' ]"
check "  with a warning per line" eq "$(grep -c ignored "$T/err")" 6
check "  and later good lines still apply" eq "$LOCALE" de_DE.UTF-8

mkdir -p "$T/boot"; : > "$T/boot/ergon-preset"
check "ERGON_PRESET is found first" eq "$(ERGON_PRESET=$T/boot/ergon-preset ergon_preset_find)" "$T/boot/ergon-preset"
check "no preset: not found" bash -c ". '$REPO/lib/preset.sh'; ERGON=$T/none; ! ergon_preset_find"

# reflector: a stub that writes a list, and one that fails; the real
# /etc/pacman.d/mirrorlist is not ours to touch, so run in a function with it
# redirected through a sed of the function's own text.
mkdir -p "$T/stub"
printf '#!/usr/bin/env bash\necho "$*" > "%s/args"\nfor a; do [ "$prev" = --save ] && printf "Server = https://cl.example/\\n" > "$a"; prev=$a; done\n' "$T" > "$T/stub/reflector"
chmod +x "$T/stub/reflector"
eval "$(declare -f ergon_mirrors | sed "s|/etc/pacman.d|$T|g")"
printf 'Server = https://old/\n' > "$T/mirrorlist"
PATH="$T/stub:$PATH" ergon_mirrors CL >/dev/null 2>&1
check "reflector is asked for the country, https, by rate" grep -q -- '--country CL --protocol https --latest 10 --sort rate' "$T/args"
check "  and its list replaces the live one" grep -q cl.example "$T/mirrorlist"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/stub/reflector"
printf 'Server = https://old/\n' > "$T/mirrorlist"
PATH="$T/stub:$PATH" ergon_mirrors CL >/dev/null 2>&1; rc=$?
check "reflector failing is not fatal and keeps the old list" bash -c "[ $rc = 0 ] && grep -q old '$T/mirrorlist' && [ ! -e '$T/mirrorlist.ergon' ]"

B="$REPO/bin/arch-bootstrap.sh"
check "bootstrap loads the preset before the timezone default" bash -c "[ \$(grep -n 'ergon_preset_apply' '$B' | head -1 | cut -d: -f1) -lt \$(grep -n '^TIMEZONE=' '$B' | cut -d: -f1) ]"
check "bootstrap runs reflector before the pin" bash -c "[ \$(grep -n '^\[ -z \"\$MIRROR_COUNTRY\" \]' '$B' | cut -d: -f1) -lt \$(grep -n '^ergon_channel\|CHANNEL=\$(ergon_channel' '$B' | head -1 | cut -d: -f1) ]"
check "bootstrap writes the NTP drop-in and enables timesyncd" bash -c "grep -q 'timesyncd.conf.d/10-ergon.conf' '$B' && grep -q 'enable systemd-timesyncd' '$B'"
check "the example preset parses clean" bash -c ". '$REPO/lib/preset.sh'; unset LOCALE KEYMAP TIMEZONE MIRROR_COUNTRY NTP; [ -z \"\$(ergon_preset_apply '$REPO/docs/ergon-preset.example' 2>&1)\" ]"
echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
