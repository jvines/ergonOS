#!/usr/bin/env bash
# ergon-browser (ERGON-103): the default browser is the machine's, a link goes to
# it, and its window is raised. Stubs xdg-mime, the browser and hyprctl.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
mkdir -p "$T/stub" "$T/share/applications"
for b in otherbrowser firefox; do
  printf '#!/bin/sh\necho "%s $*" >> "$T/log"\n' "$b" > "$T/stub/$b"; chmod +x "$T/stub/$b"
done
printf '#!/bin/sh\necho "$XDG_DEFAULT"\n' > "$T/stub/xdg-mime"
cat > "$T/stub/hyprctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  clients) echo '[{"address":"0xa","class":"Otherbrowser","focusHistoryID":2},{"address":"0xb","class":"otherbrowser","focusHistoryID":0},{"address":"0xc","class":"firefox","focusHistoryID":1}]' ;;
  dispatch) echo "$2" >> "$T/log" ;;
esac
STUB
chmod +x "$T/stub"/*
printf '[Desktop Entry]\nExec=otherbrowser --new-tab %%u\n' > "$T/share/applications/other.desktop"
export PATH="$T/stub:$PATH" T XDG_DATA_HOME="$T/share" XDG_DATA_DIRS="$T/none" HYPRLAND_INSTANCE_SIGNATURE=x
B="$REPO/bin/ergon-browser"

: > "$T/log"; XDG_DEFAULT=other.desktop BROWSER=ergon-browser "$B" https://x.org
check "a link opens in the machine's default, not Firefox" grep -qx 'otherbrowser --new-tab https://x.org' "$T/log"
check "field codes are dropped, the url appended once"     bash -c '! grep -q "%u" "$1"' _ "$T/log"
check "the window focused last is raised after the link"   grep -q 'address:0xb' "$T/log"
: > "$T/log"; XDG_DEFAULT=other.desktop "$B"
check "no link: launch only, no focus dispatch"            bash -c '! grep -q address "$1" && grep -qx "otherbrowser --new-tab" "$1"' _ "$T/log"
: > "$T/log"; XDG_DEFAULT=gone.desktop "$B" https://y.org
check "an unset or uninstalled default falls back to firefox" grep -qx 'firefox https://y.org' "$T/log"
: > "$T/log"; XDG_DEFAULT=other.desktop HYPRLAND_INSTANCE_SIGNATURE= "$B" https://z.org
check "outside Hyprland it launches and does not touch hyprctl" bash -c '! grep -q address "$1"' _ "$T/log"

check "SUPER+B runs ergon-browser, no hardcoded firefox" bash -c 'grep -q "\"Browser\".*ergon-browser" "$1" && ! grep -q "launch .. \"firefox\"" "$1"' _ "$REPO/hypr/common/binds.lua"
check "the session points \$BROWSER at it"                grep -qx 'export BROWSER=ergon-browser' "$REPO/uwsm/env-hyprland.d/ergon-browser"
check "install.sh links the env drop-in"                  grep -q 'link uwsm/env-hyprland.d/ergon-browser' "$REPO/install.sh"
printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
