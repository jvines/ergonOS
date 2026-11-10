#!/usr/bin/env bash
# ERGON-138/93/143/110/111: ergon-restart, ergon-toggle-input, ergon-clock and
# ergon-transcode against stubs and a fake /sys. The real compositor and hardware
# are VM/laptop checks.   ./bin/test-input-restart.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
has() { if grep -qE -- "$2" <<<"$3"; then echo "ok   $1"; else echo "FAIL $1: [$3] !~ $2"; fail=1; fi; }

# --- fake sysfs: a touchpad under an i2c device, a touchscreen, a keyboard
S=$T/sys; mkdir -p "$S/bus/i2c" "$S/drivers/i2c_hid_acpi" "$S/class/input"
D=$S/devices/i2c-1/i2c-ELAN0001:00; mkdir -p "$D/hid/input/input7" "$S/devices/input8" "$S/devices/input9"
ln -s ../../../drivers/i2c_hid_acpi "$D/driver"; ln -s ../../../bus/i2c "$D/subsystem"
touch "$S/drivers/i2c_hid_acpi/unbind" "$S/drivers/i2c_hid_acpi/bind"
echo "ELAN0001:00 04F3:3140 Touchpad" > "$D/hid/input/input7/name"
echo "Wacom Touchscreen" > "$S/devices/input8/name"; echo "AT Keyboard" > "$S/devices/input9/name"
ln -s "$D/hid/input/input7" "$S/class/input/input7"; ln -s ../../devices/input8 "$S/class/input/input8"; ln -s ../../devices/input9 "$S/class/input/input9"

mkdir -p "$T/bin" "$T/run"
cat > "$T/bin/udevadm" <<'X'
#!/bin/bash
n=$(cat "${@: -1}/name"); case $n in *Touchpad*) echo ID_INPUT_TOUCHPAD=1;; *Touchscreen*) echo ID_INPUT_TOUCHSCREEN=1;; esac; echo ID_INPUT=1
X
cat > "$T/bin/hyprctl" <<X
#!/bin/bash
echo "\$*" >> "$T/hypr.log"
case \$1 in devices) echo '{"mice":[{"name":"elan0001:00-04f3:3140-touchpad"},{"name":"other-mouse"}],"touch":[{"name":"wacom-touchscreen"}],"keyboards":[]}';; eval) echo ok;; esac
X
printf '#!/bin/sh\nexec "$@"\n' > "$T/bin/sudo"
for c in systemctl rfkill bluetoothctl; do printf '#!/bin/sh\necho "%s $*" >> "%s/cmds"\n' "$c" "$T" > "$T/bin/$c"; done
printf '#!/bin/sh\nprintf "%%s|" "$@" >> "%s/notes"; echo >> "%s/notes"\n' "$T" "$T" > "$T/bin/notify-send"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" ERGON_SYS="$S" XDG_RUNTIME_DIR="$T/run" XDG_CONFIG_HOME="$T/cfg"

# --- toggle
TG="$REPO/bin/ergon-toggle-input"
"$TG" touchpad >/dev/null
has "touchpad off: the libinput name, enabled=false" 'eval hl.device\(\{ name = "elan0001:00-04f3:3140-touchpad", enabled = false \}\)' "$(cat "$T/hypr.log")"
chk "marker written" "$(ls "$T/run/ergon")" "input-touchpad.off"
"$TG" touchpad >/dev/null
has "second press: enabled=true" 'enabled = true' "$(tail -1 "$T/hypr.log")"
chk "marker removed" "$(ls "$T/run/ergon")" ""
"$TG" touchscreen off >/dev/null
has "touchscreen found from the touch list" 'name = "wacom-touchscreen", enabled = false' "$(tail -1 "$T/hypr.log")"
has "state is notified" 'touchscreen\|off' "$(tail -1 "$T/notes")"
chk "bad kind refused" "$("$TG" keyboard >/dev/null 2>&1; echo $?)" 2
rm -rf "$S/class/input/input7"; "$TG" touchpad >/dev/null 2>&1; chk "no touchpad: exit 1" "$?" 1

# --- restart
R="$REPO/bin/ergon-restart"
"$R" audio >/dev/null; has "audio restarts the user units" 'systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service' "$(cat "$T/cmds")"
"$R" bluetooth >/dev/null; has "bluetooth: service, unblock, power" 'bluetooth.service' "$(cat "$T/cmds")"; has "bluetooth powered" 'bluetoothctl power on' "$(cat "$T/cmds")"
"$R" wifi >/dev/null; has "wifi restarts NetworkManager" 'restart NetworkManager.service' "$(cat "$T/cmds")"
ln -s "$D/hid/input/input7" "$S/class/input/input7"
"$R" trackpad >/dev/null; chk "trackpad: the i2c device is unbound then bound" "$(cat "$S/drivers/i2c_hid_acpi/unbind")$(cat "$S/drivers/i2c_hid_acpi/bind")" "i2c-ELAN0001:00i2c-ELAN0001:00"
chk "unknown subsystem refused" "$("$R" fans >/dev/null 2>&1; echo $?)" 2

# --- clock
C="$REPO/bin/ergon-clock"
"$C" add Nowhere/Land >/dev/null 2>&1; chk "bad zone refused" "$?" 1
"$C" add America/Santiago; "$C" add America/Santiago
chk "zone stored once" "$("$C" list)" "America/Santiago"
has "toast has local, battery, UTC and the zone" 'battery .*UTC .*America/Santiago' "$("$C" | tr '\n' ' ')"
"$C" rm America/Santiago; chk "zone removed" "$("$C" list)" ""

# --- transcode (stub converters; real ffmpeg/magick are shipped packages)
printf '#!/bin/sh\nfor a; do o=$a; done; echo "ffmpeg $*" >> "%s/conv"; : > "$o"\n' "$T" > "$T/bin/ffmpeg"
printf '#!/bin/sh\nfor a; do o=$a; done; echo "magick $*" >> "%s/conv"; : > "$o"\n' "$T" > "$T/bin/magick"
chmod +x "$T/bin/ffmpeg" "$T/bin/magick"
cd "$T" && printf 'GIF89a' > a.gif && base64 -d <<<iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg== > b.png && : > bad.txt
X="$REPO/bin/ergon-transcode"
chk "image to webp, resized" "$("$X" b.png webp 800)" "b.webp"
has "magick resize" 'magick b.png -resize 800x b.webp' "$(cat conv)"
chk "existing output is not overwritten" "$("$X" b.png webp)" "b-1.webp"
has "unsupported target refused" 'cannot become' "$("$X" b.png mp4 2>&1)"
has "non-media refused" 'not a video or image' "$("$X" bad.txt mp4 2>&1)"
exit $fail
