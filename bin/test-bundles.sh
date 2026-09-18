#!/usr/bin/env bash
# Exercise ergon-bundle against stub installers and a local git source.
#
#   ./bin/test-bundles.sh
#
# Seconds, no root, no network, no VM. sudo, pacman, ergon-aur and pyfleet are
# stubs that log their argv, so the assertions are about exactly what WOULD
# have run as root. The source is a git repository in a temp dir, fetched
# through the real `git clone` path.
#
# COVERS: meta read as data, list grammars, what a bundle directory may hold,
# consent, the copy and its .source, sync without the source, the ledger of
# what each bundle installed and remove taking only that, the keep-set
# (base system and other bundles), update, and built-in add/remove.
#
# DOES NOT COVER: real pacman, uv or ssh. That is test-hypr-session.sh.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
has()  { grep -qF -- "$2" "$1" 2>/dev/null; }
hasx() { grep -qxF -- "$2" "$1" 2>/dev/null; }
not()  { ! "$@"; }

# --- a throwaway ergonOS, and stubs in front of everything that runs as root --
E=$T/ergon
mkdir -p "$E/bin" "$E/packages" "$E/hosts" "$T/stub" "$T/log" "$T/home"
cp "$REPO/bin/ergon-bundle" "$E/bin/"
cp -r "$REPO/packages/bundles" "$REPO/packages/pacman" "$REPO/packages/aur" "$REPO/packages/python" "$E/packages/"
cp -r "$REPO/hardware" "$E/"
cp -r "$REPO/hosts/_template" "$E/hosts/"
mkdir -p "$E/hosts/testhost" && cp "$REPO/hosts/_template/host.env" "$E/hosts/testhost/"
: > "$T/pacdb"

cat > "$T/stub/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat > "$T/stub/hostname" <<'EOF'
#!/usr/bin/env bash
echo testhost
EOF
# Every name must come after `--`; anything else is a breach, not a pass.
cat > "$T/stub/pacman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/pacman"
[ "$*" != -Qq ] || { cat "$TEST_ROOT/pacdb"; exit 0; }   # the ledger's snapshot
op=$1; shift; names=(); seen=0
for a in "$@"; do
  if [ "$seen" = 1 ]; then names+=("$a"); elif [ "$a" = -- ]; then seen=1; fi
done
[ "$seen" = 1 ] || { echo "pacman $op without --" >> "$TEST_ROOT/violations"; exit 1; }
case $op in
  -S)   for p in "${names[@]}"; do grep -qxF -- "$p" "$TEST_ROOT/pacdb" || echo "$p" >> "$TEST_ROOT/pacdb"; done ;;
  -Rns) for p in "${names[@]}"; do grep -vxF -- "$p" "$TEST_ROOT/pacdb" > "$TEST_ROOT/pacdb.n"; mv "$TEST_ROOT/pacdb.n" "$TEST_ROOT/pacdb"; done ;;
  -Qi|-Qq) for p in "${names[@]}"; do grep -qxF -- "$p" "$TEST_ROOT/pacdb" || exit 1; done ;;
  *)    echo "pacman $op" >> "$TEST_ROOT/violations"; exit 1 ;;
esac
EOF
# A venv of empty dist-info directories, named the way pip names them.
cat > "$E/bin/pyfleet" <<'EOF'
#!/usr/bin/env bash
[ "$1" != path ] || { echo "$TEST_ROOT/venv"; exit 0; }
printf '%s\n' "$*" >> "$TEST_ROOT/log/pyfleet"
[ -z "${STUB_PYFAIL:-}" ] || exit 1
V=$TEST_ROOT/venv/lib/python3.13/site-packages; mkdir -p "$V"
op=$1; shift; [ "${1:-}" != -- ] || shift
for r in "$@"; do
  n=${r%% @ *}; n=${n%%[<>=!~[]*}; n=$(printf '%s' "$n" | tr 'A-Z.-' 'a-z__')
  case $op in add) mkdir -p "$V/$n-0.dist-info" ;; drop) rm -rf "$V/$n-0.dist-info" ;; esac
