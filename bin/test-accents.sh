#!/usr/bin/env bash
# ERGON-79: `ergon accents`, the command -- what it writes, what it refuses,
# and what it claims.
#
#   ./bin/test-accents.sh
#
# Seconds, no root, no network, no session. hyprctl, pgrep and gdbus are stubs
# on PATH: hyprctl answers activewindow from $STUB_ACTIVE, pgrep says fcitx5 is
# running only when $STUB_RUNNING=1, and gdbus logs every call and answers
# GetConfig with $STUB_GETCONFIG. The checkout is a fixture copy, so a change
# to its fcitx5/omacento.conf can be made and watched arriving.
#
# COVERS: status with no choices made, and status creating nothing; on, off,
# hold (and every value it must refuse), skip and unskip by name and by the
# focused window (initialClass, then class, then a refusal); a bad class
# refused before anything is written, even after a good one; the person's file
# edited in place -- comments, unknown keys and a link into their dotfiles
# kept; the render's INI shape (top-level keys before the first section, the
# Blocklist as a list section, a repo Blocklist dropped); a repo table change
# reaching someone who made choices; the old link into the checkout replaced
# and said so; a render that is not ours left alone; and "applied" printed
# only when the running fcitx5 reports the settings back -- with no call at
# all to a fcitx5 that is not running, since a call would start one.
#
# DOES NOT COVER: a real fcitx5 reading the render. bin/test-hypr-config.sh
# does that (@@accents), with omacento built from packages/pkgbuild.
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
has()  { grep -qF -- "$2" "$1" 2>/dev/null; }
hasx() { grep -qxF -- "$2" "$1" 2>/dev/null; }
not()  { ! "$@"; }

command -v jq >/dev/null || { echo "jq is missing; it is in packages/pacman and ergon-accents reads hyprctl with it"; exit 1; }

E=$T/ergon
mkdir -p "$E/bin" "$E/lib" "$E/fcitx5" "$T/stub" "$T/home"
cp "$REPO/bin/ergon-accents" "$E/bin/"
cp "$REPO/lib/accents.sh" "$E/lib/"
cp "$REPO/fcitx5/omacento.conf" "$E/fcitx5/"

