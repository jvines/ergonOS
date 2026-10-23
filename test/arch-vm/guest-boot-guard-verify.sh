#!/usr/bin/env bash
# Runs INSIDE the system the boot loader chose after the failed boots. Asserts this is
# the snapshot, then performs the real recovery: ergon-rollback makes it @.
set -uo pipefail
P=0; F=0
ok()  { printf '   ok   %s\n' "$*"; P=$((P+1)); }
bad() { printf '   FAIL %s\n' "$*"; F=$((F+1)); }
U=$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)
E="$(getent passwd "$U" | cut -d: -f6)/ergonOS"

echo "--- after the automatic fallback ---"
FSROOT=$(findmnt -no FSROOT /)
case "$FSROOT" in
  /@snapshots/*/snapshot) ok "/ is the snapshot $FSROOT, chosen by the boot loader without anyone at the keyboard" ;;
  *) bad "/ is $FSROOT, so the fallback entry did not boot" ;;
esac
[ ! -e /etc/systemd/system/ergon-break-boot.service ] \
  && ok "the broken unit is not in this root (it was added after the snapshot)" \
  || bad "the broken unit is here too — this is not the snapshot"

# GRUB re-arms while falling back; systemd-boot through ergon-boot-ok once
# this boot is up, so give that unit its minute.
for _ in $(seq 90); do
  tries=$("$E/bin/ergon-boot-guard" get tries 2>/dev/null)
  [ "$tries" != 0 ] && break; sleep 1
done
[ "$tries" != "0" ] \
  && ok "the counter was reset while falling back ($tries), so the next boot tries the normal system" \
  || bad "the counter is still 0 — the machine would fall back forever"

# The recovery a person would do next, and the reason a snapshot boot is usable:
# replace @ with this snapshot. It cannot be done from @ itself.
num=$(printf '%s' "$FSROOT" | sed -n 's|^/@snapshots/\([0-9]*\)/snapshot$|\1|p')
if [ -n "$num" ]; then
  if bash "$E/bin/ergon-rollback" "$num"; then
    ok "ergon-rollback replaced @ with snapshot $num"
  else
    bad "ergon-rollback failed from the snapshot boot"
  fi
fi
echo "--- $P passed, $F failed ---"
echo "GUARD_VERIFY_RESULT=$F"
