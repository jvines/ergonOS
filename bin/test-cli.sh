#!/usr/bin/env bash
# ERGON-30: `ergon <cmd> --help` (and -h) must never RUN the command.
#
#   ./bin/test-cli.sh
#
# Seconds, no root, no network, no session. wf-recorder, slurp, grim, pacman,
# sudo, systemctl, hyprctl and fuzzel are stubs on PATH that log their own
# name and argv, then fail -- so "this command's --help acted on the system"
# is not a guess about side effects, it is "the stub's log is non-empty".
# Every other real binary (sed, awk, git, python3, ...) still resolves
# normally; only these eight are shadowed.
#
# Runs every command bin/ergon lists, with --help and with -h, and asserts
# both exit 0 and touch none of the stubs. For a command tagged
# `# ergon:help=native` that runs its own real --help code; for everything
# else bin/ergon synthesises help and never execs the command at all -- this
# is what actually proves ERGON-30, since a bug in either path shows up here.
#
# Two more shapes, added in the fix round: a value before --help
# (`record region --help`), because a first fix only ever looked at the
# command's own $1 and walked straight past it into the real action; and bare
# `ergon --help`/`-h` under WAYLAND_DISPLAY, because those used to share a
# case arm with the true no-argument invocation and could pop the fuzzel
# picker instead of printing text.
#
# And one output check at the end, which is not about --help: the file
# `ergon new` writes for VS Code parses (ERGON-65).
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
for bin in wf-recorder slurp grim pacman sudo systemctl hyprctl fuzzel; do
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

# Runs `ergon "$@"`, asserts exit 0 and an untouched stub log. $* (not "$@")
# in the label is deliberate -- it is only ever used for the printed message.
check() {
  local desc="ergon $*"
  : > "$LOG"
  local out rc
  out=$("$ERGON_BIN" "$@" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$desc: exit $rc (expected 0): $(printf '%s' "$out" | tr '\n' ' ')"
  elif [ -s "$LOG" ]; then
    bad "$desc: ran $(tr '\n' ';' < "$LOG")"
  else
    ok "$desc"
  fi
}

cmds=$("$ERGON_BIN" --list)
[ -n "$cmds" ] || { bad "ergon --list returned nothing"; printf '\n   %d ok, %d FAILED\n' "$PASS" "$FAIL"; exit 1; }

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  for flag in --help -h; do
    check "$cmd" "$flag"
  done
done <<< "$cmds"

# A value ahead of --help must not reach the command either, for the concrete
# cases the fix-round review found doing exactly that: `ergon record region
# --help` recorded, `ergon power performance --help` changed the power
# profile, `ergon lid close --help` disabled the panel, `ergon aur <pkg>
# --help` built a package, `ergon fingerprint <finger> --help` started
# enrolment. None of these five is `# ergon:help=native`.
for line in "record region --help" "power performance --help" "lid close --help" \
            "aur somepkg --help" "fingerprint right-thumb --help"; do
  read -ra parts <<< "$line"
  check "${parts[@]}"
done

# Bare --help/-h must always just print, even in a graphical session with
# non-tty stdout -- the one condition that used to send them to the fuzzel
# picker instead, alongside the true no-argument invocation. Only that empty
# case is meant to reach fuzzel; not tested here since fuzzel's own dmenu
# read would hang this script waiting on stdin.
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
for flag in --help -h; do
  check "$flag"
done

# ergon new's .vscode/extensions.json: well-formed, and naming every
# recommendation. uv and R are stubs that succeed, which keeps this offline;
# the projects land in $T.
if ! command -v jq >/dev/null; then
  bad "ergon new: jq is needed to parse .vscode/extensions.json"
else
  mkdir -p "$T/new/bin" "$HOME/.local/bin"
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/uv"
  cp "$HOME/.local/bin/uv" "$T/new/bin/R"
  chmod +x "$HOME/.local/bin/uv" "$T/new/bin/R"
  # Every ID, not one canary: a dropped recommendation must fail here.
  declare -A WANT=(
    [python]="detachhead.basedpyright charliermarsh.ruff ms-python.python ms-python.debugpy ms-toolsai.jupyter marimo-team.vscode-marimo"
    [r]="REditorSupport.r"
  )
  for lang in python r; do
    (cd "$T/new" && PATH="$T/new/bin:$PATH" "$REPO/bin/ergon-new" "p$lang" --lang "$lang" >/dev/null 2>&1)
    if ! recs=$(jq -er '.recommendations | arrays | .[]' "$T/new/p$lang/.vscode/extensions.json" 2>&1); then
      bad "ergon new --lang $lang: .vscode/extensions.json is missing or not JSON: $recs"
      continue
    fi
    missing=""
    for id in ${WANT[$lang]}; do
      grep -qxF "$id" <<< "$recs" || missing="$missing $id"
    done
    if [ -n "$missing" ]; then
      bad "ergon new --lang $lang: .vscode/extensions.json does not recommend:$missing"
    else
      ok "ergon new --lang $lang: .vscode/extensions.json parses, and recommends all of: ${WANT[$lang]}"
    fi
  done
fi

printf '\n   %d ok, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
