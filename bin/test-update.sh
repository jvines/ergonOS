#!/usr/bin/env bash
# ERGON-26: exactly what `ergon update` would run as root, read off stub logs.
#
#   ./bin/test-update.sh
#
# Seconds, no root, no network, no Arch, no VM. sudo, pacman, systemd-run,
# systemd-inhibit, checkupdates, informant, pacdiff, paccache, fwupdmgr, pgrep,
# df and findmnt are stubs on PATH that log their argv; the kernel's module
# directory, the compositor's /proc/<pid>/exe and snapper's config live under
# ERGON_SYSROOT. So every assertion here is about a command line that WOULD
# have run as root, rather than about a message claiming it did.
#
# COVERS: the keyring refreshed in its own transaction immediately before -Su
# (and -Su still running when that fails, because a synced database left
# unfollowed IS the partial upgrade -- while a sync that FAILS stops the
# transaction, because -Su across repos synced at different times is one too);
# all of it inside ONE scope and ONE inhibitor; both wrappers probed rather
# than assumed; --yes meaning only --noconfirm -- it
# waives neither gate and never removes an orphan; nothing pending still
# reporting orphans, firmware, .pacnew and what needs restarting; a replaced
# kernel and a replaced compositor; --check writing nothing at all; and
# ERGON-29's rebuild step -- which foreign packages checkrebuild's output
# actually names, that --yes rebuilds them without asking while it still
# refuses to remove an orphan, and that --check rebuilds nothing.
#
# DOES NOT COVER: a real pacman transaction, real logind, or real firmware.
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
has()  { grep -qF -- "$2" "$1" 2>/dev/null; }
hasx() { grep -qxF -- "$2" "$1" 2>/dev/null; }
not()  { ! "$@"; }
# The gates refuse before pacman is reached at all, so the log may not exist --
# which is a pass, not a missing file to complain about on stderr.
noxact() { ! grep -qE -- '^-S[yu]' "$L/pacman" 2>/dev/null; }

mkdir -p "$T/stub" "$T/log"
EU="$T/ergon-update"
cp "$REPO/bin/ergon-update" "$EU"

# --- the machine ergon-update reads ------------------------------------------
S="$T/sysroot"
KREL=$(uname -r)
VMLINUZ="$S/usr/lib/modules/$KREL/vmlinuz"
SNAPPER="$S/etc/snapper/configs/root"
HYPREXE="$S/proc/1234/exe"
mkdir -p "$(dirname "$VMLINUZ")" "$(dirname "$SNAPPER")" "$(dirname "$HYPREXE")"
: > "$VMLINUZ"; : > "$SNAPPER"; ln -s /usr/bin/Hyprland "$HYPREXE"

# --- stubs in front of everything that runs as root or reads a real Arch ------
cat > "$T/stub/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/sudo"
exec "$@"
EOF
# The one stub with behaviour: the queries ergon-update makes must answer like
# pacman, or the script takes a different branch and the assertions below pass
# for the wrong reason. -Qo answers from the fixture, which is what proves the
# kernel check looks at the path it claims to.
cat > "$T/stub/pacman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/pacman"
case "$1" in
  -Q)
    [ "$2" != snap-pac ] || exit "${STUB_NO_SNAPPAC:-0}"
    [ "$2" != archlinux-keyring ] || { echo "archlinux-keyring 20260901-1"; exit 0; }
    exit 1 ;;
  -Qtdq)
    [ -n "${STUB_ORPHANS:-}" ] || exit 1
    printf '%s\n' ${STUB_ORPHANS} ;;
  -Qm)
    [ -n "${STUB_FOREIGN:-}" ] || exit 1
    for f in ${STUB_FOREIGN}; do echo "$f 1.0-1"; done ;;
  -Qo)
    [ -e "$2" ] || exit 1
    echo "$2 is owned by linux-lts 6.12.0-1" ;;
  -Sy) exit "${STUB_SYNC_FAIL:-0}" ;;
  -S)  exit "${STUB_KEYRING_FAIL:-0}" ;;
  -Su) exit "${STUB_PACMAN_FAIL:-0}" ;;
  -Rns) cat >> "$TEST_ROOT/log/removed" ;;
  *) echo "unexpected pacman $*" >> "$TEST_ROOT/log/violations"; exit 1 ;;
