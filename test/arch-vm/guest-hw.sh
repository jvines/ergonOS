# SOURCED by guest-desktop.sh (after the projector block, with the compositor up
# and ok/bad/note/hq/usr/shot/diag defined): the behaviour of three things that
# were first proved only on the Framework 13.
#
#   ERGON-134  an X11 client at a fractional scale is drawn at device pixels
#   ERGON-137  a real multitouch touchpad's swipes drive the compositor
#
# (ERGON-135, PipeWire's realtime priority, needs a seat and lives in
# guest-autologin.sh.) Kept in its own file so a dev loop can source it into a
# booted, provisioned disk without re-running the hour of provisioning above it.

pacman -S --needed --noconfirm xterm xorg-xwininfo xorg-xdpyinfo python-evdev libinput >/tmp/hw-pacman.log 2>&1 \
  || { bad "could not install the X11 and touchpad test tools (harness): $(tail -2 /tmp/hw-pacman.log | tr '\n' ' ')"; }

# --- ERGON-134: XWayland apps are sharp at a fractional scale -----------------
echo "--- ERGON-134: an X11 client at scale 1.6 ---"
_x_mon=$(hq monitors -j | jq -r '.[0].name')
_x_orig=$(hq monitors -j | jq -r --arg n "$_x_mon" '.[] | select(.name == $n) | "\(.x)x\(.y) \(.scale) \(.transform)"')
_x_gdk=$(su "$U" -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/1000 systemctl --user show-environment" 2>/dev/null | sed -n 's/^GDK_SCALE=//p')
hq "dispatch 'hl.dsp.focus({ monitor = \"$_x_mon\" })'" >/dev/null
# As a person does it: step the focused output up with SUPER+CTRL+M's command
# until it is at 1.6, the Framework 13's scale.
for _ in 1 2 3 4 5 6; do
  _xs=$(hq monitors -j | jq -r --arg n "$_x_mon" '.[] | select(.name == $n) | .scale')
  [ "$_xs" = 1.6 ] || [ "$_xs" = 1.60 ] && break
  usr "ergon-display scale +" >>/tmp/hw-display.log 2>&1 || break
  sleep 1
done
read -r _xw _xh _xs _xlw <<<"$(hq monitors -j | jq -r --arg n "$_x_mon" '.[] | select(.name == $n) | "\(.width) \(.height) \(.scale) \((.width / .scale) | round)"')"
case "$_xs" in 1.6|1.60) ok "ergon display scale + steps $_x_mon to 1.6 (${_xw}x${_xh} px, ${_xlw} logical wide)" ;;
  *) bad "ergon display scale + did not reach 1.6 on $_x_mon (at $_xs, ${_xw}x${_xh}); see /tmp/hw-display.log" ;; esac

_gdk_comp=$(hq getoption xwayland:force_zero_scaling -j | jq -r '.bool // .int // empty')
[ "$_gdk_comp" = true ] && ok "xwayland:force_zero_scaling is on in the running compositor" \
  || bad "xwayland:force_zero_scaling is '$_gdk_comp' in the running compositor"
