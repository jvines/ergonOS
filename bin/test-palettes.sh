#!/usr/bin/env bash
# Every palette in theme/ is well formed, readable, and renders every themed config.
#
#   ./bin/test-palettes.sh
#
# Seconds, no compositor. For each theme/*.env (type.env is the text size, not a
# palette): exactly the 22 roles ergon-theme substitutes, each a 6-digit hex;
# contrast of the text and accent roles against COOL_BG0 above a floor that every
# palette shipped before the omarchy ports already met; the raised surfaces
# differ from the ground; and `ergon-theme <palette>` renders every template with
# no @COOL_ token left over.
#
# DOES NOT COVER: how a palette LOOKS. guest-desktop.sh screenshots each one.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }

ROLES="BG0 BG1 BG2 FG0 FG1 DIM DIMMER 0 1 2 3 4 HOT_0 HOT_4 MINT BLUSH ACCENT ACTIVE URGENT WARN GOOD INACTIVE"
# Floors (WCAG contrast against BG0). Text: solarized-light is the lowest shipped
# (FG0 5.0, FG1 4.1, DIM 2.9); the rest are the lowest of every palette that
# predates the omarchy ports. DIMMER is disabled text and nord's is 1.7.
contrast() {  # contrast <env>: one line "ROLE ratio" per text/accent role
  awk -F'[=# ]+' '
    function hx(s,  i,n){n=0;s=tolower(s);for(i=1;i<=length(s);i++)n=n*16+index("0123456789abcdef",substr(s,i,1))-1;return n}
    function lin(c){c/=255; return c<=0.03928? c/12.92 : ((c+0.055)/1.055)^2.4}
    function L(h){return 0.2126*lin(hx(substr(h,1,2)))+0.7152*lin(hx(substr(h,3,2)))+0.0722*lin(hx(substr(h,5,2)))}
    function cr(a,b,  x,y,t){x=L(a);y=L(b);if(x<y){t=x;x=y;y=t}return (x+0.05)/(y+0.05)}
    /^COOL_[A-Z0-9_]+=#/{v[$1]=$2}
    END{ n=split("FG0 FG1 DIM DIMMER 0 1 2 3 4 HOT_0 HOT_4 MINT BLUSH ACCENT ACTIVE URGENT WARN GOOD",k," ")
         for(i=1;i<=n;i++) printf "%s %.2f\n", k[i], cr(v["COOL_" k[i]], v["COOL_BG0"])
         printf "FG0_OVER_FG1 %.2f\n", cr(v["COOL_FG0"], v["COOL_BG0"]) - cr(v["COOL_FG1"], v["COOL_BG0"])
         printf "BG1_SAME %d\n", (v["COOL_BG1"] == v["COOL_BG0"])
         printf "BG2_SAME %d\n", (v["COOL_BG2"] == v["COOL_BG0"]) }' "$1"
}
# The omarchy ports are held to those floors. Palettes from before them are held
# to looser ones, which is what bone (a ramp that starts at the ground) and
# everforest-light (FG1 3.8) actually are.
floor() {
  if [ "$LOOSE" = 1 ]; then case $1 in FG0) echo 3.5;; FG1) echo 3.5;; DIM) echo 2.5;; DIMMER) echo 1.5;; *) echo 1.5;; esac; return; fi
  case $1 in FG0) echo 4.5;; FG1) echo 4.0;; DIM) echo 2.5;; DIMMER) echo 1.5;; *) echo 2.0;; esac
}

# A throwaway ergonOS: the renderer, its templates, and every palette.
E=$T/ergon; mkdir -p "$E/bin" "$E/lib" "$E/theme" "$T/stub" "$T/home"
cp "$REPO/bin/ergon-theme" "$E/bin/"; cp "$REPO/lib/user-config.sh" "$E/lib/"
cp "$REPO"/theme/*.env "$E/theme/"
for d in foot mako waybar swayosd fuzzel gtk btop/themes wezterm; do
  mkdir -p "$E/$d"; cp "$REPO/$d"/*.in "$E/$d/" 2>/dev/null
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$E/bin/ergon-wallpaper"
for c in hyprctl pkill makoctl gsettings ergon-wallpaper-gen; do cp "$E/bin/ergon-wallpaper" "$T/stub/$c"; done
chmod +x "$E/bin"/* "$T/stub"/*
export PATH="$T/stub:$PATH" HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/config" XDG_RUNTIME_DIR="$T"
unset HYPRLAND_INSTANCE_SIGNATURE

n=0
for f in "$REPO"/theme/*.env; do
  p=$(basename "$f" .env); [ "$p" = type ] && continue
  n=$((n + 1)); why=""
  LOOSE=1; grep -q "omarchy" "$f" && LOOSE=0
  # Exactly the 22 roles, once each.
  got=$(sed -n 's/^COOL_\([A-Z0-9_]*\)=.*/\1/p' "$f" | sort | tr '\n' ' ')
  want=$(printf '%s\n' $ROLES | sort | tr '\n' ' ')
  [ "$got" = "$want" ] || why="$why roles differ (${got})"
  bad_hex=$(grep -E '^COOL_' "$f" | grep -vcE '^COOL_[A-Z0-9_]+=#[0-9A-Fa-f]{6}([[:space:]]|$)')
  [ "$bad_hex" = 0 ] || why="$why $bad_hex value(s) not 6-digit hex"
  if [ -z "$why" ]; then
    while read -r role r; do
      case $role in
        FG0_OVER_FG1) awk -v r="$r" 'BEGIN{exit !(r >= 0)}' || why="$why FG1 is brighter than FG0" ;;
        BG1_SAME|BG2_SAME) [ "$r" = 0 ] || why="$why ${role%_SAME} equals BG0" ;;
        *) awk -v r="$r" -v m="$(floor "$role")" 'BEGIN{exit !(r >= m)}' || why="$why $role=$r<$(floor "$role")" ;;
      esac
    done < <(contrast "$f")
  fi
  if [ -z "$why" ]; then
    out=$( cd "$E" && ERGON="$E" ./bin/ergon-theme "$p" 2>&1 ) || why="$why ergon-theme failed: $(tail -1 <<<"$out")"
    left=$(grep -rl '@COOL_' "$T/config" "$T/state" 2>/dev/null | head -1)
    [ -z "$left" ] || why="$why unexpanded @COOL_ token in $left"
  fi
  if [ -z "$why" ]; then ok "$p"; else bad "$p:$why"; fi
done
[ "$n" -ge 19 ] && ok "$n palettes checked" || bad "only $n palettes found"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
