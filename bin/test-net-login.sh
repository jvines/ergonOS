#!/usr/bin/env bash
# ERGON-129/130/141/142: captive portal, DNS choice, git identity, sshd gate.
#
#   ./bin/test-net-login.sh
#
# Seconds, no root, no network. nmcli, curl, systemctl, sudo, fuzzel and the browser are
# stubs on PATH that log their argv; git runs for real against a temp HOME.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
B="$REPO/bin"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '   FAIL %s\n' "$*"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: got [$2] want [$3]"; }

mkdir -p "$T/bin" "$T/home" "$T/run"
export HOME="$T/home" XDG_RUNTIME_DIR="$T/run" XDG_STATE_HOME="$T/home/state" LOG="$T/log"
export GIT_CONFIG_NOSYSTEM=1 PATH="$T/bin:$PATH"
unset WAYLAND_DISPLAY
: > "$LOG"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
stub nmcli 'echo "nmcli $*" >> "$LOG"
case "$*" in
  "-g CONNECTIVITY general") cat "$T/conn" ;;
  "-t -f UUID,TYPE connection show") printf "u1:802-11-wireless\nu2:vpn\nu3:802-3-ethernet\n" ;;
  "-t -f DEVICE,STATE device status") printf "wlan0:connected\nlo:unmanaged\n" ;;
esac'
stub curl 'echo "http://portal.example/login"'
stub notify-send 'echo "notify $*" >> "$LOG"'
stub sudo '"$@"'
stub systemctl 'echo "systemctl $*" >> "$LOG"'
stub fuzzel 'echo "fuzzel $*" >> "$LOG"; head -1 "$T/answers"; sed -i 1d "$T/answers"'
stub browser 'echo "browser $*" >> "$LOG"'
export ERGON_CAPTIVE_BROWSER="$T/bin/browser" T

echo "== captive portal (ERGON-129)"
echo full > "$T/conn"; "$B/ergon-captive" --once
eq "no portal: nothing opened" "$(grep -c browser "$LOG")" 0
echo portal > "$T/conn"; "$B/ergon-captive" --once
eq "portal: opens the redirect" "$(grep browser "$LOG")" "browser http://portal.example/login"
eq "portal: notifies" "$(grep -c '^notify' "$LOG")" 1
"$B/ergon-captive" --once
eq "portal: announced once" "$(grep -c browser "$LOG")" 1
echo full > "$T/conn"; "$B/ergon-captive" --once; echo portal > "$T/conn"; "$B/ergon-captive" --once
eq "new portal after full: announced again" "$(grep -c browser "$LOG")" 2
eq "--check" "$("$B/ergon-captive" --check)" portal
"$B/ergon-captive" --open; eq "--open always opens" "$(grep -c browser "$LOG")" 3

echo "== DNS (ERGON-130)"
: > "$LOG"; "$B/ergon-dns" cloudflare
eq "only wifi and ethernet profiles changed" "$(grep -c 'connection modify' "$LOG")" 2
grep -q 'modify u1 ipv4.dns 1.1.1.1,1.0.0.1 ipv4.ignore-auto-dns yes ipv6.dns 2606:4700:4700::1111,2606:4700:4700::1001 ipv6.ignore-auto-dns yes' "$LOG" && ok "cloudflare fields" || bad "cloudflare: $(cat "$LOG")"
grep -q 'device reapply wlan0' "$LOG" && ok "connected device re-applied" || bad "no reapply"
: > "$LOG"; "$B/ergon-dns" quad9; grep -q 'ipv4.dns 9.9.9.9,149.112.112.112' "$LOG" && ok "quad9" || bad "quad9"
: > "$LOG"; "$B/ergon-dns" custom 8.8.8.8 2001:4860:4860::8888
grep -q 'modify u3 ipv4.dns 8.8.8.8 ipv4.ignore-auto-dns yes ipv6.dns 2001:4860:4860::8888' "$LOG" && ok "custom splits v4/v6" || bad "custom: $(cat "$LOG")"
: > "$LOG"; "$B/ergon-dns" custom 'rm -rf' 2>/dev/null; eq "custom rejects junk" "$?" 2
eq "junk changed nothing" "$(grep -c modify "$LOG")" 0
: > "$LOG"; "$B/ergon-dns" dhcp
grep -q 'modify u1 ipv4.dns  ipv4.ignore-auto-dns no ipv6.dns  ipv6.ignore-auto-dns no' "$LOG" && ok "dhcp clears everything it set" || bad "dhcp: $(cat "$LOG")"

echo "== git identity (ERGON-141)"
printf 'Ada Lovelace\nada@example.org\n' > "$T/answers"
WAYLAND_DISPLAY=w "$B/ergon-git-identity" --first-run
eq "name set" "$(git config --global user.name)" "Ada Lovelace"
eq "email set" "$(git config --global user.email)" "ada@example.org"
printf 'Evil\nevil@example.org\n' > "$T/answers"; rm -f "$XDG_STATE_HOME/ergon/git-identity-asked"
WAYLAND_DISPLAY=w "$B/ergon-git-identity" --first-run
eq "existing identity never overwritten" "$(git config --global user.name)" "Ada Lovelace"
"$B/ergon-git-identity" Other other@example.org
eq "direct call does not overwrite either" "$(git config --global user.email)" "ada@example.org"
rm -f "$HOME/.gitconfig" "$XDG_STATE_HOME/ergon/git-identity-asked"
printf '\n\n' > "$T/answers"; WAYLAND_DISPLAY=w "$B/ergon-git-identity" --first-run
eq "skip sets nothing" "$(git config --global user.name)" ""
printf 'Late\nlate@example.org\n' > "$T/answers"; WAYLAND_DISPLAY=w "$B/ergon-git-identity" --first-run
eq "skipped first run is not asked again" "$(git config --global user.name)" ""
"$B/ergon-git-identity" Bob bob@example.org </dev/null
eq "explicit call sets it" "$(git config --global user.name)" "Bob"
"$B/ergon-git-identity" Bob notanemail 2>/dev/null; eq "bad email refused" "$?" 2

echo "== sshd gate (ERGON-142)"
export ERGON_AUTHORIZED_KEYS="$T/ak"; : > "$LOG"
"$B/ergon-ssh-enable" 2>/dev/null; eq "no file: refused" "$?" 1
echo "not a key" > "$ERGON_AUTHORIZED_KEYS"; "$B/ergon-ssh-enable" 2>/dev/null; eq "garbage: refused" "$?" 1
eq "refusal ran no systemctl" "$(grep -c systemctl "$LOG")" 0
ssh-keygen -q -t ed25519 -N '' -f "$T/k" && cp "$T/k.pub" "$ERGON_AUTHORIZED_KEYS"
"$B/ergon-ssh-enable" >/dev/null; eq "with a key: enabled" "$(grep systemctl "$LOG")" "systemctl enable --now sshd"
: > "$LOG"; "$B/ergon-ssh-enable" --disable; eq "--disable" "$(grep systemctl "$LOG")" "systemctl disable --now sshd"
_en=$(grep -nE 'enable[^#]*\bsshd\b' "$REPO/bin/provision-arch.sh" "$REPO/bin/arch-bootstrap.sh" | grep -v '^\S*:\s*#' || true)
if [ -n "$_en" ]; then bad "provisioning enables sshd: $_en"; else ok "provisioning never enables sshd"; fi

echo "== provisioning (ERGON-129)"
grep -q 'uri=http://ping.archlinux.org/nm-check.txt' "$REPO/bin/provision-arch.sh" && ok "connectivity check provisioned" || bad "no connectivity conf"

echo; echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
