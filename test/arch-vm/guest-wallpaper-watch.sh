#!/usr/bin/env bash
# Waits for a GREETER session to appear, then records why the wallpaper is or is
# not on screen, into the writable /out share.
#
# This exists because the automated suite and a real login are different paths.
# The suite starts Hyprland directly with seatd; a person logs in through greetd,
# which runs `uwsm start Hyprland`. The suite composited a wallpaper and the
# greeter session showed a flat colour, and nothing was watching the path people
# actually use.
#
# It is a FILE, not a command embedded in the expect driver. The first attempt
# inlined this into hypr-vm's heredoc, where Tcl read the $( ) as a variable and
# killed the VM before it booted.
set -uo pipefail

U=$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)
OUT=/out/wallpaper-debug.txt

mkdir -p /out
mountpoint -q /out || mount -t 9p -o trans=virtio,version=9p2000.L out /out 2>/dev/null
chmod 777 /out 2>/dev/null

# Wait for a compositor instance to exist. A person takes as long as they take
# to reach the greeter and type a password.
sig=""
for _ in $(seq 180); do
  d=$(ls -d /run/user/1000/hypr/*/ 2>/dev/null | head -1)
  if [ -n "$d" ]; then sig=$(basename "$d"); break; fi
  sleep 5
done
[ -n "$sig" ] || { echo "no Hyprland instance appeared within 15 minutes" > "$OUT"; exit 0; }

# Everything runs AS THE USER with the session's own environment, because the
# question is what that session can see -- not what root can.
run() { su - "$U" -c "XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$sig $1" 2>&1; }

{
  echo "== greeter session $sig at $(date +%T)"
  echo
  echo "-- background layer (empty means no wallpaper on screen):"
  run "hyprctl layers" | awk '/Layer level 0/{b=1;next} /Layer level 1/{b=0} b'
  echo
  echo "-- hyprpaper processes:"
  pgrep -a hyprpaper || echo "   NONE RUNNING"
  echo
  echo "-- PATH the compositor was started with:"
  tr '\0' '\n' < "/proc/$(pgrep -x Hyprland | head -1)/environ" 2>/dev/null | grep '^PATH=' || echo "   could not read"
  echo
  echo "-- does the session resolve ergon-wallpaper?"
  run "command -v ergon-wallpaper" || echo "   NOT ON PATH"
  echo
  echo "-- the wallpaper file:"
  ls -l "/home/$U/.local/share/ergon/wallpaper.png" 2>&1
  echo
  echo "-- running ergon-wallpaper now, with its output KEPT:"
  run "ergon-wallpaper"
  echo
  echo "-- what hyprpaper accepts:"
  for req in listactive listloaded; do
    printf '   %s -> %s\n' "$req" "$(run "hyprctl hyprpaper $req" | head -2 | tr '\n' ' ')"
  done
  echo
  echo "-- background layer AFTER that run:"
  run "hyprctl layers" | awk '/Layer level 0/{b=1;next} /Layer level 1/{b=0} b'
  echo
  echo "== end"
} > "$OUT" 2>&1
chmod 666 "$OUT" 2>/dev/null
