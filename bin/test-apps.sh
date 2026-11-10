#!/usr/bin/env bash
# ERGON-147: ergon-vault and ergon-tailscale against stubs, and the opt-in app
# bundles and web apps being well-formed. No server, no sudo, no session.
#   ./bin/test-apps.sh
set -uo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w=$1; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
V="$REPO/bin/ergon-vault"

mkdir -p "$T/stub" "$T/cfg"
cat > "$T/stub/rbw" <<S
#!/bin/sh
echo "\$*" >> "$T/rbw"
S
cat > "$T/stub/bitwarden" <<'S'
#!/bin/sh
:
S
cat > "$T/stub/sudo" <<S
#!/bin/sh
echo "sudo \$*" >> "$T/sudo"
[ "\$1" = tailscale ] || [ "\$1" = systemctl ] && exit 0
exec "\$@"
S
cat > "$T/stub/systemctl" <<'S'
#!/bin/sh
:
S
cat > "$T/stub/tailscale" <<S
#!/bin/sh
echo "tailscale \$*" >> "$T/ts"
[ "\$1" = status ] && echo '{"BackendState":"'\$(cat "$T/state")'","Self":{"DNSName":"me.tail.ts.net."}}'
exit 0
S
chmod +x "$T"/stub/*
export PATH="$T/stub:$PATH" XDG_CONFIG_HOME="$T/cfg" HOME="$T/home"
export ERGON_HOSTENV="$T/host.env" ERGON_POLICY_DIR="$T/policies"

: > "$T/host.env"
check "url: nothing known prints nothing" test -z "$("$V" url)"
echo 'VAULT_URL="https://vault.example.org/"' > "$T/host.env"
check "url: host.env wins, trailing slash dropped" test "$("$V" url)" = https://vault.example.org
: > "$T/host.env"; mkdir -p "$T/cfg/ergon"; echo https://saved.example.org > "$T/cfg/ergon/vault-url"
check "url: the saved answer is used when host.env has none" test "$("$V" url)" = https://saved.example.org
echo 'VAULT_URL="javascript:alert(1)"' > "$T/host.env"
check "url: a non-http value is refused" bash -c '! "$1" url' _ "$V"

rm "$T/cfg/ergon/vault-url"; : > "$T/host.env"
check "setup: unattended with no URL does nothing, exit 0" bash -c '"$1" setup </dev/null' _ "$V"
check "  and touched neither rbw nor the app" bash -c '! test -e "$1/rbw" && ! test -e "$2/Bitwarden"' _ "$T" "$T/cfg"
echo 'VAULT_URL="https://vault.example.org"' > "$T/host.env"
"$V" setup </dev/null >/dev/null
check "setup: rbw gets base_url" grep -qx 'config set base_url https://vault.example.org' "$T/rbw"
check "setup: the app gets a self-hosted server" \
  test "$(jq -r .global_environment_environment.urls.base "$T/cfg/Bitwarden/data.json")" = https://vault.example.org
echo '{"keep":1}' > "$T/cfg/Bitwarden/data.json"; "$V" setup </dev/null >/dev/null
check "  and existing app state is kept" test "$(jq -r .keep "$T/cfg/Bitwarden/data.json")" = 1

: > "$T/host.env"
printf '%s\n' "https://asked.example.org/" > "$T/answer"
script -qec "$V setup" /dev/null < "$T/answer" >/dev/null 2>&1
check "setup: asked once on a terminal, and remembered" test "$(cat "$T/cfg/ergon/vault-url" 2>/dev/null)" = https://asked.example.org

mkdir -p "$T/policies"; echo '{"policies":{"DisableTelemetry":true}}' > "$T/policies/policies.json"
"$V" firefox >/dev/null
P="$T/policies/policies.json"
check "firefox: the extension is force-installed" \
  test "$(jq -r '.policies.ExtensionSettings["{446900e4-71c2-419f-a6a7-df9c091e268b}"].installation_mode' "$P")" = normal_installed
check "  and another policy is kept" test "$(jq -r .policies.DisableTelemetry "$P")" = true
check "  and the server URL is its managed storage" \
  test "$(jq -r '.policies["3rdparty"].Extensions["{446900e4-71c2-419f-a6a7-df9c091e268b}"].environment.base' "$P")" = https://asked.example.org
before=$(jq -c . "$P"); "$V" firefox >/dev/null
check "firefox: rerunning is idempotent" test "$before" = "$(jq -c . "$P")" -a "$(jq '.policies.ExtensionSettings|length' "$P")" = 1

TS="$REPO/bin/ergon-tailscale"
echo NeedsLogin > "$T/state"
"$TS" up >/dev/null
check "tailscale up: starts tailscaled" grep -q 'sudo systemctl enable --now tailscaled' "$T/sudo"
check "  logs in with a QR and this user as operator" grep -q "sudo tailscale up --operator=${USER:-$(id -un)} --qr" "$T/sudo"
: > "$T/sudo"; echo Running > "$T/state"
"$TS" up >/dev/null
check "tailscale up: when already logged in only sets the operator" \
  bash -c 'grep -q "tailscale set --operator=" "$1" && ! grep -q "tailscale up" "$1"' _ "$T/sudo"
check "tailscale status prints the state" test "$("$TS" status | head -n1)" = Running

# --- opt-in apps ---------------------------------------------------------------
B="$REPO/packages/bundles"
for b in signal slack dropbox nordvpn sunshine craft; do
  check "bundle $b has meta and a package list" bash -c '[ -s "$1/$2/meta" ] && grep -qx "pacman\|aur" <<<"$(ls "$1/$2")"' _ "$B" "$b"
done
check "craft: the storytold suite, and not the artcraft AI app" \
  bash -c 'grep -qx storytold-suite "$1/craft/aur" && grep -qx "artcraft-launcher-bin *\(#.*\)\?" "$1/craft/aur" && ! grep -qE "^artcraft(-git)? *(#.*)?$" "$1/craft/aur"' _ "$B"
for id in spotify notion microsoft-365 1password; do
  check "web app $id: off by default, with an icon" \
    bash -c 'grep -q "^$1|.*|0\$" "$2/applications/webapps/catalog" && grep -q image/png <<<"$(file -b --mime-type "$2/applications/webapps/$1.png")"' _ "$id" "$REPO"
done
check "bitwarden and rbw are in the base" bash -c 'grep -q "^bitwarden\b" "$1/packages/pacman" && grep -q "^rbw\b" "$1/packages/pacman"' _ "$REPO"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
