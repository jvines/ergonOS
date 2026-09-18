#!/usr/bin/env bash
# Partition, encrypt and pacstrap a new Arch box, from the live ISO.
#
#   ./arch-bootstrap.sh /dev/nvme0n1
#
# This is the half that CANNOT be redone later: disk layout, encryption and the
# btrfs subvolume tree. Everything after it — packages, docker, tailscale, the
# agent CLIs, the desktop — is provision-arch.sh, which is re-runnable.
# Same split as Debian: provision makes a usable machine, this makes a bootable
# one.
#
# DESTROYS THE TARGET DISK. It asks first, by name and size, and refuses to run
# anywhere but the Arch ISO.
#
# The point of the whole layout is the snapshot rollback: snap-pac takes a
# snapshot before every pacman transaction, and grub-btrfs puts those snapshots
# in the boot menu. A kernel or Hyprland update that will not boot is then a
# boot-menu selection, not a live-USB evening. That is the entire reason this
# box is btrfs while the rest of the fleet is ext4.
set -euo pipefail

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ok  %s\n' "$*"; }
warn() { printf '   !!  %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Tunables. The two that matter are SWAP_GIB and HOSTNAME.
# ---------------------------------------------------------------------------

# Hibernation on, and the swapfile is sized from THIS machine's RAM.
#
# It used to be a constant 100, which is 96 GB plus headroom -- correct for the
# reference laptop and absurd on a 16 GB one, where it would carve 100 GB out of
# the disk. Hibernate writes the whole of RAM, so swap must be at least RAM;
# +4 GiB of headroom covers the image not compressing and leaves room to
# actually swap. A btrfs swapfile can be recreated at any size later.
#
# Known platform issues, recorded so they are recognisable if you hit them, not
# as an argument: Framework #256 (S4 self-wake), #167 (e820 map shifts between
# boots), community thread 83040 (resume freeze after the LUKS passphrase).
# pm_async=0 is the community-tested workaround for the last one.
_ram_gib=$(awk '/^MemTotal:/ { printf "%d", ($2 / 1048576) + 1 }' /proc/meminfo)
SWAP_GIB="${SWAP_GIB:-$(( _ram_gib + 4 ))}"
HIBERNATE="${HIBERNATE:-1}"

HOSTNAME="${HOSTNAME_NEW:-}"          # prompted if empty
TIMEZONE="${TIMEZONE:-America/Santiago}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"
USERNAME="${USERNAME:-jayvains}"

# The wifi regulatory domain. Not a preference: transmit power and which
# channels exist are legally determined by where the machine is, and getting it
# wrong can pin you to 2.4 GHz. Derived from the timezone when not given, since
# that is the one location question every installer already asks.
REGDOM="${REGDOM:-}"

# The dm-crypt mapper name. Overridable only so bin/test-arch-bootstrap.sh can
# use a unique one: a killed test leaves /dev/mapper/cryptroot behind, and
# because dm devices are host-kernel objects that stale entry then blocks every
# later run. Real installs always use cryptroot -- the kernel cmdline says so.
CRYPTNAME="${CRYPTNAME:-cryptroot}"

# This script's own checkout. The installed system needs the repo in order to
# run provision-arch.sh, and it gets a copy of THIS tree rather than cloning --
# see "the repo" near the end for why a clone cannot work from the ISO.
ERGON="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)"

# Stock `linux`, not linux-lts. ArchWiki's Framework 13 AI 300 page is explicit
# that linux-lts lacks patches for these APUs. linux-lts is installed anyway,
# purely as an emergency boot entry — not a kernel to work in.
KERNELS="linux linux-lts"

# ---------------------------------------------------------------------------
# Guards
#
# TWO independent flags, because conflating them makes the VM test weaker than
# it needs to be:
#
#   ARCH_BOOTSTRAP_UNATTENDED=1
#       Take every answer from the environment instead of prompting
#       (HOSTNAME_NEW, LUKS_PASSPHRASE, USER_PASSWORD) and skip the type-the-
#       disk-name confirmation. Says nothing about where it is running.
#
#   ARCH_BOOTSTRAP_TEST=1
#       "I am in a container, not on real hardware." Relaxes the live-ISO and
#       UEFI guards, and refuses to swapon -- see the swap section for why that
#       one is not optional. Implies UNATTENDED.
#
# bin/test-arch-bootstrap.sh (loopback, container) sets TEST.
# bin/test-arch-vm.sh (qemu, real UEFI, real ISO) sets only UNATTENDED, so the
# guards, the swapon and the bootloader are all genuinely exercised.
# NEITHER is a convenience flag for a real install: the ISO guard is what stops
# this wiping a running machine.
# ---------------------------------------------------------------------------
# TEST is the stronger claim, so it implies UNATTENDED.
# An `if`, not `[ .. ] && VAR=1`: under `set -e` that one-liner returns non-zero
# whenever TEST is unset, which aborts the script on the ordinary path.
if [ "${ARCH_BOOTSTRAP_TEST:-0}" = 1 ]; then
  UNATTENDED=1
else
  UNATTENDED="${ARCH_BOOTSTRAP_UNATTENDED:-0}"
fi

DISK="${1:-}"
[ -n "$DISK" ] || { echo "usage: $0 /dev/nvme0n1" >&2; exit 1; }
[ -b "$DISK" ] || { echo "$DISK is not a block device" >&2; exit 1; }

# The ISO runs from a squashfs-backed overlay; a normal install does not. This
# is the cheapest reliable "am I on the live media" test.
if [ "${ARCH_BOOTSTRAP_TEST:-0}" != 1 ]; then
  grep -q 'arch' /proc/cmdline 2>/dev/null || [ -d /run/archiso ] || {
    echo "not running from the Arch ISO — refusing (this wipes a disk)" >&2; exit 1; }
  [ -d /sys/firmware/efi ] || { echo "not booted in UEFI mode" >&2; exit 1; }
fi

command -v pacstrap >/dev/null || { echo "pacstrap missing — not the Arch ISO?" >&2; exit 1; }

say "target disk"
lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINTS "$DISK"
echo
if [ "$UNATTENDED" = 1 ]; then
  warn "UNATTENDED — disk confirmation skipped"
else
  printf 'This ERASES %s completely. Type the disk name to confirm: ' "$DISK"
  read -r confirm
  [ "$confirm" = "$DISK" ] || { echo "mismatch — aborting"; exit 1; }
fi

if [ -z "$HOSTNAME" ]; then
  printf 'hostname for this machine: '
  read -r HOSTNAME
fi
[ -n "$HOSTNAME" ] || { echo "hostname required" >&2; exit 1; }

# Locale, timezone and keymap, the way every installer asks. The defaults are
# this author's, and a distro that silently gives a stranger America/Santiago
# and a US keymap is not one they will keep.
if [ "$UNATTENDED" != 1 ]; then
  printf 'timezone [%s]: ' "$TIMEZONE"; read -r _a; [ -n "$_a" ] && TIMEZONE="$_a"
  printf 'locale   [%s]: ' "$LOCALE";   read -r _a; [ -n "$_a" ] && LOCALE="$_a"
  printf 'keymap   [%s]: ' "$KEYMAP";   read -r _a; [ -n "$_a" ] && KEYMAP="$_a"
fi
[ -f "/usr/share/zoneinfo/$TIMEZONE" ] || { echo "no such timezone: $TIMEZONE" >&2; exit 1; }

# Derive the regulatory domain from the timezone's country rather than asking a
# second location question. zoneinfo carries the mapping already.
if [ -z "$REGDOM" ]; then
  REGDOM=$(awk -v tz="$TIMEZONE" '$1 !~ /^#/ && $3 == tz { print $1; exit }' \
             /usr/share/zoneinfo/zone.tab 2>/dev/null | cut -c1-2)
  [ -n "$REGDOM" ] || REGDOM=00   # 00 is the world-safe fallback domain
fi
ok "timezone $TIMEZONE, locale $LOCALE, keymap $KEYMAP, wifi regdom $REGDOM"

# ---------------------------------------------------------------------------
# Partition. ESP is 1 GiB — enough for GRUB plus two kernels and their
# initramfs, with room for a third when you are mid-upgrade.
# ---------------------------------------------------------------------------
say "partitioning $DISK"
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+1G   -t1:ef00 -c1:EFI  "$DISK"
sgdisk -n2:0:0     -t2:8309 -c2:LUKS "$DISK"
partprobe "$DISK"; sleep 2

# nvme0n1 -> nvme0n1p1 ; sda -> sda1. loop devices take the p-suffix too, which
# is how bin/test-arch-bootstrap.sh exercises this against a file.
case "$DISK" in
  *nvme*|*mmcblk*|*loop*) P1="${DISK}p1"; P2="${DISK}p2" ;;
  *)                      P1="${DISK}1";  P2="${DISK}2"  ;;
