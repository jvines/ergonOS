#!/usr/bin/env bash
# Runs INSIDE the installed system. Installs the desktop, starts Hyprland, and
# interrogates the RUNNING compositor.
#
# This is the part no parser can reach. Hyprland's --verify-config proves the
# config is ACCEPTED; it says nothing about whether the compositor comes up,
# whether waybar maps a surface, or whether the binds actually register. It also
# exercises packages/pacman for real -- every package RESOLVING is not the same
# as every package INSTALLING together without a conflict.
#
# Hyprland has no headless backend, so this needs a DRM device (virtio-gpu) and
# a seat. seatd provides the seat without a logind session, which is what lets
# the whole thing be driven from a serial console.
#
# AUR packages are skipped: wezterm-git would build from source in a VM for no
# benefit. That is exactly why binds.lua carries the foot escape hatch, and foot
# is in the official repo -- so a terminal bind is still exercised.
set -uo pipefail

SHARE=/mnt
P=0; F=0
ok()  { printf '   ok   %s\n' "$*"; P=$((P+1)); }
bad() { printf '   FAIL %s\n' "$*"; F=$((F+1)); }
# Neither pass nor fail: a thing the VM cannot do that the hardware can. Kept
# visibly distinct so it never reads as a silent pass.
note() { printf '   --   %s\n' "$*"; }

finish() { echo "--- $P passed, $F failed ---"; echo "DESKTOP_RESULT=$F"; exit 0; }

echo "--- provisioning ---"
U=$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)
H=$(getent passwd "$U" | cut -d: -f6)

# A WRITABLE copy of the repo. The 9p share is read-only, and provision-arch.sh
# writes into $ERGON -- it scaffolds hosts/<hostname>/ from the template. On a
# real machine the repo is cloned into $HOME, so this is also the realistic
# shape rather than a convenience.
rm -rf "${H:?}/ergonOS"
cp -r "$SHARE" "$H/ergonOS"
chown -R "$U:$U" "$H/ergonOS"
ok "repo copied to $H/ergonOS (writable)"

# Normalise ownership of the user's own directories before anything runs as
# them. This harness does a great deal as root inside $H across many runs on a
# disk that is reused for weeks, and a single root-owned directory under
# ~/.local/share makes every uv command die with a bare
# "Permission denied (os error 13)" naming a path and nothing else.
#
# This is harness hygiene, not a workaround for a product bug: on a real machine
# these directories are created by the user's own session and provisioning runs
# as the user throughout.
for d in .local .local/share .local/bin .cache .config; do
  install -d -o "$U" -g "$U" "$H/$d"
done
chown -R "$U:$U" "$H/.local" "$H/.cache" 2>/dev/null || true
ok "\$HOME/.local and \$HOME/.cache owned by $U"

# Passwordless sudo, HARNESS ONLY. provision-arch.sh must run as the user
# (makepkg refuses root) but uses sudo throughout, and there is no tty to type a
# password at. Removed immediately afterwards.
echo "$U ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-harness
chmod 440 /etc/sudoers.d/99-harness

# ERGON_SKIP_AUR: wezterm-git is a long Rust build and nothing else depends on it.
#
# ERGON_SKIP_NEWS: a fresh Arch install always has unread news, and provision-arch's
# informant guard correctly refuses to run pacman until it is read -- it will not
# mark manual-intervention notices as read on your behalf. That guard is doing
# its job here; this is the override it exists to provide. A HUMAN provisioning a
# real machine should read the news instead.
# ERGON_BUNDLES: exercise the bundle machinery for real. notebooks is the
# cheapest one (marimo + jupytext, ~150 MB) and it goes through the whole
# path -- meta, the python list, pyfleet add, and recording BUNDLES in
# host.env. An untested installer feature is a feature that does not work.
#
# ERGON_HARDWARE: a VM's DMI says QEMU, so no hardware profile can ever match
# and the profile mechanism would go permanently unexercised. Forcing it is the
# only way to assert that a profile's kernel parameters reach grub.cfg. The lid,
# the ABM block, fprintd and auto-brightness are capabilities, not profile
# items, and are asserted from what this VM actually has.
#
# The bundle ledger records only what an install ADDED, and this disk is reused:
# marimo is in the venv from the previous run, so it would rightly never be
# recorded and the ledger assertion below would prove nothing. Every run starts
# with the notebooks packages absent and no ledger. On a fresh disk pyfleet has
# no uv yet and this does nothing.
su - "$U" -c "$H/ergonOS/bin/pyfleet drop -- marimo jupytext" >/dev/null 2>&1 || true
rm -f "$H/.local/state/ergon/bundle-ledger"
# Configs the Framework profile used to write, from runs before they became
# capabilities. They carry no marker, so ergon-hardware rightly never removes
# them, and they would make the capability assertions below pass or fail on a
# previous run's leftovers.
rm -f /etc/systemd/logind.conf.d/10-lid.conf /etc/systemd/sleep.conf.d/10-hibernate.conf \
      /etc/systemd/system/power-profiles-daemon.service.d/10-no-abm.conf
if su - "$U" -c "ERGON=$H/ergonOS ERGON_SKIP_AUR=1 ERGON_SKIP_NEWS=1 ERGON_BUNDLES=notebooks ERGON_HARDWARE=framework-13-amd bash $H/ergonOS/bin/provision-arch.sh" >/tmp/prov.log 2>&1; then
  ok "provision-arch.sh completed"
else
  bad "provision-arch.sh failed"
  tail -25 /tmp/prov.log | sed 's/^/     /'
fi
rm -f /etc/sudoers.d/99-harness

# --- what provisioning was supposed to leave behind ------------------------
# NOT just "the file exists" -- the greetd PACKAGE ships a default config.toml,
# so existence passes on a machine provisioning never touched. Check for our
# content: tuigreet, and the vt1 stanza.
grep -q tuigreet /etc/greetd/config.toml 2>/dev/null \
  && ok "greetd uses tuigreet (ours, not the package default)" \
  || bad "/etc/greetd/config.toml is not ours"
# Assert the command is the one that WORKS, not merely that it mentions uwsm.
# The original checked for the string 'hyprland-uwsm' and passed while the
# command was 'uwsm start -S hyprland-uwsm.desktop' -- which is doubly wrong:
# -S is not a uwsm flag, and hyprland-uwsm.desktop IS the uwsm launcher, so it
# asked uwsm to start uwsm. greetd authenticated and then ran nonsense.
if grep -q "uwsm start -e -D Hyprland hyprland.desktop" /etc/greetd/config.toml 2>/dev/null; then
  ok "greetd session command matches the packaged hyprland-uwsm.desktop"
else
  bad "greetd session command is wrong (see /etc/greetd/config.toml)"
fi
# -S has never been a uwsm flag; catch it explicitly if it ever returns.
grep -q 'uwsm start -S' /etc/greetd/config.toml 2>/dev/null \
  && bad "greetd uses 'uwsm start -S', which errors on an unrecognized argument" \
  || ok "no invalid -S flag in the session command"
# Bundles: installed AND recorded. Two different claims.
if grep -q 'BUNDLES="[^"]*notebooks' "$H/ergonOS/hosts/$(hostname -s)/host.env" 2>/dev/null; then
  ok "the notebooks bundle is recorded in host.env"
else
  bad "host.env did not record the bundle — a reprovision would forget it"
  grep -n BUNDLES "$H/ergonOS/hosts/$(hostname -s)/host.env" 2>/dev/null | sed 's/^/     /'
fi
if su - "$U" -c "\$HOME/.local/share/pyfleet/bin/python -c 'import marimo'" >/dev/null 2>&1; then
  ok "the bundle's python packages are importable in pyfleet"
else
  bad "marimo is not importable — the bundle installed nothing"
fi
# The ledger reads real dist-info names (marimo-0.x.dist-info) and a real
# `pacman -Qq`. A stub cannot prove uv names them the way the ledger parses them.
if grep -qx 'notebooks python marimo' "$H/.local/state/ergon/bundle-ledger" 2>/dev/null; then
  ok "the ledger records what the notebooks bundle installed"
else
  bad "the ledger has no 'notebooks python marimo' — remove would uninstall nothing"
  sed 's/^/     /' "$H/.local/state/ergon/bundle-ledger" 2>/dev/null | head -10
fi

# --- a bundle from a real forge, over ssh on a non-standard port ------------
# test-bundles.sh fetches from a local repository through stubs. This is the
# path a private overlay actually takes: sshd on 2222, the user's own key,
# known_hosts, and never a prompt. With real pacman and uv it also proves the
# ledger leaves alone a package that was there before the bundle, and that sync
# reinstalls a bundle with its forge gone.
asu() { su - "$U" -c "$1"; }
EB="$H/ergonOS/bin/ergon-bundle"
FORGE=/tmp/ergon-forge
URL="ssh://$U@127.0.0.1:2222$H/pub/overlay.git"
COPY="$H/ergonOS/hosts/$(hostname -s)/bundles/demo"
LEDGER="$H/.local/state/ergon/bundle-ledger"

