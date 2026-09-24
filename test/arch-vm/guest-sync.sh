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

# Staged beside the live tree and then merged into it, rather than `rm -rf`
# followed by `cp -r`. That pair is what this used to be, and it is a hole:
# ~/.config/hypr is a SYMLINK into this directory, so for as long as the
# directory is gone the compositor's entire config is gone with it -- while the
# greeter sits on another tty with no idea this is happening, waiting for
# someone to log in. Log in during those seconds and Hyprland loads a
# hyprland.lua whose requires resolve to nothing, and answers with
#
#   Emergency mode tripped: A lua config error resulted in no binds being
#   registered. Emergency binds active: SUPER + Q
#
# What a login inside that window actually gets, measured against 0.56.2 rather
# than assumed, is one of two things: for most of it the whole tree is gone and
# Hyprland says `cannot open .../hyprland.lua: No such file or directory` with
# no Lua chunk run at all; for the few files' worth of copying in between, the
# entry point exists and a module under it does not, which is the 27-line
# `module 'common.<name>' not found`. Both end in the same place -- no binds.
#
# One rsync, on the other hand, replaces each file by rename, so every path is
# either the old file or the new one at every instant and never absent.
#
# --delete, to drop what is gone upstream, but the RENDERED configs are
# protected from it: they are gitignored, so a share that is a fresh clone or a
# worktree does not have them, and deleting them here would leave exactly the
# hole described above until install.sh re-rendered them. The protect list is
# derived from the templates, so it cannot drift from what ergon-theme writes.
NEW="$H/ergonOS.staged.$$"
rm -rf "$NEW"
cp -r /mnt "$NEW"
[ -d "$KEEP/$HOST" ] && cp -r "$KEEP/$HOST" "$NEW/hosts/"
rm -rf "$KEEP"

chown -R "$U:$U" "$NEW"

PROTECT=()
while IFS= read -r tpl; do
  rel="${tpl#"$NEW"/}"
  PROTECT+=( "--filter=P /${rel%.in}" )
done < <(find "$NEW" -path "$NEW/.git" -prune -o -name '*.in' -print)

if [ -d "$H/ergonOS" ]; then
  rsync -a --delete --exclude '.git' --exclude 'hosts/' "${PROTECT[@]}" \
        "$NEW/" "$H/ergonOS/"
  rm -rf "$NEW"
else
  mv "$NEW" "$H/ergonOS"
fi

# Into the LIVE tree, not the staged one: hosts/ is excluded from the sync
# above, so anything written under it in staging would never arrive. This is
# the guest's own answer about itself and never the share's.
install -d "$H/ergonOS/hosts/$HOST"
printf 'GRAPHICAL=1\nPROFILE=laptop\n' > "$H/ergonOS/hosts/$HOST/host.env"
chown -R "$U:$U" "$H/ergonOS"

if su - "$U" -c "cd ~/ergonOS && ERGON=\$HOME/ergonOS ./install.sh" >/tmp/sync-install.log 2>&1; then
  echo "SYNC_OK: repo synced and install.sh re-run"
else
  echo "SYNC_FAIL: install.sh"
  tail -15 /tmp/sync-install.log
fi
