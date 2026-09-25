#!/usr/bin/env bash
# Resolve every bundle against the real package indexes, installing nothing.
#
#   ./bin/test-bundles-resolve.sh
#
# WHY IT EXISTS
# -------------
# test-bundles.sh stubs pacman, ergon-aur and pyfleet, and a stub installs
# anything. So until ERGON-60 no bundle had ever been resolved by anything: a
# package Arch renamed, a PyPI name that belongs to someone else, a bundle whose
# python conflicts with the base, a git pin to a commit that does not exist --
# every one of them passes that suite. The research code in the astronomy and
# inference bundles followed its default branch, and even pinned, nothing would
# have noticed a pin that does not install.
#
# WHAT IT ASKS
# ------------
#   python, git  `uv pip compile` of packages/python with each bundle's lines,
#                then with every bundle at once. pyfleet puts all of them into
#                ONE venv, so a bundle has to co-resolve with the base, and a
#                user may enable every bundle. Nothing is installed, but a git
#                line is fetched at its ref, so a pin that does not exist fails.
#   pacman       each name is a package in the sync DBs by its EXACT name, in a
#                throwaway Arch container. Not merely something pacman resolves:
#                extra/r provides some thirty r-* names and `pacman -S r-matrix`
#                installs r, but a provide never appears in `pacman -Qq`, so the
#                bundle ledger could never record it and remove never take it.
#                A group expands to its members, with the same result.
#   aur          each name is on the AUR by exact name, and is a package base,
#                because ergon-aur clones aur.archlinux.org/<name>.git.
#
# Needs the network, docker, uv, curl and jq, and can fail on PyPI, GitHub, the
# AUR or an Arch mirror rather than on the commit. What it resolved against is
# printed. ERGON=<tree> points it at another tree, which is how its negative
# controls were run: a scratch copy, never these bundles.
set -uo pipefail