# This disk is reused: clear the previous run's forge, packages and venv entry.
[ ! -f "$FORGE/pid" ] || kill "$(cat "$FORGE/pid")" 2>/dev/null || true
rm -rf "$FORGE" "$H/pub"
pacman -Rns --noconfirm cowsay >/dev/null 2>&1 || true
asu "\$HOME/ergonOS/bin/pyfleet drop -- tomli-w" >/dev/null 2>&1 || true
# figlet is installed BEFORE the bundle, which also lists it: remove must leave it.
pacman -S --needed --noconfirm figlet >/dev/null 2>&1 || bad "could not preinstall figlet (harness)"

forge_ok=1
asu "set -e
  export GIT_AUTHOR_NAME=vm GIT_AUTHOR_EMAIL=vm@ergon.invalid GIT_COMMITTER_NAME=vm GIT_COMMITTER_EMAIL=vm@ergon.invalid
  mkdir -p \$HOME/pub/work/demo
  printf 'DESCRIPTION=\"VM forge test\"\n' > \$HOME/pub/work/demo/meta
  printf 'cowsay\nfiglet\n' > \$HOME/pub/work/demo/pacman
  printf 'tomli-w\n' > \$HOME/pub/work/demo/python
  git -C \$HOME/pub/work init -q -b main
  git -C \$HOME/pub/work add -A
  git -C \$HOME/pub/work commit -qm demo
  git -C \$HOME/pub/work tag -a -m v1 v1
  git clone -q --bare \$HOME/pub/work \$HOME/pub/overlay.git
  install -d -m 700 \$HOME/.ssh
  [ -f \$HOME/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f \$HOME/.ssh/id_ed25519
  touch \$HOME/.ssh/authorized_keys && chmod 600 \$HOME/.ssh/authorized_keys
  grep -qxF \"\$(cat \$HOME/.ssh/id_ed25519.pub)\" \$HOME/.ssh/authorized_keys || cat \$HOME/.ssh/id_ed25519.pub >> \$HOME/.ssh/authorized_keys
  ssh-keygen -R '[127.0.0.1]:2222' >/dev/null 2>&1 || true" > /tmp/forge.log 2>&1 \
  || { forge_ok=0; bad "could not build the forge repository or key (harness)"; tail -5 /tmp/forge.log | sed 's/^/     /'; }

install -d -m 700 "$FORGE"
ssh-keygen -q -t ed25519 -N '' -f "$FORGE/host_key"
printf 'Port 2222\nListenAddress 127.0.0.1\nHostKey %s/host_key\nPidFile %s/pid\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nAuthenticationMethods publickey\n' \
  "$FORGE" "$FORGE" > "$FORGE/sshd_config"
# sshd re-execs itself, which it refuses to do from a relative path.
if [ "$forge_ok" = 1 ] && /usr/bin/sshd -t -f "$FORGE/sshd_config" 2> "$FORGE/err" && /usr/bin/sshd -f "$FORGE/sshd_config" 2>> "$FORGE/err"; then
  for _ in $(seq 20); do [ -s "$FORGE/pid" ] && break; sleep 0.5; done
fi
[ -s "$FORGE/pid" ] || { [ "$forge_ok" = 0 ] || bad "sshd on 2222 did not start (harness)"; sed 's/^/     /' "$FORGE/err" 2>/dev/null; forge_ok=0; }

if [ "$forge_ok" = 1 ]; then
  echo "$U ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-harness
  chmod 440 /etc/sudoers.d/99-harness

  # No known_hosts entry yet. BatchMode must turn the host-key question into a
  # fast failure: a prompt during provisioning is a hang nobody can answer.
  rc=0; asu "timeout 90 $EB info $URL//demo@v1" > /tmp/bundle-forge.log 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && grep -q 'Fetches never prompt' /tmp/bundle-forge.log; then
    ok "an unknown forge host key fails at once, without prompting"
  else
    bad "an unknown forge host key did not fail cleanly (exit $rc; 124 is a hang)"
    tail -5 /tmp/bundle-forge.log | sed 's/^/     /'
  fi

  asu "ssh-keyscan -p 2222 -t ed25519 127.0.0.1 >> \$HOME/.ssh/known_hosts 2>/dev/null"
  if asu "timeout 600 $EB add --yes $URL//demo@v1" > /tmp/bundle-forge.log 2>&1; then
    ok "added a bundle from $URL"
  else
    bad "add from the ssh forge on 2222 failed"
    tail -10 /tmp/bundle-forge.log | sed 's/^/     /'
  fi
  pacman -Q cowsay >/dev/null 2>&1 && ok "  its pacman package is installed" || bad "  cowsay is not installed"
  asu "\$HOME/.local/share/pyfleet/bin/python -c 'import tomli_w'" >/dev/null 2>&1 \
    && ok "  its python package imports in pyfleet" || bad "  tomli_w does not import"
  v1=$(asu "git -C \$HOME/pub/work rev-parse 'v1^{commit}'" 2>/dev/null)
  if grep -qxF "url=$URL" "$COPY/.source" 2>/dev/null && grep -qxF "commit=$v1" "$COPY/.source" 2>/dev/null; then
    ok "  the copy records the ssh URL with its port, and the tag's commit"
  else
    bad "  hosts/$(hostname -s)/bundles/demo/.source does not record $URL at $v1"
    sed 's/^/     /' "$COPY/.source" 2>/dev/null
  fi
  if grep -qx 'demo pacman cowsay' "$LEDGER" && grep -qx 'demo python tomli-w' "$LEDGER" && ! grep -qx 'demo pacman figlet' "$LEDGER"; then
    ok "  the ledger records cowsay and tomli-w, and not figlet, which was already here"
  else
    bad "  the ledger is wrong for demo"
    grep '^demo ' "$LEDGER" 2>/dev/null | sed 's/^/     /'
  fi

  # The forge goes away; the copy is the pin, so sync still reinstalls.
  kill "$(cat "$FORGE/pid")" 2>/dev/null || true
  sleep 1
  pacman -Rns --noconfirm cowsay >/dev/null 2>&1 || true
  if asu "timeout 900 $EB sync" > /tmp/bundle-forge.log 2>&1 && pacman -Q cowsay >/dev/null 2>&1; then
    ok "sync reinstalled the bundle with its forge down"
  else
    bad "sync did not reinstall cowsay without the forge"
    tail -10 /tmp/bundle-forge.log | sed 's/^/     /'
  fi

  asu "timeout 300 $EB remove demo" > /tmp/bundle-forge.log 2>&1 || { bad "remove demo failed"; tail -10 /tmp/bundle-forge.log | sed 's/^/     /'; }
  pacman -Q cowsay >/dev/null 2>&1 && bad "remove left cowsay installed" || ok "remove uninstalled what the bundle installed"
  pacman -Q figlet >/dev/null 2>&1 && ok "  and left figlet, which was there before it" || bad "  remove uninstalled figlet, which the bundle did not install"
  asu "\$HOME/.local/share/pyfleet/bin/python -c 'import tomli_w'" >/dev/null 2>&1 \
    && bad "  tomli_w still imports after remove" || ok "  and dropped its python package"
  if [ ! -e "$COPY" ] && ! grep -q '^demo ' "$LEDGER" 2>/dev/null; then
    ok "  and forgot the copy and its ledger entries"
  else
    bad "  the copy or its ledger entries survived remove"
  fi
  rm -f /etc/sudoers.d/99-harness
fi
[ ! -f "$FORGE/pid" ] || kill "$(cat "$FORGE/pid")" 2>/dev/null || true
rm -rf "$FORGE"

# The regdom must match the machine's ACTUAL timezone, not a constant. This
# asserted only that the file exists, which was true while it said CL on every
# machine on earth.
_tz=$(timedatectl show -p Timezone --value 2>/dev/null)
_want=$(awk -v t="$_tz" '$1 !~ /^#/ && $3 == t { print $1; exit }' /usr/share/zoneinfo/zone.tab 2>/dev/null | cut -c1-2)
_got=$(awk -F= '/ieee80211_regdom/ { print $NF }' /etc/modprobe.d/cfg80211.conf 2>/dev/null)
if [ -n "$_got" ] && [ "$_got" = "${_want:-00}" ]; then
  ok "wifi regdom $_got derived from $_tz"
else
  bad "regdom is '$_got', expected '${_want:-00}' for timezone $_tz"
fi

# The compositor keyboard layout must be the one the installer was told about.
_kb=$(awk -F= '/^KEYMAP=/ { gsub(/"/, "", $2); print $2 }' /etc/vconsole.conf 2>/dev/null)
if grep -q "kb_layout = \"${_kb:-us}\"" "$H/ergonOS/hosts/$(hostname -s)/hyprland.lua" 2>/dev/null; then
  ok "kb_layout scaffolded as '${_kb:-us}' from /etc/vconsole.conf"
else
  bad "kb_layout not scaffolded per host (expected '${_kb:-us}')"
  grep -n kb_layout "$H/ergonOS/hosts/$(hostname -s)/hyprland.lua" 2>/dev/null | sed 's/^/     /'
fi
grep -rq 'kb_layout = "us"' "$H/.config/hypr/common/" 2>/dev/null \
  && bad "the shared config still hardcodes a keyboard layout" \
  || ok "no keyboard layout hardcoded in the shared config"

# Microcode belongs to the CPU that is present.
case "$(awk -F': ' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo)" in
  GenuineIntel) _uc=intel-ucode ;;
  AuthenticAMD) _uc=amd-ucode ;;
  *)            _uc="" ;;
