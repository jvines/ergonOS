#!/usr/bin/env bash
# ERGON-118: ergon-webapp, the installer's checklist, provisioning's sync, and the
# LocalSend firewall rule. Stubs curl, hyprctl, uwsm-app and the browser.
#
#   ./bin/test-webapp.sh
#
# Seconds, no root, no network. COVERS: add/rm/list and the launcher's content
# (Exec, window class, marker), icon fetch with validation and the generic
# fallback, the checklist (defaults, opt-out, opt-in, env answer), sync
# (defaults when WEBAPPS is unset, idempotence, removing only what it made, the
# native Discord conflict), launch-or-focus, and that the firewall rule is in
# the ruleset provisioning writes. DOES NOT COVER a real Chromium window class,
# or the kernel accepting the rule: test/arch-vm/guest-desktop.sh.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { local w="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "   ok   $w"; else FAIL=$((FAIL+1)); echo "   FAIL $w"; fi; }
W="$REPO/bin/ergon-webapp"
export XDG_DATA_HOME="$T/share" HOME="$T/home" XDG_DATA_DIRS="$T/none" ERGON_HOSTENV="$T/host.env"
A="$XDG_DATA_HOME/applications"
mkdir -p "$T/stub" "$HOME" "$T/site"
unset WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE ERGON_WEBAPPS

# A real 1x1 PNG, so `file` calls it an image.
base64 -d > "$T/site/icon.png" <<'B64'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
B64
# curl stub: serves $T/site by path; a URL ending in /bad returns text.
cat > "$T/stub/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift ;; -*) ;; *) url=$1 ;; esac; shift; done
echo "$url" >> "$T/curl.log"
case "$url" in
  */page-with-icon) printf '<html><link rel="apple-touch-icon" href="/icon.png"></html>' ;;
  */icon.png) cat "$T/site/icon.png" ;;
  */bad) echo "not an image" ;;
  *) exit 22 ;;
esac > "${out:-/dev/stdout}"
STUB
printf '#!/bin/sh\necho "uwsm $*" >> "$T/log"\n' > "$T/stub/uwsm-app"
printf '#!/bin/sh\necho "chromium $*" >> "$T/log"\n' > "$T/stub/chromium"
cat > "$T/stub/hyprctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  clients) echo '[{"address":"0x1","class":"chrome-web.whatsapp.com__-Default","focusHistoryID":0}]' ;;
  dispatch) echo "$2" >> "$T/log" ;;
esac
STUB
printf '#!/bin/sh\nexit 1\n' > "$T/stub/xdg-mime"
chmod +x "$T/stub"/*
export PATH="$T/stub:$PATH" T

# --- add / list / rm ---------------------------------------------------------
"$W" add Notes https://notes.example.com/app "$T/site/icon.png" >/dev/null
F="$A/Notes.desktop"
check "add writes <name>.desktop"                 test -f "$F"
check "Exec launches the URL through ergon-webapp" grep -qx 'Exec=ergon-webapp launch "https://notes.example.com/app"' "$F"
check "its window class is set for Hyprland rules" grep -qx 'StartupWMClass=chrome-notes.example.com__app-Default' "$F"
check "it is marked as ours"                       grep -qx 'X-Ergon-Webapp=true' "$F"
check "the given icon file is installed"           grep -q "^Icon=$HOME/.local/share/icons/ergon-webapp/notes.png\$\|^Icon=$XDG_DATA_HOME/icons/ergon-webapp/notes.png\$" "$F"
check "list shows name and URL"                    bash -c '"$1" list | grep -q "^Notes .*https://notes.example.com/app$"' _ "$W"
check "a schemeless URL gets https"                bash -c '"$1" add Bare bare.example.org >/dev/null && grep -q "launch \"https://bare.example.org\"" "$2"' _ "$W" "$A/Bare.desktop"
check "javascript: is refused"                     bash -c '! "$1" add Evil "javascript:alert(1)" 2>/dev/null' _ "$W"
check "a quote in the URL is refused"              bash -c '! "$1" add Evil "https://a.org/\"x" 2>/dev/null' _ "$W"
check "a / in the name is refused"                 bash -c '! "$1" add a/b https://a.org 2>/dev/null' _ "$W"
printf '[Desktop Entry]\nName=Mine\n' > "$A/Mine.desktop"
check "a launcher we did not make is not overwritten" bash -c '! "$1" add Mine https://a.org 2>/dev/null && ! grep -q Ergon "$2"' _ "$W" "$A/Mine.desktop"
check "nor removed"                                bash -c '! "$1" rm Mine 2>/dev/null && test -f "$2"' _ "$W" "$A/Mine.desktop"
"$W" rm Notes >/dev/null
check "rm removes the entry and its icon"          bash -c '! test -e "$1" && ! test -e "$2"' _ "$F" "$XDG_DATA_HOME/icons/ergon-webapp/notes.png"
"$W" rm Bare >/dev/null

# --- icons -------------------------------------------------------------------
"$W" add Auto https://site.example.net/page-with-icon >/dev/null
check "no icon given: the site's apple-touch-icon is fetched" bash -c 'file -b --mime-type "$1" | grep -q image/png' _ "$XDG_DATA_HOME/icons/ergon-webapp/auto.png"
check "  and Icon= points at it"                   grep -q "^Icon=.*/auto.png$" "$A/Auto.desktop"
"$W" add Junk https://site.example.net/bad >/dev/null 2>&1
check "a non-image is rejected for the generic icon" grep -q '^Icon=.*/junk.svg$' "$A/Junk.desktop"
check "  which exists"                             test -s "$XDG_DATA_HOME/icons/ergon-webapp/junk.svg"
"$W" add Themed https://a.example.net/ firefox >/dev/null
check "a bare icon name is a theme icon"           grep -qx 'Icon=firefox' "$A/Themed.desktop"
for n in Auto Junk Themed; do "$W" rm $n >/dev/null; done

