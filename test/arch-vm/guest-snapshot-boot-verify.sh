#!/usr/bin/env bash
# Runs INSIDE the system booted from a snapshot's boot entry (ERGON-123): the
# rollback rehearsal set it as the one-shot entry. Proves the entry booted the
# snapshot, with the snapshot's own kernel set from the ESP, before the canary
# was written.
set -uo pipefail
P=0; F=0
ok()  { printf '   ok   %s\n' "$*"; P=$((P+1)); }
bad() { printf '   FAIL %s\n' "$*"; F=$((F+1)); }
WANT=${1:?snapshot number}

echo "--- booted from a snapshot entry ---"
echo "   cmdline: $(cat /proc/cmdline)"
[ "$(findmnt -no FSROOT /)" = "/@snapshots/$WANT/snapshot" ] \
  && ok "/ is snapshot $WANT, booted from its menu entry" \
  || bad "/ is $(findmnt -no FSROOT /), expected /@snapshots/$WANT/snapshot"
[ ! -e /rollback-canary ] && ok "the canary written after the snapshot is not here" \
  || bad "the canary is here, so this is not the snapshot"
grep -q "rootflags=subvol=@snapshots/$WANT/snapshot" /proc/cmdline \
  && ok "the entry's cmdline pins the snapshot" || bad "the cmdline does not pin the snapshot"
findmnt -no SOURCE / | grep -q /dev/mapper/cryptroot \
  && ok "unlocked through the same single prompt" || bad "root is not on cryptroot"
cur=$(cat /sys/firmware/efi/efivars/LoaderEntrySelected-* 2>/dev/null | tr -d '\0' | tr -cd '[:print:]')
case "$cur" in
  *"ergon-snapshot-$WANT"*) ok "systemd-boot says it booted ergon-snapshot-$WANT" ;;
  *) bad "LoaderEntrySelected is '$cur'" ;;
esac
echo "--- $P passed, $F failed ---"
echo "SNAPBOOT_RESULT=$F"