esac
if [ -z "$_uc" ]; then
  ok "unknown CPU vendor; no microcode expected"
elif pacman -Qi "$_uc" >/dev/null 2>&1; then
  ok "$_uc installed (matches this CPU)"
else
  bad "$_uc is not installed for this CPU"
fi
# --- hardware, by capability ---------------------------------------------------
# The VM is made s2idle-only (test-hypr-session.sh) and the disk has working
# hibernation (test-hibernate.sh), so the lid rule must take the positive path.
# It has virtio-gpu and no light sensor, so the amdgpu and auto-brightness rules
# must NOT apply. The Framework profile is forced, so its kernel parameter must.
MARK="# Written by ergon-hardware from what this machine has; removed when that stops being true."
if grep -qx '\[s2idle\]' /sys/power/mem_sleep 2>/dev/null; then
  ok "the VM firmware offers s2idle only (S3 disabled)"
else
  bad "the VM still offers S3 ($(cat /sys/power/mem_sleep 2>/dev/null)); the lid assertion below proves nothing"
fi
if grep -qxF "$MARK" /etc/systemd/logind.conf.d/10-lid.conf 2>/dev/null \
   && grep -qx 'HandleLidSwitch=suspend-then-hibernate' /etc/systemd/logind.conf.d/10-lid.conf; then
  ok "lid -> suspend-then-hibernate, chosen from s2idle-only firmware and working hibernation"
else
  bad "no generated lid drop-in on an s2idle-only machine with hibernation"
  grep -A3 'lid' /tmp/prov.log 2>/dev/null | head -4 | sed 's/^/     /'
fi
[ ! -e /etc/systemd/system/power-profiles-daemon.service.d/10-no-abm.conf ] \
  && ok "no ABM drop-in on a machine without an amdgpu panel" || bad "ABM drop-in written without an amdgpu panel"
systemctl is-enabled ergon-fprintd-resume.service >/dev/null 2>&1 \
  && ok "fprintd is restarted after resume" || bad "ergon-fprintd-resume.service is not enabled"
pacman -Q illuminanced >/dev/null 2>&1 \
  && bad "illuminanced installed on a machine with no light sensor" || ok "no auto-brightness without a light sensor"
if grep -q 'amdgpu.dcdebugmask=0x610' /etc/default/grub && grep -q 'amdgpu.dcdebugmask=0x610' /boot/grub/grub.cfg; then
  ok "the forced Framework profile's kernel parameter is in grub.cfg"
else
  bad "the Framework profile's kernel parameter did not reach grub.cfg"
fi
_sc=$(su - "$U" -c "$H/ergonOS/bin/ergon-sleep check" 2>&1)
if printf '%s\n' "$_sc" | grep -q 's2idle only' && printf '%s\n' "$_sc" | grep -q 'hibernation: ready'; then
  ok "ergon-sleep check reads s2idle-only and hibernation ready"
else
  bad "ergon-sleep check disagrees with this machine"
  printf '%s\n' "$_sc" | sed 's/^/     /' | head -8
fi

# snap-pac hooks pacman and snapshots around every transaction, which is what
# makes a bad update survivable. It is installed by arch-bootstrap.sh -- but
# "the package is installed" and "a snapshot happened" are different claims, and
# this file exists because of that distinction.
#
# Provisioning just ran pacman, so a pre/post pair must exist by now.
if command -v snapper >/dev/null 2>&1; then
  _snaps=$(snapper -c root list 2>/dev/null || true)
  _pre=$(printf '%s\n' "$_snaps" | grep -cw pre || true)
  _post=$(printf '%s\n' "$_snaps" | grep -cw post || true)
  if [ "${_pre:-0}" -ge 1 ] && [ "${_post:-0}" -ge 1 ]; then
    ok "snap-pac snapshotted around pacman ($_pre pre / $_post post)"
  else
    bad "no pre/post snapshot pair — a bad update would not be survivable"
    printf '%s\n' "$_snaps" | tail -8 | sed 's/^/     /'
    for _h in /usr/share/libalpm/hooks/*snap*; do
      [ -e "$_h" ] && echo "     hook: ${_h##*/}"
    done
  fi
else
  bad "snapper is not installed"
fi

# grub-btrfs turns those snapshots into bootable GRUB entries, which is the
# difference between "you can roll back" and "you can roll back without a live
# USB and a manual btrfs subvolume swap".
if systemctl is-enabled grub-btrfsd >/dev/null 2>&1; then
  ok "grub-btrfsd enabled (snapshots appear in the boot menu)"
else
  bad "grub-btrfsd is not enabled — snapshots will not be bootable"
fi

grep -q 'TIMELINE_LIMIT_HOURLY="5"' /etc/snapper/configs/root 2>/dev/null \
  && ok "snapper timeline trimmed" || bad "snapper timeline not trimmed"
id -nG "$U" | grep -qw video && ok "$U added to video by provisioning" || bad "$U not in video"
[ -d "$H/ergonOS/hosts/$(hostname -s)" ] && ok "hosts/$(hostname -s) scaffolded" || bad "host dir not scaffolded"

# greetd would start a greeter on vt1 and take the seat and the DRM device out
# from under the compositor this test starts by hand. Stop it for the duration.
systemctl stop greetd >/dev/null 2>&1 || true

# The click fix lives in the PACKAGE, not in any config: extra/waybar 0.15.0
# cannot switch workspaces against a Lua-configured Hyprland (Alexays/Waybar
# #5013 -- on master, not yet in a release). Assert what is actually on disk;
# provisioning logs its AUR stage to a file this harness never reads, which is
# how a failed waybar-git build went unnoticed through a whole run.
if pacman -Qi waybar-git >/dev/null 2>&1; then
  ok "waybar-git is installed (workspace clicks can work)"
else
  bad "waybar-git NOT installed: $(pacman -Qo "$(command -v waybar 2>/dev/null)" 2>&1 | tail -1)"
  sed -n '/AUR packages/,$p' /tmp/prov.log 2>/dev/null | tail -20 | sed 's/^/       /'
fi

# Any DRM card, not card0 specifically: with virtio-vga-gl the guest can
# enumerate the device under a different index, and gating on card0 aborted the
# whole desktop phase on a VM that demonstrably had a working GPU.
if ls /dev/dri/card* >/dev/null 2>&1; then
  ok "DRM device present ($(ls -m /dev/dri/card* 2>/dev/null))"
  # WHICH card matters. A UEFI framebuffer shows up as simpledrm with no render
  # node; the virtio-gpu is the one that can do GL and dmabuf. If the compositor
  # lands on the first and the renderer is on the second, everything draws but
  # nothing composites -- which is exactly the flat wallpaper and the dead grim.
  for c in /dev/dri/card*; do
    n=$(basename "$c")
    drv=$(basename "$(readlink -f "/sys/class/drm/$n/device/driver" 2>/dev/null)" 2>/dev/null)
    rnd=$(ls -d /sys/class/drm/"$n"/device/drm/render* 2>/dev/null | head -1)
    note "$n: driver=${drv:-unknown} render_node=${rnd:+yes}${rnd:-no}"
  done
  note "aquamarine chose: $(grep -oE "/dev/dri/card[0-9]+" /run/user/1000/hypr/*/hyprland.log 2>/dev/null | sort -u | tr "\n" " ")"
else
  bad "no DRM card at all — /dev/dri holds: $(ls -m /dev/dri 2>/dev/null || echo 'nothing')"
  finish
fi

# --- configs, placed BY install.sh -----------------------------------------
# This used to `cp -r` the four config directories into place and symlink
# bin/ergon* into ~/.local/bin by hand. It passed every assertion below and left a
# desktop you could not use: install.sh also links environment.d/10-ergon-path.conf,
# which is what puts $ERGON/bin on the SESSION PATH. Without it every waybar
# module whose on-click is `ergon-launch-tui ...` fires into nothing -- so the bar
# looked right, mapped its surface, passed the test, and only the bluetooth
# button (on-click: blueman-manager, a real binary) actually did anything.
#
# A harness that stages its own approximation of the install tests the harness.
# Run the installer.
printf 'GRAPHICAL=1\nPROFILE=laptop\n' > "$H/ergonOS/hosts/$(hostname -s)/host.env"
chown "$U:$U" "$H/ergonOS/hosts/$(hostname -s)/host.env"
if su - "$U" -c "cd ~/ergonOS && ERGON=\$HOME/ergonOS ./install.sh" >/tmp/install.log 2>&1; then
  ok "install.sh completed"
else
  bad "install.sh failed"; tail -20 /tmp/install.log | sed 's/^/     /'
fi

