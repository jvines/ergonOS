#!/usr/bin/env bash
# Runs INSIDE the system after it comes back. Did it RESUME, or just boot?
set -uo pipefail
P=0; F=0
ok()  { printf '   ok   %s\n' "$*"; P=$((P+1)); }
bad() { printf '   FAIL %s\n' "$*"; F=$((F+1)); }

BEFORE="${EXPECT_BOOT_ID:?harness must pass EXPECT_BOOT_ID}"
NOW=$(cat /proc/sys/kernel/random/boot_id)

echo "--- after resume ---"
echo "   boot_id before: $BEFORE"
echo "   boot_id now:    $NOW"

if [ "$NOW" = "$BEFORE" ]; then
  ok "boot_id unchanged — this is a RESUME, not a reboot"
else
  bad "boot_id changed — the machine cold-booted; resume did not happen"
fi

[ -f /tmp/hibernate-canary ] \
  && ok "tmpfs canary survived — the RAM image was restored" \
  || bad "tmpfs canary is gone — /tmp was recreated, so this was a fresh boot"

swapon --show=NAME --noheadings | grep -q swapfile \
  && ok "swap is active again after resume" || bad "swap did not come back"

findmnt -no SOURCE / | grep -q cryptroot \
  && ok "root still on the LUKS mapper" || bad "root is not on the mapper"

echo "--- $P passed, $F failed ---"
echo "HIBERNATE_RESULT=$F"
