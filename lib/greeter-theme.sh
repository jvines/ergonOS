# The greeter's colours (ERGON-42). Sourced by bin/provision-arch.sh, which
# writes the result into /etc/greetd/config.toml, and by bin/test-provisioning.sh
# and bin/test-hypr-config.sh, which pin down what it computes. Not a command.

# Why a mapping rather than the palette's own hex: tuigreet runs on vt1, a
# Linux console, which has sixteen colours and a black ground. tuigreet will
# emit 24-bit colour if it is handed #RRGGBB (measured on 0.11.1:
# 38;2;64;255;255 for #40FFFF), and the kernel console then turns each channel
# on or off at half the brightest one (rgb_foreground in drivers/tty/vt/vt.c,
# read at v6.12) -- so every pastel this desktop is made of comes out white:
# cool's ACCENT #ADFFFF, Catppuccin's mauve #CBA6F7. Named colours are emitted
# as 38;5;0..15, which the same file maps onto the console's own sixteen.
#
# So the palette contributes HUE, and only through its accent roles. Its
# neutrals have no say: the console's ground is black under every palette, and
# a light palette's FG0 is a dark grey that would vanish on it. Text is white
# and the quiet parts are gray, always.
#
# tuigreet takes a name it does not know, or a key it does not know, without a
# word: measured on 0.11.1, `border=notacolour` and `brder=lightcyan` each
# print nothing, keep running, and draw the default. That is why only names
# from the list below are ever produced, and why bin/test-hypr-config.sh
# renders each of them through a real tuigreet and reads the colour back.

# #RRGGBB -> the light console colour nearest in hue, or white when there is
# no hue to speak of (under 15% HSV saturation). Light variants only: the dark
# eight are 0xAA-level colours on black, and dark blue on black is not a
# border anyone can see.
ergon_vt_colour() {  # ergon_vt_colour '#RRGGBB'
  local h=${1#\#} r g b mx mn d hue
  case "$h" in
    [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
    *) return 1 ;;
  esac
  r=$((16#${h:0:2})); g=$((16#${h:2:2})); b=$((16#${h:4:2}))
  mx=$r; [ "$g" -gt "$mx" ] && mx=$g; [ "$b" -gt "$mx" ] && mx=$b
  mn=$r; [ "$g" -lt "$mn" ] && mn=$g; [ "$b" -lt "$mn" ] && mn=$b
  d=$((mx - mn))
  if [ $((d * 100)) -lt $((mx * 15)) ]; then echo white; return 0; fi
  # Integer HSV hue, 0..359.
  if   [ "$mx" = "$r" ]; then hue=$(( (60 * (g - b) / d + 360) % 360 ))
  elif [ "$mx" = "$g" ]; then hue=$(( 60 * (b - r) / d + 120 ))
  else                        hue=$(( 60 * (r - g) / d + 240 )); fi
  # Six 60-degree sectors centred on the console's six hues.
  case $(( (hue + 30) / 60 % 6 )) in
    0) echo lightred ;;   1) echo lightyellow ;; 2) echo lightgreen ;;
    3) echo lightcyan ;;  4) echo lightblue ;;   5) echo lightmagenta ;;
  esac
}

# A palette file -> tuigreet's --theme string. Read with sed, never sourced:
# bin/ergon-theme says why (sourcing a palette executes it).
#
# border is ACTIVE, the token every overlay on the desktop is framed in (mako,
# fuzzel, the OSD, the lock screen's field); prompt is ACCENT. Only the
# components tuigreet draws with this repo's flags are set: title and greet
# need --title and --greeting, which provisioning does not pass, and container
# is the black the console already is.
#
# button is left alone, on evidence. tuigreet draws the F-key labels in
# REVERSE video, and a Linux console has no bright backgrounds: button=
# lightcyan came out as dark grey on #00AAAA, the labels barely legible
# (VM screendump, 2026-10-14). The default, black on grey, reads.
ergon_greeter_theme() {  # ergon_greeter_theme <palette.env>
  local f=$1 k v act acc
  [ -r "$f" ] || return 1
  for k in COOL_ACTIVE COOL_ACCENT; do
    v=$(sed -n "s/^$k=\(#[0-9A-Fa-f]\{6\}\).*/\1/p" "$f" | head -1)
    v=$(ergon_vt_colour "$v") || return 1
    case $k in COOL_ACTIVE) act=$v ;; COOL_ACCENT) acc=$v ;; esac
  done
  printf 'border=%s;prompt=%s;text=white;input=white;time=gray;action=gray\n' "$act" "$acc"
}
