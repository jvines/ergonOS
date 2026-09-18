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

echo "ARM_DONE"
