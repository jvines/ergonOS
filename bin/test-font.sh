#!/usr/bin/env bash
# `ergon font` against stubs (ERGON-131): the family reaches every themed
# surface, is refused when not installed or not a plain name, is kept per user,
# and survives a palette switch and a text-size change. Seconds, no compositor.
# DOES NOT COVER how it looks; the VM run's font screenshot does.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
hasx() { grep -qxF -- "$2" "$1" 2>/dev/null; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }

E=$T/ergon
mkdir -p "$E/bin" "$E/lib" "$E/theme" "$T/stub" "$T/log" "$T/home"
cp "$REPO/bin/ergon-theme" "$REPO/bin/ergon-font" "$REPO/bin/ergon-text-size" "$E/bin/"
cp "$REPO/lib/user-config.sh" "$E/lib/"
cp "$REPO/theme/cool.env" "$REPO/theme/gruvbox.env" "$REPO/theme/type.env" "$E/theme/"
for d in foot mako waybar swayosd fuzzel gtk btop/themes wezterm hypr hypr/common; do
  mkdir -p "$E/$d"; cp "$REPO/$d"/*.in "$E/$d/" 2>/dev/null
done
printf '#!/usr/bin/env bash\n' > "$E/bin/ergon-wallpaper"
for c in hyprctl pkill makoctl gsettings pgrep ergon-wallpaper-gen; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$TEST_ROOT/log/%s"\n[ "%s" = pgrep ] && exit 1\nexit 0\n' "$c" "$c" > "$T/stub/$c"
done
# fontconfig: monospace query gets the mono list, anything else the full one
cat > "$T/stub/fc-list" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *spacing=mono*) printf 'Fira Code,Fira Code Retina\nJetBrainsMono Nerd Font\nDejaVu Sans Mono\n' ;;
  *) printf 'Inter\nNoto Sans\nFira Code\n' ;;
esac
EOS
printf '#!/usr/bin/env bash\ncat > "$TEST_ROOT/log/menu"\necho "DejaVu Sans Mono"\n' > "$T/stub/fuzzel"
chmod +x "$T/stub"/* "$E/bin"/*
export TEST_ROOT="$T" PATH="$T/stub:$PATH" HOME="$T/home" \
       XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/config" XDG_RUNTIME_DIR="$T"
ef() { ( cd "$E" && HYPRLAND_INSTANCE_SIGNATURE=test ERGON="$E" ./bin/ergon-font "$@" ); }
th() { ( cd "$E" && HYPRLAND_INSTANCE_SIGNATURE=test ERGON="$E" ./bin/ergon-theme "$@" ); }
th gruvbox >/dev/null 2>&1

check "default: foot renders JetBrainsMono" hasx "$E/foot/foot.ini" "font=JetBrainsMono Nerd Font:size=11"
check "default: GTK renders Noto Sans" hasx "$E/gtk/settings.ini" "gtk-font-name=Noto Sans 11"
check "--list marks the current family" bash -c "PATH='$PATH' HOME='$HOME' ERGON='$E' '$E/bin/ergon-font' --list | grep -qx 'JetBrainsMono Nerd Font  (current)'"

ef mono "Fira Code" >/dev/null 2>&1; check "mono Fira Code exits 0" test "$?" = 0
check "foot follows"    hasx "$E/foot/foot.ini" "font=Fira Code:size=11"
check "mako follows"    hasx "$E/mako/config" "font=Fira Code 11"
check "fuzzel follows"  hasx "$E/fuzzel/fuzzel.ini" "font=Fira Code:size=12"
check "waybar follows"  has "$E/waybar/style.css" 'font-family: "Fira Code",'
check "wezterm follows" has "$E/wezterm/wezterm.lua" '"Fira Code",'
check "hyprlock follows" has "$E/hypr/hyprlock.conf" "font_family = Fira Code"
check "lock widgets in looknfeel follow" has "$E/hypr/common/looknfeel.lua" 'font_family = "Fira Code"'
check "no placeholder is left anywhere" bash -c "! grep -rl '@FONT_' '$E' --include=foot.ini --include=config --include=style.css --include=wezterm.lua --include=hyprlock.conf"
check "persisted per user" hasx "$T/state/ergon/font.env" "FONT_MONO=Fira Code"
check "  and the checkout carries no font file" test ! -e "$E/theme/font.env"
th cool >/dev/null 2>&1
check "a palette switch keeps the family" hasx "$E/foot/foot.ini" "font=Fira Code:size=11"
( cd "$E" && ERGON="$E" HYPRLAND_INSTANCE_SIGNATURE=test ./bin/ergon-text-size large ) >/dev/null 2>&1
check "a text-size change keeps the family" hasx "$E/foot/foot.ini" "font=Fira Code:size=14"

ef ui Inter >/dev/null 2>&1
check "ui Inter reaches GTK" hasx "$E/gtk/settings.ini" "gtk-font-name=Inter 11"
check "  and gsettings" has "$T/log/gsettings" "font-name Inter 11"
check "  and left the mono family alone" hasx "$E/foot/foot.ini" "font=Fira Code:size=14"

ef mono "Comic Papyrus" >/dev/null 2>&1; check "an uninstalled family is refused" test "$?" != 0
for v in 'a"b' 'a|b' 'a&b' 'a/b' 'a\b' '-x' '$(id)'; do
  ef mono "$v" >/dev/null 2>&1; check "'$v' is refused" test "$?" != 0
done
check "  and none changed the family" hasx "$E/foot/foot.ini" "font=Fira Code:size=14"
printf 'FONT_MONO=a"b\n' > "$T/state/ergon/font.env"
th >/dev/null 2>&1; check "a hand-edited font.env stops the render" test "$?" != 0
printf 'FONT_MONO=Fira Code\nFONT_UI=Inter\n' > "$T/state/ergon/font.env"

ef >/dev/null 2>&1
check "no argument shows the picker and applies the choice" hasx "$T/state/ergon/font.env" "FONT_MONO=DejaVu Sans Mono"
check "  with the current family marked" grep -q 'Fira Code  (current)' "$T/log/menu"
ef mono default >/dev/null 2>&1
check "default restores JetBrainsMono" hasx "$E/foot/foot.ini" "font=JetBrainsMono Nerd Font:size=14"
echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
