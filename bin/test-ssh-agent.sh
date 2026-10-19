#!/usr/bin/env bash
# ERGON-106: the session SSH agent. Static: the uwsm drop-in exports the socket
# path, install.sh links it and enables openssh's socket unit, ergon-doctor
# asks the agent. Behavioural (needs docker, skipped without): in an archlinux
# container the unit's own ExecStart serves the path the drop-in exports, and
# ssh-add -l reaches it (exit 1 = reachable, no keys; 2 = nothing there).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
D="$REPO/uwsm/env-hyprland.d/ergon-ssh-agent"
got=$(env -i XDG_RUNTIME_DIR=/run/user/42 sh -c ". '$D'; printf %s \"\$SSH_AUTH_SOCK\"")
check "the drop-in exports the path ssh-agent.socket listens on" [ "$got" = /run/user/42/ssh-agent.socket ]
check "...and does not hardcode a uid" bash -c '! grep -q "run/user/[0-9]" "$1"' _ "$D"
check "install.sh links the drop-in" grep -q 'link uwsm/env-hyprland.d/ergon-ssh-agent ' "$REPO/install.sh"
check "install.sh enables ssh-agent.socket in sockets.target.wants" bash -c 'grep -q "sockets.target.wants/ssh-agent.socket" "$1" && grep -q "enable_user_unit ssh-agent.socket" "$1"' _ "$REPO/install.sh"
check "no second agent is started (gnome-keyring is secrets only)" bash -c '! grep -q "components=.*ssh" "$1"' _ "$REPO/hypr/common/autostart.lua"
check "ergon-doctor has an ssh-agent row" grep -q 'rec [a-z]* "ssh-agent"' "$REPO/bin/ergon-doctor"
check "openssh is in packages/pacman" grep -qx openssh "$REPO/packages/pacman"

if command -v docker >/dev/null 2>&1 && docker image inspect archlinux:latest >/dev/null 2>&1; then
  out=$(docker run --rm --label cl.jvines.owner=ERGON-106 -v "$D:/env:ro" archlinux:latest bash -c '
    pacman -Sy --noconfirm openssh >/dev/null 2>&1 || { echo NOPKG; exit 0; }
    unit=/usr/lib/systemd/user/ssh-agent.service
    [ -e /usr/lib/systemd/user/ssh-agent.socket ] && echo UNITS
    grep -q "^ExecStart=/usr/bin/ssh-agent -D$" $unit && echo EXEC
    mkdir -p /run/u && chmod 700 /run/u
    export XDG_RUNTIME_DIR=/run/u; . /env
    /usr/bin/ssh-agent -D -a "$SSH_AUTH_SOCK" >/dev/null 2>&1 & sleep 1
    ssh-add -l >/dev/null 2>&1; echo "EMPTY=$?"
    ssh-keygen -q -t ed25519 -N "" -f /tmp/k && ssh-add /tmp/k >/dev/null 2>&1; ssh-add -l >/dev/null 2>&1; echo "LOADED=$?"
    SSH_AUTH_SOCK=/run/u/none ssh-add -l >/dev/null 2>&1; echo "DEAD=$?"' 2>&1)
  if grep -q NOPKG <<<"$out"; then echo "   skip container checks (no network for pacman)"
  else
    check "openssh ships ssh-agent.socket and the service runs ssh-agent -D" bash -c 'grep -q UNITS <<<"$1" && grep -q EXEC <<<"$1"' _ "$out"
    check "ssh-add -l reaches the agent at the exported path (exit 1, no keys)" grep -q 'EMPTY=1' <<<"$out"
    check "...and lists a key once added (exit 0)" grep -q 'LOADED=0' <<<"$out"
    check "...and a dead path is exit 2, which the doctor calls unreachable" grep -q 'DEAD=2' <<<"$out"
  fi
else
  echo "   skip container checks (no docker / archlinux image)"
fi
echo "ssh-agent: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