done
EOF
cat > "$E/bin/ergon-aur" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$*" "${ERGON_AUR_NO_REPLACE:-}" >> "$TEST_ROOT/log/aur"
EOF
chmod +x "$T/stub"/* "$E/bin"/*

export TEST_ROOT=$T HOME=$T/home XDG_CACHE_HOME=$T/cache XDG_STATE_HOME=$T/state ERGON=$E
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$T/gitconfig
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PATH="$T/stub:$PATH"
[ "$(command -v sudo)" = "$T/stub/sudo" ] && [ "$(command -v pacman)" = "$T/stub/pacman" ] \
  || { echo "stubs are not first on PATH; refusing to run anything"; exit 1; }

EB="$E/bin/ergon-bundle"
HE="$E/hosts/testhost/host.env"
COPY="$E/hosts/testhost/bundles"
run() { "$EB" "$@" > "$T/out" 2>&1; }
reset_logs() { rm -f "$T"/log/* "$T/violations"; }

# --- the source: one good bundle and one bad bundle per attack ----------------
P=$T/pub
mkdir -p "$P"/{demo,evil,inject,pyinject,nameless,link,script,notebooks}
printf 'DESCRIPTION="Demo tools"\nSIZE_MB=1\n' > "$P/demo/meta"
printf 'figlet\njulia   # also base: must survive remove\n' > "$P/demo/pacman"
printf 'tomli-w' > "$P/demo/python"        # no trailing newline, on purpose
printf 'demopkg @ git+https://example.org/me/demo.git\n' > "$P/demo/git"
printf 'DESCRIPTION="$(touch %s/pwned)"\n' "$T" > "$P/evil/meta"
printf 'figlet\n' > "$P/evil/pacman"
printf 'DESCRIPTION="x"\n' | tee "$P/inject/meta" "$P/pyinject/meta" "$P/nameless/meta" "$P/link/meta" "$P/script/meta" "$P/notebooks/meta" > /dev/null
printf 'figlet\n--overwrite=*\n' > "$P/inject/pacman"
printf -- '--index-url=https://evil.example/simple\n' > "$P/pyinject/python"
printf 'git+https://example.org/me/x.git\n' > "$P/nameless/git"
ln -s /etc/passwd "$P/link/pacman"
printf 'figlet\n' > "$P/script/pacman"; printf 'touch %s/pwned\n' "$T" > "$P/script/apply.sh"
git -C "$P" init -q -b main && git -C "$P" add -A && git -C "$P" commit -qm one && git -C "$P" tag v1

echo "== in-tree bundles"
for d in "$E"/packages/bundles/*/; do
  b=$(basename "$d")
  check "info $b parses" run info "$b"
done
check "list runs and executes nothing from meta" run list
cp -r "$P/evil" "$E/packages/bundles/evil"
run list; run info evil
check "a built-in meta with \$(...) is not run by list or info" test ! -e "$T/pwned"
rm -rf "$E/packages/bundles/evil"

echo "== bad sources are refused before anything installs"
reset_logs
for c in evil inject pyinject nameless link script; do
  run add --yes "$P//$c"
  check "$c refused" test "$?" -ne 0
done
check "nothing reached pacman or pyfleet" test ! -e "$T/log/pacman" -a ! -e "$T/log/pyfleet"
check "nothing was copied" test ! -e "$COPY"
check "no canary" test ! -e "$T/pwned"
run add --yes "$P//inject"; check "the refusal names the file and line" has "$T/out" "inject/pacman:2"
run add --yes "$P//notebooks"; check "a copy may not take a built-in's name" has "$T/out" "is a built-in bundle"
run add --yes "github:me/overlay"; check "a source must name its bundle" has "$T/out" "name the bundle"
run add --yes "http://example.org/x.git//demo"; check "http is refused" has "$T/out" "unauthenticated"
run add --yes "ext::sh -c touch% $T/pwned//demo"; check "remote helpers are refused" test ! -e "$T/pwned"
run info "$P//"; check "LOCATION// lists the bundles" has "$T/out" "demo"

echo "== add: consent, the copy, what ran"
reset_logs
run add "$P//demo" < /dev/null
check "no terminal and no --yes: refused" test "$?" -ne 0
check "  and nothing installed" test ! -e "$T/log/pacman"
run add --yes "$P//demo@v1"
check "add --yes succeeds" test "$?" -eq 0
check "pacman got exactly the list, after --" hasx "$T/log/pacman" "-S --needed --noconfirm -- figlet julia"
check "pyfleet got python then git, after --" hasx "$T/log/pyfleet" "add -- tomli-w demopkg @ git+https://example.org/me/demo.git"
check ".source records the commit" hasx "$COPY/demo/.source" "commit=$(git -C "$P" rev-parse v1)"
check ".source records the ref" hasx "$COPY/demo/.source" "ref=v1"
check "host.env BUNDLES stays built-ins only" hasx "$HE" 'BUNDLES=""'
check "the copy holds no script" test ! -e "$COPY/demo/apply.sh"
run list; check "list shows the copy and where it came from" has "$T/out" "from file://$P//demo@v1"
run add --yes "$P//demo@v1"; check "re-adding the same commit is a no-op" has "$T/out" "already added"

echo "== sync reinstalls from the copy, without the source"
reset_logs; : > "$T/pacdb"; mv "$P" "$T/pub.away"
run sync
check "sync succeeds with the source gone" test "$?" -eq 0
check "  and reinstalls the same list" hasx "$T/log/pacman" "-S --needed --noconfirm -- figlet julia"
mv "$T/pub.away" "$P"
printf '%s\n' '--evil' >> "$COPY/demo/pacman"; reset_logs
run sync; check "a copy edited into an invalid state is skipped" test ! -e "$T/log/pacman"
git -C "$P" show v1:demo/pacman > "$COPY/demo/pacman"

