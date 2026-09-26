#!/usr/bin/env bash
# ERGON-34: what ergon-doctor says about TRIM through dm-crypt.
#
#   ./bin/test-trim.sh
#
# Seconds, no root, no VM and no device-mapper: lsblk is a stub on PATH that
# answers for a mapper and the partition and disk under it, and
# /dev/mapper/cryptroot exists only under ERGON_SYSROOT.
#
# COVERS: every state of the trim row -- a mapper passing discards, one dropping
# them over a disk that takes them (the bug), a disk that takes none (not
# dm-crypt's doing, so not a failure), lsblk answering nothing, and a machine
# with no LUKS root, which gets no row at all rather than a failure.
#
# DOES NOT COVER: rd.luks.options=discard reaching the initramfs, provisioning's
# refresh of a live root, or btrfs then choosing discard=async. Those need a
# booted machine: test/arch-vm/guest-assert.sh and guest-desktop.sh.
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
has()  { grep -qE -e "$2" "$1"; }

mkdir -p "$T/stub" "$T/ergon/lib" "$T/sysroot/dev/mapper" "$T/home"
# ergon-doctor sources this unconditionally, so the fixture has to carry it.
cp "$REPO/lib/provision-inputs.sh" "$T/ergon/lib/"
# The two questions doctor asks, in bytes: the mapper alone, and the mapper with
# what is under it, in the order lsblk -r prints them (measured).
cat > "$T/stub/lsblk" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" -bdnD "*)  printf '%s\n' "${STUB_MAPPER-0}" ;;
  *" -bnrsD "*) printf 'cryptroot %s\nnvme0n1p2 %s\nnvme0n1 %s\n' "${STUB_MAPPER-0}" "${STUB_DISK-2199023255040}" "${STUB_DISK-2199023255040}" ;;
esac
EOF
# Nothing else doctor asks may touch this machine: no root, and every unit
# question answered yes so no unrelated row can fail this suite.
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/stub/sudo"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/stub/systemctl"
chmod +x "$T/stub"/*
export PATH="$T/stub:$PATH" ERGON="$T/ergon" HOME="$T/home" ERGON_SYSROOT="$T/sysroot"
unset WAYLAND_DISPLAY
: > "$T/sysroot/dev/mapper/cryptroot"

doctor() {  # doctor <check> -> that check's JSON object
  "$REPO/bin/ergon-doctor" --json 2>/dev/null | grep -o "{\"name\":\"$1\"[^}]*}"
}

check "a mapper that passes discards is ok" \
  has <(STUB_MAPPER=4294966784 doctor trim) '"state":"ok".*passes discards'
check "a mapper dropping them over a disk that takes them is a failure" \
  has <(STUB_MAPPER=0 doctor trim) '"state":"fail"'
check "  naming what is never trimmed, and the fix" \
  has <(STUB_MAPPER=0 doctor trim) 'nvme0n1p2 is never trimmed.*provision-arch'
check "a disk that takes no discards itself is not dm-crypt's failure" \
  has <(STUB_MAPPER=0 STUB_DISK=0 doctor trim) '"state":"ok".*takes no discards'
check "lsblk answering nothing is a warning, not a verdict either way" \
  has <(STUB_MAPPER='' doctor trim) '"state":"warn"'
rm -f "$T/sysroot/dev/mapper/cryptroot"
check "no LUKS root: no row at all, so nothing can fail" \
  test -z "$(STUB_MAPPER=0 doctor trim)"

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
