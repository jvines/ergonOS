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
# An NFS export to rehearse the backup restore against, e.g.
# ERGON_TEST_NAS=192.168.0.85:/mnt/user/jvnas. Unset, only the local repository
# is exercised: the suite must not need the NAS to pass.
BACKUP_NAS="${ERGON_TEST_NAS:-}"
ERGON="$(cd "${ERGON:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

[ -f "$WORK/disk.qcow2" ] || {
  echo "no disk at $WORK/disk.qcow2 — run ./bin/test-arch-vm.sh --keep first" >&2; exit 1; }
# Same GPU auto-detection as bin/hypr-vm. With a render node the guest gets real
# GL and a dmabuf path, which is what makes the wallpaper and grim assertions
# mean anything; without one they are skips. Run this on a host with a GPU.
RENDERNODE="${HYPR_VM_RENDERNODE:-/dev/dri/renderD128}"
if [ -e "$RENDERNODE" ]; then
  GPU_DEV="virtio-gpu-gl-pci"; GPU_DISPLAY="egl-headless,gl=on,rendernode=$RENDERNODE"
  GPU_DOCKER="--device $RENDERNODE"; GPU_CONSOLE="-serial mon:stdio"
else
  GPU_DEV="virtio-gpu-pci"; GPU_DISPLAY="none"; GPU_DOCKER=""; GPU_CONSOLE="-nographic"
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

# -vga none is load-bearing. qemu adds a DEFAULT VGA adapter on top of whatever
# -device you ask for, so the guest got TWO cards: bochs-drm on card0 with no
# render node, and the virtio-gpu on card1 with one. aquamarine opens the first
# it finds, landed on the framebuffer, and every dmabuf import failed -- a
# desktop that draws perfectly and composites nothing, with no error naming a
# cause. Removing the default leaves the real GPU as card0.
spawn qemu-system-x86_64 \
  -accel kvm -cpu host -m $VM_RAM_MB -smp $VM_CPUS \
  -vga none \
  -global PIIX4_PM.disable_s3=1 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=/w/OVMF_VARS.fd \
  -drive file=/w/disk.qcow2,if=virtio,format=qcow2 \
  -device $GPU_DEV \
  -display $GPU_DISPLAY \
  -virtfs local,path=/ergon,mount_tag=ergon,security_model=none,readonly=on \
  -virtfs local,path=/w/out,mount_tag=out,security_model=none \
  -nic user,model=virtio-net-pci \
  $GPU_CONSOLE -no-reboot

unlock_and_login "$PASSPHRASE" "$VMHOST" "$USERNAME" "$USERPASS"

send "echo '$USERPASS' | sudo -S mount -t 9p -o trans=virtio,version=9p2000.L,ro ergon /mnt && echo SHARE''_OK\r"
expect {
  timeout { puts "\n!! share failed"; exit 1 }
  "SHARE_OK" {}
}

send "echo '$USERPASS' | sudo -S env BACKUP_NAS=$BACKUP_NAS bash /mnt/test/arch-vm/guest-desktop.sh\r"
# SILENCE, not a budget.
#
# "set timeout 1800" above plus a single expect makes 1800s the allowance for
# provisioning AND every check the desktop suite runs -- and expect does not
# restart that clock when output arrives, only when a pattern MATCHES. So the
# clock is really "how long may the whole thing take", which is a property of
# how busy the host is, not of whether the desktop works.
#
# It went red that way on 2026-09-24 with every single assertion passing. A
# loaded runner stretched the run from 27m45s to 41m11s -- ISO install alone
# went 2m18s -> 7m28s, and it contains none of this repo's code -- and the
# clock ran out one second after a passing check. The job log then says "the
# compositor test never completed", which reads as a broken desktop and is not.
#
# exp_continue restarts the wait, so what is measured is how long the guest has
# been QUIET. The longest legitimate quiet stretch in a green run is 905s --
# provisioning's pacman transaction says nothing at all while it works -- so
# 1800s of silence is still a generous hang detector, and a slow host now
# produces a slow build instead of a red one. The 90-minute cap is the backstop
# for the other shape of stuck: chatty and never finishing.
set started [clock seconds]
expect {
  -re {DESKTOP_RESULT=[0-9]+} {}
  -re {\r?\n} {
    if {[clock seconds] - \$started > 5400} {
      puts "\n!! the desktop test is still going after 90 minutes"; exit 1
    }
    exp_continue
  }
  timeout { puts "\n!! the desktop test went quiet for 1800s"; exit 1 }
}

send "echo '$USERPASS' | sudo -S poweroff\r"
expect eof
EXPECT

# The "   --   " lines are shown too: they are the checks the VM could not make,
# each with its evidence, and a skip that only lands in session.log reads in
# the job log as a pass.
docker run --rm --device /dev/kvm $GPU_DOCKER \
  -v "$WORK:/w" -v "$ERGON:/ergon:ro" \
  "$IMAGE" expect -f /w/session.exp 2>&1 | tee "$WORK/session.log" \
  | grep -E '^(   ok|   FAIL|   --   |--- |!! )' || true

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
