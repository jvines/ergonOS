#!/usr/bin/env bash
# Runs INSIDE the system after the rollback reboot.
set -uo pipefail
MARKER=/rollback-canary
P=0; F=0
ok()  { printf '   ok   %s\n' "$*"; P=$((P+1)); }
bad() { printf '   FAIL %s\n' "$*"; F=$((F+1)); }

echo "--- after rollback reboot ---"

if [ -f "$MARKER" ]; then
  bad "canary survived — the rollback did not take (root is still pinned, or @ was not replaced)"
else
  ok "canary is gone — the rollback actually took effect"
fi

# The system still has to be usable afterwards. A rollback that boots to a
# broken root is not a rollback either.
if findmnt -no SOURCE / | grep -q '/dev/mapper/cryptroot'; then
  ok "root still mounts from the LUKS mapper"
else
  bad "root is not on the LUKS mapper after rollback"
fi

if snapper -c root list >/dev/null 2>&1; then
  ok "snapper still works after rollback"
else
  bad "snapper is broken after rollback"
fi

# The replaced root must still be the one the bootloader points at.
if findmnt -no FSROOT / | grep -qx "/@"; then
  ok "/ is the @ subvolume (not a snapshot)"
else
  bad "/ is $(findmnt -no FSROOT /), expected /@"
fi

if swapon --show=NAME --noheadings | grep -q swapfile; then
  ok "swap is still active after rollback"
else
  bad "swap did not come back after rollback"
fi

echo "--- $P passed, $F failed ---"
echo "ROLLBACK_RESULT=$F"
