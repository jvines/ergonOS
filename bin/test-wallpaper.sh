#!/usr/bin/env bash
# The background follows the palette. That is the whole subject of this file.
#
#   ./bin/test-wallpaper.sh
#
# Seconds, no compositor, no imagemagick, no VM. `magick` is a stub that records
# the arguments it was handed and writes its output file, so every assertion
# here is about the colours that WOULD have been painted -- which is the claim,
# and is not the same claim as "a wallpaper.png exists".
#
# That distinction is why this file exists. The VM suite has asserted since the
# beginning that the wallpaper is generated and that hyprpaper maps a background
# layer (test/arch-vm/guest-desktop.sh:1619-1645), and both were true the whole
# time the background was ignoring the palette:
#
#   - the generated gradient was cached with `[ "$OUT" -nt "$PALETTE" ]`, and a
#     palette SWITCH does not touch any mtime -- theme/gruvbox.env was written
#     when the repo was cloned -- so a gradient rendered from cool was "newer
#     than the palette" and kept. Only ergon-theme's --force rebuilt it, and
#     that call is gated on HYPRLAND_INSTANCE_SIGNATURE, so `ergon theme` from
#     a tty, over ssh, or with --no-apply (install.sh, the VM harness) left the
#     desktop on the previous palette's background.
#   - a chosen IMAGE is remembered as an absolute path into a per-palette
#     directory, and the only test applied to it was that the file still
#     existed. backgrounds/cool/clifford.png exists after switching to gruvbox,
#     so it stayed selected while backgrounds/gruvbox/clifford.png sat there.
#   - and an unresolvable palette silently became cool in both ergon-wallpaper
#     and ergon-wallpaper-gen, where ergon-theme refuses and says so.
#
# COVERS: the gradient carries the active palette's own colours; a switch, an
# edit and a resize each rebuild it; an unchanged palette does not; a chosen
# image follows the switch to the same image under the new palette, and falls
# back to the gradient when there is none; a deleted image still falls back; an
# unknown palette is refused rather than silently answered with cool.
#
# DOES NOT COVER: that the resulting image looks good, that imagemagick's
# sparse-color produces the ramp the arguments describe, or that hyprpaper maps
# it. The VM suite owns the last of those; the first is a person's judgement.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

# --- a throwaway ergonOS holding only what the wallpaper path reads ----------
E=$T/ergon
mkdir -p "$E/bin" "$E/theme" "$T/stub" "$T/home" "$T/log"
cp "$REPO/bin/ergon-wallpaper" "$REPO/bin/ergon-wallpaper-gen" "$E/bin/"
# Three palettes with visibly different grounds and ramps, so an assertion that
# the wrong one was used cannot pass by coincidence.
cp "$REPO/theme/cool.env" "$REPO/theme/gruvbox.env" "$REPO/theme/nord.env" "$E/theme/"

# The stub records its whole argv and writes the file it was asked for, because
# both halves are load-bearing: the colours prove which palette was used, and
# the file existing is what the caching path then reasons about.
cat > "$T/stub/magick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/magick"
out="${@: -1}"
# REFUSES a path it cannot infer a format from, because the real magick does.
# Writing "${@: -1}" whatever its name is what let a render to
# "wallpaper.png.new.12345" pass every assertion in this file while the real
# ImageMagick answered "no encode delegate for this image format `XC'" and the
# gradient quietly stopped following the palette.
case "$out" in
  *.png|*.jpg|*.jpeg|*.webp|*.avif) ;;
  *) echo "magick: no encode delegate for this image format" >&2; exit 1 ;;