_gdk=$(su "$U" -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/1000 systemctl --user show-environment" 2>/dev/null | sed -n 's/^GDK_SCALE=//p')
[ "$_gdk" = 2 ] && ok "GDK_SCALE is 2 in the user manager at 1.6 (the lowest monitor scale, rounded)" \
  || bad "GDK_SCALE is '$_gdk' in the user manager at scale 1.6, expected 2"

# The X11 client is started by the COMPOSITOR, as autostart and the launcher do,
# so it carries the environment hl.env gave it rather than this shell's.
cat > /tmp/hw-xterm.sh <<'XT'
#!/bin/bash
exec xterm -T ergon-x11-probe -fa monospace -fs 16 -e sh -c \
  'echo "ERGON-134: this is an X11 client (xterm) on a 1.6 scaled output"; echo; echo "The quick brown fox jumps over the lazy dog 0123456789"; echo "If the glyph edges are crisp the buffer is at device pixels."; sleep 3600'
XT
chmod 755 /tmp/hw-xterm.sh
hq "dispatch 'hl.dsp.focus({workspace = 8})'" >/dev/null; sleep 1
hq "dispatch 'hl.dsp.exec_cmd(\"/tmp/hw-xterm.sh\")'" >/dev/null
_xc=""
for _ in $(seq 20); do
  _xc=$(hq clients -j | jq -c '[.[] | select(.title == "ergon-x11-probe")][0] // empty')
  [ -n "$_xc" ] && break; sleep 1
done
sleep 2
if [ -z "$_xc" ]; then
  bad "the xterm never mapped as a client"
  hq clients -j | jq -c '[.[] | {class,title,xwayland}]' | sed 's/^/     /'
else
  [ "$(jq -r .xwayland <<<"$_xc")" = true ] && ok "the xterm is an XWayland client (xwayland:true, class $(jq -r .class <<<"$_xc"))" \
    || bad "the xterm is not reported as xwayland: $_xc"
  _xpid=$(jq -r .pid <<<"$_xc")
  _xgdk=$(tr '\0' '\n' < "/proc/$_xpid/environ" 2>/dev/null | sed -n 's/^GDK_SCALE=//p')
  [ "$_xgdk" = 2 ] && ok "  and it started with GDK_SCALE=2 in its environment" \
    || bad "  its GDK_SCALE is '$_xgdk', expected 2 (ergon-display's value for 1.6)"
  # The X server's own view. force_zero_scaling means Xwayland hands the client
  # the monitor's pixels, so the X screen is the output's physical size, not
  # its logical size, and the window is its logical size times the scale.
  _xd=$(usr "DISPLAY=\$(ls /tmp/.X11-unix | sed -n 's/^X/:/p' | head -1) xdpyinfo" 2>/dev/null | sed -n 's/^ *dimensions: *\([0-9]*x[0-9]*\) pixels.*/\1/p')
  [ "$_xd" = "${_xw}x${_xh}" ] && ok "  X's screen is ${_xd}: the output's device pixels (logical would be ${_xlw}x$(( _xh * 5 / 8 )))" \
    || bad "  X's screen is '$_xd', not the output's ${_xw}x${_xh} device pixels"
  _xi=$(usr "DISPLAY=\$(ls /tmp/.X11-unix | sed -n 's/^X/:/p' | head -1) xwininfo -name ergon-x11-probe" 2>/dev/null)
  _xww=$(sed -n 's/^ *Width: *//p' <<<"$_xi"); _xwh=$(sed -n 's/^ *Height: *//p' <<<"$_xi")
  read -r _hw _hh <<<"$(jq -r '"\(.size[0]) \(.size[1])"' <<<"$_xc")"
  _ew=$(awk -v w="$_hw" 'BEGIN { printf "%d", w * 1.6 + 0.5 }'); _eh=$(awk -v h="$_hh" 'BEGIN { printf "%d", h * 1.6 + 0.5 }')
  if [ -n "$_xww" ] && [ "${_xww:-0}" -ge $((_ew - 2)) ] && [ "$_xww" -le $((_ew + 2)) ] \
     && [ "${_xwh:-0}" -ge $((_eh - 2)) ] && [ "$_xwh" -le $((_eh + 2)) ]; then
    ok "  its X window is ${_xww}x${_xwh} px = the compositor's ${_hw}x${_hh} logical x 1.6 (${_ew}x${_eh}): drawn at device pixels, not upscaled"
  else
    bad "  its X window is ${_xww:-?}x${_xwh:-?} px; at device pixels it would be ${_ew}x${_eh} (compositor logical ${_hw}x${_hh})"
    { hq monitors -j; echo "$_xc"; echo "$_xi"; } | diag hw134
  fi
  shot xwayland-scale-1.6
  usr "pkill -x xterm" >/dev/null 2>&1
  sleep 1
fi
# Back as found: the output rule, the saved layout ergon display wrote, and the
# GDK_SCALE the compositor and the manager carry.
read -r _o_pos _o_scale _o_tr <<<"$_x_orig"
hq "eval 'hl.monitor({ output = \"$_x_mon\", position = \"$_o_pos\", scale = \"$_o_scale\", transform = $_o_tr })'" >/dev/null
rm -f "/run/user/1000/ergon/display.lua" "$H/.local/state/ergon/display.lua"
sleep 1
usr "ergon-display xscale" >/dev/null 2>&1
hq "dispatch 'hl.dsp.focus({workspace = 1})'" >/dev/null
_xs=$(hq monitors -j | jq -r --arg n "$_x_mon" '.[] | select(.name == $n) | .scale')
case "$_xs" in 1|1.0|1.00) ok "  scale is back to 1 and the xterm is closed" ;; *) bad "  scale did not go back to 1 (is $_xs)" ;; esac
[ -z "$(hq clients -j | jq -r '.[] | select(.title == "ergon-x11-probe") | .address')" ] || bad "  the xterm is still open"

# --- ERGON-137: touchpad gestures, from a real (virtual) multitouch device -----
echo "--- ERGON-137: touchpad gestures ---"
modprobe uinput >/dev/null 2>&1 || true
rm -f /tmp/tp.fifo /tmp/tp.log; mkfifo /tmp/tp.fifo
python3 "${SHARE:-/mnt}/test/arch-vm/touchpad.py" </tmp/tp.fifo >/tmp/tp.log 2>&1 &
_tp_pid=$!
exec 9>/tmp/tp.fifo
for _ in $(seq 10); do grep -q READY /tmp/tp.log 2>/dev/null && break; sleep 1; done
if ! grep -q READY /tmp/tp.log; then
  bad "the virtual touchpad was not created: $(head -c 300 /tmp/tp.log)"
