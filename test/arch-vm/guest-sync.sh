#!/usr/bin/env bash
# Runs INSIDE the VM over the serial console, at every hypr-vm boot.
#
# Brings the guest's copy of the repo up to date with the host's and re-runs
# install.sh. Without it, `./bin/hypr-vm` shows the repo as it was when the disk
# was last built, and the loop for "change a colour, look at it" is a
# twelve-minute reinstall of the whole machine.
#
# It deliberately does NOT re-run provision-arch.sh. Provisioning installs
# packages and writes /etc; that is a system change and belongs to the test that
# asserts it. This is only the user-level layer, which is the part that changes
# every few minutes.
set -uo pipefail

U=$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)
H=$(getent passwd "$U" | cut -d: -f6)
HOST=$(hostname -s)

mkdir -p /mnt
mountpoint -q /mnt || \
  mount -t 9p -o trans=virtio,version=9p2000.L,ro ergon /mnt 2>/dev/null || {
    echo "SYNC_FAIL: no dotfiles share"; exit 1; }

# hosts/<host>/ is SCAFFOLDED by provisioning, not committed -- it holds this
# machine's hyprland.lua and host.env. A straight copy from the share would
# delete it, and install.sh would then link a monitor config that does not
# exist. Keep it across the copy.
KEEP=$(mktemp -d)
[ -d "$H/ergonOS/hosts/$HOST" ] && cp -r "$H/ergonOS/hosts/$HOST" "$KEEP/"

rm -rf "${H:?}/ergonOS"
cp -r /mnt "$H/ergonOS"
[ -d "$KEEP/$HOST" ] && cp -r "$KEEP/$HOST" "$H/ergonOS/hosts/"
rm -rf "$KEEP"

install -d "$H/ergonOS/hosts/$HOST"
printf 'GRAPHICAL=1\nPROFILE=laptop\n' > "$H/ergonOS/hosts/$HOST/host.env"
chown -R "$U:$U" "$H/ergonOS"

if su - "$U" -c "cd ~/ergonOS && ERGON=\$HOME/ergonOS ./install.sh" >/tmp/sync-install.log 2>&1; then
  echo "SYNC_OK: repo synced and install.sh re-run"
else
  echo "SYNC_FAIL: install.sh"
  tail -15 /tmp/sync-install.log
fi