echo "== remove: the keep-set"
mkdir -p "$E/packages/bundles/other"
printf 'DESCRIPTION="shares tomli-w"\n' > "$E/packages/bundles/other/meta"
printf 'tomli_w>=1\n' > "$E/packages/bundles/other/python"
sed -i 's/^BUNDLES=.*/BUNDLES="other"/' "$HE"
reset_logs; printf 'figlet\njulia\n' > "$T/pacdb"
run remove demo
check "remove succeeds" test "$?" -eq 0
check "only figlet is uninstalled (julia is base)" hasx "$T/log/pacman" "-Rns --noconfirm -- figlet"
check "tomli-w is kept for the other bundle; demopkg dropped" hasx "$T/log/pyfleet" "drop -- demopkg"
check "the copy is gone" test ! -e "$COPY/demo"
rm -rf "$E/packages/bundles/other"; sed -i 's/^BUNDLES=.*/BUNDLES=""/' "$HE"

echo "== built-ins"
reset_logs; : > "$T/pacdb"
run add julia notebooks nosuch
check "an unknown name fails before anything installs" test ! -e "$T/log/pacman" -a ! -e "$T/log/pyfleet"
run add julia notebooks
check "add records both" hasx "$HE" 'BUNDLES="julia notebooks"'
run remove julia
check "remove julia never uninstalls the base julia" not has "$T/log/pacman" "-Rns"
check "  and un-records it" hasx "$HE" 'BUNDLES="notebooks"'
run remove notebooks; check "removing the last one leaves BUNDLES empty" hasx "$HE" 'BUNDLES=""'

echo "== update"
run add --yes "$P//demo"
printf 'cowsay\n' >> "$P/demo/pacman"; git -C "$P" commit -qam two
reset_logs
run update demo < /dev/null
check "update without a terminal or --yes changes nothing" hasx "$COPY/demo/.source" "commit=$(git -C "$P" rev-parse HEAD~1)"
check "  but shows the change" has "$T/out" "+ pacman cowsay"
run update --yes demo
check "update --yes moves the copy" hasx "$COPY/demo/.source" "commit=$(git -C "$P" rev-parse HEAD)"
check "  and installs the new list" hasx "$T/log/pacman" "-S --needed --noconfirm -- figlet julia cowsay"
run update demo; check "a second update is up to date" has "$T/out" "up to date"

echo "== the ledger: remove takes what the bundle installed, nothing else"
L="$T/state/ergon/bundle-ledger"
# By now: julia was already installed (base, kept by an earlier remove), and
# tomli-w already in the venv (kept for the other bundle) when demo was added.
check "records what demo installed" hasx "$L" "demo pacman figlet"
check "  and what update added" hasx "$L" "demo pacman cowsay"
check "  and git lines by distribution name" hasx "$L" "demo python demopkg"
check "never a package that was already there (julia)" not has "$L" "demo pacman julia"
check "  nor a python one (tomli-w)" not has "$L" "demo python tomli-w"
sed -i '/^cowsay$/d' "$P/demo/pacman"; git -C "$P" commit -qam three
run update --yes demo
check "a line dropped by update stays recorded" hasx "$L" "demo pacman cowsay"
reset_logs
run remove demo
check "remove uninstalls exactly the recorded packages" hasx "$T/log/pacman" "-Rns --noconfirm -- cowsay figlet"
check "  and drops only the recorded python" hasx "$T/log/pyfleet" "drop -- demopkg"
check "  and forgets them" not has "$L" "demo "

reset_logs
STUB_PYFAIL=1 run add --yes "$P//demo"
check "an install that fails halfway exits non-zero" test "$?" -ne 0
check "  but records what did install" hasx "$L" "demo pacman figlet"
rm -f "$L"; reset_logs
run remove demo
check "no record: nothing is uninstalled" not has "$T/log/pacman" "-Rns"
check "  and it says so" has "$T/out" "no record of what demo installed"

mkdir -p "$E/packages/bundles/other2"
printf 'DESCRIPTION="also figlet"\n' > "$E/packages/bundles/other2/meta"
printf 'figlet\n' > "$E/packages/bundles/other2/pacman"
sed -i '/^figlet$/d' "$T/pacdb"
run add --yes "$P//demo"; run add other2; reset_logs
run remove demo
check "a package another bundle needs is kept" not has "$T/log/pacman" "-Rns"
check "  and its record moves to that bundle" hasx "$L" "other2 pacman figlet"
run remove other2
check "so removing that bundle later takes it" hasx "$T/log/pacman" "-Rns --noconfirm -- figlet"
rm -rf "$E/packages/bundles/other2"

echo
check "no stub saw a name without --" test ! -e "$T/violations"
check "no canary anywhere" test ! -e "$T/pwned"
printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
