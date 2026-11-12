#!/usr/bin/env bash
# The logo (ERGON-161): the templates carry the approved shapes, the palette
# colours them, and the boot splash renders with its logo. No VM: the screens
# are the VM suite's (test/arch-vm/guest-desktop.sh).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
paths() { grep -o '<path d="[^"]*"/>' "$1" | tr -d '\n'; }

plymouth_checks() {
  "$REPO/bin/ergon-plymouth" render cool "$T/theme" >/dev/null 2>&1
  check "ergon-plymouth render writes the script, the theme and logo.png" \
    bash -c 'cd "$0" && test -s ergon.script && test -s ergon.plymouth && test -s logo.png' "$T/theme"
  check "  logo.png is a PNG" test "$(head -c 4 "$T/theme/logo.png" | tail -c 3)" = PNG
  check "  the script loads it" grep -q 'Image("logo.png")' "$T/theme/ergon.script"
  check "  and keeps the passphrase prompt under it" bash -c 'grep -q "SetDisplayPasswordFunction" "$0" && grep -q "global.prompt_y = global.logo_y" "$0"' "$T/theme/ergon.script"
  "$REPO/bin/ergon-plymouth" render "$REPO/theme/cool.env" "$T/t2" >/dev/null 2>&1
  check "  a second render is identical (the install compares bytes)" test "$(sha256sum < "$T/theme/logo.png")" = "$(sha256sum < "$T/t2/logo.png")"
  # And a palette with no COOL_FG0 is refused, not rendered black.
  grep -v '^COOL_FG0=' "$REPO/theme/cool.env" > "$T/nofg.env"
  check "  a palette without COOL_FG0 is refused" bash -c '! "$0/bin/ergon-plymouth" render "$1" "$2" >/dev/null 2>&1' "$REPO" "$T/nofg.env" "$T/t3"
}

if [ "${1:-}" = --plymouth-only ]; then
  plymouth_checks; printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; exit
fi

canon=$(paths "$REPO/logo/ergon-mark-light.svg")
check "the canonical mark has its two paths" test "$(grep -o '<path ' <<<"$canon" | wc -l)" -eq 2
for f in waybar/logo-dim.svg.in waybar/logo-active.svg.in; do
  check "$f carries the approved mark shape" test "$(paths "$REPO/$f")" = "$canon"
done
check "hypr/lock-logo.svg.in carries the approved stacked lockup" \
  test "$(paths "$REPO/hypr/lock-logo.svg.in")" = "$(paths "$REPO/logo/ergon-lockup-stacked-light.svg")"
check "the dim mark is @COOL_DIM@ and the active one @COOL_ACTIVE@" \
  bash -c 'grep -q "#@COOL_DIM:raw@" "$0/waybar/logo-dim.svg.in" && grep -q "#@COOL_ACTIVE:raw@" "$0/waybar/logo-active.svg.in"' "$REPO"
check "the bar swaps the image on hover and keeps the click" \
  bash -c 'grep -q "#custom-menu:hover { background-image: url(\"logo-active.svg\")" "$0/waybar/style.css.in" && grep -q "\"on-click\": \"ergon-menu\"" "$0/waybar/config.jsonc"' "$REPO"
check "the generated logo files are gitignored" \
  bash -c 'cd "$0" && for f in waybar/logo-dim.svg waybar/logo-active.svg hypr/lock-logo.svg fastfetch/config.jsonc; do git check-ignore -q "$f" || exit 1; done' "$REPO"
check "fastfetch's logo is the 36x15 art" test "$(readlink -f "$REPO/fastfetch/logo.txt")" = "$(readlink -f "$REPO/logo/term/ergon-36x15.txt")"
check "librsvg and fastfetch are declared packages" bash -c 'grep -q "^librsvg " "$0/packages/pacman" && grep -q "^fastfetch " "$0/packages/pacman"' "$REPO"

if command -v rsvg-convert >/dev/null 2>&1; then
  plymouth_checks
elif command -v docker >/dev/null 2>&1; then
  # No librsvg on this host: the render runs in a throwaway Arch container.
  if out=$(docker run --rm --label cl.jvines.owner=ERGON-161 -v "$REPO:/repo:ro" archlinux:latest bash -c \
      'pacman -Sy --noconfirm librsvg >/dev/null 2>&1 && /repo/bin/test-logo.sh --plymouth-only' 2>&1); then
    PASS=$((PASS+1)); echo "   ok   the boot splash renders with its logo (in an Arch container)"
  else
    FAIL=$((FAIL+1)); echo "   FAIL the boot splash render, in an Arch container"; echo "$out" | sed 's/^/        /'
  fi
else
  echo "   --   neither rsvg-convert nor docker here; the plymouth render is not exercised"
fi
# With a real tte: every screensaver effect accepts its palette flags and draws no
# green-dominant colour (matrix's own green is what this rules out).
if command -v tte >/dev/null 2>&1; then
  eval "$(sed -n '/^palette_file()/,/^# The static fallback/p' "$REPO/bin/ergon-screensaver" | sed '$d')"
  here=$REPO/bin; PALFILE=$(palette_file); badfx=""
  for e in "${EFFECTS[@]}"; do
    mapfile -t a < <(effect_args "$e")
    out=$(tte -i "$REPO/logo/term/ergon-36x15.txt" --frame-rate 0 --canvas-width 0 --canvas-height 20 --no-eol --no-restore-cursor "$e" "${a[@]}" 2>/dev/null) || { badfx+=" $e(exit)"; continue; }
    g=$(grep -o '38;2;[0-9]*;[0-9]*;[0-9]*' <<<"$out" | sort -u | awk -F';' '$4 > $3 + 15 && $4 > $5 + 15' | wc -l)
    [ "$g" -eq 0 ] || badfx+=" $e(green)"
  done
  check "every screensaver effect runs in palette colours${badfx:+ (bad:$badfx)}" test -z "$badfx"
else
  echo "   --   tte not installed here; the screensaver effects are not exercised"
fi
printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
