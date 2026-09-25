#!/usr/bin/env bash
# ERGON-61: ship must fetch back a FAILED run's output too, and repro
# --with-data must refresh $OUT/data rather than nest a second copy inside
# it or leave the manifest and the payload disagreeing.
#
#   ./bin/test-ship-repro.sh
#
# Seconds, no root, no network, no VM. ssh, rsync, apptainer and uv are stubs
# on PATH. The ssh stub logs its argv, then runs the remote command line it
# was given through a LOCAL bash instead of a real connection -- that command
# line is plain shell text (ergon-ship builds it with $*, not an argv array),
# so replaying it locally against a fake "remote" rooted in $T reproduces the
# real exit-code plumbing under test without a real machine. rsync's stub
# copies between the two paths it was given after stripping any host: prefix,
# since that prefix is the only thing telling real rsync to go over ssh in
# the first place. apptainer's stub touches the .sif build asked for and runs
# exec's trailing words as a shell command line, the same trick as ssh's stub.
# Never a real ssh, never a real network call.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SHIP="$REPO/bin/ergon-ship"
REPRO="$REPO/bin/ergon-repro"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/home" "$T/remote" "$T/log"
export HOME="$T/home"
export XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state" \
       XDG_DATA_HOME="$HOME/.local/share" XDG_CONFIG_HOME="$HOME/.config"
export ERGON_SHIP_DIR="$T/remote" ERGON_TEST_LOG="$T/log"
reset_logs() { : > "$T/log/ssh"; : > "$T/log/rsync"; : > "$T/log/apptainer"; }

cat > "$T/stub/ssh" <<'EOF'
#!/usr/bin/env bash
# ergon-ship only ever calls `ssh $OPTS HOST CMD`, so the last argument is
# always the remote command line -- run it right here instead of connecting
# anywhere, and hand back exactly the exit status it produced.
printf '%s\n' "$*" >> "$ERGON_TEST_LOG/ssh"
cmd="${@: -1}"
bash -c "$cmd"
EOF

cat > "$T/stub/rsync" <<'EOF'
#!/usr/bin/env bash
# The last two operands are always SOURCE and DEST; strip any host: prefix
# (there is no real ssh -e underneath to resolve it) and copy locally.
printf '%s\n' "$*" >> "$ERGON_TEST_LOG/rsync"
argv=("$@"); n=${#argv[@]}
dst="${argv[$((n-1))]}"; src="${argv[$((n-2))]}"
dst="${dst#*:}"; src="${src#*:}"
printf '%s\n' "$*" | grep -q -- --delete && rm -rf "$dst"
mkdir -p "$dst"
cp -r "$src"/. "$dst"/ 2>/dev/null || true
EOF

cat > "$T/stub/apptainer" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ERGON_TEST_LOG/apptainer"
case "$1" in
  build) shift; while [[ "$1" == --* ]]; do shift; done; : > "$1" ;;
  exec)  shift; shift; bash -c "$*" ;;
esac
EOF

cat > "$T/stub/uv" <<'EOF'
#!/usr/bin/env bash
# Stands in for the far side's `uv sync`: creates the .venv/bin/python the
# ship "run" step depends on, so this suite never needs a real network fetch
# of uv or a real environment to prove ship's OWN exit-code plumbing.
[ "$1" = sync ] || exit 0
mkdir -p .venv/bin
printf '#!/usr/bin/env bash\nexit 0\n' > .venv/bin/python
chmod +x .venv/bin/python
EOF