esac
printf 'PNGSTUB\n' > "$out"
EOF
# Nothing here may reach a real compositor. hyprpaper in particular is STARTED
# by ergon-wallpaper, so an unstubbed run would leave one behind per assertion.
#
# These SUCCEED, and that is not laziness. ergon-wallpaper's delivery path ends
# in `for _ in $(seq 15); do hyprctl ... || sleep 1; done`, so a stub that fails
# costs fifteen seconds per invocation -- with the twenty-odd runs below, this
# file took over five minutes and was killed by its own timeout before it was
# written this way. A pgrep that says hyprpaper is already up and an hyprctl
# that accepts the image take the preload path, which has no sleep in it at all.
# Nothing here asserts on hyprpaper; the VM suite owns that.
for c in hyprctl pkill pgrep; do
  cat > "$T/stub/$c" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$TEST_ROOT/log/$c"
EOF
done
# Except this one, which must never run: reaching it means the fast path above
# was not taken and a real daemon would have been spawned.
cat > "$T/stub/hyprpaper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/hyprpaper"
EOF
chmod +x "$T/stub"/* "$E/bin"/*

export TEST_ROOT="$T" PATH="$T/stub:$PATH" HOME="$T/home" \
       XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/config" \
       XDG_DATA_HOME="$T/data" XDG_RUNTIME_DIR="$T"
mkdir -p "$T/state/ergon"

# Same guard test-theme.sh uses, and for the same reason: a stub that is not
# first on PATH turns this file into a slow way of rendering real wallpapers.
for c in magick hyprpaper pgrep; do
  [ "$(command -v "$c")" = "$T/stub/$c" ] \
    || { echo "stub for $c is not first on PATH; refusing to run anything"; exit 1; }
done

pal()  { printf '%s\n' "$1" > "$T/state/ergon/palette"; }
run()  { ERGON="$E" "$E/bin/ergon-wallpaper" "$@" >/dev/null 2>&1; }
# The colours the last magick run was handed, as one string.
cols() { grep -oE '#[0-9A-Fa-f]{6}' <<<"$(tail -1 "$T/log/magick" 2>/dev/null)" | tr '\n' ' '; }
runs() { wc -l < "$T/log/magick" 2>/dev/null || echo 0; }
bgst() { cat "$T/state/ergon/background" 2>/dev/null; }

# Read out of the palette files rather than written here, so this cannot drift
# from theme/ the way a second copy of a mapping always does.
hex() { sed -n "s/^$2=\(#[0-9A-Fa-f]\{6\}\).*/\1/p" "$E/theme/$1.env" | head -1; }
want() { printf '%s %s %s ' "$(hex "$1" COOL_BG0)" "$(hex "$1" COOL_0)" "$(hex "$1" COOL_4)"; }

echo
echo "== the generated gradient carries the ACTIVE palette"
for p in cool gruvbox nord; do
  pal "$p"; run
  check "$p renders $(want "$p")" test "$(cols)" = "$(want "$p")"
done

# The render SUCCEEDED, not merely that magick was invoked with the right
# colours. The stamp is only written after a render that worked, and it is
# removed when one fails -- so this is the one assertion that separates "the
# right command was built" from "an image came out". A temp file magick could
# not infer a format from passed every colour check above while producing
# nothing at all.
check "and the render actually produced an image" test -s "$T/home/.local/share/ergon/wallpaper.png.from"

# The regression itself. Ordering matters: cool is rendered, then gruvbox is
# selected without --force, which is exactly what `ergon theme gruvbox` from a
# tty leaves behind.
echo
echo "== switching palette rebuilds it, without --force"
pal cool;    run
pal gruvbox; run
check "cool -> gruvbox repaints the background" test "$(cols)" = "$(want gruvbox)"

echo
echo "== and an unchanged palette does NOT"
pal cool; run
_n=$(runs); run
check "a second run paints nothing" test "$(runs)" = "$_n"

echo
echo "== editing the palette in use rebuilds it"
sed -i 's/^COOL_0=.*/COOL_0=#00FF00/' "$E/theme/cool.env"
run
check "an edited ramp reaches the gradient" test "${cols:-$(cols)}" = "$(want cool)"
check "  and the edit is the colour asserted"  test "$(hex cool COOL_0)" = "#00FF00"

