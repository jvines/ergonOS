#!/usr/bin/env bash
# Runs INSIDE the system after the rollback reboot: the machine must be back on
# @, healthy, with the break gone and the guard armed again.
set -uo pipefail
P=0; F=0
ok()  { printf '   ok   %s\n' "$*"; P=$((P+1)); }
bad() { printf '   FAIL %s\n' "$*"; F=$((F+1)); }
U=$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)
E="$(getent passwd "$U" | cut -d: -f6)/ergonOS"   # in @home, so it survives a rollback of @

echo "--- after the rollback reboot ---"
[ "$(findmnt -no FSROOT /)" = "/@" ] && ok "/ is @ again" || bad "/ is $(findmnt -no FSROOT /)"
[ ! -e /etc/systemd/system/ergon-break-boot.service ] \
  && ok "the broken unit is gone" || bad "the broken unit survived the rollback"
systemctl is-system-running --wait >/dev/null 2>&1
case "$(systemctl is-system-running 2>/dev/null)" in
  running|degraded) ok "the system reached its default target" ;;
  *) bad "the system is $(systemctl is-system-running 2>/dev/null)" ;;
esac
ESP=$(findmnt -no TARGET -t vfat | head -1)
tries=$(grub-editenv "$ESP/EFI/ergon/grubenv" list 2>/dev/null | sed -n 's/^ergon_tries=//p')
[ "$tries" = "2" ] && ok "the counter is back to 2 after a good boot" || bad "the counter is $tries"
"$E/bin/ergon-boot-guard" status | sed 's/^/     /'
echo "--- $P passed, $F failed ---"
echo "GUARD_FINAL_RESULT=$F"
