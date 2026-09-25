#!/usr/bin/env bash
# The science tooling in lib/, tested. The other seventeen suites test the
# desktop, the installer and the system; this is the first one that tests the
# part the README advertises.
#
#   ./bin/test-science.sh
#
# WHY IT EXISTS
# -------------
# lib/ is 1,546 lines and had no test of any kind -- no pytest, no test_*.py,
# no conftest.py -- while wallpaper/*.py, ten times its size, has a dedicated
# gate on every push. 92a3b4d is what that costs: ergon_figprov claimed SVG
# takes arbitrary metadata keys, matplotlib's SVG writer raises on anything
# outside Dublin Core, and every savefig to .svg from the shared python failed
# and lost the figure. The reader looked for tags no writer emits, so the two
# halves agreed with each other and with nothing else. Nothing in this repo
# saved a figure and read it back, which is the only check that could have seen
# it.
#
# THE ENVIRONMENT
# ---------------
# `uv run`, not the pyfleet venv. pyfleet is a real person's environment whose
# state a CI gate has no business depending on -- `pyfleet sync` may never have
# run on a given host, and a gate that goes red for that reason is a gate people
# learn to ignore. uv is in packages/pacman, builds this from scratch on a cold
# cache and reuses it after.
#
# Deliberately UNPINNED. matplotlib's metadata handling is exactly what broke
# here, so "a new matplotlib changed the rules" is a thing this suite should
# report rather than be insulated from. The version it ran against is printed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }

# Find uv without assuming PATH. On an ergonOS machine it is /usr/bin/uv --
# packages/pacman ships it -- but this also runs on the CI host, where the
# forgejo-runner service has PATH=/usr/local/sbin:...:/bin and nothing else, so
# a uv from the standalone installer in ~/.local/bin is invisible to it. That
# cost one red run: the precondition below fired and the suite never started.
UV=""
for c in uv "$HOME/.local/bin/uv" /usr/bin/uv /usr/local/bin/uv; do
  if command -v "$c" >/dev/null 2>&1; then UV=$(command -v "$c"); break; fi
done
[ -n "$UV" ] || {
  echo "test-science: no uv on PATH, in ~/.local/bin or in /usr/bin" >&2
  echo "              it is in packages/pacman; on a dev box, the installer" >&2
  exit 1
}

# Its own cache and its own home. The runner is in HOST mode, so $HOME belongs
# to a person; a test suite has no business writing to their uv cache or
# leaving a matplotlib font cache in their config.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export MPLCONFIGDIR="$T/mpl"

echo "== lib/, under uv"
run=$(cd "$REPO" && "$UV" run --quiet --no-project \
        --with matplotlib --with pytest \
        python -m pytest test/science -q --no-header -p no:cacheprovider 2>&1)
rc=$?

echo "$run" | sed 's/^/   /'

# Read the verdict from pytest's own count rather than from its exit code
# alone: an import error and a failed assertion are both rc=1, and they call
# for different things -- one is a broken environment, the other is a real
# regression, and a suite that cannot tell you which wastes the first ten
# minutes of every diagnosis.
if [ "$rc" -eq 0 ]; then
  n=$(printf '%s' "$run" | grep -oE '[0-9]+ passed' | head -1 | cut -d' ' -f1)
  ok "${n:-?} assertions about lib/ hold"
elif printf '%s' "$run" | grep -q 'error'; then
  bad "the suite did not run -- this is the environment, not lib/"
else
  bad "lib/ has a regression (pytest exit $rc)"
fi

ver=$(cd "$REPO" && "$UV" run --quiet --no-project --with matplotlib \
        python -c 'import matplotlib; print(matplotlib.__version__)' 2>/dev/null)
printf '   --   against matplotlib %s\n' "${ver:-unknown}"

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
