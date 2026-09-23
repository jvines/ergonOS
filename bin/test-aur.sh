#!/usr/bin/env bash
# ERGON-29: what ergon-aur actually builds, and what it refuses to claim.
#
#   ./bin/test-aur.sh
#
# Seconds, no root, no network, no Arch, no VM. pacman, makepkg, vercmp, sudo
# and curl are stubs on PATH that log their argv; the AUR is a real local git
# repository, cloned the real way, so the pin assertions are about a commit git
# actually checked out rather than about a message saying it did.
#
# The one that matters: the makepkg stub records `git rev-parse HEAD` from the
# directory it was run in. A pin is otherwise only a claim -- this is the recipe
# that ran.
#
# COVERS: the plain form still refusing an installed package and --rebuild not;
# a pin building exactly that commit, a pin moved forward, a pin that names a
# commit the AUR does not have (fatal, rather than quietly building the previous
# one), a pin removed, and the same pin built twice in a row over the package
# the first build left behind; --outdated never turning a reply it did not get
# into "everything is current"; and the two ergon-doctor rows, which must answer
# from this machine, must not reach for the network to do it, and must not call
# a package nothing here ever built "ok".
#
# DOES NOT COVER: a real makepkg, a real pacman transaction, or the real AUR.
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

command -v jq >/dev/null \
  || { echo "jq is missing; it is in packages/pacman and ergon-aur --outdated parses with it"; exit 1; }

mkdir -p "$T/stub" "$T/log" "$T/ergon/packages" "$T/home"
: > "$T/pacdb"
: > "$T/foreign"

# --- stubs --------------------------------------------------------------------
cat > "$T/stub/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat > "$T/stub/pacman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/pacman"
case "$1" in
  -Qi) grep -qxF -- "$3" "$TEST_ROOT/pacdb" ;;
  -Qq) exit 1 ;;
  -Qm) [ -s "$TEST_ROOT/foreign" ] && cat "$TEST_ROOT/foreign" || exit 1 ;;
  -T)  exit 0 ;;
  *)   echo "pacman $*" >> "$TEST_ROOT/log/violations"; exit 1 ;;
esac
EOF
# Runs in the clone, so `git rev-parse HEAD` here is the commit the build saw.
cat > "$T/stub/makepkg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/makepkg"
[ "$1" != --printsrcinfo ] || exit 0
# The real makepkg REFUSES to overwrite a package it already built, and
# ergon-aur builds in a directory that is kept between builds: "A package has
# already been built. (use -f to overwrite)". A stub that always succeeds hides
# the one case the rebuild path is FOR -- same pinned commit, new libraries --
# so it is reproduced here rather than assumed away.
pkgfile="${PWD##*/}-$(sed -n 's/^pkgver=//p' PKGBUILD).pkg.tar.zst"
if [ -e "$pkgfile" ] && [[ " $* " != *" --force "* && " $* " != *" -f "* ]]; then
  echo "==> ERROR: A package has already been built. (use -f to overwrite)" >&2
  exit 1
fi
: > "$pkgfile"
git rev-parse HEAD >> "$TEST_ROOT/log/built-from"
EOF
# Enough of pacman's vercmp for a test: equal, else lexicographic.
cat > "$T/stub/vercmp" <<'EOF'
#!/usr/bin/env bash
[ "$1" != "$2" ] || { printf '0\n'; exit 0; }
[[ $1 < $2 ]] && printf -- '-1\n' || printf '1\n'
EOF
cat > "$T/stub/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/curl"
case "${STUB_RPC:-ok}" in
  unreachable) exit 7 ;;
  garbage)     printf 'not json at all' ;;
  error)       printf '{"type":"error","resultcount":0,"results":[],"error":"too many requests"}' ;;
  *)           cat "$TEST_ROOT/rpc.json" ;;