esac
ok "esp=$P1 luks=$P2"

# ---------------------------------------------------------------------------
# LUKS2. Passphrase only, deliberately.
#
# TPM auto-unlock (systemd-cryptenroll) is tempting and is a trap here for two
# reasons: without a PIN a stolen powered-off laptop decrypts itself, and PCR
# measurements change on every fwupd BIOS update AND on every root rollback —
# which are precisely the two events this machine is built to survive. Enrol a
# TPM keyslot later if you want, but the passphrase slot stays forever.
# ---------------------------------------------------------------------------
say "encrypting $P2"
if [ -n "${LUKS_PASSPHRASE:-}" ]; then
  # Only the test harness sets this. A real install types it, so the passphrase
  # never exists in a process list or a shell history.
  printf '%s' "$LUKS_PASSPHRASE" | cryptsetup luksFormat --type luks2 --batch-mode "$P2" -
  printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open "$P2" "$CRYPTNAME" -
else
  cryptsetup luksFormat --type luks2 "$P2"
  cryptsetup open "$P2" "$CRYPTNAME"
fi
ok "opened as /dev/mapper/$CRYPTNAME"

mkfs.fat -F32 -n EFI "$P1" >/dev/null
mkfs.btrfs -f -L arch /dev/mapper/$CRYPTNAME >/dev/null
ok "filesystems created"

