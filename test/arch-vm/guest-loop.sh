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
    pkill -u "$U" -x wezterm-gui 2>/dev/null || true
    sleep 1

    # btop alone, so it gets the full width. Two side-by-side terminals at
    # 1280px are about 78 columns each, which is just under what it needs.
    run "hyprctl dispatch 'hl.dsp.exec_raw(\"ergon-term btop\")'" >> /out/reply 2>&1
    sleep 4
    run "notify-send 'Ergon' 'A themed notification, so mako can be judged too.'" >> /out/reply 2>&1
    sleep 2
  fi

  if [ "$req" = wezterm ]; then
    # wezterm-git is a long Rust build, far past any request timeout, so it runs
    # DETACHED and reports into its own log. The VM normally skips it
    # (ERGON_SKIP_AUR=1), which is why wezterm is the one themed surface that
    # has never been looked at on this machine.
    if command -v wezterm >/dev/null 2>&1; then
      echo "wezterm already installed: $(wezterm --version 2>&1)" >> /out/reply
    else
      # makepkg needs sudo to install build dependencies, and provisioning
      # removes its passwordless sudo afterwards -- correctly. So grant it for
      # the build and take it away when the build ends, in the same command, so
      # an interrupted build cannot leave the VM with NOPASSWD sudo.
      #
      # HARNESS ONLY. This is a throwaway VM with a published password; it is
      # not a pattern for a real machine.
      printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$U" > /etc/sudoers.d/99-wezterm
      chmod 440 /etc/sudoers.d/99-wezterm
      su - "$U" -c "nohup sh -c '\$HOME/ergonOS/bin/ergon-aur wezterm-git; sudo rm -f /etc/sudoers.d/99-wezterm' > /out/wezterm-build.log 2>&1 &" >/dev/null 2>&1
      echo "wezterm-git build started; watch /out/wezterm-build.log" >> /out/reply
    fi
    chmod 666 /out/wezterm-build.log 2>/dev/null || true
  fi

  if [ "$req" = diag ]; then
    # Read the state instead of judging it from a screenshot. Twice now a theme
    # has looked unchanged in a capture when the real question was whether the
    # config was even in place.
    { echo "-- btop theme link:"; ls -l "$H/.config/btop/themes/" 2>&1
      echo "-- btop color_theme:"; grep -E '^color_theme' "$H/.config/btop/btop.conf" 2>&1
      echo "-- does the theme file resolve?"
      head -3 "$H/.config/btop/themes/cool.theme" 2>&1
      echo "-- themed configs present:"
      ls -d "$H/.config/waybar/style.css" "$H/.config/mako/config" \
            "$H/.config/yazi/theme.toml" "$H/.config/lazygit/config.yml" \
            "$H/.config/lazydocker/config.yml" "$H/.config/bat/config" 2>&1
      echo "-- does ergon-power actually cycle?"
      _b=$(su - "$U" -c "powerprofilesctl get" 2>/dev/null)
      _a=$(su - "$U" -c "ERGON=\$HOME/ergonOS \$HOME/ergonOS/bin/ergon-power cycle" 2>&1 | tail -1)
      echo "   $_b -> $_a"
      su - "$U" -c "ERGON=\$HOME/ergonOS \$HOME/ergonOS/bin/ergon-power $_b" >/dev/null 2>&1 || true
      echo "-- is ergon-power on the SESSION's path?"
      su - "$U" -c 'command -v ergon-power' 2>&1 | head -1
      echo "-- power profiles available:"
      su - "$U" -c "powerprofilesctl list" 2>&1 | grep -E '^[ *]*[a-z-]+:' | head -5
      echo "-- current profile:"; su - "$U" -c "powerprofilesctl get" 2>&1 | head -1
      echo "-- ppd service:"; systemctl is-active power-profiles-daemon 2>&1
      echo "-- platform_profile driver present?"; ls /sys/firmware/acpi/platform_profile 2>&1 | head -1
      echo "-- does an interactive zsh start CLEAN?"
      zout=$(su - "$U" -c 'zsh -i -c "exit" 2>&1' 2>&1 | head -3)
      [ -z "$zout" ] && echo "   clean (no output)" || echo "   OUTPUT: $zout"
      echo "-- does zsh find the ergon commands?"
      su - "$U" -c 'zsh -c "command -v ergon-wallpaper"' 2>&1 | head -1
      echo "-- oh-my-zsh / zplug present? (provisioning clones these)"
      ls -d "$H/.oh-my-zsh" "$H/.zplug" 2>&1 | head -2
      echo "-- what is in ~/.zshrc?"; wc -l "$H/.zshrc" 2>&1; head -4 "$H/.zshrc" 2>&1
      echo "-- bat sees the theme?"; su - "$U" -c "bat --list-themes 2>/dev/null | grep -c '^cool$'" 2>&1
    } >> /out/reply 2>&1
  fi

  if [ "$req" = tui ]; then
    # bat on a real source file. This is the syntax theme delta also uses, so
    # what shows here is what every git diff and every lazygit hunk looks like.
    pkill -u "$U" -x btop 2>/dev/null || true
    pkill -u "$U" -x foot 2>/dev/null || true
    pkill -u "$U" -x wezterm-gui 2>/dev/null || true
    sleep 1
    # ergon-term, not foot: it prefers wezterm when wezterm exists, so this
    # exercises the resolver AND shows whichever terminal the machine would
    # actually give you. wezterm is the daily one and the only themed surface
    # that had never been looked at.
    run "hyprctl dispatch 'hl.dsp.exec_raw(\"ergon-term bash -c \\\"bat --paging=always /home/$U/ergonOS/bin/ergon-peek\\\"\")'" >> /out/reply 2>&1
    sleep 4
  fi

  if [ "$req" = windows ]; then
    # The other half of the question: two windows, so focused and unfocused
    # border colours can be compared side by side.
    pkill -u "$U" -x btop 2>/dev/null || true
    pkill -u "$U" -x foot 2>/dev/null || true
    pkill -u "$U" -x wezterm-gui 2>/dev/null || true
    sleep 1
    run "hyprctl dispatch 'hl.dsp.exec_raw(\"ergon-term\")'" >> /out/reply 2>&1
    sleep 2
    run "hyprctl dispatch 'hl.dsp.exec_raw(\"ergon-term\")'" >> /out/reply 2>&1
    sleep 2
  fi

  if [ "$req" = theme ]; then
    # The repo is handed over 9p read-only and copied in at boot, so a config
    # edited on the host is not visible until it is copied again.
    # --exclude hosts/: that directory is SCAFFOLDED on the machine, not
    # committed (hosts/*/ is gitignored), so --delete against the share wipes
    # hosts/<hostname>/host.env. install.sh then reads no GRAPHICAL=1, skips its
    # entire desktop branch, and silently links nothing -- which is exactly why
    # btop stayed unthemed through three rounds of "fixing" it.
    rsync -a --delete --exclude '.git' --exclude 'hosts/' /mnt/ "$H/ergonOS/" 2>/dev/null \
      || { echo "rsync failed" >> /out/reply; }
    # Scaffold host.env, exactly as guest-sync.sh does at boot. Excluding
    # hosts/ from the rsync preserves it going forward but cannot bring back one
    # an earlier --delete already removed, and without GRAPHICAL=1 install.sh
    # skips every desktop link there is.
    hn=$(hostname -s)
    install -d "$H/ergonOS/hosts/$hn"
    printf 'GRAPHICAL=1\nPROFILE=laptop\n' > "$H/ergonOS/hosts/$hn/host.env"
    chown -R "$U:$U" "$H/ergonOS"
    # install.sh too, not just the renderer: a NEW themed app needs its config
    # linked into $HOME before any amount of re-rendering reaches it. btop was
    # themed, rendered, and still drew its own colours for exactly this reason.
    { run "ERGON=\$HOME/ergonOS \$HOME/ergonOS/install.sh"
      run "ERGON=\$HOME/ergonOS \$HOME/ergonOS/bin/ergon-theme"
      run "ERGON=\$HOME/ergonOS \$HOME/ergonOS/bin/ergon-wallpaper --force"
      run "hyprctl reload"
      # waybar does NOT reload with Hyprland. hyprctl reload re-reads the
      # compositor's config and nothing else, so a change to waybar's
      # config.jsonc or style.css sits unused in a running bar -- which is
      # exactly how an added on-click looked like it had no effect.
      pkill -u "$U" -x waybar 2>/dev/null || true
      sleep 1
      run "hyprctl dispatch 'hl.dsp.exec_raw(\"waybar\")'"
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
