#!/usr/bin/env bash
# Hibernate the VM, bring it back, and prove it RESUMED rather than rebooted.
#
#   ./test-arch-vm.sh --keep     # once, to build the disk
#   ./test-hibernate.sh          # then this
#
# This machine is never shut down -- lid close falls through to hibernate -- so
# resume is a daily path, not an edge case. It is also the path most likely to
# be silently broken: resume_offset has to be the PHYSICAL offset of the
# swapfile, the LUKS volume has to be unlocked before systemd-hibernate-resume
# runs, and if any of that is wrong the machine simply cold-boots. A failed
# resume is indistinguishable from a successful boot unless you check, which is
# how people lose a day's work and blame the application.
#
# The check is boot_id: the kernel generates it once per boot, and a resume
# preserves it.
set -euo pipefail

CACHE="${CACHE:-$HOME/.cache/fleet-artifacts}"
WORK="${WORK:-$CACHE/arch-vm}"
IMAGE=fleet-qemu
VM_RAM_MB="${VM_RAM_MB:-4096}"
VM_CPUS="${VM_CPUS:-4}"
PASSPHRASE="${LUKS_PASSPHRASE:-testpass123}"
USERPASS="${USER_PASSWORD:-testuser123}"
VMHOST="${HOSTNAME_NEW:-testarch}"
USERNAME="${USERNAME:-jayvains}"
ERGON="$(cd "${ERGON:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

[ -f "$WORK/disk.qcow2" ] || { echo "no disk — run ./bin/test-arch-vm.sh --keep first" >&2; exit 1; }
cp "$ERGON/test/arch-vm/lib.exp" "$WORK/lib.exp"
[ -c /dev/kvm ] || { echo "/dev/kvm missing" >&2; exit 1; }

say "hibernate, then resume"
cat > "$WORK/hibernate.exp" <<EXPECT
set timeout 900
log_user 1
source /w/lib.exp

# --- boot 1: record identity, then hibernate ------------------------------
spawn qemu-system-x86_64 \
  -accel kvm -cpu host -m $VM_RAM_MB -smp $VM_CPUS \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=/w/OVMF_VARS.fd \
  -drive file=/w/disk.qcow2,if=virtio,format=qcow2 \
  -virtfs local,path=/ergon,mount_tag=ergon,security_model=none,readonly=on \
  -nic user,model=virtio-net-pci \
  -nographic -no-reboot

unlock_and_login "$PASSPHRASE" "$VMHOST" "$USERNAME" "$USERPASS"

send "echo '$USERPASS' | sudo -S mount -t 9p -o trans=virtio,version=9p2000.L,ro ergon /mnt && echo SHARE''_OK\r"
expect {
  timeout { puts "\n!! share failed"; exit 1 }
  "SHARE_OK" {}
}

set bootid ""
send "echo '$USERPASS' | sudo -S bash /mnt/test/arch-vm/guest-hibernate-arm.sh\r"
expect {
  timeout { puts "\n!! arming hibernate timed out"; exit 1 }
  # Anchored on the trailing CR, and a FIXED length. Unanchored, expect matches
  # the moment the buffer holds "BOOT_ID_BEFORE=7f" -- a partial read of a line
  # still arriving -- and silently captures a two-character "UUID". A regexp
  # that can match a prefix of incoming data will, eventually, match a prefix.
  -re {BOOT_ID_BEFORE=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})} { set bootid \$expect_out(1,string); exp_continue }
  "HIBERNATE_AVAILABLE=no" { puts "\n!! the kernel reports hibernate unavailable"; exit 1 }
  "HIBERNATING_NOW" {}
}
if {\$bootid eq ""} { puts "\n!! could not read boot_id"; exit 1 }
puts "\n-- boot_id before: \$bootid"

# qemu exits when the guest powers off at the end of hibernation.
expect {
  timeout { puts "\n!! the guest never powered off — hibernation did not complete"; exit 1 }
  eof {}
}
puts "\n-- guest powered off; the RAM image should be in swap"

# --- boot 2: the same disk. If resume works, boot_id is unchanged ---------
spawn qemu-system-x86_64 \
  -accel kvm -cpu host -m $VM_RAM_MB -smp $VM_CPUS \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=/w/OVMF_VARS.fd \
  -drive file=/w/disk.qcow2,if=virtio,format=qcow2 \
  -virtfs local,path=/ergon,mount_tag=ergon,security_model=none,readonly=on \
  -nic user,model=virtio-net-pci \
  -nographic -no-reboot

unlock_and_login "$PASSPHRASE" "$VMHOST" "$USERNAME" "$USERPASS"

# No 9p mount here. The share cannot be re-established after a resume, so the
# verifier was staged onto the real filesystem before hibernating.
send "echo '$USERPASS' | sudo -S env EXPECT_BOOT_ID=\$bootid /usr/local/bin/hibernate-verify\r"
expect {
  timeout { puts "\n!! verification timed out"; exit 1 }
  -re {HIBERNATE_RESULT=[0-9]+} {}
}

send "echo '$USERPASS' | sudo -S poweroff\r"
expect eof
EXPECT

docker run --rm --device /dev/kvm \
  -v "$WORK:/w" -v "$ERGON:/ergon:ro" \
  "$IMAGE" expect -f /w/hibernate.exp 2>&1 | tee "$WORK/hibernate.log" \
  | grep -E '^(   ok|   FAIL|--- |!! |-- )' || true

say "result"
if ! grep -q 'HIBERNATE_RESULT=' "$WORK/hibernate.log"; then
  echo "   FAIL the hibernate test never completed — see $WORK/hibernate.log" >&2
  exit 1
fi
n=$(grep -o 'HIBERNATE_RESULT=[0-9]*' "$WORK/hibernate.log" | tail -1 | cut -d= -f2)
[ "$n" -eq 0 ] && echo "   ok   hibernate and resume work" || echo "   $n check(s) failed"
exit $(( n > 0 ))
