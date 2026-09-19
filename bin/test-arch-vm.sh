#!/usr/bin/env bash
# Install arch-bootstrap.sh into a real UEFI virtual machine, boot it, and
# assert on the result.
#
#   ./test-arch-vm.sh            # full run: install, reboot, verify
#   ./test-arch-vm.sh --keep     # leave the disk image behind for poking at
#
# This is the test bin/test-arch-bootstrap.sh CANNOT be. That one runs the
# installer against a loopback file in a container and proves the disk is laid
# out correctly -- subvolumes, fstab, NOCOW swapfile. It stops exactly where it
# gets interesting, because a container has no firmware and never boots:
#
#   * GRUB is installed but never runs
#   * the initramfs never unlocks LUKS
#   * `resume=` is written but never resumes
#   * grub-btrfs writes a snapshot submenu nobody ever selects
#   * snapper rollback is never exercised on a live root
#
# Every one of those is a thing that fails at the worst possible moment -- on a
# new laptop, far from a second computer. So: OVMF firmware, a real Arch ISO, a
# real LUKS passphrase typed at a real prompt over a serial console.
#
# Everything runs in a container (see Dockerfile below); qemu is never installed
# on the host. The VM needs /dev/kvm, which on checo is mode 0666.
set -euo pipefail

CACHE="${CACHE:-$HOME/.cache/fleet-artifacts}"
WORK="${WORK:-$CACHE/arch-vm}"
ISO="$CACHE/archlinux-x86_64.iso"
IMAGE=fleet-qemu

DISK_GIB="${DISK_GIB:-40}"
VM_RAM_MB="${VM_RAM_MB:-4096}"
VM_CPUS="${VM_CPUS:-4}"

# Small on purpose. The real machine gets 100 GiB to hold 96 GiB of RAM; what is
# under test is the resume= plumbing, which does not care about the size, and a
# 100 GiB preallocated swapfile in a test VM is 100 GiB of host disk.
SWAP_GIB="${SWAP_GIB:-6}"

PASSPHRASE="${LUKS_PASSPHRASE:-testpass123}"
USERPASS="${USER_PASSWORD:-testuser123}"
VMHOST="${HOSTNAME_NEW:-testarch}"
# Must match arch-bootstrap.sh USERNAME, which is what the install creates.
USERNAME="${USERNAME:-jayvains}"

KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