cat > "$T/stub/curl" <<'EOF'
#!/usr/bin/env bash
# Reached only if the uv stub above fell off PATH -- a canary, not a path
# this suite means to exercise. "No network" is a hard requirement here.
echo "test-ship-repro: curl called -- a network call escaped the stubs" >&2
exit 1
EOF
chmod +x "$T/stub"/*
export PATH="$T/stub:$PATH"
[ "$(command -v ssh)" = "$T/stub/ssh" ] || { echo "stubs are not first on PATH; refusing to run anything"; exit 1; }

mkproj() {
  local d="$T/proj-$1"; mkdir -p "$d"
  printf '[project]\nname = "%s"\n' "$1" > "$d/pyproject.toml"
  : > "$d/uv.lock"
  printf '%s\n' "$d"
}

echo "== ergon ship: ssh backend"
reset_logs
P=$(mkproj ship-fail)
( cd "$P" && "$SHIP" kira --fetch results -- 'exit 3' ) >"$T/out" 2>&1
RC=$?
check "a failing run preserves the remote exit code (got $RC)" test "$RC" -eq 3
check "  and fetches anyway -- the run whose output matters most" \
  grep -q "results/" "$T/log/rsync"

reset_logs
P=$(mkproj ship-ok)
( cd "$P" && "$SHIP" kira --fetch results -- 'exit 0' ) >"$T/out" 2>&1
RC=$?
check "a successful run exits 0" test "$RC" -eq 0
check "  and fetches too" grep -q "results/" "$T/log/rsync"

echo "== ergon ship: container backend"
reset_logs
P=$(mkproj ship-container)
( cd "$P" && "$SHIP" kira --backend container --fetch results -- 'exit 5' ) >"$T/out" 2>&1
RC=$?
check "the container arm preserves apptainer exec's exit code (got $RC)" test "$RC" -eq 5
check "  and fetches anyway" grep -q "results/" "$T/log/rsync"
check "  having actually built and exec'd through apptainer" \
  bash -c "grep -q '^build ' '$T/log/apptainer' && grep -q '^exec ' '$T/log/apptainer'"

echo "== ergon repro: --with-data on a repeat run"
mkdataproj() {
  local d="$T/dproj-$1"; mkdir -p "$d/data"
  printf '[project]\nname = "d"\n' > "$d/pyproject.toml"
  echo hello > "$d/data/a.txt"
  echo world > "$d/data/b.txt"
  echo nas   > "$T/nas-file-$1.bin"
  ln -s "$T/nas-file-$1.bin" "$d/data/linked.bin"
  printf '%s\n' "$d"
}
# -L: data/'s own listing must count a symlinked file as a file, the same way
# the manifest and the payload do, or this helper disagrees with the fix
# instead of checking it.
filelist() { ( cd "$1" 2>/dev/null && find -L . -type f | sort ); }

D=$(mkdataproj main)
( cd "$D" && "$REPRO" --out out --with-data ) >"$T/out" 2>&1
( cd "$D" && "$REPRO" --out out --with-data ) >"$T/out" 2>&1
RC=$?
check "a second --with-data run exits 0" test "$RC" -eq 0
check "  and does not nest a copy inside itself" test ! -e "$D/out/data/data"
check "  payload file set equals data/'s file set" \
  test "$(filelist "$D/out/data")" = "$(filelist "$D/data")"
check "  manifest verifies against the payload it describes" \
  bash -c "cd '$D/out' && sha256sum --quiet -c data.sha256"
# Distinct from both checks above: "payload equals data/" and "sha256sum -c
# passes" both stay green even if the manifest silently DROPS a file that cp
# still copies (that's exactly what a plain, non--L `find data -type f` in the
# manifest step does to a symlinked file) -- sha256sum -c only ever checks the
# files the manifest lists, and $OUT/data still contains the dropped file
# regardless of whether the manifest mentions it. Comparing the manifest's own
# file list against what actually landed under $OUT/data is the only one of
# these that would catch that.
check "  manifest lists exactly the payload copied to \$OUT/data" \
  test "$(sed -E 's/^[0-9a-f]+ [ *]data\///' "$D/out/data.sha256" | sort)" = \
       "$(cd "$D/out/data" && find . -type f -printf '%P\n' | sort)"
check "  a symlinked data file is copied as real bytes, not a symlink" \
  test ! -L "$D/out/data/linked.bin"
check "  and its bytes match the file it pointed at" \
  diff -q "$T/nas-file-main.bin" "$D/out/data/linked.bin"

rm "$D/data/a.txt"; echo new > "$D/data/c.txt"
( cd "$D" && "$REPRO" --out out --with-data ) >"$T/out" 2>&1
check "after data/ changes, the stale file leaves the payload" test ! -e "$D/out/data/a.txt"
check "  the new file enters it" test -e "$D/out/data/c.txt"
check "  and the two file sets still agree" \
  test "$(filelist "$D/out/data")" = "$(filelist "$D/data")"

echo "== ergon repro: a leftover payload without --with-data"
echo more > "$D/data/d.txt"
( cd "$D" && "$REPRO" --out out ) >"$T/out" 2>&1
RC=$?
check "a run without --with-data after data/ changed exits non-zero" test "$RC" -ne 0
check "  and says the payload is stale, not just \"failed\"" grep -qi "left from an earlier" "$T/out"

echo "== ergon repro: --out cannot resolve into data/"
before=$(filelist "$D/data")
( cd "$D" && "$REPRO" --out . --with-data ) >"$T/out" 2>&1; RC=$?
check "--out . is refused" test "$RC" -ne 0
check "  with data/ left intact" test "$(filelist "$D/data")" = "$before"
( cd "$D" && "$REPRO" --out data/x --with-data ) >"$T/out" 2>&1; RC=$?
check "--out data/x is refused" test "$RC" -ne 0
check "  with data/ still left intact" test "$(filelist "$D/data")" = "$before"

echo "== ergon repro: an unreadable data file fails the manifest, not silently"
D2=$(mkdataproj unreadable)
echo secret > "$D2/data/secret.txt"; chmod 000 "$D2/data/secret.txt"
( cd "$D2" && "$REPRO" --out out ) >"$T/out" 2>&1; RC=$?
check "the run exits non-zero rather than shipping an incomplete manifest" test "$RC" -ne 0
check "  and names the file it could not hash" grep -q secret.txt "$T/out"
chmod 600 "$D2/data/secret.txt"

echo "== ergon repro: a dangling symlink under data/ fails the manifest, not silently"
# Distinct from the unreadable-file case above: under -L, find falls back to
# reporting a symlink AS a symlink only when its target cannot be resolved --
# a broken link matches neither -type f nor sha256sum's error path, so it was
# the one case the fix above still let through silently.
D3=$(mkdataproj dangling)
ln -s "$T/nowhere.bin" "$D3/data/broken.bin"
( cd "$D3" && "$REPRO" --out out ) >"$T/out" 2>&1; RC=$?
check "the run exits non-zero rather than shipping an incomplete manifest" test "$RC" -ne 0
check "  and names the broken symlink" grep -q broken.bin "$T/out"

echo "== ergon repro: --out cannot make \$OUT/data land on the project itself"
# A project ROOT literally named "data" is the case a realpath check on \$OUT
# alone does not cover: \$OUT one level up resolves to something that matches
# none of the guarded patterns, yet \$OUT/data -- the literal rm -rf target --
# lands ON the project root.
PD="$T/proj-named-data/data"; mkdir -p "$PD/data"
printf '[project]\nname = "pd"\n' > "$PD/pyproject.toml"
echo important > "$PD/fit.py"
echo x > "$PD/data/a.txt"
( cd "$PD" && "$REPRO" --out .. --with-data ) >"$T/out" 2>&1; RC=$?
check "--out .. is refused when \$OUT/data would BE the project root" test "$RC" -ne 0
check "  and the project survives" test -f "$PD/fit.py" -a -f "$PD/data/a.txt"

echo "== ergon repro: data/ itself renamed or removed between runs"
D4=$(mkdataproj datagone)
( cd "$D4" && "$REPRO" --out out --with-data ) >"$T/out" 2>&1
mv "$D4/data" "$D4/data-elsewhere"
( cd "$D4" && "$REPRO" --out out ) >"$T/out" 2>&1; RC=$?
check "without --with-data, a leftover payload is refused once data/ is gone" test "$RC" -ne 0
check "  and says so" grep -qi "data/ itself is gone" "$T/out"
( cd "$D4" && "$REPRO" --out out --with-data ) >"$T/out" 2>&1; RC=$?
check "  but --with-data cleans it up instead of leaving it to lie" test "$RC" -eq 0
check "  leaving neither the stale payload" test ! -e "$D4/out/data"
check "  nor the stale manifest behind" test ! -e "$D4/out/data.sha256"

printf '\n   %d ok, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
