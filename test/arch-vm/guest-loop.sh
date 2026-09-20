#!/usr/bin/env bash
# The visual iteration loop, guest side.
#
# Design work needs to SEE the change. Before tonight that was impossible --
# grim could not capture in the VM -- so the only loop was a 15-minute session
# suite that produced assertions, not pixels. Now that the guest has a real
# dmabuf path, a screenshot is the fastest honest feedback there is.
#
# The trigger is a FILE on the writable 9p share, because there is no way to run
# a command in the guest from the host: the serial console belongs to an expect
# process and `docker attach` needs a tty. The host writes /out/request, this
# reads it, and the reply lands back on the same share.
#
#   shot    capture the desktop as it is
#   theme   re-sync the repo, re-render the theme and wallpaper, reload the
#           compositor, then capture
#   demo    open windows and fire a notification first, so the things a theme
#           actually styles -- borders, gaps, rounding, the focused/unfocused
#           distinction, notification colours -- are on screen to be judged.
#           An empty desktop shows a bar and a wallpaper and nothing else.
#
# Runs until the VM stops.
set -uo pipefail

U=$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)
H=$(getent passwd "$U" | cut -d: -f6)

mkdir -p /out
mountpoint -q /out || mount -t 9p -o trans=virtio,version=9p2000.L out /out 2>/dev/null
chmod 777 /out 2>/dev/null

# Wait for a session. A person takes as long as they take to reach the greeter.
sig=""
while [ -z "$sig" ]; do
  d=$(ls -d /run/user/1000/hypr/*/ 2>/dev/null | head -1)
  [ -n "$d" ] && sig=$(basename "$d")
  sleep 3
done
wld=$(basename "$(ls /run/user/1000/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1)" 2>/dev/null)
wld=${wld:-wayland-1}

# As the user, in the session's environment. Root cannot talk to the compositor.
run() { su - "$U" -c "XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$sig WAYLAND_DISPLAY=$wld $1" 2>&1; }

echo "ready $sig $wld" > /out/loop-status

# Self-updating. /mnt is the host's checkout over 9p, so when this script
# changes there the running copy is stale -- and every change to it so far has
# cost a VM restart and another login. Re-exec instead.
SELF=/mnt/test/arch-vm/guest-loop.sh
SELF_SUM=$(md5sum "$SELF" 2>/dev/null | cut -d" " -f1)

while :; do
  now=$(md5sum "$SELF" 2>/dev/null | cut -d" " -f1)
  if [ -n "$now" ] && [ -n "$SELF_SUM" ] && [ "$now" != "$SELF_SUM" ]; then
    echo "reloading $now" >> /out/loop-status
    exec bash "$SELF"
  fi

  [ -f /out/request ] || { sleep 1; continue; }
  req=$(tr -d '[:space:]' < /out/request 2>/dev/null)
  rm -f /out/request
  : > /out/reply

  if [ "$req" = demo ]; then
    # Close what is already open FIRST. Without this each call stacks another
    # pair of windows, the tiles get narrower every time, and btop -- which
    # needs 80x24 -- gives up and prints "terminal size too small" instead of
    # the thing being judged.
    pkill -u "$U" -x btop 2>/dev/null || true
    pkill -u "$U" -x foot 2>/dev/null || true
    sleep 1

    # btop alone, so it gets the full width. Two side-by-side terminals at
    # 1280px are about 78 columns each, which is just under what it needs.
    run "hyprctl dispatch 'hl.dsp.exec_raw(\"foot -e btop\")'" >> /out/reply 2>&1
    sleep 4
    run "notify-send 'Ergon' 'A themed notification, so mako can be judged too.'" >> /out/reply 2>&1
    sleep 2
  fi

  if [ "$req" = windows ]; then
    # The other half of the question: two windows, so focused and unfocused
    # border colours can be compared side by side.
    pkill -u "$U" -x btop 2>/dev/null || true
    pkill -u "$U" -x foot 2>/dev/null || true
    sleep 1
    run "hyprctl dispatch 'hl.dsp.exec_raw(\"foot\")'" >> /out/reply 2>&1
    sleep 2
    run "hyprctl dispatch 'hl.dsp.exec_raw(\"foot\")'" >> /out/reply 2>&1
    sleep 2
  fi

  if [ "$req" = theme ]; then
    # The repo is handed over 9p read-only and copied in at boot, so a config
    # edited on the host is not visible until it is copied again.
    rsync -a --delete --exclude '.git' /mnt/ "$H/ergonOS/" 2>/dev/null \
      || { rm -rf "${H:?}/ergonOS"; cp -r /mnt "$H/ergonOS"; }
    chown -R "$U:$U" "$H/ergonOS"
    # install.sh too, not just the renderer: a NEW themed app needs its config
    # linked into $HOME before any amount of re-rendering reaches it. btop was
    # themed, rendered, and still drew its own colours for exactly this reason.
    { run "ERGON=\$HOME/ergonOS \$HOME/ergonOS/install.sh"
      run "ERGON=\$HOME/ergonOS \$HOME/ergonOS/bin/ergon-theme"
      run "ERGON=\$HOME/ergonOS \$HOME/ergonOS/bin/ergon-wallpaper --force"
      run "hyprctl reload"
    } >> /out/reply 2>&1
    sleep 2
  fi

  # No -o. With one output grim captures it by default, and an EMPTY -o value
  # makes grim swallow the output path as its argument -- which is exactly how
  # this failed the first time it was used in anger.
  rm -f /out/desktop.png
  if run "grim /out/desktop.png" >> /out/reply 2>&1 && [ -s /out/desktop.png ]; then
    chmod 666 /out/desktop.png 2>/dev/null
    echo "OK $(date +%T)" >> /out/reply
  else
    echo "CAPTURE_FAILED" >> /out/reply
  fi
  chmod 666 /out/reply 2>/dev/null
done