# ---------------------------------------------------------------------------
# Subvolumes.
#
# The layout is dictated by one btrfs fact: SNAPSHOTS ARE NOT RECURSIVE. A
# nested subvolume shows up as an empty directory inside the snapshot. So
# anything that must SURVIVE a root rollback has to be its own subvolume —
# notably the logs from the boot that failed, and the .pkg.tar.zst files you
# need in order to fix it offline.
#
# Deliberately NOT separate:
#   /usr           — rolling it back with / is the whole point
#   /var/lib/pacman— must roll back WITH root, or the package database
#                    disagrees with what is actually installed
# ---------------------------------------------------------------------------
say "creating subvolumes"
mount /dev/mapper/$CRYPTNAME /mnt
for sv in @ @home @snapshots @var_log @var_cache_pacman_pkg @var_lib_docker @swap; do
  btrfs subvolume create "/mnt/$sv" >/dev/null
  ok "$sv"
done

# Point the filesystem's DEFAULT SUBVOLUME at @.
#
# This is the other half of the rollback story and it was missing. Stripping
# subvol= out of fstab stops fstab overriding the default -- but if no default
# is ever SET, there is nothing to override and snapper refuses outright:
#
#     Cannot detect ambit since default subvolume is unknown.
#     This can happen if the system was not set up for rollback.
#
# `snapper rollback` works by repointing this. Without it the whole btrfs layout
# is decoration. Found by bin/test-arch-vm.sh actually running the rollback.
SUBVOLID_AT=$(btrfs subvolume list "/mnt" 2>/dev/null | awk '$NF == "@" { print $2 }')
[ -n "$SUBVOLID_AT" ] || { echo "could not find the subvolid of @" >&2; exit 1; }
btrfs subvolume set-default "$SUBVOLID_AT" "/mnt"
btrfs subvolume get-default "/mnt" | grep -q "path @$" \
  || { echo "default subvolume did not take" >&2; exit 1; }