ERGON="$(cd "${ERGON:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)"
B="$ERGON/packages/bundles"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ergon-bundle's _list: one entry per line, `#` to the end of it a comment.
# What is resolved here has to be exactly what an install would be handed.
lines() { [ ! -f "$1" ] || sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"; }

# --- python and git -----------------------------------------------------------

# Found the way test-science.sh finds it, for the same reason: the runner's
# PATH has no ~/.local/bin, and that is where checo's uv lives.
UV=""
for c in uv "$HOME/.local/bin/uv" /usr/bin/uv /usr/local/bin/uv; do
  if command -v "$c" >/dev/null 2>&1; then UV=$(command -v "$c"); break; fi
done
# The interpreter pyfleet builds its venv with, read out of pyfleet rather than
# written here a second time: moving it there must move it here.
PYVER=$(sed -n 's/^PYVER="\${PYFLEET_PYTHON:-\([0-9][0-9.]*\)}"$/\1/p' "$ERGON/bin/pyfleet" 2>/dev/null)
# Arch's glibc is newer than 2.40, so every wheel tagged up to that installs
# there. This is the newest manylinux uv can be asked for.
PLAT=x86_64-manylinux_2_40

# Each list under its own path in the repo, so a failure can say where every
# line it blames was declared.
L=$T/l
mkdir -p "$L/packages"
lines "$ERGON/packages/python" > "$L/packages/python"
for d in "$B"/*/; do
  b=$(basename "$d"); mkdir -p "$L/packages/bundles/$b"
  for f in python git; do lines "$d/$f" > "$L/packages/bundles/$b/$f"; done
done

# resolve <what> <file>...
# uv names the requirement a failure is about and never the file it came from,
# so each line's name is looked for in uv's message and reported by file. From
# $T, so no pyproject.toml or uv.toml up the tree changes the answer.
resolve() {
  local what=$1 f e n hit=0; shift
  cat "$@" > "$T/req.txt"
  if (cd "$T" && "$UV" pip compile --quiet --python-version "$PYVER" \
        --python-platform "$PLAT" req.txt) > "$T/out" 2> "$T/err"; then
    ok "$what: $(grep -c '^[A-Za-z0-9]' "$T/out") packages"
    return
  fi
  bad "$what: does not resolve"
  for f in "$@"; do
    while IFS= read -r e; do
      n=${e%% @ *}; n=${n%%[!A-Za-z0-9._-]*}; n=${n//[._]/-}
      if grep -qiwF -- "$n" "$T/err"; then printf '          %s: %s\n' "${f#"$L"/}" "$e"; hit=1; fi
    done < "$f"
  done
  [ "$hit" = 1 ] || printf '          uv names none of these lines, so it is about a dependency of one\n'
  sed 's/^/          | /' "$T/err" | head -20
}

echo "== python and git: packages/python with each bundle, then with all of them"
if [ -z "$UV" ]; then
  bad "no uv on PATH, in ~/.local/bin or in /usr/bin; nothing resolved"
elif [ -z "$PYVER" ]; then
  bad "could not read PYVER's default out of bin/pyfleet; its line changed shape"
else
  printf '   --   against %s, python %s as in bin/pyfleet, %s\n' "$("$UV" --version)" "$PYVER" "$PLAT"
  all=()
  for d in "$L"/packages/bundles/*; do
    [ -s "$d/python" ] || [ -s "$d/git" ] || continue
    resolve "$(basename "$d") with packages/python" "$L/packages/python" "$d/python" "$d/git"
    all+=("$d/python" "$d/git")
  done
  resolve "every bundle at once, into the one venv" "$L/packages/python" "${all[@]}"
fi

# --- pacman --------------------------------------------------------------------

# In the container, and printed as @@ lines for this side to read. A group is
# asked about before a provide, because -Sddp expands a group to its members.
INNER=$(cat <<'EOF'
err=$(pacman -Sy 2>&1) || { echo "pacman -Sy failed: $(printf '%s' "$err" | tail -1)"; exit 0; }
pacman -Sl | awk '{ print $2 }' | sort -u > /tmp/names
dbs=""; for db in /var/lib/pacman/sync/*.db; do dbs+=", $(basename "$db") $(date -ur "$db" +%FT%TZ)"; done
echo "@@against $(pacman -Q pacman)$dbs, from $(sed -n 's|^Server = https*://\([^/]*\).*|\1|p' /etc/pacman.d/mirrorlist | head -1)"
for f in /b/*/pacman; do
  [ -f "$f" ] || continue
  b=${f%/pacman}; b=${b##*/}
  while IFS= read -r n; do
    if grep -qxF -- "$n" /tmp/names; then echo "@@ok $b $n"
    elif pacman -Sgq -- "$n" >/dev/null 2>&1; then echo "@@group $b $n"
    elif p=$(pacman -Sddp --print-format %r/%n -- "$n" 2>/dev/null); then echo "@@provide $b $n $(head -1 <<< "$p")"
    else echo "@@missing $b $n"; fi
  done < <(lines "$f")
done
echo "@@done"
EOF
)

echo "== pacman: every name is a package in the sync DBs, by its exact name"
if ! command -v docker >/dev/null; then
  bad "docker required; no pacman list checked"
else
  out=$(docker run --rm --label cl.jvines.owner=ergon-test-bundles-resolve -v "$B:/b:ro" \
          archlinux:latest bash -c "$(declare -f lines); $INNER" 2>&1) || true
  # The end marker, not the absence of failures: a container that died before
  # the loop reports no bad names, and that must not read as none existing.
  if ! grep -qx '@@done' <<< "$out"; then
    bad "the container did not get through the lists; last lines:"
    tail -5 <<< "$out" | sed 's/^/          | /'
  else
    sed -n 's/^@@against /   --   against /p' <<< "$out"
    while read -r tag b n p; do
      case $tag in
        @@group)   bad "$b/pacman: $n is a group, not a package. pacman -S installs its members, and the ledger records none of them under $n" ;;
        @@provide) bad "$b/pacman: $n is not a package; $p provides it. pacman -S would install ${p#*/}, a provide never shows in pacman -Qq, and the ledger could never record $n: name ${p#*/}" ;;
        @@missing) bad "$b/pacman: $n is not in the sync DBs at all" ;;
      esac
    done <<< "$out"
    for f in "$B"/*/pacman; do
      [ -f "$f" ] || continue
      b=${f%/pacman}; b=${b##*/}
      n=$(lines "$f" | wc -l)
      [ "$(grep -c "^@@ok $b " <<< "$out")" != "$n" ] || ok "$b/pacman: all $n are packages by that name"
    done
  fi
fi

# --- aur -----------------------------------------------------------------------

echo "== aur: every name is a package on the AUR, and a package base"
q=""
for f in "$B"/*/aur; do
  while IFS= read -r n; do q+="&arg[]=${n//+/%2B}"; done < <(lines "$f")
done
if [ -z "$q" ]; then
  printf '   --   no bundle lists an AUR package\n'
elif ! command -v curl >/dev/null || ! command -v jq >/dev/null; then
  bad "curl and jq required; no aur list checked"
else
  # -g: the [] in arg[] is a curl glob otherwise.
  reply=$(curl -fsS -g --max-time 30 "https://aur.archlinux.org/rpc/v5/info?${q#&}" 2>&1) || true
  if [ "$(jq -r '.type // empty' <<< "$reply" 2>/dev/null)" != multiinfo ]; then
    bad "the AUR did not answer, so nothing here is a statement about it: $(head -c 200 <<< "$reply")"
  else
    printf '   --   against aur.archlinux.org RPC v5, %s\n' "$(date -u +%FT%TZ)"
    have=$(jq -r '.results[] | "\(.Name) \(.PackageBase)"' <<< "$reply")
    for f in "$B"/*/aur; do
      b=${f%/aur}; b=${b##*/}
      while IFS= read -r n; do
        if ! awk -v n="$n" '$1 == n { f = 1 } END { exit !f }' <<< "$have"; then
          bad "$b/aur: $n is not on the AUR"
        elif ! awk -v n="$n" '$2 == n { f = 1 } END { exit !f }' <<< "$have"; then
          bad "$b/aur: $n is on the AUR only inside another package base, and ergon-aur clones aur.archlinux.org/$n.git"
        else
          ok "$b/aur: $n"
        fi
      done < <(lines "$f")
    done
  fi
fi

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
