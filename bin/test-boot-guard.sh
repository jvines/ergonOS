#!/usr/bin/env bash
# Break the boot on purpose and prove the machine rescues itself.
#
#   ./test-arch-vm.sh --keep       # once, to build the disk
#   ./test-hypr-session.sh         # provisions it (installs the boot guard)
#   ./test-boot-guard.sh           # then this
#
# Five boots:
#   1  record a known-good snapshot, then add a unit that always fails and that
#      default.target requires -- the machine will boot and never finish
#   2  fails. GRUB's counter goes 2 -> 1
#   3  fails. 1 -> 0
#   4  GRUB boots the last known-good snapshot BY ITSELF. From there,
#      ergon-rollback makes it @ again, which is the recovery a person would do
#   5  back on @, healthy, break gone, counter armed again
#
# What this covers that nothing else can: that GRUB really writes its counter to
# the EFI partition on this LUKS+btrfs layout (undocumented upstream), that the
# generated entry boots a snapshot's own kernel, and that a failed boot is what
# moves the counter -- none of which can be asserted from a running system.
set -euo pipefail

CACHE="${CACHE:-$HOME/.cache/fleet-artifacts}"
WORK="${WORK:-$CACHE/arch-vm}"
VM_RAM_MB="${VM_RAM_MB:-4096}"
VM_CPUS="${VM_CPUS:-4}"
PASSPHRASE="${LUKS_PASSPHRASE:-testpass123}"
USERPASS="${USER_PASSWORD:-testuser123}"
VMHOST="${HOSTNAME_NEW:-testarch}"
USERNAME="${USERNAME:-jayvains}"
ERGON="$(cd "${ERGON:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# --- what the two grub.d scripts print, before spending five boots on it ----
# The fallback entry must come from the 99 script. Emitted by the 09 one it
# lands before the normal entries, becomes entry 0, and GRUB boots it every
# time -- which is exactly what happened, and cost a whole VM run to find.
say "the grub.d scripts"
env_fake() { env ERGON_GUARD_ESP_UUID=1234-ABCD ERGON_GUARD_ROOT_UUID=dead-beef \
                 ERGON_GUARD_BOOT=/nonexistent ERGON_GUARD_GRUB_DEFAULT=/dev/null "$@"; }
c_out=$(env_fake "$ERGON/grub/09_ergon_boot_counter")
f_out=$(env_fake "$ERGON/grub/99_ergon_boot_fallback")
fail=0
case $c_out in *menuentry*) echo "   FAIL the counter script emits a menuentry, which would become entry 0"; fail=1 ;;
              *) echo "   ok   the counter script emits no menu entry" ;; esac
case $c_out in *save_env*ergon_tries*) echo "   ok   the counter is written back to the EFI partition" ;;
              *) echo "   FAIL the counter never saves ergon_tries"; fail=1 ;; esac
case $f_out in *"--id ergon-fallback"*) echo "   ok   the fallback entry carries the id the counter selects" ;;
              *) echo "   FAIL no fallback entry"; fail=1 ;; esac
case $f_out in *'no known-good snapshot has been recorded'*) echo "   ok   it refuses rather than booting an empty path" ;;
              *) echo "   FAIL nothing guards an unset ergon_good_snapshot"; fail=1 ;; esac
case $f_out in *'btrfs_subvolid=5'*'vmlinuz-linux'*) echo "   ok   it boots the snapshot's own kernel from the top of the filesystem" ;;
              *) echo "   FAIL the entry does not boot the snapshot's kernel"; fail=1 ;; esac
[ "$fail" = 0 ] || { echo "   !! not booting anything until the emitted grub script is right" >&2; exit 1; }

[ -f "$WORK/disk.qcow2" ] || { echo "no disk — run ./bin/test-arch-vm.sh --keep first" >&2; exit 1; }
[ -c /dev/kvm ] || { echo "/dev/kvm missing" >&2; exit 1; }
cp "$ERGON/test/arch-vm/lib.exp" "$WORK/lib.exp"

say "arm a broken boot, then let the machine rescue itself"
cat > "$WORK/guard.exp" <<EXPECT
set timeout 900
log_user 1
source /w/lib.exp

proc boot_vm {} {
  # expect keeps spawn_id local to a proc, so without this the caller has no VM.
  global spawn_id
  spawn qemu-system-x86_64 \
    -accel kvm -cpu host -m $VM_RAM_MB -smp $VM_CPUS \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file=/w/OVMF_VARS.fd \
    -drive file=/w/disk.qcow2,if=virtio,format=qcow2 \
    -virtfs local,path=/ergon,mount_tag=ergon,security_model=none,readonly=on \
    -nic user,model=virtio-net-pci \
    -nographic -no-reboot
}

# Ctrl-A x: qemu's own quit. Pulling the power is exactly what someone does to a
# machine that will not finish booting.
proc kill_vm {} {
  send "\\001x"
  expect {
    timeout { puts "\n!! qemu did not quit" }
    eof {}
  }
}

