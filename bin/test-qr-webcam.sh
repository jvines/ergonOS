#!/usr/bin/env bash
# ERGON-104: ergon-qr decodes a real QR code, and ergon-webcam's toggle and
# its refusal when there is no camera. No hardware needed.
#
#   ./bin/test-qr-webcam.sh
#
# ergon-qr: zbarimg and qrencode are the real ones, so this runs the decode
# on an actual generated PNG. grim is a stub that emits that PNG, slurp a stub
# that returns a region (or fails, as Escape does), wl-copy a stub that keeps
# what it is given. When zbarimg/qrencode are not installed the QR half runs in
# a throwaway archlinux container; with neither, it is skipped and says so.
#
# ergon-webcam: a fake sysfs tree stands in for /sys/class/video4linux and a
# stub ffmpeg that exits on SIGINT stands in for the encoder.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
done_() { printf '\n   %d ok, %d FAILED\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

# --- QR half ---------------------------------------------------------------
qr_half() {
  local T; T=$(mktemp -d); trap 'rm -rf "$T"' RETURN
  mkdir -p "$T/stub"
  local url=https://example.org/ergon?a=1 secret='otpauth://totp/x?secret=ABC'
  qrencode -s 8 -o "$T/url.png" "$url"
  qrencode -s 8 -o "$T/sec.png" "$secret"
  : > "$T/blank.png"
  printf '#!/usr/bin/env bash\ncat "$IMG"\n' > "$T/stub/grim"
  printf '#!/usr/bin/env bash\n[ -z "${NOSEL:-}" ] || exit 1\necho "0,0 10x10"\n' > "$T/stub/slurp"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s/wl-args"; cat > "%s/clip"\n' "$T" "$T" > "$T/stub/wl-copy"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/notes"\n' "$T" > "$T/stub/notify-send"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/stub/xdg-open"
  chmod +x "$T"/stub/*
  local PATH="$T/stub:$PATH" rc

  IMG="$T/sec.png" "$REPO/bin/ergon-qr" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && [ "$(cat "$T/clip")" = "$secret" ] && grep -q -- --sensitive "$T/wl-args" \
     && ! grep -qF "$secret" "$T/notes"; then
    ok "qr: a non-link payload is copied marked sensitive and kept out of the toast"
  else bad "qr secret: rc=$rc clip='$(cat "$T/clip" 2>/dev/null)' notes='$(cat "$T/notes" 2>/dev/null)'"; fi

  rm -f "$T/clip" "$T/notes"
  IMG="$T/url.png" "$REPO/bin/ergon-qr" >/dev/null 2>&1; rc=$?
  sleep 0.5
  if [ "$rc" -eq 0 ] && [ "$(cat "$T/clip")" = "$url" ] && grep -qF "default=Open" "$T/notes"; then
    ok "qr: a URL is copied and the toast offers Open"
  else bad "qr url: rc=$rc clip='$(cat "$T/clip" 2>/dev/null)' notes='$(cat "$T/notes" 2>/dev/null)'"; fi

  rm -f "$T/clip" "$T/notes"
  IMG="$T/blank.png" "$REPO/bin/ergon-qr" >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 0 ] && [ ! -e "$T/clip" ] && grep -q "no QR code" "$T/notes"; then
    ok "qr: no code in the region is reported and the clipboard is untouched"
  else bad "qr none: rc=$rc notes='$(cat "$T/notes" 2>/dev/null)'"; fi

  rm -f "$T/clip" "$T/notes"
  NOSEL=1 IMG="$T/url.png" "$REPO/bin/ergon-qr" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && [ ! -e "$T/clip" ]; then
    ok "qr: a cancelled selection does nothing and is not an error"
  else bad "qr cancel: rc=$rc"; fi
}

if [ "${ERGON_TEST_QR_INNER:-}" = 1 ]; then
  qr_half; done_; exit
fi

if command -v zbarimg >/dev/null && command -v qrencode >/dev/null; then
  qr_half
elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  out=$(docker run --rm --label cl.jvines.owner=ergon-104 -v "$REPO:/repo:ro" -e ERGON_TEST_QR_INNER=1 \
          archlinux bash -c 'pacman -Sy --noconfirm zbar qrencode >/dev/null 2>&1 && /repo/bin/test-qr-webcam.sh' 2>&1)
  printf '%s\n' "$out" | grep -E '^   (ok|FAIL)'
  if n=$(printf "%s\n" "$out" | sed -n "s/^   \([0-9]*\) ok, 0 FAILED.*/\1/p") && [ -n "$n" ]; then PASS=$((PASS + n)); else bad "qr container run: $(printf '%s' "$out" | tail -3)"; fi
else
  echo "   skip qr: neither zbarimg+qrencode nor docker available"
fi

# --- webcam half -------------------------------------------------------------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/home" "$T/sys" "$T/dev/dev" "$T/vid"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/notes"\n' "$T" > "$T/stub/notify-send"
# Named ffmpeg so the cmdline check matches, as the real one's does.
cat > "$T/stub/ffmpeg" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$T/ffargs"
trap 'echo int > "$T/ffint"; exit 0' INT
while :; do sleep 0.1; done
EOF
chmod +x "$T"/stub/*
export PATH="$T/stub:$PATH" HOME="$T/home" XDG_STATE_HOME="$T/home/.state" \
       ERGON_WEBCAM_DIR="$T/vid" ERGON_V4L_SYSFS="$T/sys" ERGON_V4L_DEVROOT="$T/dev"
CAM="$REPO/bin/ergon-webcam"

"$CAM" >"$T/out" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && grep -q "no camera" "$T/out" && grep -q "no camera" "$T/notes" && [ ! -e "$T/ffargs" ]; then
  ok "webcam: no camera is refused with a message and ffmpeg never runs"
else bad "webcam no camera: rc=$rc out='$(cat "$T/out")'"; fi

# A UVC camera: metadata node (index 1) listed first, capture node (index 0) second.
mkdir -p "$T/sys/video0" "$T/sys/video1" "$T/dev/dev"
echo 1 > "$T/sys/video0/index"; echo 0 > "$T/sys/video1/index"
: > "$T/dev/dev/video0"; : > "$T/dev/dev/video1"
: > "$T/notes"
"$CAM" >"$T/out" 2>&1; rc=$?
sleep 0.5
if [ "$rc" -eq 0 ] && grep -qF -- "-i /dev/video1 " "$T/ffargs" 2>/dev/null && grep -q "recording" "$T/notes"; then
  ok "webcam: starts on the capture node, skipping the metadata node"
else bad "webcam start: rc=$rc ffargs='$(cat "$T/ffargs" 2>/dev/null)'"; fi

"$CAM" >"$T/out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -e "$T/ffint" ] && grep -q "stopped" "$T/notes" && [ ! -e "$T/home/.state/ergon/webcam.pid" ]; then
  ok "webcam: the second invocation stops ffmpeg with SIGINT and clears its state"
else bad "webcam stop: rc=$rc ffint=$([ -e "$T/ffint" ] && echo y || echo n) notes='$(cat "$T/notes")'"; fi

done_