ERGON="$(cd "${ERGON:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
fail() { printf '   FAIL %s\n' "$*"; FAILED=$((FAILED+1)); }
FAILED=0

command -v docker >/dev/null || { echo "docker required" >&2; exit 1; }
[ -c /dev/kvm ] || { echo "/dev/kvm missing — this needs hardware virtualisation" >&2; exit 1; }
[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "/dev/kvm not readable/writable by $USER" >&2; exit 1; }

# ---------------------------------------------------------------------------
say "container image"
docker build -q -t "$IMAGE" - >/dev/null <<'DOCKERFILE'
FROM debian:13
ENV DEBIAN_FRONTEND=noninteractive
# ovmf is the point: the laptop boots UEFI and GRUB is installed in UEFI mode,
# so a SeaBIOS test would exercise a path that never runs on real hardware.
# libarchive-tools gives bsdtar, which reads the ISO without needing a loop
# mount (and therefore without needing root or a privileged container).
# qemu-system-gui is a RECOMMENDS of qemu-system-x86, and --no-install-recommends
# drops it. Without it this qemu has only the `none` and `curses` displays and no
# virtio-*-gl device at all, so the guest gets no GL and no dmabuf -- which is
# why hyprpaper could not composite a wallpaper and grim could not capture. Those
# were written off as "the VM cannot do graphics"; they were one missing package.
# libegl1/libgbm1/libgl1-mesa-dri are the EGL runtime qemu dlopens for
# -display egl-headless. qemu-system-gui provides the GL-capable binary but not
# these, and without them qemu exits with "Couldn't open libEGL.so.1" -- which
# reads like a qemu problem and is a missing dependency.
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      qemu-system-x86 qemu-system-gui qemu-utils ovmf expect libarchive-tools \
      libegl1 libgbm1 libgl1-mesa-dri \
      curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
DOCKERFILE
ok "$IMAGE"

# ---------------------------------------------------------------------------
say "iso"
[ -f "$ISO" ] || { echo "missing $ISO — fetch it first" >&2; exit 1; }
ok "$(du -h "$ISO" | cut -f1)  $(basename "$ISO")"

mkdir -p "$WORK"

# ---------------------------------------------------------------------------
say "disk and firmware"
rm -f "$WORK/disk.qcow2" "$WORK/OVMF_VARS.fd"
docker run --rm -v "$WORK:/w" -v "$ISO:/iso:ro" "$IMAGE" bash -euo pipefail -c "
  qemu-img create -f qcow2 /w/disk.qcow2 ${DISK_GIB}G >/dev/null
  # A WRITABLE copy of the variable store. This is not bookkeeping: the UEFI
  # boot entry efibootmgr creates during grub-install lives in here, and with a
  # read-only VARS file the install would appear to succeed and then boot to a
  # firmware shell with no boot option at all.
  cp /usr/share/OVMF/OVMF_VARS_4M.fd /w/OVMF_VARS.fd

  # Kernel and initramfs are pulled OUT of the ISO so qemu can boot them
  # directly with -kernel/-initrd. That is the only way to get console=ttyS0
  # onto the cmdline without rewriting the ISO's bootloader, and without a
  # serial console none of this can be driven headlessly.
  bsdtar -xf /iso -C /w arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img
"
# The archiso hook finds its squashfs by VOLUME LABEL, so the cmdline has to
# carry the real one. It lives in the ISO9660 primary volume descriptor at byte
# 32808; reading it beats hardcoding a label that changes every month.
ISOLABEL=$(dd if="$ISO" bs=1 skip=32808 count=32 2>/dev/null | tr -d '\0' | sed 's/[[:space:]]*$//')
[ -n "$ISOLABEL" ] || { echo "could not read ISO volume label" >&2; exit 1; }
ok "disk ${DISK_GIB}G, OVMF vars writable, iso label $ISOLABEL"
# ---------------------------------------------------------------------------
# QEMU invocation, shared by both boots.
#
# The dotfiles tree is handed over 9p rather than copied, so the installer under
# test is the working tree and not a snapshot of it. It mounts at /dotfiles, NOT
# under /mnt -- arch-bootstrap.sh owns /mnt as the target root, and a 9p share
# inside it would be unmountable at the worst moment.
# shellcheck disable=SC2329  # invoked via $(qemu_args) inside a heredoc
qemu_args() {
  cat <<ARGS
  -accel kvm -cpu host -m $VM_RAM_MB -smp $VM_CPUS \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=/w/OVMF_VARS.fd \
  -drive file=/w/disk.qcow2,if=virtio,format=qcow2 \
  -virtfs local,path=/ergon,mount_tag=ergon,security_model=none,readonly=on \
  -nic user,model=virtio-net-pci \
  -nographic -no-reboot
ARGS
}

say "phase 1: install from the ISO"
# The ISO is attached as an EXPLICIT virtio-scsi CD, not with the usual
# `-drive media=cdrom` shorthand. That shorthand means `if=ide`, and in this
# configuration -- OVMF pflash plus a virtio system disk -- it produced no
# device at all: the archiso hook waited 30s for /dev/disk/by-label/<label>,
# never found it, and dropped to an emergency shell. An explicit scsi-cd on a
# virtio-scsi controller does not depend on the machine type having a usable
# IDE shorthand. It also keeps the target disk as the only virtio-blk device,
# so it is deterministically /dev/vda.
cat > "$WORK/install.exp" <<EXPECT
set timeout 3000
log_user 1

# Sentinels are written as  echo FOO''BAR  throughout. A terminal echoes the
# command as you type it, so a send of 'echo READY' followed by an expect of
# 'READY' matches the ECHO, not the output -- NOTE: no backticks anywhere in
# this heredoc. It is unquoted (it has to be, for the harness variables to
# expand), so backticks in a COMMENT are still command substitution and bash
# runs them. That is why every error surfaced at the 'cat >' line.

spawn qemu-system-x86_64 $(qemu_args) \
  -device virtio-scsi-pci,id=scsi0 \
  -drive id=cdrom0,file=/iso,if=none,format=raw,readonly=on \
  -device scsi-cd,bus=scsi0.0,drive=cdrom0 \
  -kernel /w/arch/boot/x86_64/vmlinuz-linux \
  -initrd /w/arch/boot/x86_64/initramfs-linux.img \
  -append "archisobasedir=arch archisolabel=$ISOLABEL console=ttyS0,115200n8 cow_spacesize=4G"

expect {
  timeout { puts "\n!! ISO never showed a login prompt"; exit 1 }
  "archiso login:" {}
}
send "root\r"

# Do NOT match the shell prompt. archiso's prompt carries charset and colour
# escapes -- the raw bytes are root\x1b(B@archiso -- so a regex like
# root@archiso[^#]*# cannot match it. Poll for a sentinel instead.
# Short timeout INSIDE the poll loop. Without this each retry inherits the
# global timeout, so a failure to get a shell takes 30 x 50 minutes instead of
# 30 x 10 seconds.
set saved_timeout \$timeout
set timeout 10
set ready 0
for {set i 0} {\$i < 30} {incr i} {
  send "echo ISO''_READY\r"
  expect {
    timeout {}
    "ISO_READY" { set ready 1 }
  }
  if {\$ready} break
}
set timeout \$saved_timeout
if {!\$ready} { puts "\n!! no usable shell on the ISO"; exit 1 }

send "mkdir -p /ergon && mount -t 9p -o trans=virtio,version=9p2000.L,ro ergon /ergon && test -f /ergon/bin/arch-bootstrap.sh && echo SHARE''_OK\r"
expect {
  timeout { puts "\n!! 9p share did not mount"; exit 1 }
  "SHARE_OK" {}
}

# pacstrap needs the network, and a DHCP race here surfaces later as a mirror
# failure that looks like a broken mirrorlist.
send "until ping -c1 -W1 geo.mirror.pkgbuild.com >/dev/null 2>&1; do sleep 2; done; echo NET''UP\r"
expect {
  timeout { puts "\n!! no network in the VM"; exit 1 }
  "NETUP" {}
}

# UNATTENDED only -- deliberately NOT ARCH_BOOTSTRAP_TEST. The live-ISO guard,
# the UEFI guard and the real swapon all have to run here; that is the entire
# reason for doing this in a VM instead of a container.
send "ARCH_BOOTSTRAP_UNATTENDED=1 HOSTNAME_NEW=$VMHOST LUKS_PASSPHRASE=$PASSPHRASE USER_PASSWORD=$USERPASS SWAP_GIB=$SWAP_GIB bash /ergon/bin/arch-bootstrap.sh /dev/vda; echo BOOTSTRAP_RC=\\\$?\r"
expect {
  timeout { puts "\n!! arch-bootstrap.sh did not finish in 50 minutes"; exit 1 }
  "BOOTSTRAP_RC=0" { puts "\n-- bootstrap exited 0" }
  -re {BOOTSTRAP_RC=[1-9]} { puts "\n!! arch-bootstrap.sh failed"; exit 1 }
}

# Give the installed system a serial console so phase 2 can watch it boot.
# Harness-only; see the header of the guest script.
send "arch-chroot /mnt /bin/bash -s < /ergon/test/arch-vm/guest-serial-console.sh; echo SERIAL_RC=\\\$?\r"
expect {
  timeout { puts "\n!! serial console setup timed out"; exit 1 }
  "SERIAL_RC=0" {}
  -re {SERIAL_RC=[1-9]} { puts "\n!! could not add a serial console to the guest"; exit 1 }
}

send "umount /dotfiles; sync; poweroff\r"
expect eof
EXPECT

# The heredocs above are UNQUOTED so the harness variables expand -- which
# means every Tcl variable in them has to be written \$foo. Miss one and bash
# eats it, and under `set -u` the failure is reported against the "cat >" line
# with no hint that a generated file is wrong. Check the output instead.
for v in timeout saved_timeout i ready; do
  grep -q "\$$v" "$WORK/install.exp" || { echo "install.exp lost Tcl variable \$$v — check heredoc escaping" >&2; exit 1; }
done

docker run --rm --device /dev/kvm \
  -v "$WORK:/w" -v "$ISO:/iso:ro" -v "$ERGON:/ergon:ro" \
  "$IMAGE" expect -f /w/install.exp 2>&1 | tee "$WORK/phase1.log" | grep -E '^(==|   ok|   !!|-- |!! )' || true
grep -q 'BOOTSTRAP_RC=0' "$WORK/phase1.log" || { echo "   FAIL install did not complete — see $WORK/phase1.log" >&2; exit 1; }
# Check the serial console step too. Without this, a failure here is invisible
# until phase 2 reports "never reached the LUKS prompt" -- which reads like a
# broken bootloader rather than a harness step that did not run.
grep -q 'SERIAL_RC=0' "$WORK/phase1.log" || { echo "   FAIL guest serial console was not configured — see $WORK/phase1.log" >&2; exit 1; }
ok "installed (log: $WORK/phase1.log)"

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Shared expect helpers, sourced by BOTH boot.exp and rollback.exp.
#
# They were copy-pasted into each at first, and promptly diverged: phase 2 was
# fixed for serial autologin while phase 3 still waited for a login prompt that
# autologin never prints. One definition, two consumers.
cp "$ERGON/test/arch-vm/lib.exp" "$WORK/lib.exp"

say "phase 2: boot the installed system"
# No cdrom and no -kernel/-initrd this time: the firmware has to find GRUB in
# the ESP by itself, via the boot entry grub-install wrote into the NVRAM we
# made writable. If that entry is missing this drops to a UEFI shell and the
# first expect times out -- which is exactly the failure worth catching.
#
# Nothing below matches on a shell prompt. The install gives the user /bin/zsh,
# and a first zsh login on Arch opens the zsh-newuser-install wizard instead of
# a prompt; beyond that, prompt formatting is not something a test should be
# coupled to. Every step is confirmed by a sentinel the guest echoes instead.
cat > "$WORK/boot.exp" <<EXPECT
set timeout 900
log_user 1
source /w/lib.exp

spawn qemu-system-x86_64 $(qemu_args)
unlock_and_login "$PASSPHRASE" "$VMHOST" "$USERNAME" "$USERPASS"

send "echo '$USERPASS' | sudo -S mount -t 9p -o trans=virtio,version=9p2000.L,ro ergon /mnt && echo SHARE''_OK\r"
expect {
  timeout { puts "\n!! could not mount the 9p share in the booted system"; exit 1 }
  "SHARE_OK" {}
}

send "echo '$USERPASS' | sudo -S env EXPECT_HOSTNAME=$VMHOST bash /mnt/test/arch-vm/guest-assert.sh\r"
expect {
  timeout { puts "\n!! assertions did not finish"; exit 1 }
  -re {ASSERT_RESULT=[0-9]+} {}
}

send "echo '$USERPASS' | sudo -S poweroff\r"
expect eof
EXPECT

docker run --rm --device /dev/kvm \
  -v "$WORK:/w" -v "$ERGON:/ergon:ro" \
  "$IMAGE" expect -f /w/boot.exp 2>&1 | tee "$WORK/phase2.log" \
  | grep -E '^(   ok|   FAIL|--- |!! )' || true

if ! grep -q 'ASSERT_RESULT=' "$WORK/phase2.log"; then
  echo "   FAIL the installed system never ran the assertions — see $WORK/phase2.log" >&2
  exit 1
fi
GUESTFAIL=$(grep -o 'ASSERT_RESULT=[0-9]*' "$WORK/phase2.log" | tail -1 | cut -d= -f2)
FAILED=$((FAILED + GUESTFAIL))


# ---------------------------------------------------------------------------
say "phase 3: rehearse a rollback"
# The claim the entire btrfs layout exists to support.
#
# NOT via `snapper rollback` -- that repoints the default subvolume, and
# grub-mkconfig unconditionally pins rootflags=subvol=@ over the top of it, so
# the kernel mounts @ regardless. Verified: with the default correctly set to @
# snapper still refuses with "Cannot detect ambit". See bin/ergon-rollback.
#
# Instead this exercises the recovery you would actually perform: boot the Arch
# ISO, unlock the disk, replace @ with a snapshot, reboot. Three boots, because
# you cannot replace the subvolume you are running from.
cat > "$WORK/rollback.exp" <<EXPECT
set timeout 1200
log_user 1
source /w/lib.exp

# --- boot 1: snapshot, then break something ------------------------------
spawn qemu-system-x86_64 $(qemu_args)
unlock_and_login "$PASSPHRASE" "$VMHOST" "$USERNAME" "$USERPASS"

send "echo '$USERPASS' | sudo -S mount -t 9p -o trans=virtio,version=9p2000.L,ro ergon /mnt && echo SHARE''_OK\r"
expect {
  timeout { puts "\n!! share failed"; exit 1 }
  "SHARE_OK" {}
}

send "echo '$USERPASS' | sudo -S bash /mnt/test/arch-vm/guest-rollback-arm.sh\r"
set snapnum ""
expect {
  timeout { puts "\n!! arming the rollback timed out"; exit 1 }
  -re {PRE_SNAPSHOT=([0-9]+)} { set snapnum \$expect_out(1,string); exp_continue }
  "SNAPSHOT_CONTAINS_CANARY" { puts "\n!! the snapshot already contains the canary"; exit 1 }
  "ARM_DONE" {}
}
if {\$snapnum eq ""} { puts "\n!! could not read the snapshot number"; exit 1 }
puts "\n-- armed against snapshot \$snapnum"

send "echo '$USERPASS' | sudo -S poweroff\r"
expect eof

# --- boot 2: the ISO, where @ is not in use -------------------------------
spawn qemu-system-x86_64 $(qemu_args) \
  -device virtio-scsi-pci,id=scsi0 \
  -drive id=cdrom0,file=/iso,if=none,format=raw,readonly=on \
  -device scsi-cd,bus=scsi0.0,drive=cdrom0 \
  -kernel /w/arch/boot/x86_64/vmlinuz-linux \
  -initrd /w/arch/boot/x86_64/initramfs-linux.img \
  -append "archisobasedir=arch archisolabel=$ISOLABEL console=ttyS0,115200n8 cow_spacesize=4G"

expect {
  timeout { puts "\n!! ISO never showed a login prompt"; exit 1 }
  "archiso login:" {}
}
send "root\r"

set saved_timeout \$timeout
set timeout 10
set ready 0
for {set i 0} {\$i < 30} {incr i} {
  send "echo ISO''_READY\r"
  expect {
    timeout {}
    "ISO_READY" { set ready 1 }
  }
  if {\$ready} break
}
set timeout \$saved_timeout
if {!\$ready} { puts "\n!! no shell on the rescue ISO"; exit 1 }

send "mkdir -p /ergon && mount -t 9p -o trans=virtio,version=9p2000.L,ro ergon /ergon && echo SHARE''_OK\r"
expect {
  timeout { puts "\n!! 9p share did not mount on the ISO"; exit 1 }
  "SHARE_OK" {}
}

# Unlock the disk by hand -- this is the real recovery sequence.
send "printf '%s' '$PASSPHRASE' | cryptsetup open /dev/vda2 cryptroot - && echo UNLOCK''_OK\r"
expect {
  timeout { puts "\n!! could not unlock the disk from the ISO"; exit 1 }
  "UNLOCK_OK" {}
}

send "bash /ergon/bin/ergon-rollback \$snapnum; echo ROLLBACK_RC=\\\$?\r"
expect {
  timeout { puts "\n!! ergon-rollback timed out"; exit 1 }
  "ROLLBACK_RC=0" {}
  -re {ROLLBACK_RC=[1-9]} { puts "\n!! ergon-rollback failed"; exit 1 }
}

send "umount /dotfiles; cryptsetup close cryptroot; sync; poweroff\r"
expect eof

# --- boot 3: the canary must be gone --------------------------------------
spawn qemu-system-x86_64 $(qemu_args)
unlock_and_login "$PASSPHRASE" "$VMHOST" "$USERNAME" "$USERPASS"

send "echo '$USERPASS' | sudo -S mount -t 9p -o trans=virtio,version=9p2000.L,ro ergon /mnt && echo SHARE''_OK\r"
expect {
  timeout { puts "\n!! share failed after rollback"; exit 1 }
  "SHARE_OK" {}
}

send "echo '$USERPASS' | sudo -S bash /mnt/test/arch-vm/guest-rollback-verify.sh\r"
expect {
  timeout { puts "\n!! rollback verification timed out"; exit 1 }
  -re {ROLLBACK_RESULT=[0-9]+} {}
}
send "echo '$USERPASS' | sudo -S poweroff\r"
expect eof
EXPECT

docker run --rm --device /dev/kvm \
  -v "$WORK:/w" -v "$ISO:/iso:ro" -v "$ERGON:/ergon:ro" \
  "$IMAGE" expect -f /w/rollback.exp 2>&1 | tee "$WORK/phase3.log" \
  | grep -E '^(   ok|   FAIL|--- |!! |-- armed|PRE_SNAPSHOT)' || true

if ! grep -q 'ROLLBACK_RESULT=' "$WORK/phase3.log"; then
  echo "   FAIL the rollback rehearsal never completed — see $WORK/phase3.log" >&2
  FAILED=$((FAILED + 1))
else
  FAILED=$((FAILED + $(grep -o 'ROLLBACK_RESULT=[0-9]*' "$WORK/phase3.log" | tail -1 | cut -d= -f2)))
fi

# ---------------------------------------------------------------------------
say "result"
if [ "$FAILED" -eq 0 ]; then
  ok "installs, boots via UEFI, unlocks LUKS, swaps, snapshots"
else
  printf '   %d assertion(s) failed — logs in %s\n' "$FAILED" "$WORK"
fi
echo "   phase 1: $WORK/phase1.log"
echo "   phase 2: $WORK/phase2.log"

if [ "$KEEP" = 1 ]; then
  echo "   disk kept: $WORK/disk.qcow2"
else
  rm -f "$WORK/disk.qcow2" "$WORK/OVMF_VARS.fd"
fi
exit $(( FAILED > 0 ))
