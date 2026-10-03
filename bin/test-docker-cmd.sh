#!/usr/bin/env bash
# ERGON-51: lib/docker-cmd.sh is sourced by every bin/test-*.sh and by
# bin/hypr-vm to reach the docker socket, so a mistake in it is invisible in
# every OTHER suite here -- they all run on this host, where `docker info`
# just works and the resolver's first branch hides everything past it.
#
#   ./bin/test-docker-cmd.sh
#
# Seconds, no root, no real docker or sudo: both are stubs on a scratch PATH,
# so each branch is forced deliberately instead of hoped for. setsid detaches
# the child from whatever terminal is running this suite, which is what makes
# "no tty" reproducible on an interactive box and not just under CI; `script`
# (guarded -- it is util-linux, not guaranteed) does the opposite, to prove
# the resolver checks /dev/tty and not fd 0, which a first version of it did
# not (a review of ERGON-51 caught `docker run ... | tee | grep` -- every VM
# call site here -- closing fd 0 to a pipe and refusing a prompt it could
# have made).
set -uo pipefail

ERGON="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
# These read the global $out set by resolve(), rather than re-quoting it into
# a shell string -- $out contains its own double quotes (declare -p's output
# does), and splicing that into another command line to re-parse is exactly
# the kind of thing this repo's own ergon-lint exists to catch elsewhere.
has()   { grep -qi -- "$1" <<<"$out"; }
lacks() { ! grep -qi -- "$1" <<<"$out"; }
eq()    { [ "$out" = "$1" ]; }

# A stub docker: `info` answers with $1's exit code and $2's stderr; anything
# else just echoes, so a caller that got past resolution can still be seen.
stub_docker() {  # stub_docker <dir> <info-rc> <info-message>
  cat > "$1/docker" <<EOF
#!/bin/bash
if [ "\$1" = info ]; then echo "$3" >&2; exit $2; fi
echo "ran: \$*"
EOF
  chmod +x "$1/docker"
}
# Just enough of a real PATH for id(1) and bash builtins -- no docker, no
# sudo, unless a case above adds one.
BASE="$T/base"; mkdir -p "$BASE"
ln -s "$(command -v id)" "$BASE/id"
# The absolute path, not "bash" -- the inner shell below is launched with its
# own PATH already pointed at a directory with no bash in it, and `PATH=X
# bash -c ...` resolves "bash" against X, the new value, not this shell's.
BASH_BIN="$(command -v bash)"

resolve() {  # resolve <extra-path> [notty|tty] -> stdout+stderr, and $T/rc
  local path="$1:$BASE" mode="${2:-notty}"
  local cmd=". \"$ERGON/lib/docker-cmd.sh\"; ergon_resolve_docker; echo \$? > \"$T/rc\"; declare -p DOCKER 2>/dev/null"
  if [ "$mode" = tty ] && command -v script >/dev/null 2>&1; then
    script -qec "PATH=\"$path\" \"$BASH_BIN\" -c '$cmd'" /dev/null </dev/null 2>&1
    return
  fi
  setsid "$BASH_BIN" -c "PATH=\"$path\" \"$BASH_BIN\" -c '$cmd'" </dev/null 2>&1
}
rc() { cat "$T/rc" 2>/dev/null; }

echo "== docker missing entirely -- the old \`command -v docker\` guard, restored"
D="$T/nodocker"; mkdir -p "$D"
out=$(resolve "$D" notty)
check "refuses in one line" test "$(rc)" = 1
check "  names docker" has docker
check "  not a docker_group knob nobody asked for" lacks DOCKER_GROUP

echo "== docker reaches the socket directly -- every existing machine"
D="$T/direct"; mkdir -p "$D"; stub_docker "$D" 0 ""
out=$(resolve "$D" notty)
check "resolves to plain docker" test "$(rc)" = 0
check "  DOCKER is (docker)" eq 'declare -a DOCKER=([0]="docker")'

echo "== permission denied, sudo has a cached ticket -- CI's own path if it ever lost the group"
D="$T/cached"; mkdir -p "$D"
stub_docker "$D" 1 "permission denied while trying to connect"
cat > "$D/sudo" <<'EOF'
#!/bin/bash
[ "$1" = -n ] && exit 0
shift; exec "$@"
EOF
chmod +x "$D/sudo"
out=$(resolve "$D" notty)
check "resolves to sudo docker" test "$(rc)" = 0
check "  DOCKER is (sudo docker)" eq 'declare -a DOCKER=([0]="sudo" [1]="docker")'

echo "== permission denied, no cached ticket, no terminal -- an agent, or ssh without -t"
D="$T/notty"; mkdir -p "$D"
stub_docker "$D" 1 "permission denied while trying to connect"
cat > "$D/sudo" <<'EOF'
#!/bin/bash
[ "$1" = -n ] && exit 1
shift; exec "$@"
EOF
chmod +x "$D/sudo"
out=$(resolve "$D" notty)
check "refuses" test "$(rc)" = 1
check "  names sudo needing a ticket or a terminal" has "cached ticket"
check "  does NOT send an agent to grant itself DOCKER_GROUP=1" lacks DOCKER_GROUP

if command -v script >/dev/null 2>&1; then
  echo "== same as above, but stdin is /dev/null AND a real controlling terminal exists"
  out=$(resolve "$D" tty)
  check "the terminal (not fd 0) is what gets checked -- resolves to sudo docker" \
    test "$(rc)" = 0
fi

echo "== permission denied, no sudo installed at all -- the DOCKER_GROUP=1 message belongs here"
D="$T/nosudo"; mkdir -p "$D"
stub_docker "$D" 1 "permission denied while trying to connect"
out=$(resolve "$D" notty)
check "refuses" test "$(rc)" = 1
check "  and only now names DOCKER_GROUP" has DOCKER_GROUP

echo "== docker info fails for a reason sudo can't fix -- a dead daemon, a bad DOCKER_HOST"
D="$T/deaddaemon"; mkdir -p "$D"
stub_docker "$D" 1 "Cannot connect to the Docker daemon. Is the docker daemon running?"
cat > "$D/sudo" <<'EOF'
#!/bin/bash
[ "$1" = -n ] && exit 0
shift; exec "$@"
EOF
chmod +x "$D/sudo"
out=$(resolve "$D" notty)
check "refuses rather than silently trying root's own daemon" test "$(rc)" = 1
check "  and shows docker's own error" has "daemon running"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
