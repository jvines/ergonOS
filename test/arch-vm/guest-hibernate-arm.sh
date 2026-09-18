#!/usr/bin/env bash
# Runs INSIDE the booted system. Records identity, then hibernates.
#
# boot_id is the decisive signal and the reason this test is meaningful at all:
# the kernel generates it once per BOOT. A resume from hibernation preserves it;
# anything that merely rebooted gets a new one. Without checking it, "the
# machine came back up" proves nothing -- a failed resume looks exactly like a
# successful boot, which is precisely how a broken resume_offset goes unnoticed
# until you lose a day's work to it.
set -uo pipefail
SHARE="${SHARE:-/mnt}"

echo "--- arming hibernate ---"
echo "BOOT_ID_BEFORE=$(cat /proc/sys/kernel/random/boot_id)"

# A tmpfs marker. /tmp does not survive a reboot, so if this file is still here
# afterwards the RAM image really was restored rather than the machine having
# quietly cold-booted.
date -u +%FT%TZ > /tmp/hibernate-canary
echo "CANARY_WRITTEN=yes"

grep -qw disk /sys/power/state && echo "HIBERNATE_AVAILABLE=yes" || echo "HIBERNATE_AVAILABLE=no"
swapon --show=NAME,SIZE --noheadings | sed 's/^/   swap: /'
grep -o 'resume[^ ]*' /proc/cmdline | sed 's/^/   cmdline: /'

# Stage the verifier on the REAL filesystem before hibernating. The 9p share
# does not survive a resume -- the virtio transport comes back as
# "9pnet_virtio: no channels available for device dotfiles" -- so anything the
# post-resume step needs must already be on disk. Discovered the hard way: the
# resume itself worked perfectly and the test still failed, because the script
# that would have proved it lived on a share that was gone.
install -m 755 "${SHARE:-/mnt}/test/arch-vm/guest-hibernate-verify.sh" \
  /usr/local/bin/hibernate-verify
echo "VERIFIER_STAGED=yes"

sync
echo "HIBERNATING_NOW"
# Detached: systemd tears down the console while hibernating, and a foreground
# call would leave the harness waiting on a command that can never return.
setsid systemctl hibernate &