echo
echo "== a resize rebuilds it"
# Through the state stamp, not through an argument: passing WIDTHxHEIGHT always
# rebuilds, so it would prove nothing about the cache.
_n=$(runs)
sed -i 's/ [0-9]*x[0-9]* / 1280x800 /' "$T/data/ergon/wallpaper.png.from" 2>/dev/null \
  || sed -i 's/ [0-9]*x[0-9]* / 1280x800 /' "$T/home/.local/share/ergon/wallpaper.png.from"
run
check "a panel size that does not match the stamp repaints" test "$(runs)" -gt "$_n"

echo
echo "== a chosen image follows the palette"
D="$T/data/ergon/backgrounds"
mkdir -p "$D/cool" "$D/gruvbox"
printf 'PNGSTUB\n' > "$D/cool/clifford.png"
printf 'PNGSTUB\n' > "$D/gruvbox/clifford.png"
pal cool; run --next
check "an image is selected under cool"          test "$(bgst)" = "$D/cool/clifford.png"
pal gruvbox; run
check "  and the SAME image under gruvbox after the switch" \
  test "$(bgst)" = "$D/gruvbox/clifford.png"
pal nord; run
check "  falling back to the gradient where the palette has none" \
  test "$(bgst)" = ":generated:"

echo
echo "== a remembered image that was deleted still falls back"
pal cool; run --next
rm -f "$D/cool/clifford.png"
run
check "a deleted background does not leave the desktop bare" test "$(bgst)" = ":generated:"

echo
echo "== an unknown palette says so, and STILL draws"
# This script is what starts hyprpaper (hypr/common/autostart.lua:26-36), so it
# has to reach the bottom of the file whatever it finds. Making the unresolvable
# palette a hard error -- to match ergon-theme -- meant an early exit, no
# hyprpaper, and a desktop showing the compositor's flat background_color.
# A wrong colour is a bug. A bare desktop is the session looking broken.
pal nonesuch
_n=$(runs); _h=$(wc -l < "$T/log/hyprctl" 2>/dev/null || echo 0)
_out=$(ERGON="$E" "$E/bin/ergon-wallpaper" --force 2>&1); _rc=$?
check "ergon-wallpaper still succeeds"     test "$_rc" -eq 0
check "  names the palette it could not find" grep -q "nonesuch" <<<"$_out"
check "  and says the desktop is not showing it" grep -q "NOT showing" <<<"$_out"
check "  paints the default rather than nothing"  test "$(runs)" -gt "$_n"
check "  and reaches hyprpaper"            test "$(wc -l < "$T/log/hyprctl")" -gt "$_h"

echo
echo "== a render that fails keeps the previous background, and still draws"
# Under set -e a failing magick ended the script here, so a transient failure --
# a monitor that went away mid-run, a full disk, an OOM on a 4K canvas -- cost
# the whole wallpaper daemon rather than one repaint.
pal cool; run                                    # something good on disk first
_good=$(cat "$T/home/.local/share/ergon/wallpaper.png")
cat > "$T/stub/magick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/magick"
exit 1
EOF
chmod +x "$T/stub/magick"
_h=$(wc -l < "$T/log/hyprctl")
_out=$(ERGON="$E" "$E/bin/ergon-wallpaper" --force 2>&1); _rc=$?
check "a failed render does not kill the script" test "$_rc" -eq 0
check "  it says the render failed"              grep -q "could not render" <<<"$_out"
check "  the previous background survives intact" \
  test "$(cat "$T/home/.local/share/ergon/wallpaper.png")" = "$_good"
check "  hyprpaper is still reached"             test "$(wc -l < "$T/log/hyprctl")" -gt "$_h"
check "  and no stamp is left certifying the failure" \
  test ! -f "$T/home/.local/share/ergon/wallpaper.png.from"