esac
EOF
# systemd-run and systemd-inhibit both run the command after their own options,
# so the stubs do too: dropping it would make an unwrapped run and a wrapped one
# indistinguishable in the pacman log.
cat > "$T/stub/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/systemd-run"
[ -z "${STUB_NO_SCOPE:-}" ] || { echo "Failed to start transient scope" >&2; exit 1; }
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
EOF
cat > "$T/stub/systemd-inhibit" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/systemd-inhibit"
[ -z "${STUB_NO_INHIBIT:-}" ] || { echo "Failed to inhibit: Access denied" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in --) shift; break ;; --*) shift ;; *) break ;; esac
done
exec "$@"
EOF
cat > "$T/stub/checkupdates" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_PENDING:-}" ] || exit 2
printf '%s\n' ${STUB_PENDING}
EOF
cat > "$T/stub/informant" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/informant"
[ "$1" != check ] || exit "${STUB_NEWS:-0}"
echo "2026-09-01  manual intervention required for glibc"
EOF
cat > "$T/stub/pacdiff" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/pacdiff"
[ -n "${STUB_PACNEW:-}" ] || exit 0
printf '%s\n' ${STUB_PACNEW}
EOF
cat > "$T/stub/pgrep" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_HYPR_PID:-}" ] || exit 1
echo "${STUB_HYPR_PID}"
EOF
# checkrebuild is the local half of the rebuild question -- it reads ELF
# headers, never the network -- so the stub answers from a variable and logs
# that it was asked at all.
cat > "$T/stub/checkrebuild" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/checkrebuild"
[ -n "${STUB_REBUILD:-}" ] || exit 0
printf '%s\n' ${STUB_REBUILD}
EOF
cat > "$T/stub/df" <<'EOF'
#!/usr/bin/env bash
printf 'Avail\n%sG\n' "${STUB_FREE_GIB:-100}"
EOF
cat > "$T/stub/findmnt" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_FSTYPE:-ext4}"
EOF
for s in paccache fwupdmgr; do
  cat > "$T/stub/$s" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$TEST_ROOT/log/$s"
