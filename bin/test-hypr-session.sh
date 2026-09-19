#!/usr/bin/env bash
# Start the real compositor, with the real config, and ask it questions.
#
#   ./test-arch-vm.sh --keep      # once, to build the disk
#   ./test-hypr-session.sh        # then this, repeatedly
#
# Separate from test-arch-vm.sh on purpose. It REUSES that disk rather than
# reinstalling, so it is a few minutes rather than fifteen, and the main suite
# stays fast. It is also the only test here that needs a GPU.
#
# What it covers that nothing else can: --verify-config proves the config is
# accepted, not that the compositor starts, that the binds register, or that
# waybar maps a surface. Two API bugs in this repo would have produced a
# compositor with ZERO keybindings and no way to open a terminal -- and a config
# that parses perfectly.
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

[ -f "$WORK/disk.qcow2" ] || {
  echo "no disk at $WORK/disk.qcow2 — run ./bin/test-arch-vm.sh --keep first" >&2; exit 1; }
# Same GPU auto-detection as bin/hypr-vm. With a render node the guest gets real
# GL and a dmabuf path, which is what makes the wallpaper and grim assertions
# mean anything; without one they are skips. Run this on a host with a GPU.
RENDERNODE="${HYPR_VM_RENDERNODE:-/dev/dri/renderD128}"
if [ -e "$RENDERNODE" ]; then
  GPU_DEV="virtio-vga-gl"; GPU_DISPLAY="egl-headless,rendernode=$RENDERNODE"
  GPU_DOCKER="--device $RENDERNODE"
else
  GPU_DEV="virtio-gpu-pci"; GPU_DISPLAY="none"; GPU_DOCKER=""
fi

cp "$ERGON/test/arch-vm/lib.exp" "$WORK/lib.exp"
[ -c /dev/kvm ] || { echo "/dev/kvm missing" >&2; exit 1; }

# A WRITABLE share, for things that need to come back out of the VM -- the
# desktop screenshots below. The dotfiles share stays read-only; a test must not
# be able to modify the repo it is testing.
mkdir -p "$WORK/out"
chmod 777 "$WORK/out"

say "booting with a virtual GPU"
# virtio-gpu-pci is the whole point: Hyprland has no headless backend and needs
# a DRM device. -nographic keeps the serial console; nobody looks at the GPU.
#
# PIIX4_PM.disable_s3 takes S3 away, so the guest's firmware offers s2idle only,
# like most current laptops. That is what makes ergon-hardware choose
# suspend-then-hibernate for the lid, so the VM proves the capability path
# instead of only the "firmware offers S3" skip.
cat > "$WORK/session.exp" <<EXPECT
set timeout 1800
log_user 1
source /w/lib.exp

spawn qemu-system-x86_64 \
  -accel kvm -cpu host -m $VM_RAM_MB -smp $VM_CPUS \
  -global PIIX4_PM.disable_s3=1 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=/w/OVMF_VARS.fd \
  -drive file=/w/disk.qcow2,if=virtio,format=qcow2 \
  -device $GPU_DEV \
  -display $GPU_DISPLAY \
  -virtfs local,path=/ergon,mount_tag=ergon,security_model=none,readonly=on \
  -virtfs local,path=/w/out,mount_tag=out,security_model=none \
  -nic user,model=virtio-net-pci \
  -nographic -no-reboot

unlock_and_login "$PASSPHRASE" "$VMHOST" "$USERNAME" "$USERPASS"

send "echo '$USERPASS' | sudo -S mount -t 9p -o trans=virtio,version=9p2000.L,ro ergon /mnt && echo SHARE''_OK\r"
expect {
  timeout { puts "\n!! share failed"; exit 1 }
  "SHARE_OK" {}
}

send "echo '$USERPASS' | sudo -S bash /mnt/test/arch-vm/guest-desktop.sh\r"
expect {
  timeout { puts "\n!! the desktop test did not finish"; exit 1 }
  -re {DESKTOP_RESULT=[0-9]+} {}
}

send "echo '$USERPASS' | sudo -S poweroff\r"
expect eof
EXPECT

docker run --rm --device /dev/kvm $GPU_DOCKER \
  -v "$WORK:/w" -v "$ERGON:/ergon:ro" \
  "$IMAGE" expect -f /w/session.exp 2>&1 | tee "$WORK/session.log" \
  | grep -E '^(   ok|   FAIL|--- |!! )' || true

say "result"
if ! grep -q 'DESKTOP_RESULT=' "$WORK/session.log"; then
  echo "   FAIL the compositor test never completed — see $WORK/session.log" >&2
  exit 1
fi
n=$(grep -o 'DESKTOP_RESULT=[0-9]*' "$WORK/session.log" | tail -1 | cut -d= -f2)
if [ "$n" -eq 0 ]; then
  echo "   ok   the compositor starts, binds register, waybar maps"
else
  echo "   $n check(s) failed — see $WORK/session.log"
fi
exit $(( n > 0 ))
