#!/usr/bin/env bash
# Runs INSIDE the VM as root. Points greetd at a session command that works.
#
# A FILE, not a heredoc typed over the serial console. Two attempts at the
# latter failed silently because `sudo -S` takes its password on stdin and a
# heredoc also claims stdin -- sudo reads the first heredoc line as the
# password, the write never happens, and nothing reports an error.
set -euo pipefail

install -Dm644 /dev/stdin /etc/greetd/config.toml <<'TOML'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --asterisks --cmd 'uwsm start -e -D Hyprland hyprland.desktop'"
user = "greeter"
TOML

# --remember-user-session caches the last session command per user and would
# keep using the old broken one whatever the config says.
rm -rf /var/cache/tuigreet

# Arch ships deny=3, unlock_time=600: three typos locks you out for ten minutes.
install -Dm644 /dev/stdin /etc/security/faillock.conf <<'CONF'
deny = 10
unlock_time = 120
fail_interval = 900
CONF
faillock --user jayvains --reset || true

systemctl restart greetd
sleep 3
echo "config: $(grep -o "uwsm start[^\"']*" /etc/greetd/config.toml)"
echo "greetd: $(systemctl is-active greetd)"
echo GUEST_FIX_DONE