else
  sleep 2
  _tp_li=$(libinput list-devices 2>/dev/null | awk -v RS= '/ERGON-TEST Virtual Touchpad/')
  grep -q 'Capabilities:.*pointer.*gesture' <<<"$_tp_li" \
    && ok "libinput classifies the virtual device as a touchpad (Capabilities: $(sed -n 's/^Capabilities: *//p' <<<"$_tp_li"))" \
    || { bad "libinput does not classify the virtual device as a touchpad"; echo "$_tp_li" | diag hw137-libinput; }
  _tp_n=$(hq devices -j | jq -r '[.mice[] | select(.name | test("ERGON-TEST"; "i")) | .name][0] // empty')
  [ -n "$_tp_n" ] && ok "  and Hyprland lists it among its pointing devices ($_tp_n)" \
    || { bad "  Hyprland does not list the virtual touchpad"; hq devices -j | diag hw137-devices; }

  # The wait is for the device to finish the stroke; the sleep after it is for
  # the compositor to finish acting on it.
  tp() {
    local n; n=$(grep -c DONE /tmp/tp.log)
    echo "$*" >&9
    for _ in $(seq 50); do [ "$(grep -c DONE /tmp/tp.log)" -gt "$n" ] && break; sleep 0.2; done
    sleep 2
  }
  ws() { hq activeworkspace -j | jq -r .id; }
  hq "dispatch 'hl.dsp.focus({workspace = 5})'" >/dev/null; sleep 1
  usr "foot -T hw-gesture sh -c 'sleep 3600'" >/dev/null 2>&1 </dev/null &
  for _ in $(seq 15); do [ -n "$(hq clients -j | jq -r '.[] | select(.title == "hw-gesture") | .address')" ] && break; sleep 1; done
  sleep 2

  # 3 fingers, horizontal: the workspace follows.
  _w0=$(ws)
  tp swipe 3 -1 0
  _w1=$(ws)
  [ "$_w1" != "$_w0" ] && ok "a 3-finger swipe left moves workspace $_w0 -> $_w1" || bad "a 3-finger swipe left left the workspace at $_w0"
  tp swipe 3 1 0
  _w2=$(ws)
  [ "$_w2" = "$_w0" ] && ok "  and the 3-finger swipe right returns to $_w0" || bad "  the 3-finger swipe right went to $_w2, not back to $_w0"
  hq "dispatch 'hl.dsp.focus({workspace = 5})'" >/dev/null; sleep 1

  # 4 fingers down: fullscreen on the focused window. Undone by the compositor.
  _fs() { hq activewindow -j | jq -r '.fullscreen // 0'; }
  [ "$(_fs)" = 0 ] || bad "the gesture window is already fullscreen before the swipe"
  tp swipe 4 0 1
  [ "$(_fs)" != 0 ] && ok "a 4-finger swipe down fullscreens the focused window (fullscreen=$(_fs))" \
    || bad "a 4-finger swipe down did not fullscreen the window"
  hq "dispatch 'hl.dsp.window.fullscreen({ action = \"toggle\" })'" >/dev/null 2>&1
  sleep 1

  # 4 fingers up: float the window; and 4 fingers horizontally drag a floating one.
  _fl() { hq activewindow -j | jq -r '.floating'; }
  [ "$(_fl)" = false ] || bad "the gesture window is already floating before the swipe"
  tp swipe 4 0 -1
  [ "$(_fl)" = true ] && ok "a 4-finger swipe up floats the focused window" || bad "a 4-finger swipe up did not float the window"
  _at0=$(hq activewindow -j | jq -c .at)
  tp swipe 4 1 0
  _at1=$(hq activewindow -j | jq -c .at)
  [ "$_at1" != "$_at0" ] && [ "$(_fl)" = true ] && ok "a 4-finger swipe right drags the floating window ($_at0 -> $_at1)" \
    || bad "a 4-finger swipe right did not move the floating window (at $_at0 -> $_at1)"
  tp swipe 4 0 -1
  [ "$(_fl)" = false ] && ok "  and another 4-finger swipe up tiles it again" \
    || { note "ERGON-137: a second 4-finger swipe up leaves the window floating=$(_fl): the gesture floats, it does not toggle"
         hq "dispatch 'hl.dsp.window.float({ action = \"toggle\" })'" >/dev/null 2>&1; }
  shot touchpad-gestures

  usr "pkill -f hw-gesture" >/dev/null 2>&1
  echo quit >&9; exec 9>&-; wait "$_tp_pid" 2>/dev/null
  hq "dispatch 'hl.dsp.focus({workspace = 1})'" >/dev/null
fi
rm -f /tmp/tp.fifo
