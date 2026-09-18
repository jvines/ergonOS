#!/usr/bin/env bash
# Exercise bin/arch-bootstrap.sh against a loopback file, in a container.
#
#   ./test-arch-bootstrap.sh
#
# COVERS: everything up to the bootloader -- GPT layout, LUKS2, the btrfs
# subvolume tree, mount options, the fstab rewrite that keeps the root entry
# free of subvol= (without which snapper rollback is inert), swapfile creation,
# and a real pacstrap.
#
# DOES NOT COVER, and this is not a detail: this script DELETES the entire
# arch-chroot block before running it (see the sed below). Everything inside
# that block is therefore untested here --
#
#     mkinitcpio / the initramfs hooks     grub-install and GRUB_ENABLE_CRYPTODISK
#     the kernel cmdline and resume=       snapper create-config
#     user creation and passwords          grub-btrfs snapshot menu
#
# -- because none of it can work against a loopback file in a container: there
# is no firmware to install a bootloader into and no system bus for snapper.
#
# That excision is not hypothetical. THREE separate install-killing bugs lived
# in that block and passed this test green: a backtick in a comment that made
# the heredoc unparseable, a grep that matched Arch's commented-out
# GRUB_ENABLE_CRYPTODISK and so never enabled it, and a snapper call with no
# --no-dbus. All three were found by bin/test-arch-vm.sh, which boots the result
# in a UEFI VM. A green run here means the DISK is right, nothing more.
#
# Runs in `docker run --rm --privileged archlinux` so no loop device, device
# mapper entry or 12 GB scratch file ever appears on the host. --privileged is
# required for losetup and cryptsetup; that is the reason this is a container
# and not something you run on checo directly.
set -euo pipefail
IMG_SIZE="${IMG_SIZE:-12G}"
ERGON="$(cd "$(dirname "$0")/.." && pwd)"

echo "== testing arch-bootstrap.sh against a ${IMG_SIZE} loopback image"
docker run --rm --privileged -v /dev:/dev -v "$ERGON:/df:ro" archlinux:latest bash -euo pipefail -c "
pacman -Sy --noconfirm --needed arch-install-scripts gptfdisk btrfs-progs cryptsetup dosfstools util-linux parted >/dev/null 2>&1

# The host /dev is bind-mounted in. Docker otherwise gives a minimal devtmpfs
# with no loop nodes and, worse, no udev to create the PARTITION nodes after
# sgdisk runs -- so /dev/loopNp1 never appears and cryptsetup fails saying the
# device does not exist. The loop driver is the host kernel's
# either way; this only makes its device files visible. The loop device is
# detached in the cleanup below.
modprobe loop 2>/dev/null || true

# Pre-flight: a previous failed run leaves /dev/mapper/crypttest and a loop
# device attached to a file that no longer exists, and the next run then dies on
# \"Device cryptroot already exists\". Clean before starting, not only after.
cleanup() {
  umount -R /mnt 2>/dev/null || true
  cryptsetup close crypttest 2>/dev/null || true
  [ -n \"\${LOOP:-}\" ] && losetup -d \"\$LOOP\" 2>/dev/null || true
}
cleanup
trap cleanup EXIT

truncate -s $IMG_SIZE /tmp/disk.img
LOOP=\$(losetup --find --show --partscan /tmp/disk.img)
echo \"   loop device: \$LOOP\"

export CRYPTNAME=crypttest ARCH_BOOTSTRAP_TEST=1 HOSTNAME_NEW=testbox LUKS_PASSPHRASE=testpassphrase SWAP_GIB=1 HIBERNATE=0
# The chroot stage needs a tty for passwd; skip it here and assert on the disk
# layout, which is the part that cannot be changed after November.
# Delete the chroot invocation AND its heredoc body as one range. Replacing
# only the arch-chroot line leaves the heredoc body to run as top-level
# commands -- which is how this first failed: sed went looking for
# /etc/mkinitcpio.conf on the container instead of inside /mnt.
sed '/^arch-chroot \\/mnt/,/^CHROOT\$/d' /df/bin/arch-bootstrap.sh > /tmp/bootstrap.sh
echo '   (chroot stage removed for this test)'
bash /tmp/bootstrap.sh \"\$LOOP\" 2>&1 | sed 's/^/   /'

echo
echo '=== GENERATED FSTAB ==='
grep -v '^#' /mnt/etc/fstab | grep . | sed 's/^/   /'
echo
echo '=== ASSERTIONS ==='
fail=0
chk() { if eval \"\$2\" >/dev/null 2>&1; then echo \"   ok   \$1\"; else echo \"   FAIL \$1\"; fail=1; fi; }

chk 'ESP is vfat'              'blkid -s TYPE -o value \${LOOP}p1 | grep -qx vfat'
chk 'p2 is LUKS2'              'cryptsetup luksDump \${LOOP}p2 | grep -q \"Version:.*2\"'
chk 'btrfs on the mapper'      'blkid -s TYPE -o value /dev/mapper/crypttest | grep -qx btrfs'
for sv in @ @home @snapshots @var_log @var_cache_pacman_pkg @var_lib_docker @swap; do
  chk \"subvolume \$sv exists\"   \"btrfs subvolume list /mnt | grep -qw '\$sv'\"
done
chk 'root fstab: no subvol'    '! grep -E \"^[^#].*\\s/\\s.*subvol\" /mnt/etc/fstab'
chk '/home keeps its subvol'   'grep -qE \"\\s/home\\s.*subvol=/?@home\" /mnt/etc/fstab'
chk 'swapfile is NOCOW'        'lsattr /mnt/swap/swapfile 2>/dev/null | grep -q C'
chk 'swapfile sized right'     'test \$(stat -c%s /mnt/swap/swapfile) -eq \$((1024*1024*1024))'
chk 'pacstrap put a kernel in' 'test -f /mnt/boot/vmlinuz-linux'
chk 'lts kernel present too'   'test -f /mnt/boot/vmlinuz-linux-lts'
chk 'snapper installed'        'test -x /mnt/usr/bin/snapper'
chk 'grub-btrfs installed'     'test -d /mnt/usr/share/grub-btrfs -o -f /mnt/usr/lib/systemd/system/grub-btrfsd.service'
chk 'inetutils (hostname)'     'test -x /mnt/usr/bin/hostname'

echo
[ \$fail -eq 0 ] && echo '=== ALL ASSERTIONS PASSED ===' || { echo '=== FAILURES ABOVE ==='; exit 1; }
"