# Put the working stub back for anything after this point.
cat > "$T/stub/magick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/magick"
out="${@: -1}"
# REFUSES a path it cannot infer a format from, because the real magick does.
# Writing "${@: -1}" whatever its name is what let a render to
# "wallpaper.png.new.12345" pass every assertion in this file while the real
# ImageMagick answered "no encode delegate for this image format `XC'" and the
# gradient quietly stopped following the palette.
case "$out" in
  *.png|*.jpg|*.jpeg|*.webp|*.avif) ;;
  *) echo "magick: no encode delegate for this image format" >&2; exit 1 ;;
esac
printf 'PNGSTUB\n' > "$out"
EOF
chmod +x "$T/stub/magick"
echo
echo "== ergon-wallpaper-gen, which CAN refuse, does"
# Nothing on screen waits for it -- ergon-theme fires it detached -- and it files
# its output under the palette's NAME, so falling back to cool there wrote
# cool-coloured images into cool's own cache directory, where nothing afterwards
# could tell them from legitimate ones. That is the case for refusing, and it is
# exactly the case ergon-wallpaper does not have.
pal nonesuch
#
# Its venv guard runs before the palette resolves -- correctly, it needs numpy
# either way -- so the stub below is what lets this reach the check under test
# rather than stopping at "no python".
mkdir -p "$T/data/pyfleet/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/data/pyfleet/bin/python"
chmod +x "$T/data/pyfleet/bin/python"
_out=$(ERGON="$E" "$E/bin/ergon-wallpaper-gen" --recolour 2>&1); _rc=$?
check "ergon-wallpaper-gen exits non-zero" test "$_rc" -ne 0
check "  and names the palette"            grep -q "nonesuch" <<<"$_out"

# --- a palette switched to mid-recolour is served, not discarded ---------------
# The bug this is here for: ergon-wallpaper-gen resolved its palette at startup
# and then, if a switch had landed, returned 0 before even creating the output
# directory. Measured on chiki 2026-09-24, cycling nineteen palettes: six had
# zero backgrounds, four had two or nine, three had the full set. The worker now
# takes the lock FIRST and serves whoever is current, round after round.
echo
echo "== a palette switched to mid-recolour still gets its backgrounds"
V=$T/venv/bin; mkdir -p "$V"
FIELDS=$T/data/ergon/fields          # XDG_DATA_HOME, as exported at the top
PREP=$T/data/ergon/prepared
BGS=$T/data/ergon/backgrounds
mkdir -p "$FIELDS" "$PREP" "$E/wallpaper"
for g in lorenz clifford ikeda; do
  : > "$FIELDS/$g-0-100x100.npy"
  echo cached > "$PREP/$g-0.npz"
  printf 'def generate():\n    pass\n' > "$E/wallpaper/$g.py"
done

# Stands in for recolour.py. It writes one PNG per cache entry, and on its FIRST
# full pass it flips the palette state and stops -- which is exactly what the
# real one now does when --expect stops matching --palette-state.
cat > "$V/python" <<'PYEOF'
#!/usr/bin/env bash
set -euo pipefail
script=${1:-}; shift || true
out=""; expect=""; state=""; only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)           out=$2;    shift 2 ;;
    --expect)        expect=$2; shift 2 ;;
    --palette-state) state=$2;  shift 2 ;;
    --only)          only=$2;   shift 2 ;;
    *) shift ;;
  esac