ok "default subvolume -> @ (id $SUBVOLID_AT)"
umount /mnt

# NOTE the root mount has NO subvol= option. That is intentional and load-
# bearing: `snapper rollback` works by flipping the btrfs DEFAULT SUBVOLUME
# pointer, which a pinned subvol= in fstab overrides — ArchWiki says the common
# @ layout is "intended not to be used with snapper rollback" for exactly this
# reason. genfstab copies whatever we mount with, so the root line it writes is
# stripped of subvol= further down -- and the DEFAULT SUBVOLUME set above is
# what the booted kernel then follows.
OPTS="noatime,compress=zstd:1,ssd,space_cache=v2"
# NO subvol= on the ROOT mount -- it resolves to @ via the default subvolume set
# above. This is not cosmetic. grub-mkconfig's 10_linux runs
# make_system_path_relative_to_its_root on / and, if it finds root on an
# explicitly-named subvolume, PREPENDS rootflags=subvol=<name> to the kernel
# command line on its own. That pins root exactly as hard as a subvol= in fstab,
# and no setting in /etc/default/grub turns it off. Mounting the default instead
# makes grub see no explicit subvolume and emit no rootflags at all.
mount -o "$OPTS" /dev/mapper/$CRYPTNAME /mnt
mkdir -p /mnt/{efi,home,.snapshots,var/log,var/cache/pacman/pkg,var/lib/docker,swap}
mount -o "$OPTS,subvol=@home"                /dev/mapper/$CRYPTNAME /mnt/home
mount -o "$OPTS,subvol=@snapshots"           /dev/mapper/$CRYPTNAME /mnt/.snapshots
mount -o "$OPTS,subvol=@var_log"             /dev/mapper/$CRYPTNAME /mnt/var/log
mount -o "$OPTS,subvol=@var_cache_pacman_pkg" /dev/mapper/$CRYPTNAME /mnt/var/cache/pacman/pkg
mount -o "$OPTS,subvol=@var_lib_docker"      /dev/mapper/$CRYPTNAME /mnt/var/lib/docker
mount -o "nodatacow,subvol=@swap"            /dev/mapper/$CRYPTNAME /mnt/swap
mount "$P1" /mnt/efi
ok "mounted"

# ---------------------------------------------------------------------------
# Swap. btrfs swapfiles must be NOCOW and fully preallocated, and must not live
# on a snapshotted subvolume — hence @swap, mounted nodatacow, excluded from
# snapper. `mkswapfile` does the NOCOW+preallocate dance correctly.
# ---------------------------------------------------------------------------
say "swap (${SWAP_GIB} GiB, hibernate=$HIBERNATE)"
btrfs filesystem mkswapfile --size "${SWAP_GIB}g" /mnt/swap/swapfile
if [ "${ARCH_BOOTSTRAP_TEST:-0}" = 1 ]; then
  # NEVER swapon under test. swapon(2) is not namespaced: inside a container it
  # registers with the HOST kernel, and once the loop device goes away the entry
  # cannot be removed -- swapoff resolves its argument to a live inode, and that
  # filesystem no longer exists. It survives until reboot, pointing at a device
  # that now errors on write. This cost checo a stale 1 GiB swap area.
  warn "TEST MODE — swapfile created but not activated"
else
  swapon /mnt/swap/swapfile
  ok "swapon"
fi

# ---------------------------------------------------------------------------
say "pacstrap"
# Microcode is chosen from the CPU, not assumed.
#
# This said `amd-ucode` because the reference machine is AMD. On an Intel host
# that installs a package the CPU cannot use and omits the one it needs, and
# nothing complains: the machine boots fine and simply never receives microcode
# updates. Silent, wrong, and exactly the class of thing a distro must not do to
# someone else's laptop.
#
# grub-mkconfig picks up whichever /boot/*-ucode.img exists, so nothing further
# is needed once the right package is installed.
case "$(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)" in
  GenuineIntel) UCODE=intel-ucode ;;
  AuthenticAMD) UCODE=amd-ucode ;;
  *)            UCODE=""; warn "unknown CPU vendor — installing no microcode" ;;
