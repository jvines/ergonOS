#!/usr/bin/env bash
# ergon-drive: which drives may be wiped, and that nothing else is touched (ERGON-94).
#
#   ./bin/test-drive.sh
#
# Seconds, no root, no real disk. lsblk comes from test/drive/lsblk.json (an
# internal NVMe system disk, a mounted stick, a stick with an open LUKS
# container, an eligible stick, a closed LUKS stick, an internal HDD, a USB disk
# holding swap). sudo and every tool it would run are one stub that logs.
#
# COVERS: the eligible/refused split and its reasons; a refused or internal
# device is refused even when named; the wipe needs the typed model or size and
# a wrong answer writes nothing; the command order for exFAT, ext4 and LUKS2;
# the passphrase reaches cryptsetup by stdin, not by argument.
# DOES NOT COVER: real mkfs, sfdisk or cryptsetup behaviour, or lsblk's real JSON.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

mkdir -p "$T/stub"
cat > "$T/stub/sudo" <<'S'
#!/usr/bin/env bash
in=""; [ -t 0 ] || in=$(cat | tr '\n' ';')
printf '%s | stdin=%s\n' "$*" "$in" >> "$S_LOG"
S
chmod +x "$T/stub/sudo"
for t in udevadm; do printf '#!/bin/sh\nexit 0\n' > "$T/stub/$t"; chmod +x "$T/stub/$t"; done
export PATH="$T/stub:$PATH" ERGON_DRIVE_LSBLK="$REPO/test/drive/lsblk.json" S_LOG="$T/log" XDG_RUNTIME_DIR="$T"
D="$REPO/bin/ergon-drive"
: > "$T/log"

list=$("$D" list); why=$("$D" list --why)
check "the idle stick and the closed LUKS stick are offered" \
  bash -c 'grep -q "^/dev/sdc " <<<"$1" && grep -q "^/dev/sdd " <<<"$1"' _ "$list"
for d in nvme0n1 sda sdb sde sdf; do
  check "/dev/$d is not offered" bash -c '! grep -q "^/dev/$1 " <<<"$2"' _ "$d" "$list"
done
check "a mounted stick is refused with an unmount hint" grep -q "refused  /dev/sda.*unmount it first" <<<"$why"
check "an open LUKS container is refused" grep -q "refused  /dev/sdb.*open encrypted" <<<"$why"
check "swap on a USB disk is refused" grep -q "refused  /dev/sdf.*SWAP" <<<"$why"
check "the system disk and internal HDD are not even listed as refused" bash -c '! grep -qE "nvme0n1|/dev/sde" <<<"$1"' _ "$why"

for d in /dev/nvme0n1 /dev/sda /dev/sdb /dev/sde /dev/nonesuch; do
  printf 'x\n' | "$D" format "$d" >/dev/null 2>&1
  check "format $d is refused" test $? -ne 0
done
check "refusals ran nothing" test ! -s "$T/log"

printf '1\nwrong\n' | "$D" format /dev/sdc >/dev/null 2>&1
check "a wrong confirmation exits non-zero" test $? -ne 0
check "a wrong confirmation wrote nothing" test ! -s "$T/log"
printf '1\ny\n' | "$D" format /dev/sdc >/dev/null 2>&1
check "'y' is not a confirmation" test ! -s "$T/log"

printf '1\nUltra Fit\n' | "$D" format /dev/sdc >/dev/null 2>&1
check "typing the model erases: wipefs, sfdisk, mkfs.exfat in order" \
  bash -c '[ "$(cut -d" " -f1-2 "$1" | tr "\n" ,)" = "wipefs --all,sfdisk --quiet,udevadm settle,mkfs.exfat -L," ]' _ "$T/log"
: > "$T/log"; printf '2\n14.9G\n' | "$D" format /dev/sdc >/dev/null 2>&1
check "typing the size erases as ext4" grep -q "^mkfs.ext4 -q -L ergon /dev/sdc1" "$T/log"
: > "$T/log"; printf '3\nhunter2\nhunter2\nUltra Fit\n' | "$D" format /dev/sdc >/dev/null 2>&1
check "LUKS2: format, open, mkfs on the mapper, close" \
  bash -c 'grep -q "luksFormat --type luks2" "$1" && grep -q "mkfs.ext4 -q -L ergon /dev/mapper/" "$1" && grep -q "cryptsetup close" "$1"' _ "$T/log"
check "the passphrase went by stdin and not by argument" \
  bash -c 'grep -q "luksFormat.*stdin=hunter2" "$1" && ! grep -q "hunter2.*|" "$1"' _ "$T/log"
: > "$T/log"; printf '3\nabc\nxyz\n' | "$D" format /dev/sdc >/dev/null 2>&1
check "mismatched passwords write nothing" test ! -s "$T/log"

: > "$T/log"; printf 'old\nnew\nnew\n' | "$D" passwd /dev/sdd1 >/dev/null 2>&1
check "passwd runs luksChangeKey on the closed container" grep -q "luksChangeKey.* /dev/sdd1 " "$T/log"
check "passwd passes key FILES, not the passwords" bash -c 'l=$(grep luksChangeKey "$1"); grep -qE "key-file [^ ]*/old /dev/sdd1 [^ ]*/new" <<<"$l" && ! grep -qE "stdin=.+" <<<"$l"' _ "$T/log"
: > "$T/log"; printf 'old\nnew\nnew\n' | "$D" passwd /dev/sdb1 >/dev/null 2>&1
check "passwd refuses an open container" test ! -s "$T/log"

echo; echo "   $PASS ok, $FAIL failed"; [ "$FAIL" = 0 ]
