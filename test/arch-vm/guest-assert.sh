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

# It booted at all, which means: GRUB installed, a UEFI boot entry exists, the
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
# design: GRUB always emits it, and ergon-rollback restores by replacing the
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
# NOT a content check. At install time there are zero snapshots, so grub-btrfs
# writes a header-only (or absent) file and asserting it is non-empty fails for
# the wrong reason. What matters here is that the generator ran and the daemon
# that regenerates it is armed; whether the menu actually lists a snapshot is
# proven by the rollback rehearsal, which creates one.
check "grub-btrfsd is enabled"       'systemctl is-enabled grub-btrfsd'
check "grub-btrfs hook is present"   '[ -x /etc/grub.d/41_snapshots-btrfs ]'
check "snap-pac installed"           'pacman -Q snap-pac'

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
check "UEFI boot entry exists"       'efibootmgr | grep -qi grub'
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