esac
[ -n "$UCODE" ] && ok "microcode: $UCODE"

pacstrap -K /mnt base base-devel $KERNELS linux-firmware $UCODE \
  btrfs-progs mkinitcpio grub efibootmgr grub-btrfs snapper snap-pac \
  networkmanager sudo zsh git vim inetutils
ok "base system installed"

genfstab -U /mnt >> /mnt/etc/fstab
# Strip subvol= AND subvolid= from the ROOT line only. Every other line keeps
# its subvol=.
#
# This is the line `snapper rollback` lives or dies on: rollback works by
# flipping the btrfs DEFAULT SUBVOLUME, which a pinned subvol= in fstab
# overrides, and subvolid= pins it harder still. ArchWiki says outright that the
# common @ layout is "intended not to be used with snapper rollback" for exactly
# this reason.
#
# Matching is on the MOUNTPOINT FIELD, not on a substring. The previous version
# looked for ",subvol=@" and silently never fired, because genfstab writes
# "subvol=/@" with a leading slash -- so every install would have booted with
# root pinned and rollback quietly inert. bin/test-arch-bootstrap.sh exists
# because of this bug.
awk 'BEGIN{FS="\t"; OFS="\t"}
     $2 ~ /^\/[[:space:]]*$/ { gsub(/,subvol(id)?=[^,]*/, "", $4) } 1' \
  /mnt/etc/fstab > /mnt/etc/fstab.new && mv /mnt/etc/fstab.new /mnt/etc/fstab

grep -qE '^[^#].*[[:space:]]/[[:space:]].*subvol' /mnt/etc/fstab \
  && { warn "root fstab entry still pins a subvolume — snapper rollback will not work"; exit 1; }
ok "fstab written (root entry free of subvol=, rollback can repoint the default)"

# ---------------------------------------------------------------------------
say "chroot configuration"
arch-chroot /mnt /bin/bash -euo pipefail <<CHROOT
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
sed -i 's/^#\($LOCALE\)/\1/' /etc/locale.gen
locale-gen >/dev/null
echo "LANG=$LOCALE"     > /etc/locale.conf
echo "KEYMAP=$KEYMAP"   > /etc/vconsole.conf
echo "$HOSTNAME"        > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# A keyfile, so the passphrase is typed ONCE per boot rather than twice.
#
# With /boot inside the LUKS volume, GRUB must unlock it to read the kernel --
# and then the initramfs unlocks the very same volume again, prompting a second
# time. Two long passphrases at every boot, on a machine that resumes from
# hibernate constantly.
#
# The fix is a random keyfile embedded in the initramfs. That is NOT a weakening
# of the encryption: /boot and therefore the initramfs live INSIDE the encrypted
# volume, so the keyfile is itself encrypted at rest. An attacker with the
# powered-off disk still has nothing. systemd-cryptsetup looks for
# /etc/cryptsetup-keys.d/<volume>.key automatically, so no cmdline change.
#
# Order matters: this must happen BEFORE mkinitcpio, or the keyfile is not in
# the image and the second prompt comes back.
mkdir -p /etc/cryptsetup-keys.d
dd if=/dev/urandom of=/etc/cryptsetup-keys.d/cryptroot.key bs=512 count=8 status=none
chmod 600 /etc/cryptsetup-keys.d/cryptroot.key
chmod 700 /etc/cryptsetup-keys.d

if [ -n "${LUKS_PASSPHRASE:-}" ]; then
  # luksAddKey <device> [<NEW key file>] -- the positional is the key being
  # ADDED, so the EXISTING passphrase has to arrive via --key-file. Passing it
  # as a trailing positional silently means something else entirely.
  printf '%s' "$LUKS_PASSPHRASE" | cryptsetup luksAddKey --key-file=- "$P2" /etc/cryptsetup-keys.d/cryptroot.key
