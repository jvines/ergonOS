#!/usr/bin/env bash
# `ergon reset` against stubs (ERGON-154): backs up first, resets only the
# per-user choices, never touches ~/.config/ergon, asks before acting.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }

E=$T/ergon; mkdir -p "$E/bin" "$T/state/ergon" "$T/config/ergon" "$T/data" "$T/home"
cp "$REPO/bin/ergon-reset" "$E/bin/"
printf '#!/usr/bin/env bash\necho install >> "%s/calls"\n' "$T" > "$E/install.sh"
printf '#!/usr/bin/env bash\necho theme >> "%s/calls"\n' "$T" > "$E/bin/ergon-theme"
chmod +x "$E/install.sh" "$E/bin"/*
export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/config" XDG_DATA_HOME="$T/data" ERGON="$E"
printf 'gruvbox' > "$T/state/ergon/palette"; printf 'TEXT_SIZE=16\n' > "$T/state/ergon/type.env"
printf 'FONT_MONO=Fira Code\n' > "$T/state/ergon/font.env"; : > "$T/state/ergon/bundle-ledger"; : > "$T/state/ergon/welcome-shown"
printf '.x{color:red}\n' > "$T/config/ergon/waybar.css"
R() { "$E/bin/ergon-reset" "$@"; }

R --dry-run >/dev/null 2>&1
check "--dry-run changes nothing" test -e "$T/state/ergon/palette" -a ! -e "$T/calls" -a -z "$(ls "$T/data")"
R </dev/null >/dev/null 2>&1; check "without a terminal and without --yes it refuses" test "$?" != 0
check "  and changed nothing" test -e "$T/state/ergon/palette"
echo n | R >/dev/null 2>&1 </dev/null; check "declined: nothing changed" test -e "$T/state/ergon/type.env"

R --yes >/dev/null 2>&1; check "--yes exits 0" test "$?" = 0
B=$(ls -d "$T"/data/ergon/reset-* 2>/dev/null | head -1)
check "a timestamped backup exists" test -d "$B"
check "  with the old palette" grep -qx gruvbox "$B/state/palette"
check "  with the old size and font" bash -c "grep -q 16 '$B/state/type.env' && grep -q 'Fira Code' '$B/state/font.env'"
check "  and a copy of the override files" grep -q red "$B/user-config/waybar.css"
check "palette, size and font are gone" test ! -e "$T/state/ergon/palette" -a ! -e "$T/state/ergon/type.env" -a ! -e "$T/state/ergon/font.env"
check "the override file is untouched" grep -q red "$T/config/ergon/waybar.css"
check "the ledger and welcome stamp are untouched" test -e "$T/state/ergon/bundle-ledger" -a -e "$T/state/ergon/welcome-shown"
check "it re-linked and re-rendered, in that order" test "$(tr '\n' ' ' < "$T/calls")" = "install theme "
rm -f "$T/calls"; R --yes >/dev/null 2>&1
check "already default: still succeeds, no state invented" test "$?" = 0 -a ! -e "$T/state/ergon/palette"
chmod 500 "$T/data/ergon"; printf x > "$T/state/ergon/palette"; rm -f "$T/calls"
R --yes >/dev/null 2>&1; rc=$?; chmod 700 "$T/data/ergon"
if [ "$(id -u)" != 0 ]; then
  check "an unwritable backup stops the reset" test "$rc" != 0 -a -e "$T/state/ergon/palette" -a ! -e "$T/calls"
fi
echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