EOF
done
chmod +x "$T/stub"/*

# ergon-update reaches its sibling by $ERGON/bin, the way ergon-bundle does, so
# the seam is a throwaway repo rather than PATH.
mkdir -p "$T/ergon/bin" "$T/ergon/lib"
# The REAL lib, not a stub: the scope and the inhibitor the assertions below
# pin down are built in there, and a throwaway tree missing it would only
# prove that a missing file makes the script exit.
cp "$REPO/lib/transaction.sh" "$T/ergon/lib/transaction.sh"
cat > "$T/ergon/bin/ergon-aur" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/aur"
EOF
chmod +x "$T/ergon/bin/ergon-aur"

export TEST_ROOT=$T ERGON_SYSROOT=$S ERGON=$T/ergon PATH="$T/stub:$PATH"
[ "$(command -v sudo)" = "$T/stub/sudo" ] && [ "$(command -v pacman)" = "$T/stub/pacman" ] \
  || { echo "stubs are not first on PATH; refusing to run anything"; exit 1; }

# `env`, not a VAR=... prefix: an assignment in front of a shell FUNCTION call
# stays set in the caller afterwards, so one scenario's STUB_NEWS would gate
# every scenario after it.
update() {  # update [VAR=VAL ...] -- [args...]
  rm -rf "$T/log"; mkdir -p "$T/log"
  local e=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do e+=("$1"); shift; done
  shift
  env "${e[@]}" "$EU" "$@" > "$T/out" 2>&1 < /dev/null
}
L=$T/log
# The whole transaction, as one argv line. The point of asserting it whole is
# that all three pacman calls are inside ONE scope and ONE inhibitor: a version
# that wrapped each separately would leave the machine unprotected between them.
WRAPPED="--scope --quiet --collect --description=ergon-update -- \
systemd-inhibit --what=sleep:shutdown:handle-lid-switch --who=ergon --why=system-upgrade -- \
bash -c pacman -Sy --noconfirm || exit 10; \
pacman -S --needed --noconfirm archlinux-keyring || true; pacman -Su --noconfirm"

echo "== the transaction"
update STUB_PENDING=vim -- --yes
check "an upgrade with everything in place succeeds" test "$?" -eq 0
check "the databases are synced on their own first" hasx "$L/pacman" "-Sy --noconfirm"
check "the keyring is refreshed in its own transaction" hasx "$L/pacman" "-S --needed --noconfirm archlinux-keyring"
check "  after that sync" test "$(sed -n '/^-Sy /{n;p}' "$L/pacman")" = "-S --needed --noconfirm archlinux-keyring"
check "  immediately followed by -Su" test "$(sed -n '/^-S --needed /{n;p}' "$L/pacman")" = "-Su --noconfirm"
check "  and never as a single -Syu" not grep -q -- '-Syu' "$L/pacman"
check "all of it runs inside one scope and one inhibitor" hasx "$L/systemd-run" "$WRAPPED"
check "  as root" has "$L/sudo" "systemd-run"
check "the inhibitor covers sleep, shutdown and the lid" has "$L/systemd-inhibit" "--what=sleep:shutdown:handle-lid-switch"
check "the cache is trimmed to three versions" hasx "$L/paccache" "-rk3"

update STUB_PENDING=vim STUB_KEYRING_FAIL=1 -- --yes
check "a keyring refresh that fails is not fatal" test "$?" -eq 0
check "  and -Su still runs, so no synced database is left with nothing behind it" \
  hasx "$L/pacman" "-Su --noconfirm"
# The other way round: a sync that fails leaves the repos disagreeing about when
# they were taken, and -Su against that mix is a cross-repo partial upgrade. It
# is the one failure here that must stop the transaction rather than continue.
update STUB_PENDING=vim STUB_SYNC_FAIL=1 -- --yes
check "a database sync that fails fails the command" test "$?" -ne 0
check "  and no upgrade is attempted against a half-synced database" \
  not grep -q -- '^-Su' "$L/pacman"
check "  and it says nothing was upgraded, rather than 'part way through'" \
  has "$T/out" "nothing was upgraded"
update STUB_PENDING=vim STUB_PACMAN_FAIL=1 -- --yes
check "a failed transaction fails the command" test "$?" -ne 0
check "  and says the machine may be part way through it" has "$T/out" "part way through"

echo "== the wrappers are probed, never assumed"
update STUB_PENDING=vim STUB_NO_SCOPE=1 STUB_NO_INHIBIT=1 -- --yes
check "neither available: the upgrade still runs" hasx "$L/pacman" "-Su --noconfirm"
check "  unwrapped" not has "$L/pacman" "systemd"
check "  and says the transaction is killable" has "$T/out" "could kill this upgrade"
check "  and that the lid is not safe" has "$T/out" "do not close the lid"

echo "== --yes means do not ask, not skip the checks"
rm -f "$SNAPPER"
update STUB_PENDING=vim -- --yes
check "no rollback point: refused even with --yes" test "$?" -ne 0
check "  and no transaction started" noxact
check "  and it names the flag that accepts the risk" has "$T/out" "--no-snapshot"
update STUB_PENDING=vim -- --yes --no-snapshot
check "--no-snapshot is how you accept it" hasx "$L/pacman" "-Su --noconfirm"
: > "$SNAPPER"
update STUB_PENDING=vim STUB_NEWS=1 -- --yes
check "unread news: refused even with --yes" test "$?" -ne 0
check "  and no transaction started" noxact
check "  and it shows the news" has "$T/out" "manual intervention"
update STUB_PENDING=vim STUB_FREE_GIB=2 -- --yes
check "a full / is refused before anything is written" test "$?" -ne 0
check "  and no transaction started" noxact

echo "== orphans are reported, and removed only by a person"
update STUB_PENDING=vim STUB_ORPHANS="libfoo libbar" -- --yes
check "orphans are listed" has "$T/out" "libfoo"
check "--yes does not remove them" not grep -q -- '-Rns' "$L/pacman"
check "  it prints the command instead" has "$T/out" "pacman -Qtdq | sudo pacman -Rns -"
if command -v script >/dev/null; then
  rm -rf "$L"; mkdir -p "$L"
  echo y | script -qec \
    "env STUB_PENDING=vim STUB_ORPHANS=libfoo $EU --yes" /dev/null >/dev/null 2>&1
  check "answering yes at a terminal removes them" hasx "$L/pacman" "-Rns -"
  check "  and exactly those, off stdin" hasx "$L/removed" "libfoo"
fi

echo "== nothing pending is not the end of the run"
rm -f "$VMLINUZ"
update -- --yes
check "an up-to-date machine succeeds" test "$?" -eq 0
check "  with no transaction" noxact
check "  but orphans still checked" has "$L/pacman" "-Qtdq"
check "  firmware still checked" has "$L/fwupdmgr" "get-updates"
check "  and a replaced kernel still reported" has "$T/out" "reboot when convenient"
: > "$VMLINUZ"
update -- --yes
check "a kernel that is still installed is not reported" not has "$T/out" "reboot when convenient"

echo "== what is still running from a package that is gone"
ln -sfn '/usr/bin/Hyprland (deleted)' "$HYPREXE"
update STUB_HYPR_PID=1234 -- --yes
check "a compositor replaced under the session asks for a log out" has "$T/out" "log out and back in"
ln -sfn /usr/bin/Hyprland "$HYPREXE"
update STUB_HYPR_PID=1234 -- --yes
check "  and one that was not, does not" not has "$T/out" "log out and back in"

echo "== .pacnew files"
update STUB_PACNEW="/etc/pacman.conf.pacnew /etc/fstab.pacsave" -- --yes
check "they are listed" has "$T/out" "/etc/pacman.conf.pacnew"
check "  from pacdiff -o" hasx "$L/pacdiff" "-o"
check "  with the command that merges them" has "$T/out" "sudo -E pacdiff"

echo "== --check"
update STUB_PENDING=vim STUB_ORPHANS=libfoo -- --check
check "--check exits 0" test "$?" -eq 0
check "  runs no transaction" noxact
check "  trims no cache and refreshes no firmware" test ! -e "$L/paccache" -a ! -e "$L/fwupdmgr"
check "  removes no orphan" not grep -q -- '-Rns' "$L/pacman"
check "  but still reports them" has "$T/out" "libfoo"
check "  and says nothing was applied" has "$T/out" "--check: nothing applied"

echo "== foreign packages left linked against a library that is gone"
# checkrebuild names repo packages too; those are pacman's problem. Only the
# foreign ones are nobody's, and mistaking one for the other would hand a repo
# package to a command that builds from the AUR.
update STUB_PENDING=vim STUB_FOREIGN="waybar-git claude-code" STUB_REBUILD="foreign/waybar-git extra/vim" -- --yes
check "checkrebuild is asked, after the transaction" test -e "$L/checkrebuild"
check "  the broken foreign package is named" has "$T/out" "waybar-git"
check "  and rebuilt through ergon-aur, one package at a time" hasx "$L/aur" "--rebuild waybar-git"
check "  a REPO package needing a rebuild is not ours to rebuild" not has "$L/aur" "vim"
check "  a foreign package that is fine is left alone" not has "$L/aur" "claude-code"
# The orphan prompt exists because -Rns cascades; a rebuild reinstalls the same
# package from the pinned PKGBUILD, so --yes proceeds. These two must not drift
# into each other.
check "  --yes rebuilds without asking" not has "$T/out" "rebuild them now?"
update STUB_PENDING=vim STUB_ORPHANS=libfoo STUB_FOREIGN=waybar-git STUB_REBUILD=foreign/waybar-git -- --yes
check "  while the same --yes still refuses to remove an orphan" not grep -q -- '-Rns' "$L/pacman"

update STUB_PENDING=vim STUB_FOREIGN="waybar-git" -- --yes
check "nothing broken: nothing is rebuilt" test ! -e "$L/aur"
check "  and it says so" has "$T/out" "no foreign package links a library that is gone"

update STUB_FOREIGN=waybar-git STUB_REBUILD=foreign/waybar-git -- --yes
check "a machine with nothing pending is still checked for rebuilds" hasx "$L/aur" "--rebuild waybar-git"

update STUB_PENDING=vim STUB_FOREIGN=waybar-git STUB_REBUILD=foreign/waybar-git -- --check
check "--check rebuilds nothing" test ! -e "$L/aur"
check "  and prints the command instead" has "$T/out" "ergon aur --rebuild"

update STUB_PENDING=vim STUB_FOREIGN=waybar-git STUB_REBUILD=foreign/waybar-git --
check "no --yes and no terminal: nothing is rebuilt unasked" test ! -e "$L/aur"

mv "$T/stub/checkrebuild" "$T/checkrebuild.off"
update STUB_PENDING=vim STUB_FOREIGN=waybar-git -- --yes
check "no rebuild-detector: it says nothing is watching, rather than 'none'" \
  has "$T/out" "rebuild-detector not installed"
mv "$T/checkrebuild.off" "$T/stub/checkrebuild"

echo
check "no stub saw a command it did not expect" test ! -e "$L/violations"
printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