done
case "$script" in
  *recolour.py)
    echo "$expect" >> "$TEST_ROOT/log/recolour-rounds"
    mkdir -p "$out"
    if [ -n "$only" ]; then : > "$out/$only.png"; exit 0; fi
    if [ "$(wc -l < "$TEST_ROOT/log/recolour-rounds")" = 1 ] && [ -n "$state" ]; then
      echo nord > "$state"                      # a switch lands mid-pass
      echo "   $expect superseded by nord"
      exit 0
    fi
    for f in "$TEST_ROOT/data/ergon/prepared"/*.npz; do
      : > "$out/$(basename "$f" .npz).png"
    done ;;
esac
PYEOF
chmod +x "$V/python"

pal cool                              # the state file this suite already owns
: > "$T/log/recolour-rounds"
# env -u ERGON_PALETTE: an earlier case exports it as an unresolvable name, and
# it takes precedence over the state file this case is about.
env -u ERGON_PALETTE PYFLEET_VENV=$T/venv XDG_RUNTIME_DIR=$T ERGON="$E" \
  "$E/bin/ergon-wallpaper-gen" --recolour > "$T/log/gen.out" 2>&1 || true

check "the palette switched to mid-pass gets a directory" test -d "$BGS/nord"
check "  and all of its backgrounds"  test "$(find "$BGS/nord" -name '*.png' | wc -l)" -eq 3
check "  because the worker came back for it" \
      test "$(wc -l < "$T/log/recolour-rounds")" -ge 2
check "  and it says how many of how many" grep -q "of 3 backgrounds for nord" "$T/log/gen.out"

# --- a named palette fills without touching the screen -------------------------
# The way to repair a palette that was starved: name it, and let it be coloured
# in the background while the desktop stays on whatever it is showing. Both
# halves are the assertion -- it has to DO the work (it used to give up, because
# the desktop was on another palette) and it must not repaint anything.
echo
echo "== ERGON_PALETTE fills that palette, and leaves the desktop alone"
pal cool
_before=$(bgst)
# The rounds log is NOT reset: the stub supersedes only on its very first full
# pass, which the case above already consumed.
ERGON_PALETTE=gruvbox PYFLEET_VENV=$T/venv XDG_RUNTIME_DIR=$T ERGON="$E" \
  "$E/bin/ergon-wallpaper-gen" --recolour > "$T/log/gen2.out" 2>&1 || true
check "the named palette is filled"        test "$(find "$BGS/gruvbox" -name '*.png' | wc -l)" -ge 3
check "  the desktop was not repainted"    test "$(bgst)" = "$_before"
check "  and it reports its count"         grep -q "backgrounds for gruvbox" "$T/log/gen2.out"

# --- the compositor's own wallpapers ------------------------------------------
# hyprland ships wall0-2.png, and ergon-wallpaper offers them so they can be
# chosen. The same directory ships lockdead.png and lockdead2.png, which are
# what hyprlock draws when it has CRASHED -- a directory sweep took those too,
# and only running it said so. Hence a test, by name.
echo
echo "== the wallpapers hyprland ships"
HW=$T/usr-share-hypr
mkdir -p "$HW"
: > "$HW/wall0.png"; : > "$HW/wall1.png"; : > "$HW/wall2.png"
: > "$HW/lockdead.png"; : > "$HW/lockdead2.png"
pal cool
_list=$(ERGON_HYPR_WALLPAPERS="$HW" HOME=$T/home XDG_RUNTIME_DIR=$T ERGON="$E" \
        "$E/bin/ergon-wallpaper" --list 2>&1)
check "wall0-2 are offered"                 test "$(grep -c '/wall[0-9]\.png$' <<<"$_list")" -eq 3
check "  lockdead is NOT offered"           test "$(grep -c 'lockdead' <<<"$_list")" -eq 0
check "  the generated one is still first"  grep -q 'generated' <<<"$_list"
_none=$(ERGON_HYPR_WALLPAPERS="$T/nowhere" HOME=$T/home XDG_RUNTIME_DIR=$T ERGON="$E" \
        "$E/bin/ergon-wallpaper" --list 2>&1)
check "a machine without hyprland is unaffected" test "$(grep -c 'wall[0-9]' <<<"$_none")" -eq 0

# --- negative control --------------------------------------------------------
# Everything above is a string comparison against a palette file, and a bug in
# hex()/want() would make every one of them compare "" with "" and pass. Prove
# the comparison can fail before believing that it passed.
echo
echo "== the assertions can fail"
pal cool; run
check "cool's gradient is NOT gruvbox's colours" test "$(cols)" != "$(want gruvbox)"
check "the palette reader returns something"     test -n "$(want cool)"

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
