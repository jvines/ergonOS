#!/usr/bin/env bash
# Runs INSIDE the booted system. Records a known-good snapshot, then breaks the
# boot in a way that survives a reboot and cannot be blamed on anything else.
#
# The break is a unit that always fails and that default.target requires, so the
# machine boots, runs early userspace, and never reaches the target it boots to.
# That is the case the guard is for: not a kernel panic, but a system that comes
# up wrong. The snapshot is taken BEFORE the break exists, so the break is gone
# in the snapshot -- which is what makes the fallback provably different.
set -uo pipefail
U=$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)
E="$(getent passwd "$U" | cut -d: -f6)/ergonOS"   # in @home, so it survives a rollback of @

echo "--- arming the boot guard test ---"
# Refresh the guest's copy of the repo from the share, so this tests the code
# in the worktree rather than whatever the last provisioning run left behind.
rm -rf "$E"
cp -r /mnt "$E"
chown -R "$U:$U" "$E"
"$E/bin/ergon-boot-guard" install || { echo "GUARD_INSTALL=failed"; exit 1; }

# Clear a break left by an aborted run FIRST. Taken while one is still here, the
# known-good snapshot contains it, and the fallback boots into the same failure.
systemctl disable --now ergon-break-boot.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/ergon-break-boot.service
systemctl daemon-reload

snap=$(snapper -c root create --print-number -d "boot-guard test: known good")
echo "KNOWN_GOOD_CANDIDATE=$snap"

# Arm the recorded state directly rather than through `ergon-boot-guard ok`.
# That command only marks a boot good when the default target actually came up,
# and THIS boot may have inherited a break from an aborted run -- in which case
# it rightly refuses, and the test could never set itself up. `ok` is exercised
# for real on the last boot instead, where the system is healthy.
ESP=$(findmnt -no TARGET -t vfat | head -1)
grub-editenv "$ESP/EFI/ergon/grubenv" set ergon_good_snapshot="$snap"
grub-editenv "$ESP/EFI/ergon/grubenv" set ergon_tries=2
recorded=$(grub-editenv "$ESP/EFI/ergon/grubenv" list | sed -n 's/^ergon_good_snapshot=//p')
tries=$(grub-editenv "$ESP/EFI/ergon/grubenv" list | sed -n 's/^ergon_tries=//p')
echo "RECORDED_GOOD=$recorded TRIES=$tries"
[ "$recorded" = "$snap" ] || { echo "GUARD_RECORD=wrong"; exit 1; }

# The snapshot must not already contain the break, or the test proves nothing.
if [ -e "/.snapshots/$snap/snapshot/etc/systemd/system/ergon-break-boot.service" ]; then
  echo "SNAPSHOT_ALREADY_BROKEN=yes"; exit 1
fi

TARGET=$(systemctl get-default)
cat > /etc/systemd/system/ergon-break-boot.service <<UNIT
[Unit]
Description=Deliberately fail the boot (ergon boot-guard test)
Before=$TARGET
[Service]
Type=oneshot
ExecStart=/bin/false
UNIT
systemctl daemon-reload
# add-requires wires it to the REAL target. default.target is an alias, and a
# RequiredBy=default.target symlink is not picked up from it -- the boot then
# succeeds and the test proves nothing, which is exactly what happened once.
systemctl add-requires "$TARGET" ergon-break-boot.service >/dev/null 2>&1
echo "BREAK_TARGET=$TARGET"
if systemctl show -p Requires "$TARGET" | grep -q ergon-break-boot.service; then
  echo "BREAK_WIRED=yes"
else
  echo "BREAK_WIRED=no"
  exit 1
fi
sync
echo "ARM_DONE"
