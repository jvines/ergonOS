#!/usr/bin/env bash
# The systemd-boot half of ERGON-123 that needs no VM: what ergon-boot-entries
# writes to the ESP for a set of snapshots, and how ergon-boot-guard reads and
# moves the boot counter in the main entry's name.
#
#   ./bin/test-boot-entries.sh
#
# Against fixtures: an ESP directory, a /.snapshots tree, a root with
# /etc/kernel/cmdline (ERGON_ESP, ERGON_GUARD_SNAPDIR, ERGON_BOOTROOT). sudo
# and systemctl are stubbed. That the loader really boots these entries, and
# really renames the counter, is the VM suite's: test-arch-vm.sh phase 3 boots
# a snapshot entry, test-boot-guard.sh lets the counter run out.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { printf '   ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '   FAIL %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

mkdir -p "$T/stub" "$T/root/etc/kernel" "$T/esp/EFI/ergon" "$T/esp/loader/entries" "$T/snaps"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$T/stub/sudo"
# systemctl answers "active" for the default target, so `ok` marks the boot good.
printf '#!/usr/bin/env bash\ncase "$1" in get-default) echo graphical.target ;; is-active) echo active ;; esac\n' > "$T/stub/systemctl"
chmod +x "$T/stub"/*
export PATH="$T/stub:$PATH" ERGON_ESP="$T/esp" ERGON_GUARD_SNAPDIR="$T/snaps" ERGON_BOOTROOT="$T/root"
echo 'rd.luks.name=X=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet splash' > "$T/root/etc/kernel/cmdline"
echo uki > "$T/esp/EFI/ergon/linux.efi"; echo uki > "$T/esp/EFI/ergon/linux-lts.efi"

# Ten snapshots. 1-3 share one kernel build, 4-10 another: snapshots share the
# files by reflink and keep their timestamps, so equal stats are one build.
snap() {  # snap <n> <build>
  local b="$T/snaps/$1/snapshot/boot"; mkdir -p "$b"
  printf 'kernel %s\n' "$2" > "$b/vmlinuz-linux"; printf 'initramfs %s\n' "$2" > "$b/initramfs-linux.img"
  touch -d "2026-10-0$2 12:00" "$b/vmlinuz-linux" "$b/initramfs-linux.img"
  printf '<snapshot><date>2026-10-2%s 10:00:00</date><description>pacman -Syu %s</description></snapshot>\n' "$(( $1 % 10 ))" "$1" > "$T/snaps/$1/info.xml"
}
for n in 1 2 3; do snap "$n" 1; done
for n in 4 5 6 7 8 9 10; do snap "$n" 2; done

BE="$REPO/bin/ergon-boot-entries"; BG="$REPO/bin/ergon-boot-guard"
E="$T/esp/loader/entries"
"$BE" sync > "$T/out" 2>&1 || bad "sync failed: $(cat "$T/out")"

echo "== snapshot entries"
check "the main and the lts entry, naming their UKIs" \
  grep -qx 'uki      /EFI/ergon/linux.efi' "$E/ergon-linux.conf"
check "  linux-lts sorts last (sort-key ergon-9)" grep -qx 'sort-key ergon-9' "$E/ergon-linux-lts.conf"
check "the newest eight snapshots get entries (3..10)" \
  test "$(ls "$E"/ergon-snapshot-*.conf | wc -l)" = 8 -a -f "$E/ergon-snapshot-3.conf" -a ! -e "$E/ergon-snapshot-2.conf"
check "  each boots its own subvolume, with the rest of the cmdline kept" \
  grep -qx 'options  rd.luks.name=X=cryptroot root=/dev/mapper/cryptroot rw quiet splash rootflags=subvol=@snapshots/7/snapshot' "$E/ergon-snapshot-7.conf"
check "  and its title says when and why" grep -q '^title    ergonOS snapshot 7, 2026-10-27 10:00:00 (pacman -Syu 7)$' "$E/ergon-snapshot-7.conf"
check "two builds, so two kernel sets on the ESP" test "$(find "$T/esp/EFI/ergon/snap" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 2
k3=$(sed -n 's|^linux *||p' "$E/ergon-snapshot-3.conf"); k4=$(sed -n 's|^linux *||p' "$E/ergon-snapshot-4.conf")
check "  snapshot 3 boots build 1's kernel, 4 build 2's" \
  bash -c '[ "$(cat "$1$2")" = "kernel 1" ] && [ "$(cat "$1$3")" = "kernel 2" ]' _ "$T/esp" "$k3" "$k4"
check "no fallback entry while nothing is known-good" test ! -e "$E/ergon-fallback.conf"

before=$(find "$T/esp" -type f -newer "$T/out" | wc -l)
sleep 1; "$BE" sync >/dev/null 2>&1
check "a second sync rewrites nothing" test "$(find "$T/esp" -type f -newer "$T/out" | wc -l)" = "$before"

rm -rf "$T/snaps/10"; "$BE" sync >/dev/null 2>&1
check "a deleted snapshot loses its entry, and the window moves to 2..9" \
  test ! -e "$E/ergon-snapshot-10.conf" -a -f "$E/ergon-snapshot-2.conf"
rm -rf "$T/snaps"/{3,4,5,6,7,8,9}; "$BE" sync >/dev/null 2>&1
check "a build no entry uses any more leaves the ESP" test "$(find "$T/esp/EFI/ergon/snap" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 1
for n in 3 4 5 6 7 8 9 10; do snap "$n" 2; done; "$BE" sync >/dev/null 2>&1

echo "== the boot guard on systemd-boot"
"$BG" record 1 > "$T/out" 2>&1 || bad "record failed: $(cat "$T/out")"
check "record: the main entry carries the counter" test -f "$E/ergon-linux+2.conf" -a ! -e "$E/ergon-linux.conf"
check "  get tries reads it from the name" test "$("$BG" get tries)" = 2
check "  the known-good snapshot is on the ESP" test "$("$BG" get good)" = 1
check "  and has the fallback entry, though older than the window" \
  grep -qx 'options  rd.luks.name=X=cryptroot root=/dev/mapper/cryptroot rw quiet splash rootflags=subvol=@snapshots/1/snapshot' "$E/ergon-fallback.conf"
check "  sorted right after the main entry (sort-key ergon-2)" grep -qx 'sort-key ergon-2' "$E/ergon-fallback.conf"
"$BE" sync >/dev/null 2>&1
check "sync keeps the counter in the main entry's name" test -f "$E/ergon-linux+2.conf" -a ! -e "$E/ergon-linux.conf"
# What systemd-boot does on two boots that never come up.
mv "$E/ergon-linux+2.conf" "$E/ergon-linux+0-2.conf"
check "two failed boots: tries 0" test "$("$BG" get tries)" = 0
"$BG" ok > "$T/out" 2>&1
check "ok on a healthy boot re-arms the counter" test -f "$E/ergon-linux+2.conf" -a ! -e "$E/ergon-linux+0-2.conf"
check "  and records the newest snapshot as known-good" test "$("$BG" get good)" = 10
"$BG" disable > "$T/out" 2>&1
check "disable takes the counter off and drops the fallback" test -f "$E/ergon-linux.conf" -a ! -e "$E/ergon-fallback.conf"

echo "== a GRUB machine is left alone"
mv "$T/root/etc/kernel/cmdline" "$T/root/grub-was-here"; mkdir -p "$T/root/etc/default"; : > "$T/root/etc/default/grub"
out=$("$BE" sync 2>&1); rc=$?
check "ergon-boot-entries says GRUB and exits 0" bash -c '[ "$1" = 0 ] && grep -q GRUB <<<"$2"' _ "$rc" "$out"

echo "== the boot guard on GRUB (ERGON-126)"
# grub-mkconfig writes grub.cfg under umask 077, so it is root's alone, and
# provisioning runs the guard as the user. Here only the sudo stub can read it.
G="$T/root/boot/grub/grub.cfg"; mkdir -p "$T/root/boot/grub" "$T/root/etc/grub.d"
cat > "$T/stub/sudo" <<STUB
#!/usr/bin/env bash
chmod 600 "$G" 2>/dev/null; "\$@"; rc=\$?; chmod 000 "$G" 2>/dev/null; exit \$rc
STUB
cat > "$T/stub/grub-mkconfig" <<'STUB'
#!/usr/bin/env bash
for s in "$ERGON_BOOTROOT"/etc/grub.d/*; do [ -x "$s" ] && "$s"; done > "$2"; chmod 000 "$2"
STUB
printf '#!/usr/bin/env bash\ncase "$*" in *FSTYPE*) echo btrfs ;; *UUID*) echo 1234-ABCD ;; *) echo /@ ;; esac\n' > "$T/stub/findmnt"
printf '#!/usr/bin/env bash\nf=$1; shift; [ "$1" = create ] && : > "$f"; [ "$1" = set ] && echo "$2" >> "$f"; true\n' > "$T/stub/grub-editenv"
chmod +x "$T/stub"/*
export ERGON_GUARD_ESP_UUID=1234-ABCD ERGON_GUARD_ROOT_UUID=dead-beef ERGON_GUARD_BOOT=/nonexistent
"$BG" install > "$T/out" 2>&1; rc=$?
check "install exits 0 for a user who cannot read grub.cfg" test "$rc" = 0
check "  without the warning provisioning printed" bash -c '! grep -q "did not reach grub.cfg" "$1"' _ "$T/out"
check "  the fallback entry is in grub.cfg" sudo grep -q 'id ergon-fallback' "$G"
check "  the counter and the fallback scripts are installed" test -x "$T/root/etc/grub.d/09_ergon_boot_counter" -a -x "$T/root/etc/grub.d/99_ergon_boot_fallback"
check "  and the success unit" test -f "$T/root/etc/systemd/system/ergon-boot-ok.service"
check "status says the fallback entry is there" bash -c '"$1" status 2>&1 | grep -q "fallback entry is in grub.cfg"' _ "$BG"

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
