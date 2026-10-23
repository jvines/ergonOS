#!/usr/bin/env bash
# Runs INSIDE the booted system. Takes a snapshot, then breaks something.
#
# It does NOT call `snapper rollback` -- that repoints the btrfs default
# subvolume, which this layout cannot honour: grub-mkconfig unconditionally
# pins rootflags=subvol=@ on the kernel command line, so the kernel mounts @
# whatever the default says. See bin/ergon-rollback for the full explanation.
#
# So this only arms the test. The restore itself is done by ergon-rollback from
# the Arch ISO, which is the real recovery path: you cannot replace the
# subvolume you are running from.
set -euo pipefail

MARKER=/rollback-canary

echo "--- arming rollback ---"

# A snapshot of the known-good state, before the canary exists.
before=$(snapper -c root create --print-number -d "vm-test: before canary")
echo "PRE_SNAPSHOT=$before"

# The change that must NOT survive the rollback.
date -u +%FT%TZ > "$MARKER"
sync
test -f "$MARKER" && echo "CANARY_WRITTEN=yes"

# Prove the snapshot actually captured the pre-canary state: the canary must be
# absent inside it. If this fails the test would "pass" later for the wrong
# reason -- a snapshot that already contains the canary can never lose it.
if [ -e "/.snapshots/$before/snapshot$MARKER" ]; then
  echo "SNAPSHOT_CONTAINS_CANARY=yes  (test would be meaningless)" >&2
  exit 1
fi
echo "SNAPSHOT_IS_CLEAN=yes"

# The snapshot must reach the boot menu by itself (ERGON-123): the path unit
# on /.snapshots runs ergon-boot-entries, which copies its kernel to the ESP
# and writes its entry. Then the next boot is that entry, once, chosen the way
# a person picking it from the menu would.
ENT=/efi/loader/entries/ergon-snapshot-$before.conf
for _ in $(seq 60); do [ -f "$ENT" ] && break; sleep 1; done
if [ -f "$ENT" ]; then
  echo "SNAPSHOT_ENTRY=yes"
  sed 's/^/     /' "$ENT"
  bootctl set-oneshot "ergon-snapshot-$before.conf" && echo "ONESHOT_SET=yes"
else
  echo "SNAPSHOT_ENTRY=no"
  ls /efi/loader/entries/ | sed 's/^/     /'
  systemctl status ergon-boot-entries.path ergon-boot-entries.service --no-pager 2>&1 | tail -15
fi

echo "ARM_DONE"
