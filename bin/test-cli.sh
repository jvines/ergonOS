#!/usr/bin/env bash
# ERGON-30: `ergon <cmd> --help` (and -h) must never RUN the command.
#
#   ./bin/test-cli.sh
#
# Seconds, no root, no network, no session. wf-recorder, slurp, grim, pacman,
# sudo, systemctl and hyprctl are stubs on PATH that log their own name and
# argv, then fail -- so "this command's --help acted on the system" is not a
# guess about side effects, it is "the stub's log is non-empty". Every other
# real binary (sed, awk, git, python3, ...) still resolves normally; only
# these seven are shadowed.
#
# Runs every command bin/ergon lists, with --help and with -h, and asserts
# both exit 0 and touch none of the stubs. For a command tagged
# `# ergon:help=native` that runs its own real --help code; for everything
# else bin/ergon synthesises help and never execs the command at all -- this
# is what actually proves ERGON-30, since a bug in either path shows up here.
#
# $HOME and the XDG dirs point into the scratch dir for the whole run, so a
# command's incidental `mkdir -p "$STATE"` (ergon-svc, ergon-offline) lands in
# throwaway space rather than this machine's real ~/.local/state.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ERGON_BIN="$REPO/bin/ergon"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }

mkdir -p "$T/stub" "$T/home"
LOG="$T/log"
: > "$LOG"
for bin in wf-recorder slurp grim pacman sudo systemctl hyprctl; do
  cat > "$T/stub/$bin" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$bin" "\$*" >> "$LOG"
exit 1
EOF
  chmod +x "$T/stub/$bin"
done

export PATH="$T/stub:$PATH"
export HOME="$T/home"
export XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state" \
       XDG_DATA_HOME="$HOME/.local/share" XDG_CONFIG_HOME="$HOME/.config"

cmds=$("$ERGON_BIN" --list)
[ -n "$cmds" ] || { bad "ergon --list returned nothing"; printf '\n   %d ok, %d FAILED\n' "$PASS" "$FAIL"; exit 1; }

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  for flag in --help -h; do
    : > "$LOG"
    out=$("$ERGON_BIN" "$cmd" "$flag" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      bad "ergon $cmd $flag: exit $rc (expected 0): $(printf '%s' "$out" | tr '\n' ' ')"
    elif [ -s "$LOG" ]; then
      bad "ergon $cmd $flag: ran $(tr '\n' ';' < "$LOG")"
    else
      ok "ergon $cmd $flag"
    fi
  done
done <<< "$cmds"

printf '\n   %d ok, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