else
  echo "enter the disk passphrase once more, to register the boot keyfile:"
  cryptsetup luksAddKey "$P2" /etc/cryptsetup-keys.d/cryptroot.key
fi

# FILES= is what actually puts it in the image. mkinitcpio's default is an empty
# FILES=() line, so rewrite rather than append.
sed -i 's|^FILES=.*|FILES=(/etc/cryptsetup-keys.d/cryptroot.key)|' /etc/mkinitcpio.conf
grep -q '^FILES=(/etc/cryptsetup-keys.d/cryptroot.key)' /etc/mkinitcpio.conf \
  || { echo "FILES= was not set in mkinitcpio.conf" >&2; exit 1; }

# systemd-based initramfs. NOTE there is deliberately no 'resume' hook: the
# systemd hook supersedes base/udev/resume and pulls in
# systemd-hibernate-resume itself. Listing both is the classic silent
# hibernation failure.
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

LUKS_UUID=\$(blkid -s UUID -o value "$P2")
# No rootflags= here, because grub-mkconfig adds its own rootflags=subvol=@
# unconditionally and a second copy would just be redundant. That pin is fine:
# bin/ergon-rollback restores by replacing the CONTENT of @, so @ is always the
# right thing to boot. (It is snapper's OWN rollback that the pin defeats --
# see ergon-rollback for why that command is not usable on this layout.)
CMDLINE="rd.luks.name=\$LUKS_UUID=cryptroot root=/dev/mapper/cryptroot rw"
if [ "$HIBERNATE" = 1 ]; then
  RESUME_OFFSET=\$(btrfs inspect-internal map-swapfile -r /swap/swapfile)
  CMDLINE="\$CMDLINE resume=/dev/mapper/cryptroot resume_offset=\$RESUME_OFFSET"
fi
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"\$CMDLINE\"|" /etc/default/grub

# GRUB must unlock the LUKS volume itself to read /boot from inside it.
#
# Match only an ACTIVE setting. Arch's stock /etc/default/grub already contains
# the line, commented out:
#
#     #GRUB_ENABLE_CRYPTODISK=y
#
# so a plain "grep -q GRUB_ENABLE_CRYPTODISK" matches the COMMENT, the append is
# skipped, and grub-install then refuses with "attempt to install to encrypted
# disk without cryptodisk enabled" -- after the disk is already wiped and
# pacstrapped. Rewrite the line whether it is commented or not.
if grep -qE '^[[:space:]]*#?[[:space:]]*GRUB_ENABLE_CRYPTODISK=' /etc/default/grub; then
  sed -i 's|^[[:space:]]*#\?[[:space:]]*GRUB_ENABLE_CRYPTODISK=.*|GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub
else
  echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
fi
# Fail here rather than inside grub-install, which reports it as a GRUB problem
# rather than as a config one.
grep -qE '^GRUB_ENABLE_CRYPTODISK=y' /etc/default/grub \
  || { echo "GRUB_ENABLE_CRYPTODISK is not active in /etc/default/grub" >&2; exit 1; }

grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Snapper. The 10/10/10/10 timeline defaults are tuned for a fileserver and will
# fill the disk on a laptop that also holds a ${SWAP_GIB}GiB swapfile.
# snapper needs to create /.snapshots itself, so hand it the mountpoint.
umount /.snapshots && rmdir /.snapshots
#
# --no-dbus is REQUIRED here and is not optional tidiness. snapper talks to
# snapperd over the system bus by default, and inside arch-chroot there is no
# system bus: the call fails with
#     Failure (org.freedesktop.DBus.Error.ServiceUnknown)
# which aborts the whole chroot block under "set -e", after the disk has been
# partitioned, encrypted and pacstrapped.
snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots >/dev/null
mkdir /.snapshots && mount -a
sed -i -e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' \
       -e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' \
       -e 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' \
       -e 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' \
       -e 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' \
       /etc/snapper/configs/root
systemctl enable snapper-timeline.timer snapper-cleanup.timer \
                 grub-btrfsd NetworkManager >/dev/null

