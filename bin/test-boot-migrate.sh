#!/usr/bin/env bash
# ergon-boot-migrate (ERGON-125) against a fixture GRUB install: what it
# writes, that GRUB stays, that the layout flips only at the end, that a run
# broken half way is finished by the next one, and that the LUKS keyfile never
# reaches the ESP.
#
#   ./bin/test-boot-migrate.sh
#
# sudo, findmnt, lsblk, mkinitcpio, lsinitcpio, bootctl, efibootmgr and
# systemctl are stubs. Whether firmware boots the result is the VM's to show,
# and the VM installs systemd-boot directly: no GRUB machine is built there.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { printf '   ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '   FAIL %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
BM="$REPO/bin/ergon-boot-migrate"

mkdir -p "$T/stub"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/stub/$1"; chmod +x "$T/stub/$1"; }
stub sudo 'exec "$@"'
stub systemctl 'true'
stub findmnt 'case "$*" in *FSTYPE*) echo btrfs ;; *FSROOT*) echo "${FSROOT:-/@}" ;; *SOURCE*) echo /dev/vda1 ;; *UUID*) echo ROOT-UUID ;; esac'
stub lsblk 'case "$*" in *PKNAME*) echo vda ;; *PARTN*) echo 1 ;; esac'
# Builds what each preset names, and an image that carries FILES= as built.
stub mkinitcpio 'for p in "$ERGON_BOOTROOT"/etc/mkinitcpio.d/*.preset; do
  ( . "$p"; grep "^FILES=" "$ERGON_BOOTROOT/etc/mkinitcpio.conf" > "$ERGON_BOOTROOT$default_image"
    [ -z "${default_uki:-}" ] || { cat "$ERGON_BOOTROOT/etc/kernel/cmdline" "$ERGON_BOOTROOT$default_image" > "$default_uki"; } ); done'
stub lsinitcpio 'cat "$2"'
stub bootctl '[ -z "${BOOTCTL_FAIL:-}" ] || exit 1; mkdir -p "$ERGON_ESP/EFI/systemd"; echo sdboot > "$ERGON_ESP/EFI/systemd/systemd-bootx64.efi"'
stub efibootmgr 'case "$*" in *--create*) echo "$*" >> "$T/creates"; echo "Boot0001* Linux Boot Manager HD(1,GPT,abcd)" >> "$T/nvram" ;; esac; cat "$T/nvram"'
sed -i "s|\$T|$T|g" "$T/stub/efibootmgr"
export PATH="$T/stub:$PATH"

fixture() {  # a GRUB install as arch-bootstrap.sh made them before ERGON-123
  rm -rf "$T/root" "$T/esp" "$T/creates"; R="$T/root"
  mkdir -p "$R/etc/default" "$R/etc/mkinitcpio.d" "$R/boot" "$R/sys/firmware/efi" "$R/dev/mapper" "$T/esp/EFI/GRUB"
  echo 'GRUB_CMDLINE_LINUX_DEFAULT="rd.luks.name=LUKS-UUID=cryptroot rd.luks.options=discard root=/dev/mapper/cryptroot rw"' > "$R/etc/default/grub"
  echo 'GRUB_CMDLINE_LINUX=""' >> "$R/etc/default/grub"
  printf 'HOOKS=(base systemd autodetect block sd-encrypt filesystems)\nFILES=(/etc/cryptsetup-keys.d/cryptroot.key)\n' > "$R/etc/mkinitcpio.conf"
  printf "ALL_kver=\"/boot/vmlinuz-linux\"\nPRESETS=('default' 'fallback')\ndefault_image=\"/boot/initramfs-linux.img\"\n" > "$R/etc/mkinitcpio.d/linux.preset"
  echo kernel > "$R/boot/vmlinuz-linux"; echo FILES=old > "$R/boot/initramfs-linux.img"
  : > "$R/dev/mapper/cryptroot"; echo grub > "$T/esp/EFI/GRUB/grubx64.efi"
  echo "Boot0000* GRUB HD(1,GPT,abcd)/File(\\EFI\\GRUB\\grubx64.efi)" > "$T/nvram"
  export ERGON_BOOTROOT="$R" ERGON_ESP="$T/esp"
}
layout() { ( . "$REPO/lib/bootloader.sh"; ergon_boot_layout "$T/root" ); }
export -f layout; export REPO T

echo "== a GRUB install moves"
fixture
check "check: it can" bash -c '"$1" check | grep -q "can move to systemd-boot"' _ "$BM"
"$BM" run > "$T/out" 2>&1; rc=$?
check "run exits 0" test "$rc" = 0
check "the keyfile is out of FILES=, and the old conf is kept" \
  bash -c 'grep -qx "FILES=()" "$1/etc/mkinitcpio.conf" && grep -q cryptsetup-keys "$1/etc/mkinitcpio.conf.grub"' _ "$R"