# --- the checklist -----------------------------------------------------------
check "unattended: the three defaults"             bash -c '[ "$("$1" choose </dev/null)" = "whatsapp discord youtube" ]' _ "$W"
check "ERGON_WEBAPPS opts in"                      bash -c '[ "$(ERGON_WEBAPPS="whatsapp zoom x" "$1" choose)" = "whatsapp zoom x" ]' _ "$W"
check "ERGON_WEBAPPS=none opts out of all"         bash -c '[ -z "$(ERGON_WEBAPPS=none "$1" choose)" ]' _ "$W"
check "an unknown id is refused"                   bash -c '! ERGON_WEBAPPS=nope "$1" choose 2>/dev/null' _ "$W"
if command -v script >/dev/null 2>&1; then
  out=$(printf '2 4\n\n' | script -qec "$W choose" /dev/null 2>/dev/null | tail -1 | tr -d '\r' | sed 's/.*: //')
  check "interactive: toggling 2 off and 4 on"     test "$out" = "whatsapp youtube x"
fi
check "the template ships the defaults"            grep -qx 'WEBAPPS="whatsapp discord youtube"' "$REPO/hosts/_template/host.env"
check "provisioning records the answer in host.env" grep -q 'ergon-webapp" choose' "$REPO/bin/provision-arch.sh"

# --- sync --------------------------------------------------------------------
: > "$T/host.env"
"$W" sync >/dev/null
check "WEBAPPS unset: the defaults are created"    bash -c 'cd "$1" && ls WhatsApp.desktop Discord.desktop YouTube.desktop >/dev/null' _ "$A"
check "  and nothing else"                         test "$(ls "$A" | grep -c .)" = 4   # + Mine.desktop
check "  with the built-in marker"                 grep -qx 'X-Ergon-Webapp-Builtin=whatsapp' "$A/WhatsApp.desktop"
check "  and the bundled icon"                     bash -c 'file -b --mime-type "$1" | grep -q image/png' _ "$XDG_DATA_HOME/icons/ergon-webapp/whatsapp.png"
touch -d '2001-01-01' "$A/WhatsApp.desktop"
"$W" sync >/dev/null
check "a second sync changes nothing"              bash -c 'test "$(stat -c %Y "$1")" = "$(date -d 2001-01-01 +%s)"' _ "$A/WhatsApp.desktop"
"$W" add Mine2 https://mine.example.org/ >/dev/null
echo 'WEBAPPS="whatsapp zoom"' > "$T/host.env"
"$W" sync >/dev/null
check "opt-in creates Zoom"                        test -f "$A/Zoom.desktop"
check "dropping an id removes that built-in"       bash -c '! test -e "$1/Discord.desktop" && ! test -e "$1/YouTube.desktop"' _ "$A"
check "a web app the user added survives sync"     test -f "$A/Mine2.desktop"
check "a launcher we did not make survives sync"   test -f "$A/Mine.desktop"
echo 'WEBAPPS=""' > "$T/host.env"; "$W" sync >/dev/null
check "empty WEBAPPS removes every built-in"       bash -c '! test -e "$1/WhatsApp.desktop" && ! test -e "$1/Zoom.desktop" && test -f "$1/Mine2.desktop"' _ "$A"
printf '[Desktop Entry]\nName=Hand\n' > "$A/WhatsApp.desktop"
echo 'WEBAPPS="whatsapp"' > "$T/host.env"; "$W" sync >/dev/null 2>&1
check "a hand-made WhatsApp.desktop is left alone" bash -c '! grep -q Ergon "$1"' _ "$A/WhatsApp.desktop"
rm -f "$A/WhatsApp.desktop"