# Assert the LINKS, not the copies. Each of these is a thing that was missing.
# The reaper timer is what keeps "services are off by default" true past login.
# `systemctl --user is-enabled` needs a session bus and there is none here, so
# check the thing enabling actually IS: the WantedBy symlink. That is also what
# a fresh machine has before its first graphical login, which is the case that
# was broken.
# The unit's ExecStart must point at a binary that EXISTS. A stale path there
# fails every ten minutes, silently, in a log nobody reads -- which is exactly
# what the repo rename did to it.
_exec=$(sed -n 's/^ExecStart=//p' "$H/.config/systemd/user/ergon-reap.service" 2>/dev/null | awk '{print $1}')
_exec=${_exec/\%h/$H}
if [ -x "$_exec" ]; then
  ok "ergon-reap ExecStart resolves ($_exec)"
else
  bad "ergon-reap ExecStart does not exist: '$_exec'"
fi

if [ -L "$H/.config/systemd/user/timers.target.wants/ergon-reap.timer" ]; then
  ok "ergon-reap.timer enabled (wants symlink present)"
else
  bad "ergon-reap.timer not enabled — idle services would run forever"
  ls -la "$H/.config/systemd/user/timers.target.wants/" 2>/dev/null | sed 's/^/     /'
fi

for pair in \
  ".config/hypr:the compositor config" \
  ".config/waybar:the bar" \
  ".config/mako:notifications" \
  ".config/fuzzel:the launcher" \
  ".config/gtk-3.0/settings.ini:GTK3 theme" \
  ".config/environment.d/10-ergon-path.conf:session PATH"; do
  f=${pair%%:*}; what=${pair#*:}
  [ -e "$H/$f" ] && ok "install.sh linked $what" || bad "install.sh did not link $f ($what)"
done

# The user must be in `video` to open /dev/dri/card*, which are root:video 0660.
# Without it Hyprland dies with "CBackend::create() failed!" and nothing else --
# no permission error, no mention of DRM. provision-arch.sh does this on a real
# machine; this test bypasses provisioning, so it has to do it too. That the
# omission produced exactly this crash is a decent argument that the
# provision-arch step is load-bearing rather than defensive.
usermod -aG video,input,render,seat "$U" 2>/dev/null || usermod -aG video,input,render "$U" 2>/dev/null || true
id -nG "$U" | tr ' ' '\n' | grep -qx video && ok "$U is in the video group" || bad "$U is not in video"

systemctl start seatd >/dev/null 2>&1 || seatd -g wheel >/tmp/seatd.log 2>&1 &
sleep 2
pgrep -x seatd >/dev/null && ok "seatd running" || bad "seatd did not start"

# --- start the compositor --------------------------------------------------
echo "--- starting Hyprland ---"
install -d -o "$U" -g "$U" -m 700 /run/user/1000
cat > /tmp/start-hypr.sh <<'EOF'
export XDG_RUNTIME_DIR=/run/user/1000
export LIBSEAT_BACKEND=seatd
export XDG_CURRENT_DESKTOP=Hyprland

# PATH comes from the same file systemd --user would read, not from a
# convenient reimplementation of it. This session is started by hand and so has
# no systemd user manager to apply environment.d -- but if the test invents its
# own PATH, it proves the PATH the test invented, which is how a broken
# environment.d link survived a green run.
ENVD="$HOME/.config/environment.d/10-ergon-path.conf"
if [ -r "$ENVD" ]; then
  set -a; . "$ENVD"; set +a
else
  echo "WARNING: $ENVD missing; ergon-* will not be on PATH" >&2
fi

exec Hyprland -c "$HOME/.config/hypr/hyprland.lua"
EOF
chmod +x /tmp/start-hypr.sh
# `su -` (login shell), not `su`: supplementary groups are established at
# session setup, so a non-login su keeps the OLD group set and the usermod above
# would have no effect until the next real login.
setsid su - "$U" -c "bash /tmp/start-hypr.sh" > /tmp/hypr.log 2>&1 &

# Wait for the IPC socket rather than sleeping a fixed amount.
for _ in $(seq 1 30); do
  [ -n "$(find /run/user/1000/hypr -name '.socket.sock' 2>/dev/null | head -1)" ] && break
  sleep 2
done

export XDG_RUNTIME_DIR=/run/user/1000
SIG=$(ls /run/user/1000/hypr 2>/dev/null | head -1)
if [ -z "$SIG" ]; then
  bad "Hyprland never created an IPC socket"
  echo "   --- hypr.log ---"; tail -25 /tmp/hypr.log | sed 's/^/     /'
  finish
fi
export HYPRLAND_INSTANCE_SIGNATURE="$SIG"
ok "Hyprland is running (instance $SIG)"

# -s /bin/bash, not the user's login shell.
#
# `su -c` runs the command THROUGH the target user's shell, which here is zsh.
# A Lua dispatch argument -- hl.dsp.focus({workspace = 3}) -- is then parsed by
# zsh before hyprctl ever sees it: the parens are glob qualifiers and the braces
# are a brace expansion. What comes back is a zsh error ("unknown sort
# specifier", "number expected") that reads exactly like Hyprland rejecting the
# syntax, and sends you off rewriting a call that was correct.
hq() { su "$U" -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl $*" 2>&1; }

# Every graphical client below needs the SAME environment a real session gets,
# and getting it wrong fails in a way that reads as a product bug: waybar says
# "cannot open display", foot says "no compositor running?", grim says nothing
# at all -- none of which mention the variable that is missing.
#
# WAYLAND_DISPLAY is discovered, not assumed. It is wayland-1 on a fresh boot
# and wayland-0 or wayland-2 whenever it is not, and hard-coding it turns a
# second compositor start into an unexplained hang.
WLD=""
for _s in /run/user/1000/wayland-*; do
  case "$_s" in *.lock) continue ;; esac
  [ -S "$_s" ] && { WLD=${_s##*/}; break; }
done
[ -n "$WLD" ] && ok "wayland socket is $WLD" || bad "no wayland socket in /run/user/1000"

# The PATH a session really gets, from the file systemd --user really reads.
SESSION_PATH=$(HOME="$H" bash -c '
  set -a; . "$HOME/.config/environment.d/10-ergon-path.conf" 2>/dev/null; set +a; echo "$PATH"')
case "$SESSION_PATH" in
  *"$H/ergonOS/bin"*) ok "session PATH includes the repo bin" ;;
  *) bad "session PATH does not include $H/ergonOS/bin — every ergon-* click is a no-op" ;;
esac

# Run something as the user, inside the session, the way the session would.
usr() {
  su - "$U" -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/1000 \
                HYPRLAND_INSTANCE_SIGNATURE=$SIG \
                WAYLAND_DISPLAY=$WLD \
                XDG_CURRENT_DESKTOP=Hyprland \
                PATH='$SESSION_PATH' $*"
}

# Dump the compositor log on ANY failure. An instance directory exists as soon
# as Hyprland starts, so "socket present" does not mean "came up" -- without the
# log a crash right after startup is indistinguishable from a broken hyprctl.
dump_log() {
  # Hyprland writes its real log to $XDG_RUNTIME_DIR/hypr/<sig>/hyprland.log,
  # NOT to stdout. Tailing the redirect of the launch command gives an empty
  # file and no clue at all -- which is exactly what happened the first time.
  echo "   --- hyprland.log (tail) ---"
  tail -40 /run/user/1000/hypr/*/hyprland.log 2>/dev/null | sed 's/^/     /'
  echo "   --- launch stdout/stderr ---"
  tail -15 /tmp/hypr.log 2>/dev/null | sed 's/^/     /'
  echo "   --- DRM cards ---"
  ls -l /dev/dri/ 2>/dev/null | sed 's/^/     /'
  echo "   --- outputs seen by DRM ---"
  for c in /sys/class/drm/card*/status; do [ -r "$c" ] && echo "     $c: $(cat "$c")"; done
}

if hq version | grep -q Hyprland; then
  ok "hyprctl responds"
else
  bad "hyprctl does not respond"
  echo "   hyprctl said: $(hq version | head -3)"
  dump_log
fi

# The binds are the thing two API bugs would have silently emptied.
NB=$(hq binds -j 2>/dev/null | grep -c '"key"' || true)
NB=${NB:-0}
if [ "$NB" -gt 20 ]; then ok "$NB keybindings registered"; else bad "only $NB keybindings registered"; fi

# The cheatsheet, through the real ergon-keys pipeline -- this used to grep the
# JSON for the word "description", and passed while the screenshot, media and
# night-light keys were registered, undescribed, and missing from the list.
# Every bind a person can press must come out as a row; switch: binds (the
# lid) are events rather than keys, and may be absent.
KEYS_OUT=$(usr "ergon-keys --print" 2>/tmp/keys.err) || true
KEYS_ROWS=$(printf '%s\n' "$KEYS_OUT" | grep -c . || true)
KEYS_WANT=$(hq binds -j | jq '[.[] | select(.description != "" or (.key | startswith("switch:") | not))] | length' 2>/dev/null || echo "?")
if [ "$KEYS_ROWS" -gt 20 ] && [ "$KEYS_ROWS" = "$KEYS_WANT" ]; then
  ok "ergon-keys lists all $KEYS_ROWS pressable binds the compositor has"
else
  bad "ergon-keys lists $KEYS_ROWS rows; the compositor has $KEYS_WANT pressable binds"
  hq binds -j | jq -r '.[] | select(.description == "" and (.key | startswith("switch:") | not))
                      | "     undescribed: modmask \(.modmask), key \(.key)"' 2>/dev/null
  sed 's/^/     /' /tmp/keys.err | head -5
fi

# Workspaces and the scratchpad are bound by KEYCODE, so they can be pressed on
# any layout. The JSON cannot show that -- under Lua it reports such a bind as
# key "" and keycode 0 -- so read the plain form, which prints the bind as it
# was written, and check each sits on its physical key.
if KC_OUT=$(hq binds | awk '
    /^\tkey: /         { k = substr($0, 7) }
    /^\tdescription: / { d = substr($0, 15); want = 0
      if (d ~ /^(Move to w|W)orkspace [1-9]$/) want = 9 + substr(d, length(d))
      if (d == "Toggle scratchpad" || d == "Send to scratchpad") want = 49
      if (want) { n++; if (k !~ ("code:" want "$")) { wrong = 1; print "     " d ": " k } } }
    END { exit (n == 20 && !wrong) ? 0 : 1 }'); then
  ok "workspace and scratchpad binds are on keycodes 10-18 and 49"
else
  bad "workspace/scratchpad binds are not all on keycodes 10-18 and 49"
  printf '%s\n' "$KC_OUT"
fi
# ...and the cheatsheet names those keys as each layout labels them.
#
# "A Workspace 1 row and no code: anywhere" proved nothing: on us, the fallback
# ergon-keys uses when it has no keymap prints the same 1 a working keymap
# does. So switch the compositor through the layouts the keys were moved for
# and require what the key really types on each. The key left of 1 differs on
# all four, and from the fallback's "key left of 1". Each layout is read twice:
# through the compositor's own keymap, and with no Wayland display, which makes
# ergon-keys compile one from the layout `hyprctl devices` reports.
#
# `hyprctl keyword` does not work on a Lua config; eval does. The keymap is
# applied on the compositor's next loop iteration, so wait for the keyboard to
# report it rather than sleeping.
kb_main() { hq devices -j | jq -r '((.keyboards | map(select(.main)) + .)[0] // {}) | "\(.layout // "")\t\(.variant // "")"'; }
set_layout() {
  hq "eval 'hl.config({ input = { kb_layout = \"$1\", kb_variant = \"${2:-}\" } })'" >/dev/null
  for _ in $(seq 1 20); do
    [ "$(kb_main)" = "$1"$'\t'"${2:-}" ] && return 0
    sleep 0.25
  done
  return 1
}
key_of() { printf '%s\n' "$1" | awk -F'  +' -v d="$2" '$2 == d { sub(/^SUPER \+ /, "", $1); print $1 }'; }
IFS=$'\t' read -r KB0 KV0 < <(kb_main)
if printf '%s\n' "$KEYS_OUT" | grep -q 'code:'; then bad "ergon-keys shows a raw code:N"; else ok "ergon-keys shows no raw code:N"; fi
# Without this, a dead first source would pass below as "session" on the fallback.
if usr "timeout 2 xkbcli dump-keymap-wayland" 2>/dev/null | grep -q 'xkb_symbols'; then
  ok "the compositor hands clients its keymap (ergon-keys' first source)"
else
  bad "xkbcli dump-keymap-wayland got no keymap; ergon-keys can only compile one"
fi
for want in 'us 1 `' 'latam 1 |' 'es 1 º' 'fr & ²'; do
  read -r L W1 SP <<<"$want"
  if ! set_layout "$L"; then bad "could not switch the compositor to $L (it reports '$(kb_main | tr '\t' ' ')')"; continue; fi
  for src in session compiled; do
    if [ "$src" = session ]; then out=$(usr "ergon-keys --print" 2>/dev/null)
    else out=$(usr "WAYLAND_DISPLAY=none ergon-keys --print" 2>/dev/null); fi
    got="$(key_of "$out" "Workspace 1") $(key_of "$out" "Toggle scratchpad")"
    if [ "$got" = "$W1 $SP" ]; then
      ok "ergon-keys on $L, $src keymap: SUPER + $W1 is workspace 1, SUPER + $SP the scratchpad"
    else
      bad "ergon-keys on $L, $src keymap: workspace 1 and the scratchpad are on '$got', want '$W1 $SP'"
    fi
  done
done
set_layout "${KB0:-us}" "${KV0:-}" || bad "could not restore the layout to '${KB0:-us}'"
# Hyprland fires EVERY bind that matches, so a chord bound twice is two actions
# on one press. ergon-lint catches the literal ones; this catches the chords
# built at runtime (the workspace loop, the help key chosen by layout).
KEYS_DUPS=$(printf '%s\n' "$KEYS_OUT" | awk -F'  +' 'NF { print toupper($1) }' | sort | uniq -d)
if [ -z "$KEYS_DUPS" ]; then ok "no chord is bound twice"; else bad "chords bound twice: ${KEYS_DUPS//$'\n'/, }"; fi

# Window rules and monitors.
hq monitors -j | grep -q '"name"' && ok "a monitor is present" || bad "no monitors"

# waybar should map a layer surface. This is the one config no parser checks.
#
# autostart.lua execs waybar from the compositor, so it is already running and
# already has the right environment. The test used to start a SECOND one beside
# it, with an incomplete environment: that copy died on "cannot open display"
# while the real one worked, and the assertion passed on the real one -- so the
# log carried a fatal-looking waybar error that meant nothing. Wait for the one
# the session started; only start one here if the session did not.
for _ in $(seq 1 20); do hq layers | grep -q waybar && break; sleep 1; done
if ! hq layers | grep -q waybar; then
  echo "     autostart did not bring up waybar; starting one by hand"
  usr "waybar -c $H/.config/waybar/config.jsonc -s $H/.config/waybar/style.css" >/tmp/waybar.log 2>&1 &
  sleep 6
fi
if hq layers | grep -q waybar; then
  ok "waybar mapped a layer surface"
else
  bad "waybar did not map a layer surface"
  tail -12 /tmp/waybar.log 2>/dev/null | sed 's/^/     /'
fi

# ergon-doctor is the bug-report format for a public distro, so it has to work
# on a machine it has never seen. Assert it RUNS and that its JSON parses --
# a health check that dies is worse than none, because it dies exactly when
# something is already wrong.
# A doctor FAILURE on a machine this test has just proven healthy is a bug in
# doctor, not news about the machine. That distinction was worth making: the
# first version reported "rollback: kernel cmdline pins a subvolume" as a hard
# failure on a disk whose rollback had been rehearsed successfully, and "no pre
# snapshots" while an assertion twenty lines earlier counted seven.
#
# So: crashing is a failure, and so is reporting a failure here.
if usr "ergon-doctor --json" > /tmp/doctor.json 2>/tmp/doctor.err; then
  ok "ergon-doctor reports no failures on a machine this run proved healthy"
elif [ -s /tmp/doctor.json ]; then
  bad "ergon-doctor reports failures on a healthy machine — a false signal"
  python3 -c 'import json;[print("      ",c["name"],c["note"]) for c in json.load(open("/tmp/doctor.json"))["checks"] if c["state"]=="fail"]' 2>/dev/null
else
  bad "ergon-doctor crashed"
  sed 's/^/     /' /tmp/doctor.err
fi
if python3 -c 'import json,sys; d=json.load(open("/tmp/doctor.json")); sys.exit(0 if d["checks"] else 1)' 2>/dev/null; then
  ok "ergon-doctor --json parses ($(python3 -c 'import json;print(len(json.load(open("/tmp/doctor.json"))["checks"]))') checks)"
else
  bad "ergon-doctor --json is not valid JSON"
  head -3 /tmp/doctor.json | sed 's/^/     /'
fi
printf '   --   doctor says:\n'
usr ergon-doctor 2>&1 | sed 's/^/        /'

# Figure provenance has to be AUTOMATIC or it is worthless -- a helper you must
# remember to call is one you will not. So assert the whole chain: a plain
# script that knows nothing about ergon saves a figure, and the provenance is
# in it. Anything less tests the helper rather than the promise.
cat > /tmp/prov_plot.py <<'PLOT'
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
plt.plot([0, 1], [0, 1])
plt.savefig("/tmp/prov.png")
PLOT
chown "$U" /tmp/prov_plot.py
if usr "\$HOME/.local/share/pyfleet/bin/python /tmp/prov_plot.py" >/tmp/prov.err 2>&1; then
  if usr "ergon-fig whence /tmp/prov.png" > /tmp/prov.out 2>&1; then
    ok "figures carry provenance with no code change ($(grep -c . /tmp/prov.out) fields)"
  else
    bad "the figure saved but carries no provenance"
    sed 's/^/     /' /tmp/prov.out
  fi
else
  bad "a plain matplotlib script failed — the savefig patch broke saving"
  tail -6 /tmp/prov.err | sed 's/^/     /'
fi

# --- do the clicks actually do anything? ------------------------------------
# The whole point, and the thing nothing here ever asked. "waybar mapped a layer
# surface" stayed true throughout a week in which the bar was unusable: every
# module rendered, every module highlighted on hover, and every click went
# nowhere. No test in this repo had ever executed a single on-click command, so
# nothing noticed.
#
# Two levels, because they fail in different places:
#   1. does every on-click RESOLVE to something that exists on the session PATH
#   2. does a synthetic click on a real pixel produce a real effect
# (1) is cheap and covers every module at once. (2) is the only thing that can
# prove the pointer path works end to end.

echo "--- click targets ---"

resolves() { PATH="$SESSION_PATH" bash -c 'command -v "$1" >/dev/null' _ "$1"; }

# jq cannot read config.jsonc (it has comments) and stripping them would be its
# own source of bugs, so pull the values out textually. The file is ours and the
# shape is fixed.
# An empty extraction must FAIL, not pass. "no missing commands" and "no
# commands found" are the same empty string, and the second one is a broken
# test reporting success -- the exact shape of every bug this file has had.
CLICKS=$(grep -oE '"on-click[a-z-]*"[[:space:]]*:[[:space:]]*"[^"]+"' \
  "$H/.config/waybar/config.jsonc" 2>/dev/null | sed 's/.*:[[:space:]]*"//; s/"$//')
N_CLICKS=$(printf '%s\n' "$CLICKS" | grep -c . || true)
[ "${N_CLICKS:-0}" -ge 5 ] || bad "only $N_CLICKS on-click handlers found in waybar config — extraction is broken"

MISSING=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  first=${line%% *}
  # `activate` and `mode` are waybar-internal, not commands.
  case "$first" in activate|mode|"") continue ;; esac
  resolves "$first" || MISSING="$MISSING $first"
done <<EOF
$CLICKS
EOF
if [ -n "$MISSING" ]; then
  bad "waybar on-click commands missing from the session PATH:$MISSING"
else
  ok "every waybar on-click resolves on the session PATH"
fi

# The same question for the config's own commands. `hyprctl binds` cannot
# answer it under a Lua config: every bind reports dispatcher "__lua" with an
# integer arg, because the action is a Lua closure rather than a dispatch
# string. The introspection that existed for hyprland.conf is simply gone, so
# check the source instead.
#
# Two things, both narrow enough to have no false positives:
#   - every ergon-* referenced anywhere in the desktop config must exist and
#     resolve. This is the exact failure that made the bar inert.
#   - every daemon autostart.lua execs must resolve, or the session comes up
#     missing a piece with nothing but a line in the compositor log.
# Only tokens that are actually commands. `ergon-float` is a WINDOW CLASS -- it
# appears in binds.lua as `wezterm start --class ergon-float` and in windows.lua as
# the rule that floats it -- so a scan for the ergon- prefix alone reports it as a
# missing binary on every run. The repo knows which ergon-* are commands: they are
# the files in bin/.
MISSING=""
ERGREFS=$(grep -rhoE '\bergon-[a-z-]+' "$H/.config/hypr" "$H/.config/waybar" \
         "$H/.config/fuzzel" 2>/dev/null | sort -u \
         | while read -r t; do [ -f "$H/ergonOS/bin/$t" ] && echo "$t"; done)
N_ERG=$(printf '%s\n' "$ERGREFS" | grep -c . || true)
[ "${N_ERG:-0}" -ge 3 ] || bad "only $N_ERG ergon-* references found in the desktop config — extraction is broken"
for j in $ERGREFS; do resolves "$j" || MISSING="$MISSING $j"; done
if [ -n "$MISSING" ]; then
  bad "ergon-* referenced by the desktop config but not on the session PATH:$MISSING"
else
  ok "every ergon-* the desktop config names resolves ($N_ERG of them)"
fi

MISSING=""
EXECS=$(grep -hoE 'hl\.exec_cmd\("[^"]+"' "$H/.config/hypr/common/autostart.lua" 2>/dev/null \
        | sed 's/.*("//; s/"$//' | awk '{print $1}' | sort -u)
N_EXECS=$(printf '%s\n' "$EXECS" | grep -c . || true)
[ "${N_EXECS:-0}" -ge 5 ] || bad "only $N_EXECS autostart commands found — extraction is broken"
for e in $EXECS; do resolves "$e" || MISSING="$MISSING $e"; done
if [ -n "$MISSING" ]; then
  bad "autostart commands missing from the session PATH:$MISSING"
else
  ok "every autostart daemon resolves ($N_EXECS of them)"
fi

# --- a synthetic click on a real pixel --------------------------------------
# ydotool injects through uinput, so the compositor sees a genuine input device
# and takes the genuine path: libinput -> cursor -> surface -> GTK. A Wayland
# client cannot fake that for another client, which is why this needs a kernel
# device rather than a protocol call.
echo "--- synthetic clicks ---"
modprobe uinput >/dev/null 2>&1 || true
YSOCK=/tmp/.ydotool_socket
if [ ! -e /dev/uinput ]; then
  bad "no /dev/uinput — cannot test clicks"
elif ! command -v ydotoold >/dev/null; then
  bad "ydotoold not installed — cannot test clicks"
else
  setsid ydotoold --socket-path="$YSOCK" \
    --socket-own="$(id -u "$U"):$(id -g "$U")" >/tmp/ydotoold.log 2>&1 &
  for _ in $(seq 1 20); do [ -S "$YSOCK" ] && break; sleep 0.5; done

  if [ ! -S "$YSOCK" ]; then
    bad "ydotoold never created its socket"
    sed 's/^/     /' /tmp/ydotoold.log
  else
    # Hyprland must actually adopt the new device, or every click lands nowhere
    # and the failure looks exactly like the bug being tested for.
    seen=0
    for _ in $(seq 1 20); do
      hq devices 2>/dev/null | grep -qi ydotool && { seen=1; break; }
      sleep 0.5
    done
    [ "$seen" = 1 ] && ok "Hyprland adopted the synthetic pointer" \
                    || bad "Hyprland never saw the ydotool device"

    # Prove the cursor can be placed AT ALL before drawing conclusions from
    # clicks that land wherever it happened to be. The first version of this
    # test reported "clicking did nothing across the whole left edge" while the
    # cursor sat at 640,400 the entire time -- it had never moved, so nothing
    # had been clicked and the finding was about the harness.
    hq "dispatch 'hl.dsp.cursor.move({x = 100, y = 15})'" >/tmp/movecursor.out 2>&1
    sleep 0.5
    CPOS=$(hq cursorpos 2>/dev/null | tr -d ' ')
    if [ "$CPOS" = "100,15" ]; then
      ok "the cursor can be placed (movecursor works)"
    else
      bad "movecursor did not move the cursor: asked for 100,15, got '$CPOS'"
      echo "     hyprctl said: $(cat /tmp/movecursor.out)"
    fi

    click_at() {
      hq "dispatch 'hl.dsp.cursor.move({x = $1, y = $2})'" >/dev/null 2>&1
      sleep 0.4
      usr "YDOTOOL_SOCKET=$YSOCK ydotool click 0xC0" >/tmp/ydotool.out 2>&1
      sleep 1
    }

    # Workspace buttons. Their width depends on the font, so probe across the
    # left edge of the bar rather than hard-coding a pixel that is right on one
    # machine only. Starting workspace is 1; ANY button but the first must
    # change it.
    hq "dispatch 'hl.dsp.focus({workspace = 1})'" >/dev/null 2>&1; sleep 1
    HIT=""
    for x in 6 18 30 42 54 66 78 90 102 114 126 138 150; do
      click_at "$x" 15
      ws=$(hq activeworkspace -j 2>/dev/null | jq -r '.id // empty')
      [ -n "$ws" ] && [ "$ws" != 1 ] && { HIT="x=$x switched to workspace $ws"; break; }
    done
    if [ -n "$HIT" ]; then
      ok "clicking a workspace button switches workspace ($HIT)"
    else
      bad "clicking the workspace buttons did nothing across the whole left edge"
      echo "     cursor ended at: $(hq cursorpos 2>/dev/null)"
      echo "     ydotool said:    $(cat /tmp/ydotool.out 2>/dev/null)"
      echo "     active ws:       $(hq activeworkspace 2>/dev/null | head -1)"
      echo "     --- waybar layer surfaces ---"
      hq layers 2>/dev/null | grep -A3 waybar | sed 's/^/     /'
      echo "     --- input devices hyprland sees ---"
      hq devices 2>/dev/null | sed -n '/Mice:/,$p' | sed 's/^/     /'
    fi

    # The keycode binds, PRESSED, on each layout they were moved for. Above,
    # they are only shown to be registered on code:10-18 and 49. Under Lua a
    # code:N bind is matched by a different branch of Hyprland's keybind
    # manager than a hyprlang one -- the branch hyprctl cannot even report (key
    # "", keycode 0) -- and a bind that registers and never fires is exactly
    # what nothing else here would notice. So the keys go in through uinput, as
    # a keyboard's do, with the compositor set (set_layout, above) to layouts
    # on which they type &, |, º or ² rather than 1 and grave. evdev codes:
    # LEFTMETA 125, KEY_2 3, GRAVE 41; xkb keycode = evdev + 8, so these are
    # code:11 and code:49.
    super_key() { usr "YDOTOOL_SOCKET=$YSOCK ydotool key 125:1 $1:1 $1:0 125:0" >/tmp/ydotool.out 2>&1; sleep 0.6; }
    special() { hq monitors -j 2>/dev/null | jq -r '[.[] | select(.focused)][0].specialWorkspace.name // ""'; }
    if ! hq devices -j 2>/dev/null | jq -e '.keyboards[] | select(.name | test("ydotool"))' >/dev/null; then
      bad "Hyprland has no ydotool keyboard, so the keycode binds cannot be pressed"
    else
      for L in us latam es fr; do
        if ! set_layout "$L"; then bad "could not switch the compositor to $L"; continue; fi
        hq "dispatch 'hl.dsp.focus({workspace = 1})'" >/dev/null 2>&1; sleep 0.5
        ws0=$(hq activeworkspace -j 2>/dev/null | jq -r '.id // empty')
        super_key 3;  ws=$(hq activeworkspace -j 2>/dev/null | jq -r '.id // empty')
        super_key 41; sp_open=$(special)
        super_key 41; sp_shut=$(special)
        if [ "$ws0" = 1 ] && [ "$ws" = 2 ] && [ "$sp_open" = special:scratch ] && [ -z "$sp_shut" ]; then
          ok "on $L, SUPER + the 2 key goes to workspace 2 and SUPER + the key left of 1 toggles the scratchpad"
        else
          bad "on $L: from workspace '$ws0', SUPER + the 2 key gave '$ws' (want 2); the key left of 1 opened '$sp_open' (want special:scratch), then left '$sp_shut' open (want nothing)"
          echo "     ydotool said: $(cat /tmp/ydotool.out 2>/dev/null)"
          [ "$sp_shut" != special:scratch ] || hq "dispatch 'hl.dsp.workspace.toggle_special(\"scratch\")'" >/dev/null 2>&1
        fi
      done
      set_layout "${KB0:-us}" "${KV0:-}" || bad "could not restore the layout to '${KB0:-us}'"
    fi

    # A module whose on-click is a shell command. ergon-launch-tui is the one every
    # broken module went through, and a window appearing is proof the whole
    # chain ran: PATH, terminal fallback, window rules.
    before=$(hq clients -j 2>/dev/null | jq 'length')
    usr "ergon-launch-tui btop" >/tmp/launchtui.log 2>&1 &
    for _ in $(seq 1 20); do
      hq clients -j 2>/dev/null | grep -q 'ergon-tui-btop' && break
      sleep 1
    done
    if hq clients -j 2>/dev/null | grep -q 'ergon-tui-btop'; then
      ok "ergon-launch-tui opens a window (the bar's click handlers work)"
    else
      bad "ergon-launch-tui opened nothing — clients went $before -> $(hq clients -j 2>/dev/null | jq 'length')"
      tail -8 /tmp/launchtui.log | sed 's/^/     /'
    fi
  fi
fi

# Only dump the log when something actually failed. An unconditional dump makes
# a passing run look like a failing one and buries the next real failure.
# --- a look at the actual desktop --------------------------------------
# Everything above is an assertion. This is the part you can LOOK at: open a
# couple of windows, let them settle, and have the compositor screenshot itself.
# /out is a writable 9p share, so the PNG lands outside the VM.
if [ -d /out ] || mkdir -p /out 2>/dev/null; then
  mount -t 9p -o trans=virtio,version=9p2000.L out /out 2>/dev/null || true
fi

if mountpoint -q /out 2>/dev/null; then
  usr foot >/dev/null 2>&1 &
  sleep 4
  usr fuzzel >/dev/null 2>&1 &
  sleep 3
  # -o <output>, not the whole logical space. qemu's virtio-gpu presents more
  # than one output and a bare `grim` captures every one of them, then blocks
  # forever on the one that never presents a frame under software rendering. It
  # hung the entire test for six minutes before this had a timeout, which read
  # as the compositor having died.
  MON=$(hq monitors -j 2>/dev/null | jq -r '.[0].name // empty')
  if timeout 60 su - "$U" -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$SIG WAYLAND_DISPLAY=$WLD grim -o '$MON' /out/desktop.png" >/tmp/grim.log 2>&1; then
    chmod 666 /out/desktop.png 2>/dev/null || true
    ok "screenshot written to the out share"
  else
    # grim needs a working dmabuf path, and aquamarine cannot get one in the
    # VM -- the compositor log fills with
    #     [EGL] eglCreateImageKHR ... EGL_BAD_ALLOC: createImageFromDmaBufs failed
    # and wlr-screencopy then blocks until the timeout kills it. That is the
    # emulated GPU, not the desktop: on hardware with a real driver this works.
    #
    # So it is only a SKIP when the log actually shows that, and a real failure
    # otherwise -- a screenshot regression on a machine that can render must
    # still fail rather than hide behind a VM excuse.
    if grep -q "createImageFromDmaBufs failed" /run/user/1000/hypr/*/hyprland.log 2>/dev/null; then
      note "grim cannot capture: no dmabuf path in the VM (see docs/testing-the-desktop.md)"
    else
      bad "grim could not capture the desktop"
      sed 's/^/     /' /tmp/grim.log 2>/dev/null
    fi
  fi
else
  bad "the writable out share did not mount"
fi

# Leave greetd RUNNING. The test disables it to get the display to itself, but
# a VM you cannot log into is useless for looking at, and the greeter is the
# real entry point -- the same one the Framework will boot to.
systemctl enable greetd >/dev/null 2>&1 || true
ok "greetd left enabled for interactive use"

# --- things that made the desktop useless and nothing asserted ------------
# A RUNNING daemon is not the claim worth making: the bar's profile button did
# nothing for a whole session while power-profiles-daemon was active the entire
# time, because waybar's module did not cycle on click in this build. So assert
# the switch itself.
if systemctl is-active --quiet power-profiles-daemon; then
  ok "power-profiles-daemon is running"
  # Assert the POLICY, not the switch.
  #
  # Switching needs an active seat session: power-profiles-daemon's polkit
  # action is allow_active, so `su - user` -- which has no logind session -- is
  # correctly refused with
  #   AccessDenied: Not Authorized: ...PowerProfiles.switch-profile
  # This harness drives the compositor through seatd without logind, so it has
  # no active session either. A test that performs the switch here would fail on
  # a machine where the button works perfectly, which is worse than no test.
  #
  # What CAN be checked without a seat: that the profile list has something to
  # cycle to, and that the polkit action permits an active session to do it.
  _n=$(su - "$U" -c 'powerprofilesctl list' 2>/dev/null | grep -cE '^[* ]*[a-z-]+:')
  [ "${_n:-0}" -ge 2 ] && ok "$_n power profiles to cycle between" \
                       || bad "only ${_n:-0} power profile — the button has nothing to switch to"
  if pkaction --action-id org.freedesktop.UPower.PowerProfiles.switch-profile --verbose 2>/dev/null \
     | grep -A1 'implicit active' | grep -qi 'yes\|auth_admin_keep\|auth_self_keep'; then
    ok "polkit lets an active session switch profile"
  else
    note "could not read the polkit policy for switch-profile (pkaction missing?)"
  fi
else
  bad "power-profiles-daemon is not running — clicking the profile icon does nothing"
fi
# Assert the thing that survives a REBOOT, not the rmmod we just did. The first
# version of this checked /dev/fd0 in the same boot that removed the module by
# hand: it passed, and the prompt was still there on the next boot, because the
# module comes back from the initramfs. The cmdline is the durable fact.
grep -q 'modprobe.blacklist=floppy' /proc/cmdline 2>/dev/null \
  && ok "floppy blacklisted on the running cmdline" \
  || { grep -q 'modprobe.blacklist=floppy' /boot/grub/grub.cfg 2>/dev/null \
       && ok "floppy blacklisted in grub.cfg (takes effect next boot)" \
       || bad "nothing blacklists floppy on the cmdline — the prompt returns every boot"; }
[ -e /dev/fd0 ] \
  && note "/dev/fd0 still present in this boot (it predates the blacklist)" \
  || ok "no floppy device"

# --- the shell -------------------------------------------------------------
# zsh is the login shell and the OS now ships its configuration, so a broken
# one is not cosmetic: it is every terminal, every ssh command and the greeter's
# own environment. A config that errors on startup still "works" interactively,
# which is why this asserts a CLEAN start rather than a start.
[ "$(getent passwd "$U" | cut -d: -f7)" = /bin/zsh ] \
  && ok "zsh is the login shell" || bad "login shell is not zsh"
# stdin a pipe ON PURPOSE: that is what made zplug warn once per plugin, and
# this suite only reproduced it by accident, through the `echo pw | sudo -S`
# that launches it.
zerr=$(echo | su - "$U" -c 'zsh -i -c "exit" 2>&1' 2>&1 | grep -vE '^\s*$' | head -3)
[ -z "$zerr" ] && ok "an interactive zsh starts with no output" \
               || bad "zsh prints on startup: $zerr"
su - "$U" -c 'zsh -c "command -v ergon-wallpaper"' >/dev/null 2>&1 \
  && ok "zsh resolves the ergon commands" || bad "ergon-* not on zsh's PATH"

# --- the bar's commands actually resolve ----------------------------------
# waybar and autostart exec ergon-* BY NAME. If PATH does not carry them the bar
# still draws and every click silently does nothing -- reported three times from
# a real session before it was believed, and invisible to a test that only asks
# whether a window opened in ITS OWN session, which has a correct PATH.
#
# So assert the thing a login actually depends on: that the commands resolve for
# a plain login shell, the way the greeter's session will find them.
for c in ergon-launch-tui ergon-wallpaper ergon-brightness; do
  if su - "$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)" -c "command -v $c" >/dev/null 2>&1; then
    ok "$c resolves on the login PATH"
  else
    bad "$c is not on the login PATH — the bar will draw and do nothing"
  fi
done

# --- the wallpaper --------------------------------------------------------
# hyprpaper.conf points at a GENERATED png, and for the life of this project
# nothing generated it: hyprpaper logged, exited, and the desktop fell back to
# the compositor's background_color. The fallback is deliberate and it looks
# fine, so every machine quietly had a flat colour instead of the wallpaper it
# ships, and no assertion here noticed.
W="$(getent passwd "$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)" | cut -d: -f6)/.local/share/ergon/wallpaper.png"
[ -s "$W" ] && ok "wallpaper generated ($(du -h "$W" | cut -f1))" \
            || bad "no wallpaper at $W — hyprpaper will exit and the desktop falls back to a flat colour"
# The file existing is not the point; hyprpaper actually putting a surface on
# the background layer is. A file that hyprpaper cannot read looks identical
# from the outside to one that is not there.
# Polled. hyprpaper is started by ergon-wallpaper during autostart and has to
# render before it maps anything, so a single check here races it -- this
# reported "background layer is empty" while the diagnosis printed immediately
# below showed the layer present and full-screen a second later.
_bg=0
for _ in $(seq 15); do
  if hq layers | awk '/Layer level 0/{b=1;next} /Layer level 1/{b=0} b && /hyprpaper/{f=1} END{exit !f}'; then
    _bg=1; break
  fi
  sleep 1
done
# The evidence the GPU-less VM branch below needs, gathered up front. Tested for
# being non-empty, never by exit status: under pipefail, grep leaving early
# kills dmesg with SIGPIPE and a match reads as a miss.
_hp=$(sed 's/\x1b\[[0-9;]*m//g' /run/user/1000/hyprpaper.log 2>/dev/null)
_k=$({ dmesg; journalctl -k -b --no-pager; } 2>/dev/null | grep -oE 'features: [-+]virgl.*' | head -1)
_egl=$(grep -m1 'failed to create dri2 screen' <<<"$_hp")
_gbm=$(grep -m1 'Failed to allocate a GBM buffer' <<<"$_hp")
if [ "$_bg" = 1 ]; then
  ok "hyprpaper mapped a background layer"
elif grep -q "createImageFromDmaBufs failed" /run/user/1000/hypr/*/hyprland.log 2>/dev/null; then
  # Same VM limitation that stops grim capturing, and for the same reason:
  # QEMU's virtio-gpu has no working dmabuf path, so EGL refuses the import
  # (EGL_BAD_ALLOC) and hyprpaper cannot allocate a buffer for the background.
  # On hardware with a real driver it can.
  #
  # A SKIP only when the log actually shows that failure, and a hard failure
  # otherwise -- a wallpaper regression on a machine that can render must still
  # fail rather than hide behind a VM excuse. Same rule as the grim check above.
  note "wallpaper cannot be composited: no dmabuf path in the VM (see docs/testing-the-desktop.md)"
elif ! pgrep -x hyprpaper >/dev/null && [[ $_k == *-virgl* ]] && [ -n "$_egl" ] && [ -n "$_gbm" ]; then
  # The GPU-less VM (checo's runner has no render node, so the guest gets a
  # virtio-gpu with 3D off). hyprpaper draws with GL through hyprtoolkit; there
  # is no hardware driver for EGL to load, Mesa falls back to kms_swrast, and
  # kms_swrast needs dumb buffers, which the device hyprpaper opened refuses
  # (DRM_IOCTL_MODE_CREATE_DUMB: Permission denied, as a render node does). It
  # cannot allocate a single buffer and exits. The compositor draws on the same
  # device because it holds the primary node.
  #
  # A SKIP only when all three are in evidence: the kernel says this virtio-gpu
  # has no virgl, and hyprpaper's own log shows EGL failing and the allocation
  # failing. On hardware there is no virtio-gpu line; on the render-node VM it
  # reads +virgl. Either way a hyprpaper that exits is a failure there.
  note "hyprpaper cannot draw: the VM's GPU has no 3D and hyprpaper needs GL"
  note "  kernel:    $_k"
  note "  hyprpaper: $_egl"
  note "  hyprpaper: $_gbm"
else
  bad "background layer is empty — the wallpaper is not actually on screen"
  # What hyprpaper said is in the log ergon-wallpaper keeps for it; what it
  # accepts over IPC is asked below. Both are printed in the run that fails,
  # because this failure was diagnosed by guesswork for as long as neither was.
  echo "     --- hyprpaper diagnosis ---"
  pgrep -x hyprpaper >/dev/null && echo "     running: yes (pid $(pgrep -x hyprpaper | head -1))" \
                                || echo "     running: NO — it exited"
  echo "     kernel: ${_k:-no virtio-gpu feature line}"
  if [ -f /run/user/1000/hyprpaper.log ]; then
    tail -20 /run/user/1000/hyprpaper.log | sed 's/^/     hyprpaper: /'
  else
    echo "     no /run/user/1000/hyprpaper.log — ergon-wallpaper never started it"
  fi
  grep -iE 'hyprpaper|wallpaper' /run/user/1000/hypr/*/hyprland.log 2>/dev/null \
    | grep -viE 'exec_cmd' | tail -8 | sed 's/^/     log: /'
  for req in "listloaded" "listactive"; do
    printf '     %s -> %s\n' "$req" "$(hq hyprpaper $req 2>&1 | head -2 | tr '\n' ' ')"
  done
  # The two candidate spellings, with the error text kept rather than discarded.
  printf '     preload  -> %s\n' "$(hq hyprpaper preload "$W" 2>&1 | head -1)"
  printf '     wallpaper-> %s\n' "$(hq hyprpaper wallpaper ",$W" 2>&1 | head -1)"
  printf '     reload   -> %s\n' "$(hq hyprpaper reload ",$W" 2>&1 | head -1)"
  sleep 1
  hq layers | awk '/Layer level 0/{b=1;next} /Layer level 1/{b=0} b' | sed 's/^/     after: /'
  echo "     --- end ---"
fi

# --- what the OS hands its agents -----------------------------------------
# Every one of these is installed by a step that WARNS rather than fails, so
# provisioning stays green whatever happens here and nothing else in this suite
# would notice. That is exactly why they need asserting: this ran green once
# with the whole block silently doing nothing, and the count was identical.
U=$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)
H=$(getent passwd "$U" | cut -d: -f6)

# ergon-explain prefers /usr/share over the checkout, and both skills tell an
# agent the body lives there.
n=$(ls -1 /usr/share/ergon/knowledge/*.md 2>/dev/null | wc -l)
[ "$n" -ge 1 ] && ok "knowledge installed system-wide ($n topics)" \
               || bad "no topics at /usr/share/ergon/knowledge — ergon explain falls back to a checkout"
[ -f /usr/share/ergon/AGENTS.md ] && ok "machine AGENTS.md installed" \
                                  || bad "no /usr/share/ergon/AGENTS.md"

# Claude Code has no machine-wide AGENTS.md; the managed policy file is its one
# OS-level hook, and it must point AT ours rather than be a copy that drifts.
if [ "$(readlink -f /etc/claude-code/CLAUDE.md 2>/dev/null)" = /usr/share/ergon/AGENTS.md ]; then
  ok "claude code: managed policy -> the machine AGENTS.md"
else
  bad "/etc/claude-code/CLAUDE.md does not resolve to /usr/share/ergon/AGENTS.md"
fi

# One SKILL.md, both harnesses. A skill that reaches only one of them is the
# failure this is here to catch.
for d in "$H/.claude/skills" "$H/.codex/skills"; do
  s=$(ls -1d "$d"/ergon-* 2>/dev/null | wc -l)
  [ "$s" -ge 1 ] && ok "skills linked into ${d#"$H"/} ($s)" \
                 || bad "no ergon skills in $d"
done
[ -e "$H/.codex/AGENTS.md" ] && ok "codex: global AGENTS.md linked" \
                             || bad "no $H/.codex/AGENTS.md"
# Readable through the link, not merely present: a dangling symlink satisfies
# -e on its own target check but gives an agent nothing.
grep -q 'ergon explain' "$H/.codex/AGENTS.md" 2>/dev/null \
  && ok "codex AGENTS.md reads through to the content" \
  || bad "$H/.codex/AGENTS.md is present but unreadable or empty"

# The off-disk backup: provisioning installed it, and it round-trips.
# shellcheck source=guest-backup.sh
. "$SHARE/test/arch-vm/guest-backup.sh"

[ "$F" -gt 0 ] && dump_log
finish