useradd -m -G wheel -s /bin/zsh "$USERNAME"
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
# USER_PASSWORD is set only by the VM harness. A real install types it, so it
# never reaches a process list or a shell history -- same reasoning as
# LUKS_PASSPHRASE above.
if [ -n "${USER_PASSWORD:-}" ]; then
  printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | chpasswd
else
  echo "set a password for $USERNAME:"
  passwd "$USERNAME"
fi
passwd -l root
CHROOT

# --- the repo ---------------------------------------------------------------
# Whoever runs this is already holding the repo -- that is how this script came
# to be executing. So the installed system gets a copy of THAT tree, rather than
# the `git clone <dotfiles>` the closing message used to print: a literal
# placeholder, for a private remote, on a live ISO that has no SSH key. Nobody
# could follow it, and it was the first instruction a real install would hit.
#
# Copying also means this step needs no network at all, and that the machine is
# provisioned by exactly the tree that installed it, commit for commit.
say "the repo"
DEST="/home/$USERNAME/ergonOS"
REPO_AT=""
if [ -x "$ERGON/bin/provision-arch.sh" ]; then
  mkdir -p "/mnt$DEST"
  # -a preserves modes, which is not cosmetic: every bin/ergon-* has to stay
  # executable. A 644 command is invisible to `ergon` and dies under
  # provisioning -- that already cost a VM run once, and ergon-lint now fails
  # on it. .git comes along on purpose, so the machine can pull once a key
  # exists.
  cp -a "$ERGON/." "/mnt$DEST/"
  arch-chroot /mnt chown -R "$USERNAME:$USERNAME" "$DEST"
  [ -x "/mnt$DEST/bin/provision-arch.sh" ] \
    || { echo "the copied provision-arch.sh is not executable" >&2; exit 1; }
  REPO_AT="$DEST"
  # -c safe.directory: the checkout is usually not owned by whoever runs the
  # installer -- root on the ISO, or a 9p share carrying the host's uid -- and
  # git refuses to read a repo it considers someone else's. That turned the
  # commit this machine was installed from into "no git metadata", which is
  # precisely the fact worth keeping. Scoped to this one path, read-only.
  ok "copied this checkout to $DEST ($(git -c safe.directory="$ERGON" -C "$ERGON" rev-parse --short HEAD 2>/dev/null || echo 'no git metadata'))"
else
  warn "this is not a full ergonOS checkout, so the new system has no copy of the repo"
  warn "put one at $DEST before provisioning"
fi

say "done"
printf '\n  Reboot, remove the ISO, then:\n\n'
if [ -n "$REPO_AT" ]; then
  printf '    %s/bin/provision-arch.sh\n\n' "$REPO_AT"
  printf '  The repo is already on the machine -- this checkout was copied in, so\n'
  printf '  there is nothing to clone and no key to arrange first.\n'
else
  printf '    git clone https://github.com/jvines/ergonOS.git ~/ergonOS\n'
  printf '    ~/ergonOS/bin/provision-arch.sh\n'
fi
# Quoted heredoc: this block is pure prose and expands nothing, so a backtick
# or a $ in the instructions cannot become code. The unquoted form already
# turned an example 'cryptsetup open' into a command that would RUN at the end
# of a successful install.
cat <<'EOF'

  BEFORE trusting this machine, rehearse the rollback once:

    snapper -c root create -d "before break"
    sudo pacman -U <an old kernel from the Arch Linux Archive>
    reboot                      # confirm it fails

    # Pick a snapshot from the grub-btrfs submenu to get a shell, OR boot the
    # Arch ISO and run: cryptsetup open /dev/nvme0n1p2 cryptroot -- then:
    ergon-rollback --list
    ergon-rollback <number>
    reboot

  NOT 'snapper rollback'. That repoints the btrfs default subvolume, and
  grub-mkconfig unconditionally prepends rootflags=subvol=@ to the kernel
  command line, so the kernel mounts @ regardless of what the default says --
  the rollback reports success and changes nothing. ergon-rollback replaces the
  CONTENT of @ instead, which is what this layout actually supports.

  A rollback you have never exercised is not a rollback.
EOF
