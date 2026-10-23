#!/usr/bin/env bash
# Runs INSIDE the booted, installed system. Everything here is a claim that the
# container-based loopback test structurally cannot make, because it never boots.
set -uo pipefail
P=0; F=0
ok()   { printf '   ok   %s\n' "$*"; P=$((P+1)); }
bad()  { printf '   FAIL %s\n' "$*"; F=$((F+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "--- booted system assertions ---"
# Print the cmdline unconditionally. The rootflags assertion failed once
# with no way to see WHAT was on it -- /proc/cmdline never reaches the
# console otherwise, and the cause had to be inferred.
echo "   cmdline: $(cat /proc/cmdline)"
echo "   default subvol: $(btrfs subvolume get-default / 2>/dev/null)"

# It booted at all, which means: systemd-boot installed, a UEFI boot entry exists, the
# initramfs unlocked LUKS with the typed passphrase, and root mounted.
check "root is the LUKS mapper"      'findmnt -no SOURCE / | grep -q "/dev/mapper/cryptroot"'
check "root is btrfs"                '[ "$(findmnt -no FSTYPE /)" = btrfs ]'
check "hostname was set at install"  '[ "$(cat /etc/hostname)" = "$EXPECT_HOSTNAME" ]'

# THE one the fstab bug would have broken. If root is pinned to a subvolume in
# fstab, `snapper rollback` completes and changes nothing.
# `[ -r ... ] &&` in front of this one and the HOOKS one below: grep answers 1
# for "no such line" and 2 for "no such file", and the `!` turns BOTH into a
# pass -- so a missing or unreadable file satisfied the two assertions here that
# exist to prove what is NOT in one.
check "root fstab entry has no subvol" '[ -r /etc/fstab ] && ! grep -E "^[^#].*[[:space:]]/[[:space:]].*subvol" /etc/fstab'
check "/home still pins its subvol"    'grep -E "^[^#].*[[:space:]]/home[[:space:]].*subvol=/@home" /etc/fstab'

# The default subvolume must point at @. ergon-rollback resets it after replacing
# @, and a kernel that ignored rootflags would otherwise land somewhere else.
check "default subvolume is @"      'btrfs subvolume get-default / | grep -q "path @$"'
# rootflags=subvol=@ IS expected, and is load-bearing under the ergon-rollback
# design: /etc/kernel/cmdline carries it, and ergon-rollback restores by replacing the
# CONTENT of @ rather than by repointing the default. What must never happen
# is root being pinned to something that is not @ -- a leftover snapshot pin
# would mean a rollback boots the wrong tree.
check "rootflags, if set, pins @"  '! grep -q rootflags=subvol /proc/cmdline || grep -q "rootflags=subvol=@\\( \\|$\\)" /proc/cmdline'

# Swap and hibernate. The loopback test could create the file but never activate
# it, and never had a kernel cmdline to check.
check "swap is active"               'swapon --show=NAME --noheadings | grep -q swapfile'
check "resume= on the cmdline"       'grep -q "resume=/dev/mapper/cryptroot" /proc/cmdline'
check "resume_offset= on the cmdline" 'grep -q "resume_offset=" /proc/cmdline'
check "hibernate is available"       'grep -qw disk /sys/power/state'
check "swap is big enough for RAM"   '[ "$(awk "/SwapTotal/{print \$2}" /proc/meminfo)" -ge "$(awk "/MemTotal/{print \$2}" /proc/meminfo)" ]'

# ERGON-34: TRIM through dm-crypt. Provisioning has not run yet, so the cmdline
# is all a fresh install has -- and discard=async is the point: btrfs picks it by
# itself at mount, and only when the mapper takes discards (measured).
check "rd.luks.options=discard on the cmdline" 'grep -q "rd.luks.options=discard" /proc/cmdline'
check "cryptroot passes discards (DISC-MAX)"   '[ "$(lsblk -bdnD -o DISC-MAX /dev/mapper/cryptroot | tr -d " ")" -gt 0 ]'
check "btrfs root mounted discard=async"       'findmnt -no OPTIONS / | grep -q "discard=async"'

# sd-encrypt, and NOT a duplicated resume hook.
check "initramfs uses sd-encrypt"    'grep -q "sd-encrypt" /etc/mkinitcpio.conf'
check "no legacy resume hook"        '[ -r /etc/mkinitcpio.conf ] && ! grep -E "^HOOKS=.*[( ]resume[ )]" /etc/mkinitcpio.conf'

# Snapshots: the reason this machine is btrfs at all.
check "snapper root config exists"   '[ -f /etc/snapper/configs/root ]'
check "snapper can list"             'snapper -c root list'
check "snap-pac installed"           'pacman -Q snap-pac'

# --- the boot chain (ERGON-123) ---------------------------------------------
# systemd-boot on an unencrypted ESP, a UKI per kernel, Plymouth asking for the
# passphrase from the initramfs, once. GRUB is not installed at all.
ESP=$(findmnt -no TARGET /efi 2>/dev/null)
check "the ESP is mounted at /efi"            '[ "$(findmnt -no FSTYPE /efi)" = vfat ]'
check "the ESP is not encrypted (a plain partition)" '! lsblk -no TYPE "$(findmnt -no SOURCE /efi)" | grep -q crypt'
check "systemd-boot is installed on the ESP"  'bootctl is-installed'
check "booted by systemd-boot"                'grep -q "Product: systemd-boot" <<<"$(bootctl status 2>/dev/null)"'
check "no GRUB package"                       '! pacman -Q grub'
echo "   efibootmgr: $(efibootmgr 2>&1 | grep -E "^Boot(Current|Order|0)" | tr "\n" " ")"
check "UEFI boot entry is systemd-boot"       'grep -qi "Linux Boot Manager" <<<"$(efibootmgr)"'
for k in linux linux-lts; do
  check "UKI for $k on the ESP"               "[ -s $ESP/EFI/ergon/$k.efi ]"
  check "  and an entry for it"               "[ -n \"\$(ls $ESP/loader/entries/ergon-$k.conf $ESP/loader/entries/ergon-$k+*.conf 2>/dev/null)\" ]"
done
check "this boot came from a UKI (stub set LoaderImageIdentifier/StubInfo)" '[ -n "$(ls /sys/firmware/efi/efivars/StubInfo-* 2>/dev/null)" ]'
check "the cmdline is /etc/kernel/cmdline"    '[ "$(tr -s " " < /etc/kernel/cmdline | sed "s/ $//")" = "$(tr -s " " < /proc/cmdline | sed "s/ $//")" ]'
check "the UKI carries that cmdline"          'objdump -s -j .cmdline $ESP/EFI/ergon/linux.efi >/dev/null 2>&1 || grep -aq "rd.luks.name=" $ESP/EFI/ergon/linux.efi'
check "Plymouth is in the initramfs"          'grep -q "usr/bin/plymouthd" <<<"$(lsinitcpio /boot/initramfs-linux.img)"'
check "  with the ergon theme"                'grep -q "plymouth/themes/ergon/ergon.script" <<<"$(lsinitcpio /boot/initramfs-linux.img)"'
check "  and splash on the cmdline"           'grep -qw splash /proc/cmdline'
check "Plymouth ran in this boot"             '[ -n "$(journalctl -b -u plymouth-start.service -o cat --no-pager 2>/dev/null)" ]'
check "the passphrase went through Plymouth"  'grep -qi "Forward Password Requests to Plymouth" <<<"$(journalctl -b -o cat --no-pager)"'
check "the boot splash is the ergon theme"    'grep -qx "Theme=ergon" /etc/plymouth/plymouthd.conf'
# Asked once: nothing before the kernel decrypts (the ESP is plain), there is
# no keyfile for a second unlock, and the volume has one keyslot.
check "no keyfile in /etc/cryptsetup-keys.d"  '[ -z "$(ls /etc/cryptsetup-keys.d 2>/dev/null)" ]'
check "no keyfile in the initramfs"           '! grep -q cryptsetup-keys <<<"$(lsinitcpio /boot/initramfs-linux.img)"'
check "one LUKS keyslot (the passphrase)"     '[ "$(cryptsetup luksDump "$(cryptsetup status cryptroot | awk "\$1 == \"device:\" { print \$2 }")" | grep -cE "^  [0-9]+: luks2")" = 1 ]'
check "the LUKS key is Argon2id"              'cryptsetup luksDump "$(cryptsetup status cryptroot | awk "\$1 == \"device:\" { print \$2 }")" | grep -q "PBKDF:.*argon2id"'
# Snapshot entries: written by ergon-boot-entries whenever /.snapshots changes.
# No snapshots exist yet at install; that the menu lists one and that it boots
# is proven by the rollback rehearsal, which makes one and boots it.
check "ergon-boot-entries.path is enabled"    'systemctl is-enabled ergon-boot-entries.path'
check "  and watching"                        'systemctl is-active ergon-boot-entries.path'
check "systemd-boot-update keeps the loader current" 'systemctl is-enabled systemd-boot-update.service'
check "the installer recorded AUTOLOGIN"      'grep -qx "AUTOLOGIN=[01]" /etc/ergon/install.env'

# Both kernels, so a bad one is a menu selection rather than a live USB.
check "linux kernel present"         '[ -f /boot/vmlinuz-linux ]'
check "linux-lts kernel present"     '[ -f /boot/vmlinuz-linux-lts ]'
# ERGON-26: `ergon update` asks pacman who owns the RUNNING kernel's modules,
# and reports a reboot when nobody does. This machine boots linux-lts, which is
# exactly the case the version compare it replaced got wrong: `uname -r` against
# `pacman -Q linux` never matches here, so every run claimed a reboot was due.
# A stub can only answer from a fixture; whether the path is the one pacman
# owns on a real Arch install is a question only this VM can settle.
check "pacman owns the running kernel's modules" 'pacman -Qo "/usr/lib/modules/$(uname -r)/vmlinuz"'

check "booted in UEFI mode"          '[ -d /sys/firmware/efi ]'

# The repo has to BE here, because provisioning is the next thing that runs and
# the ISO has no key to clone a private remote with. arch-bootstrap.sh copies
# the checkout it ran from; before that, the closing message told you to clone
# a placeholder, and no fresh machine could follow it.
U=$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)
R="/home/$U/ergonOS"
check "the repo was copied in"       "[ -d '$R' ]"
# Executable, not merely present: a 644 provision-arch.sh is the failure that
# already cost a VM run, which is why ergon-lint checks modes now.
check "provision-arch.sh is runnable" "[ -x '$R/bin/provision-arch.sh' ]"
check "the ergon commands came too"  "[ -x '$R/bin/ergon-bundle' ]"
# Owned by the user, or everything that writes into the tree needs sudo.
check "the copy belongs to the user" "[ \"\$(stat -c %U '$R')\" = \"$U\" ]"

echo "--- $P passed, $F failed ---"
echo "ASSERT_RESULT=$F"
