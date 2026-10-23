#!/usr/bin/env bash
# Runs INSIDE the system after the screenshot boot (guest-autologin-arm.sh),
# as root. The passphrase was typed once, at Plymouth's graphical prompt;
# nothing else was typed on the display. What must be true now (ERGON-123):
# greetd logged the user straight into Hyprland through uwsm, and no app can
# raise a keyring dialog.
set -uo pipefail
P=0; F=0
ok()  { printf '   ok   %s\n' "$*"; P=$((P+1)); }
bad() { printf '   FAIL %s\n' "$*"; F=$((F+1)); }
U=$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)
UID_=$(id -u "$U"); H=$(getent passwd "$U" | cut -d: -f6)
asu() { runuser -u "$U" -- env XDG_RUNTIME_DIR="/run/user/$UID_" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_/bus" "$@"; }

echo "--- automatic login after the unlock ---"
grep -q "plymouth.ignore-serial-consoles" /proc/cmdline \
  && ok "this boot drew the unlock prompt on the display" || bad "this is not the screenshot boot: $(cat /proc/cmdline)"
for _ in $(seq 120); do pgrep -u "$U" -x Hyprland >/dev/null && break; sleep 1; done
pgrep -u "$U" -x Hyprland >/dev/null && ok "Hyprland is running as $U with nothing typed at a greeter" \
  || bad "no Hyprland for $U after 120 s"
sid=$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$U" '$3 == u { print $1 }' | while read -r s; do
        [ "$(loginctl show-session "$s" -p Type --value)" = wayland ] && echo "$s"; done | head -1)
if [ -n "$sid" ]; then
  svc=$(loginctl show-session "$sid" -p Service --value); vt=$(loginctl show-session "$sid" -p VTNr --value)
  [ "$svc" = greetd ] && ok "its session ($sid) was opened by greetd, on vt$vt" || bad "session $sid came from '$svc'"
else
  bad "no wayland session for $U"; loginctl list-sessions --no-legend | sed 's/^/     /'
fi
grep -q 'wayland-wm@hyprland.desktop.service.*running' <<<"$(asu systemctl --user list-units --no-legend 'wayland-wm@*' 2>/dev/null)" \
  && ok "  started through uwsm (wayland-wm@hyprland.desktop.service)" \
  || bad "  not under uwsm: $(asu systemctl --user list-units --no-legend 'wayland-wm*' 2>&1 | head -2)"
pgrep -x tuigreet >/dev/null && bad "tuigreet is running too" || ok "no greeter was shown"
for _ in $(seq 60); do pgrep -u "$U" -x waybar >/dev/null && break; sleep 1; done
pgrep -u "$U" -x waybar >/dev/null && ok "the bar is up" || bad "no waybar after 60 s"

# The desktop settles, then the harness takes its screenshot from qemu.
sleep 10
echo "SHOT_NOW"
sleep 15

echo "--- the keyring asks for nothing ---"
[ "$(cat "$H/.local/share/keyrings/default" 2>/dev/null)" = Default_keyring ] \
  && ok "the default keyring is Default_keyring" || bad "default keyring is '$(cat "$H/.local/share/keyrings/default" 2>/dev/null)'"
[ ! -e "$H/.local/share/keyrings/login.keyring" ] && ok "no password-protected login keyring was created" \
  || bad "a login keyring exists: the greeter path created one"
grep -q pam_gnome_keyring /etc/pam.d/greetd && bad "/etc/pam.d/greetd still has pam_gnome_keyring" \
  || ok "/etc/pam.d/greetd has no pam_gnome_keyring"
if printf 'e123-secret' | asu timeout 20 secret-tool store --label='ERGON-123 check' ergon e123 2>/tmp/st.err; then
  [ "$(asu timeout 10 secret-tool lookup ergon e123 2>/dev/null)" = e123-secret ] \
    && ok "a secret stored and read back through the Secret Service, no prompt" || bad "the secret did not read back"
  asu timeout 10 secret-tool clear ergon e123 2>/dev/null || true
else
  bad "secret-tool store failed or waited: $(head -c 200 /tmp/st.err)"
fi
dk=$(asu busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service ReadAlias s default 2>/dev/null | sed -n 's/^o "\(.*\)"$/\1/p')
[ "$(asu busctl --user get-property org.freedesktop.secrets "$dk" org.freedesktop.Secret.Collection Locked 2>/dev/null)" = "b false" ] \
  && ok "the default collection ($dk) is unlocked" || bad "the default collection '$dk' is locked or missing"
pgrep -x gcr-prompter >/dev/null && bad "a keyring prompt (gcr-prompter) is open" || ok "no keyring prompt is open"
asu "$H/ergonOS/bin/ergon-doctor" 2>/dev/null | grep -E 'keyring|autologin|bootloader|boot-splash|snapshot-menu' | sed 's/^/     /'

echo "--- $P passed, $F failed ---"
echo "AUTOLOGIN_RESULT=$F"