# --- the Discord conflict ----------------------------------------------------
echo 'WEBAPPS="discord youtube"' > "$T/host.env"
printf '#!/bin/sh\n' > "$T/stub/discord"; chmod +x "$T/stub/discord"
"$W" sync >/dev/null
check "native Discord installed: no Discord web app" bash -c '! test -e "$1/Discord.desktop" && test -f "$1/YouTube.desktop"' _ "$A"
rm "$T/stub/discord"; "$W" sync >/dev/null
check "native Discord gone: the web app appears"   test -f "$A/Discord.desktop"
printf '#!/bin/sh\n' > "$T/stub/discord"; chmod +x "$T/stub/discord"; "$W" sync >/dev/null
check "installing the bundle later removes it"     bash -c '! test -e "$1/Discord.desktop"' _ "$A"
rm "$T/stub/discord"

# --- launch ------------------------------------------------------------------
: > "$T/log"; "$W" launch https://example.org/x
check "launch starts Chromium in app mode"         grep -qx "uwsm -- chromium --app=https://example.org/x" "$T/log"
: > "$T/log"; HYPRLAND_INSTANCE_SIGNATURE=x "$W" launch https://web.whatsapp.com/
check "an open web app is focused, not relaunched" bash -c 'grep -q "address:0x1" "$1" && ! grep -q chromium "$1"' _ "$T/log"
check "the class helper matches Chromium's"        test "$("$W" class https://discord.com/channels/@me)" = 'chrome-discord.com__channels_@me-Default'

# --- repo wiring -------------------------------------------------------------
check "chromium is a base package"                 grep -qx 'chromium *#.*' "$REPO/packages/pacman"
check "localsend is installed (AUR)"               grep -q '^localsend-bin ' "$REPO/packages/aur"
check "install.sh runs sync"                       grep -q 'ergon-webapp" sync' "$REPO/install.sh"
check "Hyprland floats LocalSend"                  grep -q 'localsend_app.*float = true' "$REPO/hypr/common/windows.lua"
NFT=$(sed -n '/^if _changed \/etc\/nftables.conf/,/^NFT$/p' "$REPO/bin/provision-arch.sh")
check "firewall: 53317 tcp+udp accepted from private IPv4" bash -c 'grep -Eq "ip saddr \{[^}]*192\.168\.0\.0/16[^}]*\} meta l4proto \{ tcp, udp \} th dport 53317 accept" <<<"$1"' _ "$NFT"
check "firewall: ...and private IPv6"              bash -c 'grep -Eq "ip6 saddr \{ fc00::/7, fe80::/10 \} .*th dport 53317 accept" <<<"$1"' _ "$NFT"
check "firewall: no unscoped accept of 53317"      bash -c '! grep -E "53317" <<<"$1" | grep -Ev "saddr|drop|^\s*#" | grep -q accept' _ "$NFT"
check "firewall: virtual interfaces dropped first" bash -c 'a=$(grep -n "iifkind.*53317 drop" <<<"$1" | cut -d: -f1); b=$(grep -n "ip saddr.*53317 accept" <<<"$1" | cut -d: -f1); [ -n "$a" ] && [ "$a" -lt "$b" ]' _ "$NFT"
printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
