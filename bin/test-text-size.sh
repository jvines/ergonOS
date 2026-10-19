#!/usr/bin/env bash
# `ergon text-size` against stubs (ERGON-116): the generator's output at two
# factors, that the size is persisted per user, and that a theme switch keeps it.
# Seconds, no compositor. DOES NOT COVER how it looks; the VM run does.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
hasx() { grep -qxF -- "$2" "$1" 2>/dev/null; }

E=$T/ergon
mkdir -p "$E/bin" "$E/lib" "$E/theme" "$T/stub" "$T/log" "$T/home"
cp "$REPO/bin/ergon-theme" "$REPO/bin/ergon-text-size" "$E/bin/"
cp "$REPO/lib/user-config.sh" "$E/lib/"
cp "$REPO/theme/cool.env" "$REPO/theme/gruvbox.env" "$REPO/theme/type.env" "$E/theme/"
for d in foot mako waybar swayosd fuzzel gtk btop/themes wezterm; do
  mkdir -p "$E/$d"; cp "$REPO/$d"/*.in "$E/$d/" 2>/dev/null
done
printf '#!/usr/bin/env bash\n' > "$E/bin/ergon-wallpaper"
for c in hyprctl pkill makoctl gsettings pgrep ergon-wallpaper-gen fuzzel; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$TEST_ROOT/log/%s"\n[ "%s" = pgrep ] && exit 1\nexit 0\n' "$c" "$c" > "$T/stub/$c"
done
# the picker answers "large"
printf '#!/usr/bin/env bash\ncat > "$TEST_ROOT/log/menu"\necho "large  14 pt"\n' > "$T/stub/fuzzel"
chmod +x "$T/stub"/* "$E/bin"/*
export TEST_ROOT="$T" PATH="$T/stub:$PATH" HOME="$T/home" \
       XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/config" XDG_RUNTIME_DIR="$T"
ts() { ( cd "$E" && HYPRLAND_INSTANCE_SIGNATURE=test ERGON="$E" ./bin/ergon-text-size "$@" ); }
th() { ( cd "$E" && HYPRLAND_INSTANCE_SIGNATURE=test ERGON="$E" ./bin/ergon-theme "$@" ); }
th gruvbox >/dev/null 2>&1

ts normal >/dev/null 2>&1
check "normal: foot at the designed 11" hasx "$E/foot/foot.ini" "font=JetBrainsMono Nerd Font:size=11"
check "normal: waybar at the designed 13" hasx "$E/waybar/style.css" "  font-size: 13px;"
: > "$T/log/gsettings"
ts 1.5 >/dev/null 2>&1   # 11 * 1.5 = 16.5 -> 17
check "factor 1.5: foot 17"    hasx "$E/foot/foot.ini" "font=JetBrainsMono Nerd Font:size=17"
check "factor 1.5: mako 17"    hasx "$E/mako/config" "font=JetBrainsMono Nerd Font 17"
check "factor 1.5: fuzzel 19"  hasx "$E/fuzzel/fuzzel.ini" "font=JetBrainsMono Nerd Font:size=19"
check "factor 1.5: waybar 20"  hasx "$E/waybar/style.css" "  font-size: 20px;"
check "factor 1.5: wezterm 17" hasx "$E/wezterm/wezterm.lua" "config.font_size = 17.0"
check "factor 1.5: GTK scale 1.55" hasx "$T/log/gsettings" "set org.gnome.desktop.interface text-scaling-factor 1.55"
check "mako was reloaded" grep -q reload "$T/log/makoctl"
check "persisted per user" hasx "$T/state/ergon/type.env" "TEXT_SIZE=17"
check "  and the checkout default is untouched" hasx "$E/theme/type.env" "TEXT_SIZE=11"
th cool >/dev/null 2>&1
check "a theme switch keeps the size" hasx "$E/foot/foot.ini" "font=JetBrainsMono Nerd Font:size=17"
ts large >/dev/null 2>&1
check "name large = 14 pt" hasx "$T/state/ergon/type.env" "TEXT_SIZE=14"
ts small >/dev/null 2>&1
check "name small = 9 pt" hasx "$T/state/ergon/type.env" "TEXT_SIZE=9"
ts >/dev/null 2>&1
check "no argument shows the picker and applies the choice" hasx "$T/state/ergon/type.env" "TEXT_SIZE=14"
check "  with the current size marked" grep -q 'small  9 pt  (current)' "$T/log/menu"
for v in 0.2 5 abc 1.5x -1 ""; do
  [ -n "$v" ] || continue
  ts "$v" >/dev/null 2>&1; check "'$v' is refused" test "$?" != 0
done
check "  and none changed the size" hasx "$T/state/ergon/type.env" "TEXT_SIZE=14"
echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
