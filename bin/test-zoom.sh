#!/usr/bin/env bash
# ergon-zoom (ERGON-108): the x1.5 steps, the cap at 8, the floor at 1, reset, and
# that the value reaches hyprctl eval as the Lua hl.config form. hyprctl is a stub
# holding the factor in a file; the VM suite owns reading the real option back.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
mkdir -p "$T/stub"
printf '#!/usr/bin/env bash\necho "$*" >> "$T/log"\ncase "$1" in\n  getoption) printf "{\\"option\\":\\"cursor:zoom_factor\\",\\"float\\":%%s}" "$(cat "$T/z")" ;;\n  eval) sed -n "s/.*zoom_factor = \\\\([0-9.]*\\\\).*/\\\\1/p" <<<"$2" > "$T/z"; echo ok ;;\nesac\n' > "$T/stub/hyprctl"
chmod +x "$T/stub/hyprctl"
export PATH="$T/stub:$PATH" T
X="$REPO/bin/ergon-zoom"
echo 1.0 > "$T/z"
check "in: 1.5"        test "$("$X" in)" = 1.5000
check "in again: 2.25" test "$("$X" in)" = 2.2500
check "the stub saw a Lua hl.config call" grep -q 'eval hl.config({ cursor = { zoom_factor = 2.2500 } })' "$T/log"
for _ in 1 2 3 4 5 6; do "$X" in >/dev/null; done
check "in is capped at 8" test "$("$X" in)" = 8.0000
check "out: 8 / 1.5"     test "$("$X" out)" = 5.3333
check "reset: 1"         test "$("$X" reset)" = 1.0000
check "out never goes below 1" test "$("$X" out)" = 1.0000
check "unknown argument refused" bash -c '! "$0" sideways 2>/dev/null' "$X"
echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
