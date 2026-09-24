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

# The LIVE session, re-resolved for every request. The signature used to be
# taken once, above, and a compositor restart broke that silently: the
# OOM kill on 2026-09-21 restarted Hyprland, the dead instance's directory
# stayed behind and sorted first, and every request after it -- including
# `ergon-wallpaper` runs that then started a hyprpaper against the dead
# session -- went to a compositor that no longer existed. The live one is the
# directory whose hyprland.lock names a running PID; its second line is the
# Wayland display.
live_session() {
  local d pid
  for d in /run/user/1000/hypr/*/; do
    pid=$(head -1 "${d}hyprland.lock" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      sig=$(basename "$d")
      wld=$(sed -n 2p "${d}hyprland.lock" 2>/dev/null)
      wld=${wld:-wayland-1}
      return 0
    fi
  done
  return 1
}

# As the user, in the session's environment. Root cannot talk to the compositor.
run() { live_session || true
        su - "$U" -c "XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$sig WAYLAND_DISPLAY=$wld $1" 2>&1; }

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

  # Keep the guest's checkout current with the share.
  #
  # The guest works from a COPY of the repo, not from /mnt directly, and until
  # now only a `palette:` or `theme` request ever refreshed it. So anything
  # committed on the host stayed invisible to someone driving the VM by
  # keybind -- which presented as "I still see 12 themes" after eighteen had
  # been pushed, with nothing wrong anywhere except that the files were not
  # there.
  #
  # Checked every SYNC_EVERY iterations rather than every second: this is a 9p
  # mount and `find` across it is not free. `-quit` stops at the first changed
  # file, so the usual case costs one stat.
  SYNC_EVERY=${SYNC_EVERY:-10}
  SYNC_TICK=$(( ${SYNC_TICK:-0} + 1 ))
  if [ "$SYNC_TICK" -ge "$SYNC_EVERY" ]; then
    SYNC_TICK=0
    STAMP=$H/.ergon-sync-stamp
    if [ ! -f "$STAMP" ] || [ -n "$(find /mnt -path /mnt/.git -prune -o \
         -newer "$STAMP" -print -quit 2>/dev/null)" ]; then
      # --delete so a file removed upstream goes away here too; hosts/ is
      # excluded because the guest writes its own and it is not the share's.
      #
      # The RENDERED configs are protected from --delete. They are gitignored,
      # so a share that is a fresh clone or a git worktree does not have them,
      # and deleting them under a LIVE session leaves the compositor one reload
      # away from "Emergency mode tripped: ... no binds ... SUPER + Q" --
      # hypr/common/looknfeel.lua is required by hypr/hyprland.lua, and a Lua
      # config is one chunk. The list is derived from the templates so it cannot
      # drift from what ergon-theme writes.
      PROTECT=()
      while IFS= read -r tpl; do
        rel="${tpl#/mnt/}"
        PROTECT+=( "--filter=P /${rel%.in}" )
        # -prune, not -not -path: this is a 9p mount and the repo's .git holds
        # ~1900 files that find would otherwise descend into on every sync, for
        # the same reason the -quit above exists.
      done < <(find /mnt -path /mnt/.git -prune -o -name '*.in' -print 2>/dev/null)
      if rsync -a --delete --exclude '.git' --exclude 'hosts/' "${PROTECT[@]}" \
           /mnt/ "$H/ergonOS/" 2>/dev/null; then
        chown -R "$U:$U" "$H/ergonOS" 2>/dev/null || true
        # --no-apply: render the configs so they match the synced templates,
        # but do NOT regenerate the wallpaper, reload hyprland or restart
        # waybar. A file sync must not redraw the screen of someone who is
        # using it; their next palette switch picks the new look up.
        #
        # Its exit status is NOT ignored, and that is the whole point of the
        # line: this used to end in `|| true` with the output sent to
        # /dev/null, and then stamp the sync as done regardless -- so a render
        # that failed was never retried, never reported, and left the guest
        # running whatever was on disk. The one step that guarantees the
        # generated configs exist was the one step allowed to fail quietly.
        if run "ERGON=\$HOME/ergonOS \$HOME/ergonOS/bin/ergon-theme --no-apply" \
             >/tmp/ergon-sync-render.log 2>&1; then
          touch "$STAMP"
          echo "synced from share at $(date +%H:%M:%S)" >> /out/loop-status
        else
          echo "RENDER FAILED at $(date +%H:%M:%S): $(tail -3 /tmp/ergon-sync-render.log | tr '\n' ' ')" \
            >> /out/loop-status
        fi

        # A session that loaded while a config file was missing is still in
        # emergency mode, with SUPER+Q and nothing else, and no amount of
        # fixing the files on disk reaches it: Hyprland reads them once. The
        # binds are the only symptom visible from here, and a reload is the
        # only way out -- safe to do precisely because the render above just
        # succeeded. A healthy session has ~80; five is generous.
        # live_session, not `run`, as the gate: `run` falls through to a
        # `su` that answers nothing when nobody is logged in, and counting
        # zero binds there would mean "no session", not "broken session".
        nb=0
        live_session && nb=$(run "hyprctl binds -j" 2>/dev/null | grep -c '"key"')
        if live_session && [ "$nb" -lt 5 ]; then
          echo "session had $nb binds -- reloading a config that never loaded" >> /out/loop-status
          run "hyprctl reload" >/dev/null 2>&1 || true
        fi
      fi
    fi
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

  # exec -- run /out/exec.sh inside the compositor's session and return its
  # output. Diagnosing anything in here otherwise means adding a request, and
  # every one of those costs a round trip through the whole harness; several
  # have been added for a single question and never used again.
  if [ "$req" = exec ]; then
    if [ -f /out/exec.sh ]; then
      run "sh /out/exec.sh" >> /out/reply 2>&1
    else
      echo "no /out/exec.sh" >> /out/reply
    fi
  fi

  # execroot -- /out/exec.sh as root, OUTSIDE the session. Needed for anything
  # reading raw devices: libinput debug-events on /dev/input/event* is the only
  # way to see what a key actually delivers, and guessing at that from the
  # symptom has now cost three wrong hypotheses in a row.
  if [ "$req" = execroot ]; then
    if [ -f /out/exec.sh ]; then
      sh /out/exec.sh >> /out/reply 2>&1
    else
      echo "no /out/exec.sh" >> /out/reply
    fi
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

  if [ "$req" = power ]; then
    # Run it INSIDE the compositor's session. `su - user` has no logind seat, so
    # polkit refuses allow_active actions there by design -- every test of this
    # so far measured the harness rather than the product.
    #
    # A SCRIPT, not a command escaped through hyprctl's Lua payload and two
    # layers of shell quoting. That was tried and produced nothing at all, which
    # is indistinguishable from the command failing. Third time this session
    # that inline escaping has cost a round trip.
    rm -f /out/power.log
    cat > /out/power-test.sh <<'PTEST'
{
  echo "session: $XDG_SESSION_ID"
  loginctl show-session "$XDG_SESSION_ID" -p Active -p Seat -p State 2>&1
  echo "cgroup: $(cat /proc/self/cgroup 2>/dev/null | head -1)"
  echo "logind sees this pid as session: $(loginctl --property=Id show-session "$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}' | head -1)" 2>/dev/null)"
  echo "pkcheck: $(pkcheck --action-id org.freedesktop.UPower.PowerProfiles.switch-profile --process $$ 2>&1; echo "rc=$?")"
  echo "before: $(powerprofilesctl get 2>&1)"
  echo "cycle:  $(ergon-power cycle 2>&1)"
  echo "after:  $(powerprofilesctl get 2>&1)"
} > /out/power.log 2>&1
PTEST
    chmod 755 /out/power-test.sh
    run "hyprctl dispatch 'hl.dsp.exec_raw(\"sh /out/power-test.sh\")'" >/dev/null 2>&1
    sleep 4
    { echo "-- ergon-power, inside the session:"; cat /out/power.log 2>&1; } >> /out/reply 2>&1
  fi

  if [ "$req" = bar ]; then
    was=$(pgrep -x waybar | head -1)
    # uwsm puts waybar in a systemd scope; a bare pkill as root can lose the
    # race with the compositor's own respawn, and the bar comes back with the
    # config it already had. Kill, confirm it is gone, then start it.
    pkill -u "$U" -x waybar 2>/dev/null || true
    for _ in 1 2 3 4 5; do pgrep -x waybar >/dev/null || break; sleep 1; done
    pkill -9 -u "$U" -x waybar 2>/dev/null || true
    sleep 1
    run "hyprctl dispatch 'hl.dsp.exec_raw(\"waybar\")'" >/dev/null 2>&1
    sleep 3
    now=$(pgrep -x waybar | head -1)
    { echo "-- waybar pid: $was -> ${now:-NONE}"
      [ -n "$now" ] && [ "$now" != "$was" ] && echo "   restarted" || echo "   NOT restarted"
      echo "-- on-click in the live ppd module?"
      awk '/"power-profiles-daemon": \{/{f=1} f{print} f&&/^  \},?$/{exit}' \
        "$H/.config/waybar/config.jsonc" | grep -E 'on-click|format|^\s*\}' | head -6
    } >> /out/reply 2>&1
  fi

  if [ "$req" = diag ]; then
    # Read the state instead of judging it from a screenshot. Twice now a theme
    # has looked unchanged in a capture when the real question was whether the
    # config was even in place.
    { echo "-- btop theme link:"; ls -l "$H/.config/btop/themes/" 2>&1
      echo "-- btop color_theme:"; grep -E '^color_theme' "$H/.config/btop/btop.conf" 2>&1
      echo "-- does the theme file resolve?"
      head -3 "$H/.config/btop/themes/ergon.theme" 2>&1
      echo "-- themed configs present:"
      ls -d "$H/.config/waybar/style.css" "$H/.config/mako/config" \
            "$H/.config/yazi/theme.toml" "$H/.config/lazygit/config.yml" \
            "$H/.config/lazydocker/config.yml" "$H/.config/bat/config" 2>&1
      echo "-- polkit policy for switch-profile:"
      pkaction --action-id org.freedesktop.UPower.PowerProfiles.switch-profile --verbose 2>&1 | head -12
      echo "-- polkit agent running?"; pgrep -a polkit-agent-helper -a 2>/dev/null | head -1; pgrep -af 'polkitagent|polkit-kde|polkit-gnome' | head -1
      echo "-- waybar: pid / started / version"
      pgrep -a waybar | head -1; ps -o lstart= -p "$(pgrep -x waybar | head -1)" 2>/dev/null
      su - "$U" -c "waybar --version" 2>&1 | head -1
      echo "-- the ppd module in the LIVE config:"
      sed -n '/"power-profiles-daemon"/,/^  }/p' "$H/.config/waybar/config.jsonc" 2>&1 | grep -vE '^\s*//' | head -12
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

  # palette:<name> -- switch the live desktop to a palette, so one can be judged
  # on a real screen instead of in a screenshot. <name> is an installed palette,
  # `next`/`prev` to step, or the name of a candidate .env staged on the
  # writable share, which is how a palette gets tried BEFORE it is committed.
  #
  # This deliberately does no applying of its own. It used to regenerate the
  # wallpaper, reload hyprland and restart waybar here, which meant the harness
  # held a second copy of what `ergon theme` should do -- so `ergon theme` could
  # be visibly broken on a real machine while the VM looked fine. Now the same
  # command a user types is the thing under test.
  case "$req" in
    palette:*)
      _arg="${req#palette:}"
      case "$_arg" in
        next) _arg=--next ;;
        prev) _arg=--prev ;;
        *) [ -f "/out/$_arg.env" ] && _arg="/out/$_arg.env" ;;
      esac
      # Take the scripts from the share first. Only the `theme` request used to
      # rsync, so a fix to ergon-theme or ergon-wallpaper did not reach the
      # guest unless a full reinstall was asked for -- which presented as six
      # palettes rendering byte-identical on screen while the .env files on the
      # share were plainly different. bin/ and theme/ are enough here; the full
      # sync stays with `theme`.
      rsync -a /mnt/bin/ "$H/ergonOS/bin/" 2>/dev/null || true
      rsync -a /mnt/theme/ "$H/ergonOS/theme/" 2>/dev/null || true
      # wallpaper/ too, and it is not optional. The background is the largest
      # themed surface and NONE of the code that re-colours it lives in bin/:
      # wallpaper/lib.py decides how a field becomes colour, render.py bakes the
      # palette-independent half and recolour.py applies the palette. Leaving it
      # out meant a palette switch ran whatever was copied in at boot -- measured
      # on 2026-09-24, the guest held 9 generator modules against 61 on the
      # share, so every palette got 9 backgrounds and no amount of fixing the
      # renderer on the host changed what the VM did with it.
      rsync -a /mnt/wallpaper/ "$H/ergonOS/wallpaper/" 2>/dev/null || true
      chown -R "$U:$U" "$H/ergonOS/bin" "$H/ergonOS/theme" "$H/ergonOS/wallpaper"
      run "ERGON=\$HOME/ergonOS \$HOME/ergonOS/bin/ergon-theme $_arg" >> /out/reply 2>&1
      sleep 3
      ;;
  esac

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
      # The loop is root, and the harness removes passwordless sudo after
      # provisioning -- so install.sh's own linking step cannot run here. Do it
      # directly, or a newly added ergon-* stays invisible to the bar and every
      # theme iteration tests a desktop missing the command under test.
      for _c in "$H/ergonOS"/bin/ergon-* "$H/ergonOS"/bin/erg-*; do
        [ -x "$_c" ] && ln -sfn "$_c" "/usr/local/bin/$(basename "$_c")" 2>/dev/null
      done
      # Provisioning's polkit rule, applied here too. The theme request runs
      # install.sh only, and this rule is what makes any polkit-guarded desktop
      # action work at all under uwsm -- without it the iteration loop tests a
      # desktop that cannot switch a power profile no matter what the bar says.
      install -Dm644 /dev/stdin /etc/polkit-1/rules.d/49-ergon-desktop.rules <<'PKRULE'
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("wheel") &&
        action.id == "org.freedesktop.UPower.PowerProfiles.switch-profile") {
        return polkit.Result.YES;
    }
});
PKRULE
      systemctl reload polkit 2>/dev/null || systemctl restart polkit 2>/dev/null || true
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