esac
EOF
chmod +x "$T/stub"/*

export TEST_ROOT=$T HOME=$T/home ERGON=$T/ergon PATH="$T/stub:$PATH"
export AURDIR=$T/aur XDG_STATE_HOME=$T/state
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$T/gitconfig
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
[ "$(command -v pacman)" = "$T/stub/pacman" ] && [ "$(command -v makepkg)" = "$T/stub/makepkg" ] \
  || { echo "stubs are not first on PATH; refusing to run anything"; exit 1; }

EA="$REPO/bin/ergon-aur"
L=$T/log
BUILT=$T/state/ergon/aur-builds

# --- the AUR: a real repository with two commits ------------------------------
SRC=$T/aur-remote/demo-git
git init -q -b master "$SRC"
printf 'pkgver=1\n' > "$SRC/PKGBUILD"; git -C "$SRC" add PKGBUILD; git -C "$SRC" commit -qm one
C1=$(git -C "$SRC" rev-parse HEAD)
printf 'pkgver=2\n' > "$SRC/PKGBUILD"; git -C "$SRC" commit -qam two
C2=$(git -C "$SRC" rev-parse HEAD)
# Pre-cloned, because the real clone URL is the AUR and this test has no network.
mkdir -p "$AURDIR"
git clone -q "$SRC" "$AURDIR/demo-git"

# packages/aur, rewritten per scenario. The comment continuation line is there
# on purpose: _pin must read the package's OWN line and nothing else.
pinfile() {  # pinfile [pin]
  { printf '# a comment with pin=%s in it, which is not a package line\n' "${1:-0000000}"
    printf 'demo-git%s\n' "${1:+          # pin=$1}"
  } > "$ERGON/packages/aur"
}
run() {  # run [VAR=VAL ...] -- [args...]
  rm -rf "$L"; mkdir -p "$L"
  local e=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do e+=("$1"); shift; done
  shift
  env "${e[@]}" "$EA" "$@" > "$T/out" 2>&1 < /dev/null
}
built_from() { head -1 "$L/built-from" 2>/dev/null; }

echo "== one package, three modes"
pinfile
run -- demo-git
check "an uninstalled package builds and installs" hasx "$L/makepkg" "-si --noconfirm --force"
echo demo-git >> "$T/pacdb"
run -- demo-git
check "an installed one does not" test ! -e "$L/makepkg"
check "  and says so" has "$T/out" "already installed"
run -- --rebuild demo-git
check "--rebuild builds it anyway — that is the whole point of the flag" hasx "$L/makepkg" "-si --noconfirm --force"
run -- ../etc/passwd
check "a path is not a package name" test "$?" -eq 2
check "  and nothing was built" test ! -e "$L/makepkg"
run -- --nonsense
check "an unknown option is refused rather than treated as a package" test "$?" -eq 2

echo "== a pin is the commit that actually builds"
pinfile "$C1"
run -- --rebuild demo-git
check "the reviewed commit is what makepkg saw, not the AUR's tip" test "$(built_from)" = "$C1"
pinfile "$C2"
run -- --rebuild demo-git
check "moving the pin forward moves the build" test "$(built_from)" = "$C2"
pinfile 0123456789abcdef0123456789abcdef01234567
run -- --rebuild demo-git
check "a pin the AUR does not have fails" test "$?" -ne 0
check "  and builds nothing — the previous pin is not a fallback" test ! -e "$L/makepkg"
check "  and names the file to fix" has "$T/out" "packages/aur pins demo-git"
pinfile
run -- --rebuild demo-git
check "removing a pin returns the build to the AUR's tip" test "$(built_from)" = "$C2"
check "  and leaves the clone on a branch, not detached" \
  test -n "$(git -C "$AURDIR/demo-git" symbolic-ref -q HEAD)"

echo "== what was built is recorded, so doctor can compare it to the pin"
check "the commit is recorded under the package name" hasx "$BUILT" "demo-git $C2"
pinfile "$C1"
run -- --rebuild demo-git
check "  and replaced, not appended, on the next build" test "$(wc -l < "$BUILT")" -eq 1
check "  with the commit that build used" hasx "$BUILT" "demo-git $C1"

echo "== a rebuild with the pin unchanged, which is what update calls"
# The rebuild that matters does not move the pin at all: -Syu bumped a soname
# and the same reviewed commit has to be built again against the new libraries.
# The clone still holds the previous build's package, so makepkg refuses unless
# it is forced -- and then `ergon update` prints "failed to rebuild", the
# ledger is never written, and checkrebuild names the package again forever.
pinfile "$C1"
run -- --rebuild demo-git
run -- --rebuild demo-git
check "the same commit builds again, over the package already sitting there" \
  test "$(built_from)" = "$C1"
check "  which takes makepkg's -f" has "$L/makepkg" "--force"
( cd "$AURDIR/demo-git" && TEST_ROOT=$T "$T/stub/makepkg" -si --noconfirm >/dev/null 2>&1 )
check "  and without it makepkg really does refuse, so the test above is not vacuous" \
  test "$?" -ne 0

echo "== --outdated builds nothing and invents nothing"
printf 'demo-git 1.0-1\n' > "$T/foreign"
printf '{"type":"multiinfo","resultcount":1,"results":[{"Name":"demo-git","Version":"2.0-1"}]}\n' > "$T/rpc.json"
pinfile
run -- --outdated
check "a newer AUR version is reported" has "$T/out" "1.0-1 → 2.0-1"
check "  with the command that acts on it" has "$T/out" "--rebuild demo-git"
check "  and nothing is built" test ! -e "$L/makepkg"
check "  the RPC call is bounded in time" has "$L/curl" "--max-time"
printf '{"type":"multiinfo","resultcount":1,"results":[{"Name":"demo-git","Version":"1.0-1"}]}\n' > "$T/rpc.json"
run -- --outdated
check "a current package is reported current" has "$T/out" "ok   demo-git 1.0-1"
printf '{"type":"multiinfo","resultcount":0,"results":[]}\n' > "$T/rpc.json"
run -- --outdated
check "a foreign package the AUR has never heard of is called out" has "$T/out" "is not in the AUR"

# The failure this mode exists to avoid: a silent exit 0 reading as "up to date".
for how in unreachable garbage error; do
  run STUB_RPC="$how" -- --outdated
  check "an RPC reply that is $how exits 2" test "$?" -eq 2
  check "  and says nothing was a statement about what is current" has "$T/out" "did not answer"
done

printf 'demo-git 1.0-1\n' > "$T/foreign"
printf '{"type":"multiinfo","resultcount":1,"results":[{"Name":"demo-git","Version":"9.9-1"}]}\n' > "$T/rpc.json"
pinfile "$C1"
run -- --outdated
check "a PINNED package is measured in commits, not in the packager's version" \
  has "$T/out" "1 newer PKGBUILD commit"
check "  and the AUR's version is not reported as an update to it" not has "$T/out" "9.9-1"
check "  with the log command that reviews them" has "$T/out" "log --oneline"
check "  and how to advance the pin afterwards" has "$T/out" "packages/aur"

echo "== doctor answers from this machine, and does not reach for the AUR"
# ergon-doctor sources this unconditionally, so the fixture has to carry it.
mkdir -p "$ERGON/lib"; cp "$REPO/lib/provision-inputs.sh" "$ERGON/lib/"
cat > "$T/stub/checkrebuild" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_REBUILD:-}" ] || exit 0
printf '%s\n' ${STUB_REBUILD}
EOF
chmod +x "$T/stub/checkrebuild"
doctor() {  # doctor <check> -> that check's JSON object
  "$REPO/bin/ergon-doctor" --json 2>/dev/null | grep -o "{\"name\":\"$1\"[^}]*}"
}
unset WAYLAND_DISPLAY
printf 'demo-git 1.0-1\n' > "$T/foreign"

rm -rf "$L"; mkdir -p "$L"
pinfile "$C1"; printf 'demo-git %s\n' "$C1" > "$BUILT"
check "a package built from the pinned commit is not flagged" has <(doctor aur-pins) '"state":"ok"'
check "  and doctor asked the AUR nothing to say so" test ! -e "$L/curl"
# The failure a pin exists to catch: the repo moved and this machine did not.
pinfile "$C2"
check "a pin advanced in the repo but not on the machine is a warning" has <(doctor aur-pins) '"state":"warn"'
check "  naming the package to rebuild" has <(doctor aur-pins) "demo-git"

# Every machine provisioned before the pins existed has these packages installed
# and no record of building them -- and the plain form of ergon-aur returns
# early for an installed package, so re-provisioning never fills that in. Called
# "ok", a whole fleet would have read as compliant on the strength of nobody
# having looked.
pinfile "$C1"; rm -f "$BUILT"
check "a pinned package with no build recorded here is not called ok" \
  has <(doctor aur-pins) '"state":"warn"'
check "  and is reported as unknown, not as a mismatch nobody found" \
  has <(doctor aur-pins) "never built here"
printf 'other-git 1.0-1\n' > "$T/foreign"
check "a pin for a package this machine does not install is not its row to answer" \
  test -z "$(doctor aur-pins)"
printf 'demo-git 1.0-1\n' > "$T/foreign"

export STUB_REBUILD=foreign/demo-git
check "a foreign package linked against a library that is gone is a warning" has <(doctor aur) '"state":"warn"'
check "  naming it, with the command that fixes it" has <(doctor aur) "ergon aur --rebuild"
export STUB_REBUILD=extra/vim
check "a REPO package needing a rebuild is not reported as ours" has <(doctor aur) '"state":"ok"'
unset STUB_REBUILD

echo
check "no stub saw a command it did not expect" test ! -e "$L/violations"
printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
