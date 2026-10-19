#!/usr/bin/env bash
# ERGON-105: scripts that parse tool output must not care about the user's locale.
#
#   ./bin/test-locale-parsing.sh
#
# ERGON-102 lets a user set LANG, LC_TIME and friends (and LC_NUMERIC with
# --numeric, e.g. es_CL, whose decimal separator is a comma). Tools that gettext
# their output (pacman prints "[instalado]", not "[installed]") or format numbers
# by locale then break a parser that was written against English. Each check runs
# the changed command line, lifted out of the real script, with stubs that behave
# the way the real tool does outside LC_ALL=C, once in C and once under the
# hostile locale, and demands the same answer. Take a pin out and its check fails.
#
# Seconds, no root, no container: the locales are compiled into a temp LOCPATH
# with localedef. Without localedef and /usr/share/i18n the test says SKIP.
#
# DOES NOT COVER: the real pacman/btrfs catalogues. That "[instalado]" is what
# real pacman prints under LANG=es_CL was measured in archlinux:latest (with
# NoExtract removed); the stubs encode it.
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }

command -v localedef >/dev/null && [ -r /usr/share/i18n/locales/es_CL ] && [ -r /usr/share/i18n/locales/en_DK ] \
  || { echo "   SKIP no localedef / i18n sources here; nothing to test with"; exit 0; }
mkdir -p "$T/loc"
for l in es_CL en_DK; do
  localedef -i "$l" -f UTF-8 "$T/loc/$l.UTF-8" 2>/dev/null || true   # warnings are not errors
done
export LOCPATH="$T/loc"
[ "$(LC_ALL=es_CL.UTF-8 printf '%.1f' 1,5)" = "1,5" ] \
  || { echo "   SKIP the es_CL locale did not build (decimal comma not in effect)"; exit 0; }
HOSTILE=(LANG=es_CL.UTF-8 LC_NUMERIC=es_CL.UTF-8 LC_TIME=en_DK.UTF-8 LC_COLLATE=es_CL.UTF-8)

# Stubs: translated or comma-decimal unless LC_ALL=C is set in their own env.
mkdir -p "$T/bin"
cat > "$T/bin/pacman" <<'S'
#!/usr/bin/env bash
word=instalado; [ "${LC_ALL:-}" = C ] && word=installed
printf 'core bash 5.3-1 [%s: 5.4-1]\ncore less 1-1 [%s]\ncore zlib 1.3-1\n' "$word" "$word"
S
cat > "$T/bin/btrfs" <<'S'
#!/usr/bin/env bash
dec=,; [ "${LC_ALL:-}" = C ] && dec=.
printf 'Metadata,single: Size:1%s00GiB, Used:1%s00GiB, Free (estimated): 0%s00B\n' "$dec" "$dec" "$dec"
S
chmod +x "$T/bin/"*

# Lift one command line out of a script by a fixed substring (first match).
lift() { grep -m1 -A1 -F -- "$2" "$REPO/bin/$1" | sed 's/^[[:space:]]*\(elif\|if\) //; s/\\$//' | tr '\n' ' '; }
same() {  # <what> <script> <needle> <eval-prefix> <eval-suffix>
  local what=$1 line c h
  line=$(lift "$2" "$3") || true
  [ -n "$line" ] || { bad "$what: could not find '$3' in $2"; return; }
  line=$(sed 's/; \[ "\$newer".*//' <<<"$line")
  c=$(env PATH="$T/bin:$PATH" LC_ALL=C bash -c "$4$line$5" 2>&1)
  h=$(env PATH="$T/bin:$PATH" "${HOSTILE[@]}" bash -c "$4$line$5" 2>&1)
  if [ -n "$c" ] && [ "$c" = "$h" ]; then ok "$what: same answer under es_CL ($c)"
  else bad "$what: C gave '$c', es_CL gave '$h'"; fi
}

# doctor's "newer than the tested day" count reads pacman -Sl's English tag.
same "doctor pacman -Sl" ergon-doctor 'newer=$(LC_ALL=C pacman -Sl' \
  'vercmp() { echo 1; }; ' '; echo "$newer"'
# Unpinned, the stub talks Spanish: prove the harness can see a regression.
leak=$(env PATH="$T/bin:$PATH" "${HOSTILE[@]}" pacman -Sl core | awk '$4 == "[installed:"' | wc -l)
[ "$leak" = 0 ] && ok "harness: an unpinned pacman -Sl under es_CL does lose the match" \
                || bad "harness: the pacman stub does not translate, so the check above proves nothing"

# update's btrfs gate greps the decimal "0.00".
line=$(grep -m1 -F 'Metadata.*Free.*0' "$REPO/bin/ergon-update" | sed 's/^[[:space:]]*if //; s/; then$//')
c=$(env PATH="$T/bin:$PATH" LC_ALL=C bash -c "$line && echo gate" 2>&1)
h=$(env PATH="$T/bin:$PATH" "${HOSTILE[@]}" bash -c "$line && echo gate" 2>&1)
[ "$c" = gate ] && [ "$h" = gate ] && ok "update btrfs Metadata-free gate fires under es_CL" \
                                   || bad "update btrfs gate: C '$c', es_CL '$h'"

# archive: the real script, a tree with sub-second mtimes, listing identical.
A="$T/tree"; mkdir -p "$A/old1/x" "$A/old2/x" "$A/new/x"
for d in old1 old2; do dd if=/dev/zero of="$A/$d/x/f" bs=1k count=2048 2>/dev/null; done
touch -d '2020-01-01 00:00:00.123456789' "$A/old1/x/f"
touch -d '2020-01-01 00:00:00.987654321' "$A/old2/x/f"
touch -d '2020-01-01' "$A/old1" "$A/old2" "$A/old1/x" "$A/old2/x"
dd if=/dev/zero of="$A/new/x/f" bs=1k count=2048 2>/dev/null
c=$(env LC_ALL=C "$REPO/bin/ergon-archive" "$A" --older-than 30 --min-size 1 2>&1)
h=$(env "${HOSTILE[@]}" "$REPO/bin/ergon-archive" "$A" --older-than 30 --min-size 1 2>&1)
{ [ "$c" = "$h" ] && grep -q 'old1' <<<"$c" && ! grep -q '/new' <<<"$c"; } \
  && ok "archive lists the same stale trees under es_CL" || bad "archive differs: C '$c' / es_CL '$h'"

# Date parsing the scripts do is ISO-only; LC_TIME=en_DK must not change it.
d=$(env "${HOSTILE[@]}" bash -c 'echo $(( ($(date -u -d 2026-10-19 +%s) - $(date -u -d 2026-10-12 +%s)) / 86400 ))')
[ "$d" = 7 ] && ok "ISO date arithmetic is the same under en_DK" || bad "date arithmetic gave '$d'"

echo; echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
