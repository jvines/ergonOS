#!/usr/bin/env bash
# Exercise ergon-audio-output against stub pactl and swayosd-client.
#
#   ./bin/test-audio-output.sh
#
# COVERS: the next sink is chosen (wrapping round), an unknown default falls
# to the first, the default is set, every playing stream is moved, the OSD
# names the device, and one sink changes nothing.
# DOES NOT COVER: real PipeWire; the VM suite owns that.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '   FAIL %s\n' "$*"; }
mkdir "$T/stub"
cat > "$T/stub/pactl" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "list sinks")        cat "$T/sinks" ;;
  get-default-sink*)  cat "$T/default" ;;
  "list short")        printf '41\t1\tfirefox\n57\t1\tmpv\n' ;;
  *)                   printf 'pactl %s\n' "\$*" >> "$T/log" ;;
esac
STUB
cat > "$T/stub/swayosd-client" <<STUB
#!/usr/bin/env bash
printf 'osd %s\n' "\$*" >> "$T/log"
STUB
chmod +x "$T/stub"/*
export PATH="$T/stub:$PATH"
for s in "alsa_output.speakers|Built-in Speakers" "alsa_output.hdmi|HDMI / DisplayPort" "bluez_output.hs|WH-1000XM5"; do
  printf 'Sink #1\n\tState: RUNNING\n\tName: %s\n\tDescription: %s\n\tVolume: front-left: 1 / 100%%\n' "${s%%|*}" "${s#*|}"
done > "$T/sinks"

run() { : > "$T/log"; echo "$1" > "$T/default"; "$REPO/bin/ergon-audio-output"; }
has() { grep -qxF -- "$1" "$T/log"; }

run alsa_output.speakers
has "pactl set-default-sink alsa_output.hdmi" && ok "speakers -> hdmi" || bad "speakers -> hdmi"
has "pactl move-sink-input 41 alsa_output.hdmi" && has "pactl move-sink-input 57 alsa_output.hdmi" \
  && ok "every playing stream moved" || bad "streams not moved"
has "osd --custom-message HDMI / DisplayPort --custom-icon audio-speakers-symbolic" \
  && ok "OSD names the new device" || bad "OSD: $(grep osd "$T/log")"

run bluez_output.hs
has "pactl set-default-sink alsa_output.speakers" && ok "wraps round to the first" || bad "no wrap"

run gone_device
has "pactl set-default-sink alsa_output.speakers" && ok "unknown default picks the first" || bad "unknown default"

head -5 "$T/sinks" > "$T/one"; mv "$T/one" "$T/sinks"
run alsa_output.speakers
! grep -q set-default "$T/log" && grep -q "Only one" "$T/log" && ok "single sink: no change, says so" || bad "single sink"

echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