check "the cmdline is GRUB's, pinned to @, no keyfile" \
  grep -qx 'rd.luks.name=LUKS-UUID=cryptroot rd.luks.options=discard root=/dev/mapper/cryptroot rw rootflags=subvol=@ quiet' "$R/etc/kernel/cmdline"
check "the preset builds a UKI on the ESP; GRUB's preset is kept" \
  bash -c 'grep -q "default_uki=\"$2/EFI/ergon/linux.efi\"" "$1/etc/mkinitcpio.d/linux.preset" && test -f "$1/etc/mkinitcpio.d/linux.preset.grub"' _ "$R" "$T/esp"
check "the UKI exists and holds no keyfile" bash -c 'test -s "$1" && ! grep -q cryptsetup-keys "$1"' _ "$T/esp/EFI/ergon/linux.efi"
check "the image GRUB boots is still in /boot" test -s "$R/boot/initramfs-linux.img"
check "an ergonOS entry, and GRUB as an entry of its own" \
  bash -c 'grep -q "uki      /EFI/ergon/linux.efi" "$1/ergon-linux.conf" && grep -q "efi      /EFI/GRUB/grubx64.efi" "$1/ergon-grub.conf"' _ "$T/esp/loader/entries"
check "a firmware entry for systemd-boot on the ESP's disk and partition" grep -q -- '--disk /dev/vda --part 1' "$T/creates"
check "GRUB's firmware entry is still there" grep -q 'GRUB' "$T/nvram"
check "the layout is now systemd-boot" test "$(layout)" = systemd-boot

cp -a "$T/esp" "$T/esp.before"; cp "$R/etc/kernel/cmdline" "$T/cmdline.before"
out=$("$BM" run 2>&1); rc=$?
check "a second run has nothing to do" bash -c '[ "$1" = 0 ] && grep -q "nothing to migrate" <<<"$2"' _ "$rc" "$out"
check "  and changes nothing" bash -c 'diff -r "$1/esp" "$1/esp.before" && diff "$1/cmdline.before" "$2/etc/kernel/cmdline"' _ "$T" "$R"

echo "== interrupted half way, then run again"
fixture
BOOTCTL_FAIL=1 "$BM" run > "$T/out" 2>&1; rc=$?
check "bootctl failing stops the run" test "$rc" != 0
check "  the layout is still GRUB, though the cmdline is written" bash -c '[ "$(layout)" = grub ] && [ -s "$1" ]' _ "$R/etc/kernel/cmdline"
check "  no firmware entry was added" test ! -e "$T/creates"
"$BM" run > "$T/out" 2>&1; rc=$?
check "the next run finishes it" bash -c '[ "$1" = 0 ] && [ "$(layout)" = systemd-boot ]' _ "$rc"
check "  with one firmware entry" test "$(wc -l < "$T/creates")" = 1

echo "== what it refuses"
fixture
FSROOT=/@snapshots/5/snapshot "$BM" run > "$T/out" 2>&1; rc=$?
check "a root that is not @: refused, nothing written" \
  bash -c '[ "$1" != 0 ] && [ ! -e "$2/etc/kernel/cmdline" ] && grep -q "not the @ subvolume" "$3"' _ "$rc" "$R" "$T/out"
FSROOT=/@snapshots/5/snapshot "$BM" run --auto > "$T/out" 2>&1; rc=$?
check "  provisioning's --auto skips it and exits 0" bash -c '[ "$1" = 0 ] && grep -q "keeps GRUB" "$2"' _ "$rc" "$T/out"
mkdir -p "$R/etc/mkinitcpio.conf.d"; echo 'FILES+=(/etc/cryptsetup-keys.d/x.key)' > "$R/etc/mkinitcpio.conf.d/k.conf"
"$BM" run > "$T/out" 2>&1; rc=$?
check "a keyfile in mkinitcpio.conf.d: refused, no UKI" bash -c '[ "$1" != 0 ] && [ ! -e "$2/EFI/ergon/linux.efi" ]' _ "$rc" "$T/esp"
rm -r "$R/etc/mkinitcpio.conf.d"
out=$(BOOT_MIGRATE=0 "$BM" run --auto 2>&1)
check "BOOT_MIGRATE=0 keeps GRUB" bash -c 'grep -q "BOOT_MIGRATE=0" <<<"$1" && [ ! -e "$2/etc/kernel/cmdline" ]' _ "$out" "$R"
rm "$R/etc/default/grub"; mkdir -p "$R/etc/kernel"; echo x > "$R/etc/kernel/cmdline"
out=$("$BM" check 2>&1)
check "a systemd-boot install: nothing to migrate" grep -q 'nothing to migrate' <<<"$out"

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
