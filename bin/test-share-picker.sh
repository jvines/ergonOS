#!/usr/bin/env bash
# ERGON-159: ergon-share-picker prints xdph's selection protocol. Stubs for
# ergon-gpu, hyprctl, fuzzel and hyprland-share-picker are put on PATH; no session.
# DOES NOT COVER: that xdph accepts the line (the VM suite runs it as xdph would).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
unset ERGON_LANG LC_ALL LC_MESSAGES; export LANG=C
mkdir "$T/bin"
cat >"$T/bin/ergon-gpu" <<'S'
#!/bin/sh
[ "${STUB_SOFTWARE:-1}" = 1 ]
S
cat >"$T/bin/hyprctl" <<'S'
#!/bin/sh
echo '[{"name":"Virtual-1","width":1920,"height":1080},{"name":"DP-2","width":2560,"height":1440}]'
S
cat >"$T/bin/hyprland-share-picker" <<'S'
#!/bin/sh
echo "real picker $*"
S
cat >"$T/bin/fuzzel" <<'S'
#!/bin/sh
cat >"$STUB_SHOWN"
[ -n "${STUB_PICK:-}" ] || exit 1
echo "$STUB_PICK"
S
chmod +x "$T"/bin/*
export PATH="$T/bin:$PATH" STUB_SHOWN="$T/shown"
export XDPH_WINDOW_SHARING_LIST='4242[HC>]foot[HT>]htop - hot[HE>]0xabc[HA>]77[HC>]firefox[HT>]Docs[HE>]0xdef[HA>]'
P="$REPO/bin/ergon-share-picker"

out=$(STUB_PICK=1 "$P"); rc=$?
eq "a screen: the line" "$out" "[SELECTION]/screen:DP-2"; eq "  exit 0" "$rc" 0
eq "the list shows outputs then windows" "$(cat "$T/shown")" "screen  Virtual-1  1920x1080
screen  DP-2  2560x1440
window  foot  htop - hot
window  firefox  Docs"
out=$(STUB_PICK=3 "$P"); eq "a window: the line carries the handle, not the address" "$out" "[SELECTION]/window:77"
out=$(STUB_PICK=2 "$P" --allow-token); eq "--allow-token adds the r flag" "$out" "[SELECTION]r/window:4242"
out=$(STUB_PICK= "$P"); rc=$?
eq "cancel: no output" "$out" ""; eq "  and a non-zero exit" "$([ $rc -ne 0 ] && echo yes)" yes
out=$(STUB_PICK=99 "$P"); rc=$?; eq "an index out of range prints nothing" "$out" ""
out=$(STUB_SOFTWARE=0 STUB_PICK=1 "$P" --allow-token); eq "hardware rendering: the real picker, same arguments" "$out" "real picker --allow-token"
out=$(XDPH_WINDOW_SHARING_LIST= STUB_PICK=0 "$P"); eq "no windows: outputs still listed" "$out" "[SELECTION]/screen:Virtual-1"
out=$(ERGON_LANG=es STUB_PICK=0 "$P"); eq "Spanish labels" "$(head -1 "$T/shown")" "pantalla  Virtual-1  1920x1080"
grep -q 'custom_picker_binary = ergon-share-picker' "$REPO/hypr/xdph.conf" && ok "xdph.conf names it" || bad "xdph.conf does not name it"
printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