proc share {} {
  send "echo '$USERPASS' | sudo -S mount -t 9p -o trans=virtio,version=9p2000.L,ro ergon /mnt && echo SHARE''_OK\r"
  expect {
    timeout { puts "\n!! share failed"; exit 1 }
    "SHARE_OK" {}
  }
}

# --- boot 1: record the known-good snapshot, then break the boot -----------
boot_vm
unlock_and_login "$PASSPHRASE" "$VMHOST" "$USERNAME" "$USERPASS"
share
send "echo '$USERPASS' | sudo -S bash /mnt/test/arch-vm/guest-boot-guard-arm.sh\r"
expect {
  timeout { puts "\n!! arming timed out"; exit 1 }
  "GUARD_INSTALL=failed" { puts "\n!! the boot guard would not install"; exit 1 }
  "GUARD_RECORD=wrong"   { puts "\n!! the guard recorded the wrong snapshot"; exit 1 }
  "SNAPSHOT_ALREADY_BROKEN=yes" { puts "\n!! the snapshot already contains the break"; exit 1 }
  "BREAK_WIRED=no" { puts "\n!! the break unit is not wired to the boot target"; exit 1 }
  "ARM_DONE" {}
}
send "echo '$USERPASS' | sudo -S systemctl poweroff\r"
expect {
  timeout { puts "\n!! the guest did not power off"; exit 1 }
  eof {}
}
puts "\n-- armed: the next two boots must fail"

# --- boots 2 and 3: they must NOT reach the default target -----------------
# The counter GRUB prints is the proof that its write to the EFI partition
# survived the last power cut -- the one thing no running system can show.
foreach attempt {2 3} {
  set want [expr {4 - \$attempt}]
  boot_vm
  # The disk is encrypted, so GRUB and the initramfs both ask before anything
  # can fail. Answer every prompt and keep waiting for the failure.
  expect {
    timeout { puts "\n!! boot \$attempt neither failed nor finished"; kill_vm; exit 1 }
    -nocase "passphrase" { send "$PASSPHRASE\r"; exp_continue }
    -re "ergon boot guard: tries=(\[0-9\]+)" {
      if {\$expect_out(1,string) != \$want} {
        puts "\n!! boot \$attempt started with tries=\$expect_out(1,string), expected \$want: GRUB is not persisting the counter"
        kill_vm; exit 1
      }
      exp_continue
    }
    -re {Dependency failed for|Deliberately fail the boot|ergon-break-boot\.service: |emergency mode} {}
  }
  puts "\n-- boot \$attempt failed as intended"
  # Let it settle so GRUB's write is not raced by the power cut.
  sleep 5
  kill_vm
}

# --- boot 4: GRUB must choose the fallback with nobody at the keyboard -----
boot_vm
expect {
  timeout { puts "\n!! GRUB did not announce the fallback entry"; kill_vm; exit 1 }
  -nocase "passphrase" { send "$PASSPHRASE\r"; exp_continue }
  "booting the last known-good snapshot" {}
}
puts "\n-- GRUB chose the fallback by itself"
unlock_and_login "$PASSPHRASE" "$VMHOST" "$USERNAME" "$USERPASS"
share
send "echo '$USERPASS' | sudo -S bash /mnt/test/arch-vm/guest-boot-guard-verify.sh\r"
expect {
  timeout { puts "\n!! verification timed out"; exit 1 }
  -re {GUARD_VERIFY_RESULT=[0-9]+} {}
}
send "echo '$USERPASS' | sudo -S systemctl poweroff\r"
expect {
  timeout { puts "\n!! the guest did not power off after the rollback"; exit 1 }
  eof {}
}

# --- boot 5: back on @, healthy ------------------------------------------
boot_vm
unlock_and_login "$PASSPHRASE" "$VMHOST" "$USERNAME" "$USERPASS"
share
send "echo '$USERPASS' | sudo -S bash /mnt/test/arch-vm/guest-boot-guard-final.sh\r"
expect {
  timeout { puts "\n!! the final check timed out"; exit 1 }
  -re {GUARD_FINAL_RESULT=[0-9]+} {}
}
send "echo '$USERPASS' | sudo -S systemctl poweroff\r"
expect {
  timeout {}
  eof {}
}
EXPECT

docker run --rm --device /dev/kvm -v "$WORK:/w" -v "$ERGON:/ergon:ro" \
  "${IMAGE:-fleet-qemu}" expect -f /w/guard.exp 2>&1 | tee "$WORK/guard.log"

# The guest scripts print their own counts; the driver's job is to insist both
# ran and both were clean.
v=$(grep -o 'GUARD_VERIFY_RESULT=[0-9]*' "$WORK/guard.log" | tail -1 | cut -d= -f2)
f=$(grep -o 'GUARD_FINAL_RESULT=[0-9]*' "$WORK/guard.log" | tail -1 | cut -d= -f2)
say "result"
[ -n "$v" ] && [ -n "$f" ] || { echo "   !! one of the guest checks never reported"; exit 1; }
if [ "$v" = 0 ] && [ "$f" = 0 ]; then
  echo "   ok  a machine that cannot boot rescues itself, and the rollback sticks"
else
  echo "   !! failures: $v in the fallback boot, $f after the rollback"
  exit 1
fi
