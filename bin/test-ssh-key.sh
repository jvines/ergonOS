#!/usr/bin/env bash
# ERGON-106: ergon ssh-key. Real ssh, ssh-keygen and ssh-agent in a temp HOME
# (skipped if openssh is not on the host): setup appends one Match all + Include block to
# the end of an existing config without otherwise touching it, ssh -F "$HOME/.ssh/config" -G then shows
# addkeystoagent true for other hosts while a per-host no wins, and new/add/list/copy work
# against a private agent.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
K="$REPO/bin/ergon-ssh-key"
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
for t in ssh ssh-keygen ssh-agent ssh-add; do command -v $t >/dev/null || { echo "ssh-key: skip (no $t)"; exit 0; }; done
T=$(mktemp -d); trap 'kill ${AGENT_PID:-} 2>/dev/null; rm -rf "$T"' EXIT
export HOME="$T/h"; mkdir -p "$HOME"; unset WAYLAND_DISPLAY
eval "$(ssh-agent -s -a "$T/agent.sock")" >/dev/null; export SSH_AUTH_SOCK="$T/agent.sock"
AGENT_PID=$SSH_AGENT_PID

# fresh machine: no ~/.ssh at all
"$K" setup
check "fresh: ~/.ssh is 0700 and config 0600" [ "$(stat -c %a "$HOME/.ssh")/$(stat -c %a "$HOME/.ssh/config")" = 700/600 ]
check "fresh: ssh -F "$HOME/.ssh/config" -G has addkeystoagent true" bash -c 'ssh -F "$HOME/.ssh/config" -G somehost </dev/null 2>/dev/null | grep -qx "addkeystoagent true"'
rm -rf "$HOME/.ssh"

# existing config with a Host block: block appended last, the rest byte-identical
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
printf 'Host work\n    User bob\n    AddKeysToAgent no\n' > "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
cp "$HOME/.ssh/config" "$T/orig"
"$K" setup; "$K" setup
check "the block is there exactly once" [ "$(grep -c "^Include " "$HOME/.ssh/config")" = 1 ]
check "...at the very end" bash -c 'tail -2 "$HOME/.ssh/config" | tr "\n" "|" | grep -qx "Match all|Include ~/.ssh/config.d/ergon.conf|"'
check "the user's lines survive byte-identical at the start" bash -c 'head -c "$(stat -c %s "$1")" "$HOME/.ssh/config" | cmp -s - "$1"' _ "$T/orig"
check "the first-time backup equals the original" cmp -s "$HOME/.ssh/config.ergon-backup" "$T/orig"
check "config mode is kept" [ "$(stat -c %a "$HOME/.ssh/config")" = 600 ]
check "ssh -G: an unrelated host gets addkeystoagent true" bash -c 'ssh -F "$HOME/.ssh/config" -G somehost </dev/null 2>/dev/null | grep -qx "addkeystoagent true"'
check "...and the user's own per-host AddKeysToAgent no wins for its host" bash -c 'ssh -F "$HOME/.ssh/config" -G work </dev/null 2>/dev/null | grep -qx "addkeystoagent false"'
check "the snippet holds only Host * and AddKeysToAgent yes" bash -c '[ "$(grep -vE "^#|^$" "$HOME/.ssh/config.d/ergon.conf" | tr -s " " | tr "\n" "|")" = "Host *|  AddKeysToAgent yes|" ] || [ "$(grep -vE "^#|^$" "$HOME/.ssh/config.d/ergon.conf" | sed "s/^ *//" | tr "\n" "|")" = "Host *|AddKeysToAgent yes|" ]'

# migration from the first version, which prepended its Include
printf "Include ~/.ssh/config.d/ergon.conf # ergon: managed include, keep it the first line\n\n" > "$T/mig"; cat "$T/orig" >> "$T/mig"
cp "$T/mig" "$HOME/.ssh/config"; "$K" setup
check "migration: the prepended line is gone" bash -c '! grep -q "keep it the first line" "$HOME/.ssh/config"'
check "migration: user lines intact, block last, once" bash -c 'head -c "$(stat -c %s "$1")" "$HOME/.ssh/config" | cmp -s - "$1" && [ "$(grep -c "^Include " "$HOME/.ssh/config")" = 1 ]' _ "$T/orig"

# keys
check "list on an empty ~/.ssh says so" bash -c '"$1" list | grep -q "no keys"' _ "$K"
check "new --insecure-empty-passphrase makes the key" bash -c '"$@" >/dev/null 2>&1' _ "$K" new --insecure-empty-passphrase work --comment tester@box
check "new: private key is 0600 and the comment is kept" bash -c '[ "$(stat -c %a "$HOME/.ssh/work")" = 600 ] && grep -q " tester@box$" "$HOME/.ssh/work.pub"'
check "new: the key is loaded in the agent" bash -c 'ssh-add -l | grep -q tester@box'
check "new refuses to overwrite" bash -c '! "$1" new work 2>/dev/null' _ "$K"
check "new: rejects a path as NAME" bash -c '! "$1" new ../x 2>/dev/null' _ "$K"
ssh-add -D >/dev/null 2>&1
check "list: shows it not loaded" bash -c '"$1" list | grep -q "^work .*not loaded"' _ "$K"
check "add loads it" bash -c '"$1" add work >/dev/null 2>&1 && "$1" list | grep -q "^work  *loaded"' _ "$K"
check "copy prints the public key" bash -c '"$1" copy work 2>&1 | grep -q "^ssh-ed25519 "' _ "$K"
# a key with an empty passphrase made by plain ssh-keygen is what `new` must detect
check "an unencrypted key is detectable the way new detects it" bash -c 'ssh-keygen -q -t ed25519 -N "" -f "$HOME/e" && ssh-keygen -y -P "" -f "$HOME/e" >/dev/null 2>&1'
check "an encrypted key is not" bash -c 'ssh-keygen -q -t ed25519 -N pw -f "$HOME/p" && ! ssh-keygen -y -P "" -f "$HOME/p" >/dev/null 2>&1'
# wl-copy: stub that would hang the pipe if it kept stdout open
mkdir -p "$T/bin"; printf '#!/bin/sh\ncat >"%s/clip"; ( sleep 5 ) &\n' "$T" > "$T/bin/wl-copy"; chmod +x "$T/bin/wl-copy"
check "copy returns promptly with a lingering wl-copy (stdout detached)" bash -c 'PATH="$1/bin:$PATH" WAYLAND_DISPLAY=w timeout 3 bash -c "\"$2\" copy work | cat" >/dev/null && grep -q ssh-ed25519 "$1/clip"' _ "$T" "$K"
check "install.sh runs setup" grep -q 'ergon-ssh-key" setup' "$REPO/install.sh"
echo "ssh-key: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
