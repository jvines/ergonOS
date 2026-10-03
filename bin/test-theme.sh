#!/usr/bin/env bash
# Exercise what `ergon theme` does to a RUNNING desktop, against stubs.
#
#   ./bin/test-theme.sh
#
# Seconds, no compositor, no VM. hyprctl, pkill, makoctl and gsettings are
# stubs that log their argv, so the assertions are about exactly what would
# have been done to a live session -- which daemon is reloaded, which is
# restarted, and which is signalled.
#
# The foot half is not a stub. A real pty is opened with script(1) and the
# escape sequences are read back out of it, because "the right bytes were
# built" and "the bytes reached the terminal" are different claims and only
# the second one is the feature.
#
# COVERS: mako reloaded, btop signalled and NOT signalled when the signal is
# known to kill it, waybar and swayosd restarted, every colour in foot.ini
# reaching an open foot window, and the palette actually changing when a
# different one is named.
#
# DOES NOT COVER: that mako, btop, swayosd and foot then LOOK right. Nothing
# outside a session can claim that; the palette-switch section of
# test/arch-vm/guest-desktop.sh makes the part of it that is assertable.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d)
SPID=""
cleanup() { [ -n "$SPID" ] && kill "$SPID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
has()  { grep -qaF -- "$2" "$1" 2>/dev/null; }
hasx() { grep -qxF -- "$2" "$1" 2>/dev/null; }
not()  { ! "$@"; }
quiet() { "$@" >/dev/null 2>&1; }

# --- a throwaway ergonOS, holding only what the renderer touches -------------
E=$T/ergon
mkdir -p "$E/bin" "$E/lib" "$E/theme" "$T/stub" "$T/log" "$T/home"
cp "$REPO/bin/ergon-theme" "$E/bin/"
cp "$REPO/lib/user-config.sh" "$E/lib/"
cp "$REPO/theme/cool.env" "$REPO/theme/gruvbox.env" "$REPO/theme/gruvbox-light.env" \
   "$REPO/theme/catppuccin-latte.env" "$REPO/theme/type.env" "$E/theme/"
for d in foot mako waybar swayosd fuzzel gtk btop/themes wezterm; do
  mkdir -p "$E/$d"; cp "$REPO/$d"/*.in "$E/$d/" 2>/dev/null
done

# ergon-theme calls this one by path, not through PATH.
cat > "$E/bin/ergon-wallpaper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/ergon-wallpaper"
EOF

for c in hyprctl pkill makoctl gsettings; do
  cat > "$T/stub/$c" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$TEST_ROOT/log/$c"
EOF
done
# This one LINGERS, because the real one does: it is detached and recolours
# every background from cached fields, which takes seconds to minutes. That is
# the whole point of the assertion further down -- the apply lock must not
# still be held by it.
cat > "$T/stub/ergon-wallpaper-gen" <<'EOF'
#!/usr/bin/env bash
printf '%s
' "$*" >> "$TEST_ROOT/log/ergon-wallpaper-gen"
exec sleep 30
EOF
# pgrep answers for the fake foot: -x foot gives the pty holder, -P its child.
cat > "$T/stub/pgrep" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-x foot") cat "$TEST_ROOT/footpid" 2>/dev/null ;;
  -P*)        cat "$TEST_ROOT/footchild" 2>/dev/null ;;
  *)          exit 1 ;;
esac
EOF
chmod +x "$T/stub"/* "$E/bin"/*
export TEST_ROOT="$T" PATH="$T/stub:$PATH" HOME="$T/home" \
       XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/config" \
       XDG_RUNTIME_DIR="$T"

# ergon-wallpaper-gen is in the list because ergon-theme resolves it through
# PATH and detaches it: on a machine with ergonOS installed, five runs of this
# file would leave five real numpy recolours running after it exits, holding
# the same lock a real palette switch uses.
for c in pkill hyprctl makoctl gsettings ergon-wallpaper-gen; do
  [ "$(command -v "$c")" = "$T/stub/$c" ] \
    || { echo "stub for $c is not first on PATH; refusing to run anything"; exit 1; }
done

# --- a real pty, standing in for an open foot window -------------------------
# script(1) holds the master and writes everything the slave receives into a
# file, which is the only way to prove from outside that the sequences arrived.
: > "$T/footpid"; : > "$T/footchild"
# --flush, or the typescript sits in a buffer and the sequences that did
# arrive are invisible until script exits.
script -q -f -c "sleep 30" "$T/typescript" >/dev/null 2>&1 &
SPID=$!
for _ in $(seq 40); do
  CHILD=$(ps --ppid "$SPID" -o pid= 2>/dev/null | tr -d ' ' | head -1)
  [ -n "$CHILD" ] && break
  sleep 0.1
done
PTY=$(ps -o tty= -p "${CHILD:-0}" 2>/dev/null | tr -d '[:space:]')
if [ -n "${CHILD:-}" ] && [ -c "/dev/$PTY" ]; then
  printf '%s\n' "$SPID"  > "$T/footpid"
  printf '%s\n' "$CHILD" > "$T/footchild"
else
  # Not a note. Five of the assertions below are the only ones in this repo
  # that watch bytes reach a terminal, and a harness that quietly skips its
  # strongest checks reports "0 failed" having tested the thing least.
  bad "no pty available (script(1), /dev/ptmx): the foot assertions cannot run"
fi

run() { ( cd "$E" && HYPRLAND_INSTANCE_SIGNATURE=test ERGON="$E" ./bin/ergon-theme "$@" ) ; }
reset_logs() { rm -f "$T/log"/*; }

# --- the apply step, on a session that is up ---------------------------------
run cool > "$T/out" 2>&1
check "it applies when there is a compositor to apply to" has "$T/out" "applying"
check "mako is told to reload"                hasx "$T/log/makoctl" "reload"
check "btop is signalled, not restarted"      hasx "$T/log/pkill" "-USR2 -x btop"
check "waybar is restarted"                   hasx "$T/log/pkill" "-x waybar"
check "  and started again"                   has  "$T/log/hyprctl" 'exec_raw("waybar")'
check "swayosd is restarted, since it reads its CSS once and has no reload" \
  hasx "$T/log/pkill" "-x swayosd-server"
check "  and started again the way autostart.lua starts it" \
  has "$T/log/hyprctl" 'exec_raw("swayosd-server")'
check "hyprland is told to reload"            hasx "$T/log/hyprctl" "reload"
check "the wallpaper is redrawn from the new ramp" has "$T/log/ergon-wallpaper" "--force"
check "  and the backgrounds are recoloured for the palette just chosen" \
  has "$T/log/ergon-wallpaper-gen" "--recolour"

# The apply step takes a lock so that holding SUPER+T cannot leave two of every
# daemon. That lock must be released when the APPLY ends, not when the
# detached recolour does -- the recolour is still running right now (its stub
# sleeps 30s), and if it inherited the lock fd the next palette press waits out
# the full flock timeout before anything moves.
check "the apply lock is not left held by the detached recolour" \
  flock -n "$T/ergon-theme-apply.lock" true

# --- foot, through a real pty -------------------------------------------------
if [ -s "$T/footpid" ]; then
  ini="$E/foot/foot.ini"
  check "an open foot window is told the new foreground" \
    has "$T/typescript" "]10;#$(sed -n 's/^foreground=//p' "$ini" | head -1)"
  check "  and the new background" \
    has "$T/typescript" "]11;#$(sed -n 's/^background=//p' "$ini" | head -1)"
  check "  and the cursor, which is the SECOND colour on that line" \
    has "$T/typescript" "]12;#$(sed -n 's/^cursor=//p' "$ini" | head -1 | awk '{print $2}')"
  check "  and the selection, both ways round" \
    bash -c 'grep -qaF "]17;#$2" "$1" && grep -qaF "]19;#$3" "$1"' _ "$T/typescript" \
      "$(sed -n 's/^selection-background=//p' "$ini" | head -1)" \
      "$(sed -n 's/^selection-foreground=//p' "$ini" | head -1)"

  # The drift guard. The mapping from palette role to ANSI slot lives in
  # foot.ini.in; if a key is added or renamed there and the OSC builder does
  # not follow, new windows get it and the open one silently does not.
  # Per SLOT, not per colour. Eleven of the twenty-one values in this palette
  # appear more than once -- foreground, selection-foreground and bright7 are
  # all the same hex -- so asking only whether a colour reached the terminal
  # passes with every bright slot written to the wrong ANSI index. Verified by
  # making exactly that mutation.
  missed=""
  while IFS='=' read -r k v; do
    case "$k" in alpha|'') continue ;; esac
    case "$k" in
      foreground)           want="]10;#$v" ;;
      background)           want="]11;#$v" ;;
      cursor)               want="]12;#$(printf '%s' "$v" | awk '{print $NF}')" ;;
      selection-background) want="]17;#$v" ;;
      selection-foreground) want="]19;#$v" ;;
      regular[0-7])         want="]4;${k#regular};#$v" ;;
      bright[0-7])          want="]4;$(( ${k#bright} + 8 ));#$v" ;;
      *)                    want="" ;;
    esac
    # An unmapped key is the drift this guard exists for: something was added
    # to the template that nothing turns into a sequence.
    if [ -z "$want" ]; then missed="$missed $k(no-slot)"; continue; fi
    grep -qaF "$want" "$T/typescript" || missed="$missed $k"
  done < <(sed -n '/^\[colors-dark\]/,/^\[colors-light\]/p' "$ini" | grep '=')
  check "every colour foot.ini sets reaches the window ($(printf '%s' "$missed" | wc -w) missed)" \
    test -z "$missed"
  [ -n "$missed" ] && printf '     unmapped:%s\n' "$missed"
fi

# --- btop, when signalling it is known to kill it -----------------------------
# btop#860: with the GPU box shown, the redraw after a reload runs off the end
# of a vector and the process aborts. Stale colours are better than that.
reset_logs
mkdir -p "$T/config/btop"
printf 'shown_boxes = "cpu mem gpu0"\n' > "$T/config/btop/btop.conf"
run cool >/dev/null 2>&1
check "a btop showing the GPU box is left alone" not hasx "$T/log/pkill" "-USR2 -x btop"
check "  while everything else still happens"    hasx "$T/log/makoctl" "reload"
printf 'shown_boxes = "cpu mem net proc"\n' > "$T/config/btop/btop.conf"
reset_logs
run cool >/dev/null 2>&1
check "a btop without it is signalled again"     hasx "$T/log/pkill" "-USR2 -x btop"

# --- and the render itself still follows the palette --------------------------
reset_logs
run gruvbox >/dev/null 2>&1
check "switching to another palette exits 0" test "$?" = 0
bg=$(sed -n 's/^COOL_BG1=\(#[0-9A-Fa-f]*\).*/\1/p'    "$E/theme/gruvbox.env" | head -1)
act=$(sed -n 's/^COOL_ACTIVE=\(#[0-9A-Fa-f]*\).*/\1/p' "$E/theme/gruvbox.env" | head -1)
# One check per needle, not one for both. An empty needle makes every grep
# below match any file at all, and "$bg$act" is non-empty while either half is
# -- so a palette missing exactly one role passed, against a renderer that had
# refused to render anything.
check "the palette names the background these assertions look for" test -n "$bg"
check "  and the accent"                                            test -n "$act"
# ${x:-<unset>} rather than $x: an empty needle would leave a prefix that both
# files always contain, so the check would pass against the stale render it is
# meant to catch. The placeholder cannot match anything.
check "naming another palette rewrites the surfaces" \
  has "$E/mako/config" "background-color=${bg:-<unset>}"
# Anchored on the declaration, not on the hex: the template renders @COOL_ACTIVE@
# into its own comment as well, so a bare colour match would pass with the rule
# it is about deleted -- and the OSD would fall through to upstream's white.
check "  including the one that had never been themed at all" \
  has "$E/swayosd/style.css" "background: ${act:-<unset>};"
# A dark palette computes the same icon theme the launcher used to hardcode, so
# only a light one can tell the fix from the bug.
run gruvbox-light >/dev/null 2>&1
check "  and a light palette reaches the launcher's icons, which it never did" \
  has "$E/fuzzel/fuzzel.ini" "icon-theme=Papirus-Light"
check "  the same way it reaches GTK's" \
  has "$E/gtk/settings.ini" "gtk-icon-theme-name=Papirus-Light"

# --- gtk-4.0 carries both modes, so a running GTK4 app follows a switch -------
# Asserted per BLOCK, through the one define every palette renders exactly once
# per copy of gtk.css.in; a whole-file grep would pass with the two swapped.
bg() { sed -n 's/^COOL_BG0=\(#[0-9A-Fa-f]*\).*/\1/p' "$E/theme/$1.env" | head -1; }
blk() { awk -v m="prefers-color-scheme: $1)" '/^@media /{ on = index($0, m) > 0 } on' "$E/gtk/gtk4.css" \
          | grep -qF "@define-color window_bg_color ${2:-<unset>};"; }
check "gtk-4.0's light block is the active light palette" blk light "$(bg gruvbox-light)"
check "  and its dark block the last dark palette used"   blk dark  "$(bg gruvbox)"
check "gtk-3.0 keeps the active palette alone: GTK3 cannot parse @media" \
  bash -c '! grep -q "^@media" "$1" && grep -qF "window_bg_color $2;" "$1"' _ "$E/gtk/gtk.css" "$(bg gruvbox-light)"
check "gtk-4.0's settings.ini says light under a light palette, for a session that says nothing" \
  hasx "$E/gtk/settings4.ini" "gtk-interface-color-scheme=light"
check "  and carries the rest of settings.ini with it" \
  hasx "$E/gtk/settings4.ini" "gtk-icon-theme-name=Papirus-Light"
check "  while gtk-3.0's never sees the key: GTK3 warns on every start" \
  not has "$E/gtk/settings.ini" "gtk-interface-color-scheme"
check "the user's file is imported once, outside both blocks" \
  test "$(grep -c '^@import' "$E/gtk/gtk4.css")-$(tail -n1 "$E/gtk/gtk4.css" | cut -c1-7)" = "1-@import"
run cool >/dev/null 2>&1; run gruvbox-light >/dev/null 2>&1
check "a remembered dark palette beats the light one's sibling" blk dark "$(bg cool)"
rm -f "$T/state/ergon/palette-dark"; run gruvbox-light >/dev/null 2>&1
check "  and with nothing remembered, the sibling fills it"       blk dark "$(bg gruvbox)"
rm -f "$T/state/ergon/palette-light"; run cool >/dev/null 2>&1
check "  and with no sibling either, the default does"            blk light "$(bg catppuccin-latte)"
check "gtk-4.0's settings.ini says dark under a dark palette" \
  hasx "$E/gtk/settings4.ini" "gtk-interface-color-scheme=dark"
check "  without prefer-dark, which pins GTK4 to Adwaita's dark variant for the life of the app" \
  not has "$E/gtk/settings4.ini" "gtk-application-prefer-dark-theme"
check "  while gtk-3.0 keeps it: GTK3 has nothing else" \
  hasx "$E/gtk/settings.ini" "gtk-application-prefer-dark-theme=1"
check "--check sees gtk4.css as current right after a render" quiet run --check

# Session start (autostart.lua): GNOME's keys from the active palette and
# nothing else. Without it a fresh install's 'default' colour scheme makes
# every GTK4 app light under a dark palette.
reset_logs; _before=$(cat "$E/gtk/gtk4.css")
run --gsettings >/dev/null 2>&1
check "--gsettings sets the active palette's colour scheme (cool: dark)" \
  hasx "$T/log/gsettings" "set org.gnome.desktop.interface color-scheme prefer-dark"
check "  and does nothing else: no render, no reload, no restart" \
  bash -c '[ ! -e "$1/log/pkill" ] && [ ! -e "$1/log/hyprctl" ] && [ "$(cat "$2")" = "$3" ]' \
  _ "$T" "$E/gtk/gtk4.css" "$_before"

# ERGON-37 text size, LAST: it ends on a deliberately broken type.env, after
# which every render fails. Back on gruvbox-light first, which is the palette
# and the fresh gsettings log its first checks were written against.
run gruvbox-light >/dev/null 2>&1
# --- text size (ERGON-37): one number, every surface, nothing else -----------
check "type.env is not offered as a palette" not has <(run --list) "type"
run type >/dev/null 2>&1
check "  and naming it is refused before it is remembered" \
  hasx "$T/state/ergon/palette" "gruvbox-light"
check "the default size leaves GTK's text at 1.00" \
  hasx "$T/log/gsettings" "set org.gnome.desktop.interface text-scaling-factor 1.00"
reset_logs
run --text 16 >/dev/null 2>&1
check "--text 16 exits 0" test "$?" = 0
# 16/11 of each designed size, rounded: 11 -> 16, 12 -> 17, 13 -> 19.
check "  foot, mako and wezterm follow it" bash -c '
  grep -qx "font=JetBrainsMono Nerd Font:size=16" "$1/foot/foot.ini" &&
  grep -qx "font=JetBrainsMono Nerd Font 16" "$1/mako/config" &&
  grep -qx "config.font_size = 16.0" "$1/wezterm/wezterm.lua"' _ "$E"
check "  the launcher and the bar keep their proportion to it" bash -c '
  grep -qx "font=JetBrainsMono Nerd Font:size=17" "$1/fuzzel/fuzzel.ini" &&
  grep -qx "  font-size: 19px;" "$1/waybar/style.css"' _ "$E"
check "  and so does GTK's text scale" \
  hasx "$T/log/gsettings" "set org.gnome.desktop.interface text-scaling-factor 1.45"
# Each refusal must leave the size in use alone, in the file and on screen.
for v in 7 33 110 1.5 ab "9 " -1; do
  run --text "$v" >/dev/null 2>&1
  check "--text '$v' is refused" test "$?" != 0
done
check "  and none of them replaced the size in use" hasx "$T/state/ergon/type.env" "TEXT_SIZE=16"
check "  or reached a rendered file" has "$E/foot/foot.ini" "size=16"
check "bare --text prints the size in use" test "$(run --text 2>/dev/null)" = 16
run --check --text 20 >/dev/null 2>&1
check "--check --text writes no size: --check only reads" hasx "$T/state/ergon/type.env" "TEXT_SIZE=16"
# A hand-edited file is held to the same rules.
printf "TEXT_SIZE=16\nFONT_SIZE=12\n" > "$T/state/ergon/type.env"
run >/dev/null 2>&1
check "a type.env carrying any other key stops the render" test "$?" != 0

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
