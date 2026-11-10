#!/usr/bin/env bash
# ergon-secureboot (ERGON-124) against a fixture ESP and a stub sbctl: nothing
# happens for a machine that never opted in, enrolling refuses outside setup
# mode, and every file the firmware or systemd-boot loads is signed before the
# keys go in. Whether OVMF then boots it is the VM's.
#
#   ./bin/test-secureboot.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { printf '   ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '   FAIL %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
SB="$REPO/bin/ergon-secureboot"; E="$T/esp"

mkdir -p "$T/stub" "$T/sbstub" "$T/sb" "$T/root/etc/kernel" "$T/root/usr/lib/systemd/boot/efi" \
  "$E/EFI/systemd" "$E/EFI/BOOT" "$E/EFI/ergon/snap/k1" "$E/EFI/GRUB" "$E/loader/entries"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$T/stub/sudo"
echo 'root=/dev/mapper/cryptroot rw' > "$T/root/etc/kernel/cmdline"
for f in EFI/systemd/systemd-bootx64.efi EFI/BOOT/BOOTX64.EFI EFI/ergon/linux.efi EFI/ergon/snap/k1/vmlinuz EFI/GRUB/grubx64.efi; do
  echo bin > "$E/$f"
done
echo bin > "$T/root/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
echo false > "$T/sb/setup"; echo false > "$T/sb/on"
cat > "$T/sbstub/sbctl" <<EOF
#!/usr/bin/env bash
S="$T/sb"
case "\$1" in
status) printf '{"installed": %s, "setup_mode": %s, "secure_boot": %s}\n' \$([ -f \$S/keys ] && echo true || echo false) \$(cat \$S/setup) \$(cat \$S/on) ;;
create-keys) touch \$S/keys; echo create >> \$S/log ;;
sign) shift; out=""; [ "\$1" = -s ] && shift; [ "\$1" = -o ] && { out=\$2; shift 2; }
      f=\$1; [ -z "\$out" ] || { cp "\$f" "\$out"; f=\$out; }; echo SIGNED >> "\$f"; echo "sign \$f" >> \$S/log ;;
verify) find "$E" -type f \( -name '*.efi' -o -name '*.EFI' -o -name vmlinuz \) | while read -r f; do
          grep -q SIGNED "\$f" && echo "✓ \$f is signed" || echo "✗ \$f is not signed"; done ;;
enroll-keys) echo "enroll \$*" >> \$S/log; echo false > \$S/setup ;;
esac
EOF
chmod +x "$T/stub"/* "$T/sbstub/sbctl"
export PATH="$T/stub:$PATH" ERGON_ESP="$E" ERGON_BOOTROOT="$T/root"

echo "== a machine that never opted in"
out=$("$SB" sync 2>&1); rc=$?
check "sync does nothing and exits 0 without sbctl" bash -c '[ "$1" = 0 ] && [ -z "$2" ] && ! grep -rq SIGNED "$3"' _ "$rc" "$out" "$E"
export PATH="$T/sbstub:$PATH"
out=$("$SB" sync 2>&1); rc=$?
check "  and with sbctl but no keys" bash -c '[ "$1" = 0 ] && ! grep -rq SIGNED "$2" && [ ! -e "$3/log" ]' _ "$rc" "$E" "$T/sb"
check "status says it is not set up" bash -c '"$1" status | grep -q "not set up"' _ "$SB"

echo "== enable"
out=$("$SB" enable 2>&1); rc=$?
check "outside setup mode it refuses, and says how to get there" \
  bash -c '[ "$1" != 0 ] && grep -q "reboot --firmware-setup" <<<"$2" && grep -q "Reset to Setup Mode" <<<"$2"' _ "$rc" "$out"
check "  having made no keys and enrolled nothing" test ! -e "$T/sb/log"
echo true > "$T/sb/setup"
"$SB" enable > "$T/out" 2>&1; rc=$?
check "in setup mode it exits 0" test "$rc" = 0
check "  keys made" test -f "$T/sb/keys"
for f in EFI/systemd/systemd-bootx64.efi EFI/BOOT/BOOTX64.EFI EFI/ergon/linux.efi EFI/ergon/snap/k1/vmlinuz; do
  check "  $f signed" grep -q SIGNED "$E/$f"
done
check "  a signed systemd-boot for bootctl to install on updates" grep -q SIGNED "$T/root/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed"
check "  GRUB's binary is left alone, and does not block it" bash -c '! grep -q SIGNED "$1"' _ "$E/EFI/GRUB/grubx64.efi"
check "  Microsoft's keys enrolled too" grep -qx 'enroll enroll-keys --microsoft' "$T/sb/log"
check "  signed before enrolled" bash -c '[ "$(grep -n "^sign" "$1" | tail -1 | cut -d: -f1)" -lt "$(grep -n "^enroll" "$1" | cut -d: -f1)" ]' _ "$T/sb/log"
"$SB" status > "$T/out" 2>&1; rc=$?
check "status: enrolled but Secure Boot off is a warning" bash -c '[ "$1" != 0 ] && grep -q "off in the firmware" "$2"' _ "$rc" "$T/out"
echo true > "$T/sb/on"
"$SB" status > "$T/out" 2>&1; rc=$?
check "status: on, everything signed" bash -c '[ "$1" = 0 ] && grep -q "every boot file on the ESP is signed" "$2"' _ "$rc" "$T/out"

echo "== snapshot kernels copied after enabling are signed"
mkdir -p "$T/snaps/3/snapshot/boot"
echo k > "$T/snaps/3/snapshot/boot/vmlinuz-linux"; echo i > "$T/snaps/3/snapshot/boot/initramfs-linux.img"
echo '<snapshot><date>x</date></snapshot>' > "$T/snaps/3/info.xml"
ERGON_GUARD_SNAPDIR="$T/snaps" "$REPO/bin/ergon-boot-entries" sync >/dev/null 2>&1
k=$(sed -n 's|^linux *||p' "$E/loader/entries/ergon-snapshot-3.conf")
check "ergon-boot-entries signs the kernel it stages" bash -c '[ -n "$2" ] && grep -q SIGNED "$1$2"' _ "$E" "$k"

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