cat > "$T/stub/hyprctl" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "activewindow -j" ] && printf '%s\n' "${STUB_ACTIVE:-{\}}"
EOF
cat > "$T/stub/pgrep" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_RUNNING:-0}" = 1 ]
EOF
cat > "$T/stub/gdbus" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/gdbus.log"
case "$*" in *GetConfig*) printf '%s\n' "${STUB_GETCONFIG:-}" ;; esac
EOF
chmod +x "$T/stub"/*
export TEST_ROOT=$T PATH="$T/stub:$PATH" HOME=$T/home XDG_CONFIG_HOME=$T/home/.config ERGON=$E
unset DBUS_SESSION_BUS_ADDRESS
[ "$(command -v gdbus)" = "$T/stub/gdbus" ] && [ "$(command -v pgrep)" = "$T/stub/pgrep" ] \
  || { echo "stubs are not first on PATH; refusing to run anything"; exit 1; }

PREFS=$XDG_CONFIG_HOME/ergon/accents
LIVE=$XDG_CONFIG_HOME/fcitx5/conf/omacento.conf
OUT=$T/out
acc() { "$E/bin/ergon-accents" "$@" > "$OUT" 2>&1; }
# The top-level part of the render: everything before its first [section].
top() { awk '/^\[/ { exit } /^[A-Za-z]/ { print }' "$LIVE"; }
# One [section]'s non-comment lines.
section() { awk -v s="[$1]" '$0 == s { on = 1; next } /^\[/ { on = 0 } on && /^[^#]/ { print }' "$LIVE"; }

echo "== nothing chosen yet"
acc
check "status runs" test "$?" -eq 0
check "  on, after the repo's 250 ms" has "$OUT" "on, after a 250 ms hold"
check "  skipped nowhere" has "$OUT" "nowhere: every application"
check "  and it says fcitx5 is not running rather than asking it" has "$OUT" "not running"
check "  status creates nothing" test ! -e "$PREFS" -a ! -e "$LIVE"
check "  and made no D-Bus call: one would START an fcitx5" test ! -e "$T/gdbus.log"

echo "== the old link into the checkout"
mkdir -p "$(dirname "$LIVE")"
ln -s "$E/fcitx5/omacento.conf" "$LIVE"
acc on
check "on succeeds over the link" test "$?" -eq 0
check "  the link is a file now" test -f "$LIVE" -a ! -L "$LIVE"
check "  and it says so" has "$OUT" "was a link into the checkout"
check "  the checkout's file was not written through the link" cmp -s "$REPO/fcitx5/omacento.conf" "$E/fcitx5/omacento.conf"
check "  saved, and says fcitx5 will read it when it starts" has "$OUT" "takes effect when it starts"
check "  never 'applied' with nothing running" not has "$OUT" "applied"

echo "== off, hold, and the shape fcitx5 needs"
acc off
check "off" hasx "$PREFS" "enabled=off"
check "  one enabled= line, not two" test "$(grep -c '^enabled=' "$PREFS")" -eq 1
check "  Enabled=False is a TOP-LEVEL key of the render" hasx <(top) "Enabled=False"
acc hold 400
check "hold 400" hasx <(top) "HoldTime=400"
check "  the repo's own HoldTime=250 is not also there" not grep -q '^HoldTime=250' "$LIVE"
check "  Language and the table survive" hasx <(top) "Language=es"
check "  the table is still the repo's" hasx <(section Table) "5=n ñ ń"
check "  no Enabled or HoldTime below the first section, where they would be table rows" \
  test -z "$(awk '/^\[/ { s = 1 } s && /^(Enabled|HoldTime)=/' "$LIVE")"
check "  the first line is the render's own marker" test "$(head -1 "$LIVE")" = "$(. "$E/lib/accents.sh"; printf '%s' "$ERGON_ACCENTS_MARK")"
cp "$PREFS" "$T/prefs.before"
for v in 99 1001 abc "" 2.5 -300; do
  acc hold "$v"
  check "hold '$v' is refused" test "$?" -eq 2
done
check "  and none of them wrote anything" cmp -s "$PREFS" "$T/prefs.before"
acc hold 0250
check "hold 0250 is 250, not an octal surprise" hasx "$PREFS" "hold=250"

echo "== skip and unskip"
acc skip foot
check "skip foot" test "$(section Blocklist)" = "0=foot"
acc skip foot
check "  twice is still once" test "$(grep -c '^skip=foot$' "$PREFS")" -eq 1
STUB_ACTIVE='{"class":"org.wezfurlong.wezterm","initialClass":"org.wezfurlong.wezterm"}' acc skip
check "skip with no class takes the focused window's" test "$(section Blocklist | tail -1)" = "1=org.wezfurlong.wezterm"
STUB_ACTIVE='{"class":"late-class","initialClass":""}' acc skip
check "  initialClass empty: its class" hasx "$PREFS" "skip=late-class"
STUB_ACTIVE='{}' acc skip
check "  no focused window: refused" test "$?" -eq 2
check "    saying why" has "$OUT" "no focused window"
cp "$PREFS" "$T/prefs.before"
acc skip good-one 'bad"one'
check "a bad class is refused" test "$?" -eq 2
check "  before the good one before it was written" cmp -s "$PREFS" "$T/prefs.before"
acc unskip foot
check "unskip foot" not grep -q '=foot$' <(section Blocklist)
check "  the rest renumbered from 0" test "$(section Blocklist | head -1)" = "0=org.wezfurlong.wezterm"
acc unskip nothere
check "unskip of a class not skipped says so" has "$OUT" "nothere was not skipped"

echo "== the person's file is theirs"
printf '# my own note\ncolour=blue\n' >> "$PREFS"
acc hold 300
check "a hand-written comment survives a change" hasx "$PREFS" "# my own note"
check "  and a key this does not know" hasx "$PREFS" "colour=blue"
check "  the hold changed in place" test "$(grep -c '^hold=' "$PREFS")" -eq 1 -a "$(grep '^hold=' "$PREFS")" = "hold=300"
mkdir -p "$T/dotfiles"; mv "$PREFS" "$T/dotfiles/accents"; ln -s "$T/dotfiles/accents" "$PREFS"
acc off
check "a prefs file linked into dotfiles stays a link" test -L "$PREFS"
check "  and the change went through it" hasx "$T/dotfiles/accents" "enabled=off"
printf 'hold=5000\nenabled=maybe\n' >> "$PREFS"
acc
check "nonsense in the file is named, not applied" has "$OUT" "ignoring hold=5000"
check "  the last good value stands: 300" has "$OUT" "after a 300 ms hold"

echo "== the repo still reaches someone who chose"
sed -i 's/^5=n ñ ń$/5=n ñ ń ň/' "$E/fcitx5/omacento.conf"
printf '\n[Blocklist]\n0=from-the-repo\n' >> "$E/fcitx5/omacento.conf"
acc hold 300
check "a table row changed in the repo arrives" hasx <(section Table) "5=n ñ ń ň"
check "  with the person's choices intact" hasx <(top) "HoldTime=300"
check "  a [Blocklist] in the repo's file is dropped: that list is the person's" \
  not grep -q from-the-repo "$LIVE"
check "  exactly one [Blocklist]" test "$(grep -c '^\[Blocklist\]$' "$LIVE")" -eq 1

echo "== a file that is not our render"
printf 'Enabled=True\nHoldTime=900\n' > "$LIVE"
cp "$LIVE" "$T/foreign"
acc on
check "is refused" test "$?" -eq 3
check "  and left exactly as it was" cmp -s "$LIVE" "$T/foreign"
rm -f "$LIVE"; acc on

echo "== 'applied' means fcitx5 said so"
rm -f "$T/gdbus.log"
want="({'HoldTime': <'300'>, 'Enabled': <'True'>, 'Blocklist': <{'0': <'org.wezfurlong.wezterm'>, '1': <'late-class'>}>, 'Language': <'es'>},)"
STUB_RUNNING=1 STUB_GETCONFIG="$want" acc hold 300
check "fcitx5 reports these settings: applied" has "$OUT" "applied"
check "  after ReloadAddonConfig omacento, not fcitx5-remote -r" has "$T/gdbus.log" "ReloadAddonConfig omacento"
check "  and read back with GetConfig" has "$T/gdbus.log" "GetConfig fcitx://config/addon/omacento"
STUB_RUNNING=1 STUB_GETCONFIG="${want/300/250}" acc hold 300
check "fcitx5 reports something else: not applied" test "$?" -eq 1
check "  and says so" has "$OUT" "did not take it"
check "  never 'applied'" not has "$OUT" " applied"
STUB_RUNNING=1 STUB_GETCONFIG="$want" acc
check "status agrees with a fcitx5 that holds them" has "$OUT" "running, with exactly these"
rm -f "$T/gdbus.log"
acc hold 300
check "nothing running: no call at all" test ! -e "$T/gdbus.log"

echo
printf '   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
