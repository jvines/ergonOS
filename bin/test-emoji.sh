#!/usr/bin/env bash
# ERGON-87: ergon-emoji's parsing of emoji-test.txt, and the pick being copied
# and typed. fuzzel, wl-copy and wtype are stubs. ./bin/test-emoji.sh
set -uo pipefail
export ERGON_LANG=en   # the assertions read English; i18n follows the session locale (ERGON-158)
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
E="$REPO/bin/ergon-emoji"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }

cat > "$T/fx.txt" <<'D'
# group: Smileys & Emotion
1F600                                                  ; fully-qualified     # 😀 E1.0 grinning face
263A                                                   ; unqualified         # ☺ E0.6 smiling face
263A FE0F                                              ; fully-qualified     # ☺️ E0.6 smiling face
1F44D 1F3FD                                            ; fully-qualified     # 👍🏽 E1.0 thumbs up: medium skin tone
1F3F3 200D 1F308                                       ; minimally-qualified # 🏳‍🌈 E4.0 rainbow flag
D
chk "only fully-qualified, name kept" "$("$E" --list "$T/fx.txt")" "😀  grinning face
☺️  smiling face
👍🏽  thumbs up: medium skin tone"

mkdir "$T/bin"
printf '#!/bin/sh\nhead -n1\n' > "$T/bin/fuzzel"
printf '#!/bin/sh\ncat > "%s/clip"\n' "$T" > "$T/bin/wl-copy"
printf '#!/bin/sh\nshift; printf %%s "$1" > "%s/typed"\n' "$T" > "$T/bin/wtype"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*
# Pick mode reads the real data path; give it the fixture by a fake /usr path
# is not possible, so exercise it through a wrapper that points find_data at it.
mkdir -p "$T/x/bin" "$T/x/lib"; cp "$REPO/lib/i18n.sh" "$T/x/lib/"   # the script finds lib/ beside bin/
sed "s#^find_data() {#find_data() { echo $T/fx.txt; return 0; }\nold_find() {#" "$E" > "$T/x/bin/e"; chmod +x "$T/x/bin/e"
PATH="$T/bin:$PATH" "$T/x/bin/e"
chk "copied" "$(cat "$T/clip")" "😀"
chk "typed"  "$(cat "$T/typed")" "😀"
exit $fail
