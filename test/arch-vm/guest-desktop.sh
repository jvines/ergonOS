#!/usr/bin/env bash
# Runs INSIDE the installed system. Installs the desktop, starts Hyprland, and
# interrogates the RUNNING compositor.
#
# This is the part no parser can reach. Hyprland's --verify-config proves the
# config is ACCEPTED; it says nothing about whether the compositor comes up,
# whether waybar maps a surface, or whether the binds actually register. It also
# exercises packages/pacman for real -- every package RESOLVING is not the same
# as every package INSTALLING together without a conflict.
#
# Hyprland has no headless backend, so this needs a DRM device (virtio-gpu) and
# a seat. seatd provides the seat without a logind session, which is what lets
# the whole thing be driven from a serial console.
#
# AUR packages are skipped: wezterm-git would build from source in a VM for no
# benefit. That is exactly why binds.lua carries the foot escape hatch, and foot
# is in the official repo -- so a terminal bind is still exercised.
set -uo pipefail

SHARE=/mnt
P=0; F=0
ok()  { printf '   ok   %s\n' "$*"; P=$((P+1)); }
bad() { printf '   FAIL %s\n' "$*"; F=$((F+1)); }
# Neither pass nor fail: a thing the VM cannot do that the hardware can. Kept
# visibly distinct so it never reads as a silent pass.
note() { printf '   --   %s\n' "$*"; }

finish() { echo "--- $P passed, $F failed ---"; echo "DESKTOP_RESULT=$F"; exit 0; }

echo "--- provisioning ---"
U=$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)
H=$(getent passwd "$U" | cut -d: -f6)

# A WRITABLE copy of the repo. The 9p share is read-only, and provision-arch.sh
# writes into $ERGON -- it scaffolds hosts/<hostname>/ from the template. On a
# real machine the repo is cloned into $HOME, so this is also the realistic
# shape rather than a convenience.
rm -rf "${H:?}/ergonOS"
cp -r "$SHARE" "$H/ergonOS"
chown -R "$U:$U" "$H/ergonOS"
ok "repo copied to $H/ergonOS (writable)"

# Normalise ownership of the user's own directories before anything runs as
# them. This harness does a great deal as root inside $H across many runs on a
# disk that is reused for weeks, and a single root-owned directory under
# ~/.local/share makes every uv command die with a bare
# "Permission denied (os error 13)" naming a path and nothing else.
#
# This is harness hygiene, not a workaround for a product bug: on a real machine
# these directories are created by the user's own session and provisioning runs
# as the user throughout.
for d in .local .local/share .local/bin .cache .config; do
  install -d -o "$U" -g "$U" "$H/$d"
done
chown -R "$U:$U" "$H/.local" "$H/.cache" 2>/dev/null || true
ok "\$HOME/.local and \$HOME/.cache owned by $U"

# Passwordless sudo, HARNESS ONLY. provision-arch.sh must run as the user
# (makepkg refuses root) but uses sudo throughout, and there is no tty to type a
# password at. Removed immediately afterwards.
echo "$U ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-harness
chmod 440 /etc/sudoers.d/99-harness

# ERGON_SKIP_AUR: wezterm-git is a long Rust build and nothing else depends on it.
#
# ERGON_SKIP_NEWS: a fresh Arch install always has unread news, and provision-arch's
# informant guard correctly refuses to run pacman until it is read -- it will not
# mark manual-intervention notices as read on your behalf. That guard is doing
# its job here; this is the override it exists to provide. A HUMAN provisioning a
# real machine should read the news instead.
# ERGON_BUNDLES: exercise the bundle machinery for real. notebooks goes through
# the whole path -- meta, the python list, pyfleet add, the ledger's dist-info
# names, and recording BUNDLES in host.env. An untested installer feature is a
# feature that does not work. Since ERGON-54 it is Jupyter rather than marimo,
# and still the cheapest bundle with a python list: 129 MiB over the base,
# against 443 for inference and 870 for ml (uv, 2026-09-26). r and julia are
# pacman-only, so they would leave the python half of the ledger unexercised.
#
# ERGON_HARDWARE: a VM's DMI says QEMU, so no hardware profile can ever match
# and the profile mechanism would go permanently unexercised. Forcing it is the
# only way to assert that a profile's kernel parameters reach grub.cfg. The lid,
# the ABM block, fprintd and auto-brightness are capabilities, not profile
# items, and are asserted from what this VM actually has.
#
# The bundle ledger records only what an install ADDED, and this disk is reused:
# jupyterlab is in the venv from the previous run (before ERGON-54, from the
# base), so it would rightly never be recorded and the ledger assertion below
# would prove nothing. Every run starts with the notebooks packages absent and
# no ledger. On a fresh disk pyfleet has no uv yet and this does nothing.
su - "$U" -c "$H/ergonOS/bin/pyfleet drop -- jupyterlab ipykernel ipywidgets jupytext" >/dev/null 2>&1 || true
rm -f "$H/.local/state/ergon/bundle-ledger"
# Configs the Framework profile used to write, from runs before they became
# capabilities. They carry no marker, so ergon-hardware rightly never removes
# them, and they would make the capability assertions below pass or fail on a
# previous run's leftovers.
rm -f /etc/systemd/logind.conf.d/10-lid.conf /etc/systemd/sleep.conf.d/10-hibernate.conf \
      /etc/systemd/system/power-profiles-daemon.service.d/10-no-abm.conf
# Provisioning is the longest thing this script does and, until 2026-09-24, the
# quietest: its output went straight into a file, so the console said NOTHING for
# 905s on an idle host and 1452s on a busy one. The harness watching this console
# cannot tell that from a hang, and on 2026-09-24 it stopped telling them apart —
# the weekly suite went red with every assertion passing, because the run was
# slow rather than stuck (bin/test-hypr-session.sh).
#
# So: run it in the background and say where it is every 30 seconds. The full log
# still goes to the file (pacman's output on a serial console is minutes of
# scrolling nobody reads), but the console now carries a heartbeat with the last
# line of real progress on it — which both keeps the watchdog fed and tells a
# person reading the job log what it was doing when it stopped.
su - "$U" -c "ERGON=$H/ergonOS ERGON_SKIP_AUR=1 ERGON_SKIP_NEWS=1 ERGON_BUNDLES=notebooks ERGON_HARDWARE=framework-13-amd bash $H/ergonOS/bin/provision-arch.sh" >/tmp/prov.log 2>&1 &
_prov=$!
_t0=$(date +%s)
while kill -0 "$_prov" 2>/dev/null; do
  sleep 30
  kill -0 "$_prov" 2>/dev/null || break
  printf '   ..   provisioning, %ss: %s\n' "$(( $(date +%s) - _t0 ))" \
    "$(tail -1 /tmp/prov.log 2>/dev/null | tr -d '\r' | cut -c1-72)"
done
if wait "$_prov"; then
  ok "provision-arch.sh completed in $(( $(date +%s) - _t0 ))s"
else
  bad "provision-arch.sh failed"
  tail -25 /tmp/prov.log | sed 's/^/     /'
fi
rm -f /etc/sudoers.d/99-harness

# --- what provisioning was supposed to leave behind ------------------------
# NOT just "the file exists" -- the greetd PACKAGE ships a default config.toml,
# so existence passes on a machine provisioning never touched. Check for our
# content: tuigreet, and the vt1 stanza.
grep -q tuigreet /etc/greetd/config.toml 2>/dev/null \
  && ok "greetd uses tuigreet (ours, not the package default)" \
  || bad "/etc/greetd/config.toml is not ours"
# Assert the command is the one that WORKS, not merely that it mentions uwsm.
# The original checked for the string 'hyprland-uwsm' and passed while the
# command was 'uwsm start -S hyprland-uwsm.desktop' -- which is doubly wrong:
# -S is not a uwsm flag, and hyprland-uwsm.desktop IS the uwsm launcher, so it
# asked uwsm to start uwsm. greetd authenticated and then ran nonsense.
if grep -q "uwsm start -e -D Hyprland hyprland.desktop" /etc/greetd/config.toml 2>/dev/null; then
  ok "greetd session command matches the packaged hyprland-uwsm.desktop"
else
  bad "greetd session command is wrong (see /etc/greetd/config.toml)"
fi
# -S has never been a uwsm flag; catch it explicitly if it ever returns.
grep -q 'uwsm start -S' /etc/greetd/config.toml 2>/dev/null \
  && bad "greetd uses 'uwsm start -S', which errors on an unrecognized argument" \
  || ok "no invalid -S flag in the session command"
# Bundles: installed AND recorded. Two different claims.
if grep -q 'BUNDLES="[^"]*notebooks' "$H/ergonOS/hosts/$(hostname -s)/host.env" 2>/dev/null; then
  ok "the notebooks bundle is recorded in host.env"
else
  bad "host.env did not record the bundle — a reprovision would forget it"
  grep -n BUNDLES "$H/ergonOS/hosts/$(hostname -s)/host.env" 2>/dev/null | sed 's/^/     /'
fi
if su - "$U" -c "\$HOME/.local/share/pyfleet/bin/python -c 'import jupyterlab'" >/dev/null 2>&1; then
  ok "the bundle's python packages are importable in pyfleet"
else
  bad "jupyterlab is not importable — the bundle installed nothing"
fi
# The ledger reads real dist-info names (jupyterlab-4.x.dist-info) and a real
# `pacman -Qq`. A stub cannot prove uv names them the way the ledger parses them.
if grep -qx 'notebooks python jupyterlab' "$H/.local/state/ergon/bundle-ledger" 2>/dev/null; then
  ok "the ledger records what the notebooks bundle installed"
else
  bad "the ledger has no 'notebooks python jupyterlab' — remove would uninstall nothing"
  sed 's/^/     /' "$H/.local/state/ergon/bundle-ledger" 2>/dev/null | head -10
fi
# ERGON-54: marimo is the base notebook, so it runs with no bundle naming it --
# the notebooks bundle above no longer lists it. services/marimo/up.sh starts
# exactly this executable. Only a fresh disk proves the base put it there: a
# reused one keeps marimo from runs when the bundle did.
if su - "$U" -c "\$HOME/.local/share/pyfleet/bin/marimo --version" >/dev/null 2>&1; then
  ok "marimo runs from the base pyfleet, with no bundle"
else
  bad "pyfleet has no working marimo — packages/python did not install it"
fi

# --- ERGON-21: the docker group is opt-in, not a provisioning default ------
# host.env was scaffolded above with the template's default, DOCKER_GROUP=0,
# so THIS run must not have added the user -- sudoless docker is a choice per
# host, not something every install gets for free. usermod's effect on real
# /etc/group is exactly what the hermetic doctor test cannot prove.
if id -nG "$U" | grep -qw docker; then
  bad "DOCKER_GROUP=0 (the default) and provisioning added $U to the docker group anyway"
else
  ok "DOCKER_GROUP=0 (the default): $U was not added to the docker group"
fi
# Flip it for the ERGON-22 re-provision below, which is about to happen anyway
# -- proving the other half (1 DOES add the group) without a fourth full
# provisioning run just for this knob.
sed -i 's/^DOCKER_GROUP=0/DOCKER_GROUP=1/' "$H/ergonOS/hosts/$(hostname -s)/host.env"

# --- ERGON-22: a system change reaching a machine already installed --------
# provision-arch.sh is the only thing that writes system-level state, and
# `ergon sync` used to re-run install.sh alone -- so packages, systemd
# drop-ins, polkit rules and GRUB settings reached fresh installs and nothing
# else. The claim here is the whole round trip on a real machine: provisioned,
# a commit lands upstream that touches a provisioning input, sync notices and
# re-provisions, and doctor then calls the machine current.
#
# The older commit is manufactured by pushing one FORWARD instead of checking
# one out. Every commit older than the one that introduced this carries an
# ergon-sync that cannot detect anything, so rewinding would test the old code;
# going forward exercises the new code over the same range.
G="$H/ergonOS"
STAMP=/var/lib/ergon/provisioned

# ONE row of doctor's JSON, and no verdict on the machine as a whole.
#
# `ergon-doctor` exits 1 when ANY check fails, so its status answers "does this
# whole machine pass" and never "is this row ok". Piped straight into `grep -q`
# under this file's `set -o pipefail`, that status became the pipeline's, and an
# assertion about one row was silently a verdict on every other row. Both of
# this harness's row assertions were written that way and both misreported on
# the run that found nftables.service inactive: "doctor does not call the
# machine current after a sync" failed while printing a provisioned row that was
# ok, and "doctor did not fail the firewall row" failed while printing a row
# whose state WAS fail -- that one, being about a row doctor must fail, could
# never have passed at all. Same defect and same fix as bin/test-provisioning.sh's
# doctor() helper. The whole-machine question is still asked, deliberately and by
# exit status, at "ergon-doctor reports no failures" far below: they are two
# different questions and both are worth asking.
doctor_row() {  # doctor_row <row> <command...> -> that row's JSON object, or ''
  local row=$1; shift
  "$@" 2>/dev/null | grep -o "{\"name\":\"$row\"[^}]*}" || true
}
if grep -qx "commit=$(su - "$U" -c "git -C $G rev-parse HEAD")" "$STAMP" 2>/dev/null; then
  ok "provisioning recorded the commit it ran from in $STAMP"
else
  bad "$STAMP does not record the commit provisioning ran from"
  sed 's/^/     /' "$STAMP" 2>/dev/null
fi

# How the packages arrived, from pacman's own log rather than from the script.
# -Sy WITHOUT -u points the database at today's versions while the installed
# packages stay behind, so the next package pulled in links against a
# libfoo.so.N the old libfoo does not provide -- and `ergon sync` now re-runs
# this on machines that have not been upgraded in months, which is exactly the
# state that bites. Nothing else catches a revert to the -Sy/-S pair: the
# hermetic test stubs provision-arch.sh out, and the stamp says a run happened,
# not how. `pacman -r <root> -Sy` from pacstrap does not match either pattern,
# and the later bare `-S --needed` fallbacks (waybar, graphics) are correct --
# it is the refresh without the upgrade that must never appear.
if grep -q "Running 'pacman -Syu" /var/log/pacman.log 2>/dev/null \
   && ! grep -qE "Running 'pacman -Sy[^u]" /var/log/pacman.log 2>/dev/null; then
  ok "packages were installed in one -Syu transaction, with no bare -Sy refresh"
else
  bad "provisioning did not install in a single -Syu transaction"
  grep -o "Running 'pacman -S[^']*" /var/log/pacman.log 2>/dev/null | sed 's/^/     /' | head -5
fi

echo "$U ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-harness
chmod 440 /etc/sudoers.d/99-harness
# ERGON-20. The re-provision below is the only run in this suite that meets a
# daemon.json already on the machine, so put a key in it that provisioning does
# not write and assert further down that the merge kept it. On a real laptop
# that key is "data-root" pointing at /home, and the stanza used to replace the
# file whole and restart dockerd in the same breath -- the daemon came back on
# /var/lib/docker, where none of the machine's images or volumes are.
if jq -S '."insecure-registries" = ["registry.jvines.cl:5000"]' /etc/docker/daemon.json > /tmp/dj.staged 2>/dev/null \
   && mv /tmp/dj.staged /etc/docker/daemon.json; then
  ok "staged an operator key in daemon.json for the re-provision to keep"
else
  bad "could not stage an operator key in /etc/docker/daemon.json (harness)"
fi
rm -rf /tmp/ergon-origin.git /tmp/ergon-ahead
# git clean: the 9p share is a working tree and can carry work in progress,
# which this copy inherits. ergon-sync rightly refuses a dirty tree, and which
# tree the disk was built from is not what is under test.
if su - "$U" -c "set -e
    git -C $G clean -qfd
    git clone -q --bare $G /tmp/ergon-origin.git
    git -C $G remote set-url origin /tmp/ergon-origin.git
    git clone -q /tmp/ergon-origin.git /tmp/ergon-ahead
    printf '\n# ERGON-22: a provisioning input changes upstream.\n' >> /tmp/ergon-ahead/packages/pacman
    git -C /tmp/ergon-ahead -c user.email=vm@ergon.invalid -c user.name=vm commit -qam 'packages: a provisioning input changes'
    git -C /tmp/ergon-ahead push -q origin HEAD" > /tmp/sync-setup.log 2>&1
then
  su - "$U" -c "ERGON_SKIP_AUR=1 ERGON_SKIP_NEWS=1 $G/bin/ergon-sync --yes" > /tmp/sync.log 2>&1
  ahead=$(su - "$U" -c "git -C $G rev-parse HEAD")
  if grep -qx "commit=$ahead" "$STAMP" 2>/dev/null; then
    ok "ergon sync re-provisioned for an incoming change to packages/pacman"
  else
    bad "sync did not re-provision — the stamp is still $(sed -n 's/^commit=//p' "$STAMP" 2>/dev/null), the repo is at $ahead"
    tail -15 /tmp/sync.log | sed 's/^/     /'
  fi
  _prov_row=$(doctor_row provisioned su - "$U" -c "$G/bin/ergon-doctor --json")
  case "$_prov_row" in
    *'"state":"ok"'*)
      ok "ergon doctor reports the machine as provisioned at the current commit" ;;
    # An absent row is its own failure: a check that never ran proves nothing,
    # and must not fall through into the message about the stamp being stale.
    "")
      bad "doctor printed no 'provisioned' row at all — the check did not run"
      su - "$U" -c "$G/bin/ergon-doctor" 2>&1 | tail -5 | sed 's/^/     /' ;;
    *)
      bad "doctor does not call the machine current after a sync: $_prov_row"
      su - "$U" -c "$G/bin/ergon-doctor" 2>/dev/null \
        | grep -E 'provisioned|base-packages' | sed 's/^/     /' ;;
  esac
  # ERGON-21, other half: this re-provision ran with DOCKER_GROUP=1 (flipped
  # above), so it must have added the group this time.
  if id -nG "$U" | grep -qw docker; then
    ok "DOCKER_GROUP=1: the re-provision above added $U to the docker group"
  else
    bad "DOCKER_GROUP=1 but $U is not in the docker group after re-provisioning"
  fi
else
  bad "could not stage a commit ahead of the guest's repo (harness)"
  tail -5 /tmp/sync-setup.log | sed 's/^/     /'
fi

# --- ERGON-64: greetd unlocks the login keyring ------------------------------
# After BOTH provisioning runs, so "exactly once" is idempotence on the file the
# greetd package really ships. This harness never logs in through greetd; what
# is asked is whether the lines sit where they work, each after its include.
if awk 'p ~ /^auth +include +system-local-login$/ && /^auth +optional +pam_gnome_keyring\.so$/ { a++ }
        p ~ /^session +include +system-local-login$/ && /^session +optional +pam_gnome_keyring\.so +auto_start$/ { s++ }
        /pam_gnome_keyring/ { n++ }  { p = $0 }
        END { exit !(a == 1 && s == 1 && n == 2) }' /etc/pam.d/greetd 2>/dev/null; then
  ok "/etc/pam.d/greetd has pam_gnome_keyring once each, right after its auth and session includes"
else
  bad "/etc/pam.d/greetd does not carry both pam_gnome_keyring lines, once, after the includes"
  sed 's/^/     /' /etc/pam.d/greetd 2>/dev/null
fi
[ -e /usr/lib/security/pam_gnome_keyring.so ] && ok "  and the module is where PAM looks for it" \
  || bad "  but /usr/lib/security/pam_gnome_keyring.so does not exist"
if [ "$(grep -c pam_gnome_keyring /etc/pam.d/passwd)" = 1 ] && grep -A1 -E '^password[[:space:]]+include[[:space:]]+system-auth' \
     /etc/pam.d/passwd | grep -qE '^password[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so$'; then
  ok "/etc/pam.d/passwd re-keys the login keyring, once, right after its include"
else bad "/etc/pam.d/passwd does not carry pam_gnome_keyring once after its include"; sed 's/^/     /' /etc/pam.d/passwd; fi

# --- ERGON-20: the firewall, and where a published port binds --------------
# bin/test-firewall.sh reads the ruleset provisioning WRITES. Only a booted
# machine can say whether the kernel accepted it, and only a running dockerd
# can say what `-p` actually binds -- which is the half a firewall cannot
# cover, because a published port is DNAT'd past the input hook.
echo "--- firewall ---"
# What provisioning printed for a stage, from whichever log caught the run. It
# is printed HERE, on failure, because provisioning's own account of this stage
# was thrown away: /tmp/prov.log is dumped only when provisioning EXITS
# non-zero, and a stage that warns still exits zero. The run that found
# nftables.service inactive therefore had provisioning's warnings, the unit
# status and the journal all sitting on the disk, and reported none of them --
# 35 minutes for a failure with no evidence in it.
prov_stage() {  # prov_stage <stage title> -- that stage's lines from both runs
  local title=$1 log
  for log in /tmp/prov.log /tmp/sync.log; do
    [ -s "$log" ] || continue
    printf '     --- %s said, under "%s" ---\n' "$log" "$title"
    sed 's/\x1b\[[0-9;]*m//g' "$log" \
      | sed -n "/^== $title\$/,/^== /p" | sed '$d' | sed 's/^/     /'
  done
}
_fw_explained=0
firewall_why() {  # everything the next reader needs, once per run
  [ "$_fw_explained" = 0 ] || return 0
  _fw_explained=1
  echo "     --- systemctl status nftables ---"
  systemctl status --no-pager --full nftables 2>&1 | sed 's/^/     /'
  echo "     --- journalctl -u nftables ---"
  journalctl -u nftables --no-pager -n 30 2>&1 | sed 's/^/     /'
  prov_stage "firewall and container publishing"
}
grep -q 'table inet ergon' /etc/nftables.conf 2>/dev/null \
  && ok "/etc/nftables.conf is ours, not the nftables package's default" \
  || bad "/etc/nftables.conf does not define the inet ergon table"
# Arch's packaged unit is Type=oneshot with no RemainAfterExit=, so it is
# "inactive (dead)" a moment after a perfectly successful load. Our drop-in is
# what makes this question meaningful at all -- and asking it is what caught the
# drop-in adding an ExecStop to a unit that had none, which destroyed the table
# ExecStart had just loaded.
if systemctl is-active --quiet nftables; then
  ok "nftables.service is active"
else
  bad "nftables.service is not active — the ruleset provisioning wrote did not load"
  nft -c -f /etc/nftables.conf 2>&1 | sed 's/^/     /'
  firewall_why
fi
# policy drop in the KERNEL, not a string in the file. --verify-config passing
# while nothing was registered is this repo's standing lesson.
if _chain=$(nft list chain inet ergon input 2>/dev/null) && [ -z "${_chain##*policy drop*}" ]; then
  ok "inet ergon input is loaded with policy drop"
else
  bad "the inet ergon input chain is not loaded with policy drop"
  nft list ruleset 2>&1 | head -20 | sed 's/^/     /'
  firewall_why
fi

# THE caveat this card turns on. Docker's rules live in the same nf_tables
# backend through iptables-nft, so `flush ruleset` -- in the file, or in an
# ExecStop, which is where upstream's really is -- destroys the DOCKER chains of
# a running daemon and every container silently loses its networking. Both
# halves are asserted, because the drop-in is what makes the scoped ruleset
# survive the verb people actually type. (Arch ships no ExecStop at all, so on
# THIS distro the drop-in is not narrowing a flush, it is supplying the teardown
# the unit does not have -- which is why it must also set RemainAfterExit=yes.)
# Read the property, THEN judge it, and require the scoped teardown rather than
# merely the absence of the wide one. As `systemctl show ... | grep -q 'flush
# ruleset' || ok` this answered "stops by destroying only the ergon table" for
# three machines that do not: one where systemctl itself failed, one where the
# unit is unknown, and -- the case that matters on Arch, which ships NO ExecStop
# -- one where the drop-in never reached the unit, so stopping nftables leaves
# the ergon table loaded and `is-active` lies about it. grep's 1 for "that string
# is absent" was standing in for a positive claim it cannot make.
_execstop=$(systemctl show nftables -p ExecStop 2>/dev/null)
case "$_execstop" in
  *'flush ruleset'*)
    bad "nftables.service still stops with 'nft flush ruleset' — a restart would wipe docker's chains" ;;
  *'destroy table inet ergon'*)
    ok "nftables.service stops by destroying only the ergon table" ;;
  ExecStop=)
    bad "nftables.service has no ExecStop at all — the drop-in never reached the unit, so a stop leaves the ergon table loaded"
    firewall_why ;;
  *)
    bad "could not read nftables.service's ExecStop, so its teardown was not checked: '${_execstop:-systemctl printed nothing}'"
    firewall_why ;;
esac
if ! nft list chain ip nat DOCKER >/dev/null 2>&1; then
  note "no ip nat DOCKER chain on this machine — nothing for a reload to wipe, so that claim is untested"
else
  # Three separate facts, reported separately. As one conjunction this said
  # "restarting nftables destroyed docker's nat chains" on a run where docker's
  # chains were never touched and OUR chain was the one that did not come back —
  # a true failure pointing at the wrong half of the card.
  systemctl restart nftables; _fw_rc=$?
  [ "$_fw_rc" = 0 ] || { bad "systemctl restart nftables failed (exit $_fw_rc)"; firewall_why; }
  nft list chain ip nat DOCKER >/dev/null 2>&1 \
    && ok "restarting nftables keeps docker's nat chains" \
    || bad "restarting nftables destroyed docker's nat chains — every running container just lost its network"
  if _chain=$(nft list chain inet ergon input 2>/dev/null) && [ -z "${_chain##*policy drop*}" ]; then
    ok "  and reloads our own"
  else
    bad "  but the ergon chain did not come back after the restart"
    firewall_why
  fi
fi

# The doctor row's dangerous state, and the one only a booted machine has: the
# unit is Type=oneshot and our drop-in makes it RemainAfterExit=yes, so
# `systemctl is-active` still says active after someone types `nft flush
# ruleset` while debugging. doctor read a failed `nft list` as "I am not root"
# and answered ok — as root, on a machine with an empty ruleset. Asserted with
# root in hand, which is the only way to reach that branch at all.
if nft destroy table inet ergon 2>/dev/null; then
  # `env`, not an ERGON= prefix on the function call: in bash a prefix assignment
  # to a SHELL FUNCTION stays set after it returns, and ERGON is read again below.
  _fw_row=$(doctor_row firewall env ERGON="$G" "$G/bin/ergon-doctor" --json)
  case "$_fw_row" in
    *'"state":"fail"'*)
      ok "as root and with no ergon table, doctor fails the firewall row" ;;
    "")
      bad "doctor printed no 'firewall' row at all — the check did not run" ;;
    *)
      bad "doctor did not fail the firewall row on a machine where nothing filters inbound: $_fw_row" ;;
  esac
  # Put it back before anything else runs, and say whether that worked: the
  # tests after this one must not be quietly running on an unfiltered machine.
  if systemctl restart nftables >/dev/null 2>&1 \
     && _chain=$(nft list chain inet ergon input 2>/dev/null) && [ -z "${_chain##*policy drop*}" ]; then
    ok "and the ruleset is back after a restart"
  else
    bad "the ruleset did not come back — the rest of this run is unfiltered"
    firewall_why
  fi
else
  note "could not destroy the ergon table — doctor's root-with-no-table branch was not tested"
fi

echo "--- where docker publishes ---"
grep -q '"ip"[[:space:]]*:[[:space:]]*"127\.0\.0\.1"' /etc/docker/daemon.json 2>/dev/null \
  && ok "daemon.json binds published ports to 127.0.0.1" \
  || bad "/etc/docker/daemon.json does not set \"ip\": \"127.0.0.1\""
# The merge, end to end. The key above was staged into daemon.json before
# ergon-sync re-provisioned this machine, so this says whether provisioning
# keeps what a machine had or writes over it — and dockerd was restarted in
# between, which is what makes losing it expensive rather than cosmetic.
if [ "$(jq -r '."insecure-registries"[0] // ""' /etc/docker/daemon.json 2>/dev/null)" = registry.jvines.cl:5000 ]; then
  ok "re-provisioning merged into daemon.json and kept the operator key"
else
  bad "re-provisioning discarded what was already in daemon.json"
  sed 's/^/     /' /etc/docker/daemon.json 2>/dev/null
fi
# The binding itself, which is the acceptance criterion. busybox is ~4 MB and
# the container never has to serve anything: what listens on the host is
# dockerd's proxy for the published port, and that is the thing under test.
# The harness has user-mode NAT so the pull works, but it can fail offline --
# a missing image says nothing about where docker binds, so that is a note and
# not a failure.
if docker image inspect busybox >/dev/null 2>&1 \
   || timeout 180 docker pull -q busybox >/dev/null 2>&1; then
  docker rm -f ergon-fw-probe >/dev/null 2>&1 || true
  if docker run -d --name ergon-fw-probe -p 8080:80 busybox sleep 60 >/dev/null 2>&1; then
    sleep 1
    _bound=$(ss -ltn 2>/dev/null | awk '{print $4}' | grep ':8080$' | sort | tr '\n' ' ' | sed 's/ $//')
    case "$_bound" in
      "127.0.0.1:8080") ok "docker run -p 8080:80 listens on 127.0.0.1:8080 and nowhere else" ;;
      "")               bad "nothing listens on 8080 after publishing it — the probe did not come up, or userland-proxy is off and only the DNAT would show" ;;
      *)                bad "a published port listens on '$_bound', not 127.0.0.1:8080 alone" ;;
    esac
    docker rm -f ergon-fw-probe >/dev/null 2>&1 || true
  else
    bad "the probe container would not start; where a published port binds was not tested"
  fi
else
  note "no busybox image and the pull failed (offline?) — where a published port binds was not tested"
fi
rm -f /etc/sudoers.d/99-harness

# --- a bundle from a real forge, over ssh on a non-standard port ------------
# test-bundles.sh fetches from a local repository through stubs. This is the
# path a private overlay actually takes: sshd on 2222, the user's own key,
# known_hosts, and never a prompt. With real pacman and uv it also proves the
# ledger leaves alone a package that was there before the bundle, and that sync
# reinstalls a bundle with its forge gone.
asu() { su - "$U" -c "$1"; }
EB="$H/ergonOS/bin/ergon-bundle"
FORGE=/tmp/ergon-forge
URL="ssh://$U@127.0.0.1:2222$H/pub/overlay.git"
COPY="$H/ergonOS/hosts/$(hostname -s)/bundles/demo"
LEDGER="$H/.local/state/ergon/bundle-ledger"

# This disk is reused: clear the previous run's forge, packages and venv entry.
[ ! -f "$FORGE/pid" ] || kill "$(cat "$FORGE/pid")" 2>/dev/null || true
rm -rf "$FORGE" "$H/pub"
pacman -Rns --noconfirm cowsay >/dev/null 2>&1 || true
asu "\$HOME/ergonOS/bin/pyfleet drop -- tomli-w" >/dev/null 2>&1 || true
# figlet is installed BEFORE the bundle, which also lists it: remove must leave it.
pacman -S --needed --noconfirm figlet >/dev/null 2>&1 || bad "could not preinstall figlet (harness)"

forge_ok=1
asu "set -e
  export GIT_AUTHOR_NAME=vm GIT_AUTHOR_EMAIL=vm@ergon.invalid GIT_COMMITTER_NAME=vm GIT_COMMITTER_EMAIL=vm@ergon.invalid
  mkdir -p \$HOME/pub/work/demo
  printf 'DESCRIPTION=\"VM forge test\"\n' > \$HOME/pub/work/demo/meta
  printf 'cowsay\nfiglet\n' > \$HOME/pub/work/demo/pacman
  printf 'tomli-w\n' > \$HOME/pub/work/demo/python
  git -C \$HOME/pub/work init -q -b main
  git -C \$HOME/pub/work add -A
  git -C \$HOME/pub/work commit -qm demo
  git -C \$HOME/pub/work tag -a -m v1 v1
  git clone -q --bare \$HOME/pub/work \$HOME/pub/overlay.git
  install -d -m 700 \$HOME/.ssh
  [ -f \$HOME/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f \$HOME/.ssh/id_ed25519
  touch \$HOME/.ssh/authorized_keys && chmod 600 \$HOME/.ssh/authorized_keys
  grep -qxF \"\$(cat \$HOME/.ssh/id_ed25519.pub)\" \$HOME/.ssh/authorized_keys || cat \$HOME/.ssh/id_ed25519.pub >> \$HOME/.ssh/authorized_keys
  ssh-keygen -R '[127.0.0.1]:2222' >/dev/null 2>&1 || true" > /tmp/forge.log 2>&1 \
  || { forge_ok=0; bad "could not build the forge repository or key (harness)"; tail -5 /tmp/forge.log | sed 's/^/     /'; }

install -d -m 700 "$FORGE"
ssh-keygen -q -t ed25519 -N '' -f "$FORGE/host_key"
printf 'Port 2222\nListenAddress 127.0.0.1\nHostKey %s/host_key\nPidFile %s/pid\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nAuthenticationMethods publickey\n' \
  "$FORGE" "$FORGE" > "$FORGE/sshd_config"
# sshd re-execs itself, which it refuses to do from a relative path.
if [ "$forge_ok" = 1 ] && /usr/bin/sshd -t -f "$FORGE/sshd_config" 2> "$FORGE/err" && /usr/bin/sshd -f "$FORGE/sshd_config" 2>> "$FORGE/err"; then
  for _ in $(seq 20); do [ -s "$FORGE/pid" ] && break; sleep 0.5; done
fi
[ -s "$FORGE/pid" ] || { [ "$forge_ok" = 0 ] || bad "sshd on 2222 did not start (harness)"; sed 's/^/     /' "$FORGE/err" 2>/dev/null; forge_ok=0; }

if [ "$forge_ok" = 1 ]; then
  echo "$U ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-harness
  chmod 440 /etc/sudoers.d/99-harness

  # No known_hosts entry yet. BatchMode must turn the host-key question into a
  # fast failure: a prompt during provisioning is a hang nobody can answer.
  rc=0; asu "timeout 90 $EB info $URL//demo@v1" > /tmp/bundle-forge.log 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && grep -q 'Fetches never prompt' /tmp/bundle-forge.log; then
    ok "an unknown forge host key fails at once, without prompting"
  else
    bad "an unknown forge host key did not fail cleanly (exit $rc; 124 is a hang)"
    tail -5 /tmp/bundle-forge.log | sed 's/^/     /'
  fi

  asu "ssh-keyscan -p 2222 -t ed25519 127.0.0.1 >> \$HOME/.ssh/known_hosts 2>/dev/null"
  if asu "timeout 600 $EB add --yes $URL//demo@v1" > /tmp/bundle-forge.log 2>&1; then
    ok "added a bundle from $URL"
  else
    bad "add from the ssh forge on 2222 failed"
    tail -10 /tmp/bundle-forge.log | sed 's/^/     /'
  fi
  pacman -Q cowsay >/dev/null 2>&1 && ok "  its pacman package is installed" || bad "  cowsay is not installed"
  asu "\$HOME/.local/share/pyfleet/bin/python -c 'import tomli_w'" >/dev/null 2>&1 \
    && ok "  its python package imports in pyfleet" || bad "  tomli_w does not import"
  v1=$(asu "git -C \$HOME/pub/work rev-parse 'v1^{commit}'" 2>/dev/null)
  if grep -qxF "url=$URL" "$COPY/.source" 2>/dev/null && grep -qxF "commit=$v1" "$COPY/.source" 2>/dev/null; then
    ok "  the copy records the ssh URL with its port, and the tag's commit"
  else
    bad "  hosts/$(hostname -s)/bundles/demo/.source does not record $URL at $v1"
    sed 's/^/     /' "$COPY/.source" 2>/dev/null
  fi
  if grep -qx 'demo pacman cowsay' "$LEDGER" && grep -qx 'demo python tomli-w' "$LEDGER" && ! grep -qx 'demo pacman figlet' "$LEDGER"; then
    ok "  the ledger records cowsay and tomli-w, and not figlet, which was already here"
  else
    bad "  the ledger is wrong for demo"
    grep '^demo ' "$LEDGER" 2>/dev/null | sed 's/^/     /'
  fi

  # The forge goes away; the copy is the pin, so sync still reinstalls.
  kill "$(cat "$FORGE/pid")" 2>/dev/null || true
  sleep 1
  pacman -Rns --noconfirm cowsay >/dev/null 2>&1 || true
  if asu "timeout 900 $EB sync" > /tmp/bundle-forge.log 2>&1 && pacman -Q cowsay >/dev/null 2>&1; then
    ok "sync reinstalled the bundle with its forge down"
  else
    bad "sync did not reinstall cowsay without the forge"
    tail -10 /tmp/bundle-forge.log | sed 's/^/     /'
  fi

  asu "timeout 300 $EB remove demo" > /tmp/bundle-forge.log 2>&1 || { bad "remove demo failed"; tail -10 /tmp/bundle-forge.log | sed 's/^/     /'; }
  pacman -Q cowsay >/dev/null 2>&1 && bad "remove left cowsay installed" || ok "remove uninstalled what the bundle installed"
  pacman -Q figlet >/dev/null 2>&1 && ok "  and left figlet, which was there before it" || bad "  remove uninstalled figlet, which the bundle did not install"
  asu "\$HOME/.local/share/pyfleet/bin/python -c 'import tomli_w'" >/dev/null 2>&1 \
    && bad "  tomli_w still imports after remove" || ok "  and dropped its python package"
  if [ ! -e "$COPY" ] && ! grep -q '^demo ' "$LEDGER" 2>/dev/null; then
    ok "  and forgot the copy and its ledger entries"
  else
    bad "  the copy or its ledger entries survived remove"
  fi
  rm -f /etc/sudoers.d/99-harness
fi
[ ! -f "$FORGE/pid" ] || kill "$(cat "$FORGE/pid")" 2>/dev/null || true
rm -rf "$FORGE"

# The regdom must match the machine's ACTUAL timezone, not a constant. This
# asserted only that the file exists, which was true while it said CL on every
# machine on earth.
_tz=$(timedatectl show -p Timezone --value 2>/dev/null)
_want=$(awk -v t="$_tz" '$1 !~ /^#/ && $3 == t { print $1; exit }' /usr/share/zoneinfo/zone.tab 2>/dev/null | cut -c1-2)
_got=$(awk -F= '/ieee80211_regdom/ { print $NF }' /etc/modprobe.d/cfg80211.conf 2>/dev/null)
if [ -n "$_got" ] && [ "$_got" = "${_want:-00}" ]; then
  ok "wifi regdom $_got derived from $_tz"
else
  bad "regdom is '$_got', expected '${_want:-00}' for timezone $_tz"
fi

# The compositor keyboard layout must be the one the installer was told about.
_kb=$(awk -F= '/^KEYMAP=/ { gsub(/"/, "", $2); print $2 }' /etc/vconsole.conf 2>/dev/null)
if grep -q "kb_layout = \"${_kb:-us}\"" "$H/ergonOS/hosts/$(hostname -s)/hyprland.lua" 2>/dev/null; then
  ok "kb_layout scaffolded as '${_kb:-us}' from /etc/vconsole.conf"
else
  bad "kb_layout not scaffolded per host (expected '${_kb:-us}')"
  grep -n kb_layout "$H/ergonOS/hosts/$(hostname -s)/hyprland.lua" 2>/dev/null | sed 's/^/     /'
fi
# The directory first. `grep -rq ... && bad || ok` reported "no keyboard layout
# hardcoded" for a common/ that install.sh had never linked, because grep's 2 for
# "no such directory" and its 1 for "no match" both skip the bad and land on ok.
if [ ! -d "$H/.config/hypr/common" ]; then
  bad "no $H/.config/hypr/common — the shared config was never linked, so nothing was checked"
elif grep -rq 'kb_layout = "us"' "$H/.config/hypr/common/"; then
  bad "the shared config still hardcodes a keyboard layout"
else
  ok "no keyboard layout hardcoded in the shared config"
fi

# Microcode belongs to the CPU that is present.
case "$(awk -F': ' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo)" in
  GenuineIntel) _uc=intel-ucode ;;
  AuthenticAMD) _uc=amd-ucode ;;
  *)            _uc="" ;;
esac
if [ -z "$_uc" ]; then
  ok "unknown CPU vendor; no microcode expected"
elif pacman -Qi "$_uc" >/dev/null 2>&1; then
  ok "$_uc installed (matches this CPU)"
else
  bad "$_uc is not installed for this CPU"
fi
# --- hardware, by capability ---------------------------------------------------
# The VM is made s2idle-only (test-hypr-session.sh) and the disk has working
# hibernation (test-hibernate.sh), so the lid rule must take the positive path.
# It has virtio-gpu and no light sensor, so the amdgpu and auto-brightness rules
# must NOT apply. The Framework profile is forced, so its kernel parameter must.
MARK="# Written by ergon-hardware from what this machine has; removed when that stops being true."
if grep -qx '\[s2idle\]' /sys/power/mem_sleep 2>/dev/null; then
  ok "the VM firmware offers s2idle only (S3 disabled)"
else
  bad "the VM still offers S3 ($(cat /sys/power/mem_sleep 2>/dev/null)); the lid assertion below proves nothing"
fi
if grep -qxF "$MARK" /etc/systemd/logind.conf.d/10-lid.conf 2>/dev/null \
   && grep -qx 'HandleLidSwitch=suspend-then-hibernate' /etc/systemd/logind.conf.d/10-lid.conf; then
  ok "lid -> suspend-then-hibernate, chosen from s2idle-only firmware and working hibernation"
else
  bad "no generated lid drop-in on an s2idle-only machine with hibernation"
  grep -A3 'lid' /tmp/prov.log 2>/dev/null | head -4 | sed 's/^/     /'
fi
[ ! -e /etc/systemd/system/power-profiles-daemon.service.d/10-no-abm.conf ] \
  && ok "no ABM drop-in on a machine without an amdgpu panel" || bad "ABM drop-in written without an amdgpu panel"
systemctl is-enabled ergon-fprintd-resume.service >/dev/null 2>&1 \
  && ok "fprintd is restarted after resume" || bad "ergon-fprintd-resume.service is not enabled"
pacman -Q illuminanced >/dev/null 2>&1 \
  && bad "illuminanced installed on a machine with no light sensor" || ok "no auto-brightness without a light sensor"
if grep -q 'amdgpu.dcdebugmask=0x610' /etc/default/grub && grep -q 'amdgpu.dcdebugmask=0x610' /boot/grub/grub.cfg; then
  ok "the forced Framework profile's kernel parameter is in grub.cfg"
else
  bad "the Framework profile's kernel parameter did not reach grub.cfg"
fi
_sc=$(su - "$U" -c "$H/ergonOS/bin/ergon-sleep check" 2>&1)
if printf '%s\n' "$_sc" | grep -q 's2idle only' && printf '%s\n' "$_sc" | grep -q 'hibernation: ready'; then
  ok "ergon-sleep check reads s2idle-only and hibernation ready"
else
  bad "ergon-sleep check disagrees with this machine"
  printf '%s\n' "$_sc" | sed 's/^/     /' | head -8
fi

# snap-pac hooks pacman and snapshots around every transaction, which is what
# makes a bad update survivable. It is installed by arch-bootstrap.sh -- but
# "the package is installed" and "a snapshot happened" are different claims, and
# this file exists because of that distinction.
#
# Provisioning just ran pacman, so a pre/post pair must exist by now.
if command -v snapper >/dev/null 2>&1; then
  _snaps=$(snapper -c root list 2>/dev/null || true)
  _pre=$(printf '%s\n' "$_snaps" | grep -cw pre || true)
  _post=$(printf '%s\n' "$_snaps" | grep -cw post || true)
  if [ "${_pre:-0}" -ge 1 ] && [ "${_post:-0}" -ge 1 ]; then
    ok "snap-pac snapshotted around pacman ($_pre pre / $_post post)"
  else
    bad "no pre/post snapshot pair — a bad update would not be survivable"
    printf '%s\n' "$_snaps" | tail -8 | sed 's/^/     /'
    for _h in /usr/share/libalpm/hooks/*snap*; do
      [ -e "$_h" ] && echo "     hook: ${_h##*/}"
    done
  fi
else
  bad "snapper is not installed"
fi

# grub-btrfs turns those snapshots into bootable GRUB entries, which is the
# difference between "you can roll back" and "you can roll back without a live
# USB and a manual btrfs subvolume swap".
if systemctl is-enabled grub-btrfsd >/dev/null 2>&1; then
  ok "grub-btrfsd enabled (snapshots appear in the boot menu)"
else
  bad "grub-btrfsd is not enabled — snapshots will not be bootable"
fi

grep -q 'TIMELINE_LIMIT_HOURLY="5"' /etc/snapper/configs/root 2>/dev/null \
  && ok "snapper timeline trimmed" || bad "snapper timeline not trimmed"
id -nG "$U" | grep -qw video && ok "$U added to video by provisioning" || bad "$U not in video"
[ -d "$H/ergonOS/hosts/$(hostname -s)" ] && ok "hosts/$(hostname -s) scaffolded" || bad "host dir not scaffolded"

# greetd would start a greeter on vt1 and take the seat and the DRM device out
# from under the compositor this test starts by hand. Stop it for the duration.
systemctl stop greetd >/dev/null 2>&1 || true

# The click fix lives in the PACKAGE, not in any config: extra/waybar 0.15.0
# cannot switch workspaces against a Lua-configured Hyprland (Alexays/Waybar
# #5013 -- on master, not yet in a release). Assert what is actually on disk;
# provisioning logs its AUR stage to a file this harness never reads, which is
# how a failed waybar-git build went unnoticed through a whole run.
if pacman -Qi waybar-git >/dev/null 2>&1; then
  ok "waybar-git is installed (workspace clicks can work)"
else
  bad "waybar-git NOT installed: $(pacman -Qo "$(command -v waybar 2>/dev/null)" 2>&1 | tail -1)"
  sed -n '/AUR packages/,$p' /tmp/prov.log 2>/dev/null | tail -20 | sed 's/^/       /'
fi

# ERGON-29: a pin in packages/aur is only worth having if the build actually
# used it. ergon-aur detaches the clone onto that commit before makepkg and
# records what it built from -- and provisioning has just run, so both of those
# are this machine's own answer rather than a claim in a file. Stubs can prove
# the checkout; only a real provision proves the pin survives the path
# provisioning actually takes.
PIN=$(awk '$1 == "waybar-git" && match($0, /pin=[0-9a-f]{7,40}/) {
             print substr($0, RSTART + 4, RLENGTH - 4) }' "$H/ergonOS/packages/aur")
if [ -z "$PIN" ]; then
  note "waybar-git carries no pin in packages/aur; nothing to honour"
else
  BUILT_FROM=$(awk '$1 == "waybar-git" { print $2 }' "$H/.local/state/ergon/aur-builds" 2>/dev/null)
  [ "$BUILT_FROM" = "$PIN" ] \
    && ok "waybar-git was built from the PKGBUILD commit packages/aur pins" \
    || bad "waybar-git was built from '${BUILT_FROM:-nothing recorded}', not the pinned $PIN"
  AT=$(git -C "$H/.cache/aur/waybar-git" rev-parse HEAD 2>/dev/null)
  [ "$AT" = "$PIN" ] \
    && ok "  and the clone it builds in is checked out at exactly that commit" \
    || bad "  but the clone sits at '${AT:-nothing}', not $PIN"
fi

# ERGON-29: the rebuild `ergon update` performs builds the SAME commit again --
# only the libraries under it moved -- into the clone the previous build already
# left a package in, and makepkg REFUSES to overwrite one ("A package has
# already been built") rather than rebuilding it. No stub can show that:
# bin/test-aur.sh's makepkg is a script that writes a file, so it reproduces the
# refusal only because it was told to. This is the real makepkg, over a package
# provisioning built minutes ago.
#
# openai-codex-bin rather than waybar-git: it is a downloaded static binary, so
# the rebuild costs a fetch instead of a compile, and the collision is the same
# one.
AURD=$H/.cache/aur/openai-codex-bin
PREV=$(ls -- "$AURD"/*.pkg.tar.* 2>/dev/null | head -1)
if [ -z "$PREV" ]; then
  note "no built package under $AURD; a rebuild there would collide with nothing"
else
  # makepkg -i installs through sudo, and the harness password-less rule was
  # removed after provisioning. Back for this one command only.
  echo "$U ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-harness
  chmod 440 /etc/sudoers.d/99-harness
  if su - "$U" -c "ERGON=$H/ergonOS $H/ergonOS/bin/ergon-aur --rebuild openai-codex-bin" \
       > /tmp/rebuild.log 2>&1; then
    ok "a rebuild builds over the package the previous build left in the clone"
  else
    bad "ergon aur --rebuild failed where a package of its own was already built"
    tail -5 /tmp/rebuild.log | sed 's/^/       /'
  fi
  rm -f /etc/sudoers.d/99-harness
fi

# Any DRM card, not card0 specifically: with virtio-vga-gl the guest can
# enumerate the device under a different index, and gating on card0 aborted the
# whole desktop phase on a VM that demonstrably had a working GPU.
if ls /dev/dri/card* >/dev/null 2>&1; then
  ok "DRM device present ($(ls -m /dev/dri/card* 2>/dev/null))"
  # WHICH card matters. A UEFI framebuffer shows up as simpledrm with no render
  # node; the virtio-gpu is the one that can do GL and dmabuf. If the compositor
  # lands on the first and the renderer is on the second, everything draws but
  # nothing composites -- which is exactly the flat wallpaper and the dead grim.
  for c in /dev/dri/card*; do
    n=$(basename "$c")
    drv=$(basename "$(readlink -f "/sys/class/drm/$n/device/driver" 2>/dev/null)" 2>/dev/null)
    rnd=$(ls -d /sys/class/drm/"$n"/device/drm/render* 2>/dev/null | head -1)
    note "$n: driver=${drv:-unknown} render_node=${rnd:+yes}${rnd:-no}"
  done
  note "aquamarine chose: $(grep -oE "/dev/dri/card[0-9]+" /run/user/1000/hypr/*/hyprland.log 2>/dev/null | sort -u | tr "\n" " ")"
else
  bad "no DRM card at all — /dev/dri holds: $(ls -m /dev/dri 2>/dev/null || echo 'nothing')"
  finish
fi

# --- configs, placed BY install.sh -----------------------------------------
# This used to `cp -r` the four config directories into place and symlink
# bin/ergon* into ~/.local/bin by hand. It passed every assertion below and left a
# desktop you could not use: install.sh also links environment.d/10-ergon-path.conf,
# which is what puts $ERGON/bin on the SESSION PATH. Without it every waybar
# module whose on-click is `ergon-launch-tui ...` fires into nothing -- so the bar
# looked right, mapped its surface, passed the test, and only the bluetooth
# button (on-click: blueman-manager, a real binary) actually did anything.
#
# A harness that stages its own approximation of the install tests the harness.
# Run the installer.
printf 'GRAPHICAL=1\nPROFILE=laptop\n' > "$H/ergonOS/hosts/$(hostname -s)/host.env"
chown "$U:$U" "$H/ergonOS/hosts/$(hostname -s)/host.env"
if su - "$U" -c "cd ~/ergonOS && ERGON=\$HOME/ergonOS ./install.sh" >/tmp/install.log 2>&1; then
  ok "install.sh completed"
else
  bad "install.sh failed"; tail -20 /tmp/install.log | sed 's/^/     /'
fi

# Assert the LINKS, not the copies. Each of these is a thing that was missing.
# The reaper timer is what keeps "services are off by default" true past login.
# `systemctl --user is-enabled` needs a session bus and there is none here, so
# check the thing enabling actually IS: the WantedBy symlink. That is also what
# a fresh machine has before its first graphical login, which is the case that
# was broken.
# The unit's ExecStart must point at a binary that EXISTS. A stale path there
# fails every ten minutes, silently, in a log nobody reads -- which is exactly
# what the repo rename did to it.
_exec=$(sed -n 's/^ExecStart=//p' "$H/.config/systemd/user/ergon-reap.service" 2>/dev/null | awk '{print $1}')
_exec=${_exec/\%h/$H}
if [ -x "$_exec" ]; then
  ok "ergon-reap ExecStart resolves ($_exec)"
else
  bad "ergon-reap ExecStart does not exist: '$_exec'"
fi

if [ -L "$H/.config/systemd/user/timers.target.wants/ergon-reap.timer" ]; then
  ok "ergon-reap.timer enabled (wants symlink present)"
else
  bad "ergon-reap.timer not enabled — idle services would run forever"
  ls -la "$H/.config/systemd/user/timers.target.wants/" 2>/dev/null | sed 's/^/     /'
fi

for pair in \
  ".config/hypr:the compositor config" \
  ".config/waybar:the bar" \
  ".config/mako:notifications" \
  ".config/fuzzel:the launcher" \
  ".config/gtk-3.0/settings.ini:GTK3 theme" \
  ".config/environment.d/10-ergon-path.conf:session PATH" \
  ".config/uwsm/env-hyprland.d/ergon-keyring:the Electron keyring variable"; do
  f=${pair%%:*}; what=${pair#*:}
  [ -e "$H/$f" ] && ok "install.sh linked $what" || bad "install.sh did not link $f ($what)"
done

# The user must be in `video` to open /dev/dri/card*, which are root:video 0660.
# Without it Hyprland dies with "CBackend::create() failed!" and nothing else --
# no permission error, no mention of DRM. provision-arch.sh does this on a real
# machine; this test bypasses provisioning, so it has to do it too. That the
# omission produced exactly this crash is a decent argument that the
# provision-arch step is load-bearing rather than defensive.
usermod -aG video,input,render,seat "$U" 2>/dev/null || usermod -aG video,input,render "$U" 2>/dev/null || true
id -nG "$U" | tr ' ' '\n' | grep -qx video && ok "$U is in the video group" || bad "$U is not in video"

systemctl start seatd >/dev/null 2>&1 || seatd -g wheel >/tmp/seatd.log 2>&1 &
sleep 2
pgrep -x seatd >/dev/null && ok "seatd running" || bad "seatd did not start"

# --- start the compositor --------------------------------------------------
echo "--- starting Hyprland ---"
# A USER MANAGER, before anything else touches /run/user/1000.
#
# This harness has never had one: it is driven from a serial console, so there
# is no logind session, and without a session there is no user@1000.service, no
# session bus, no app.slice and no oomd policy in it. The out-of-memory section
# far below was gated on asking that manager a question, so it asked nothing and
# asserted nothing on every run. Lingering starts the manager with no session at
# all, which is exactly the gap.
#
# FIRST, and not later: user-runtime-dir@1000.service mounts a tmpfs on
# /run/user/1000, so lingering after the compositor has put its socket there
# hides the socket and takes the rest of this suite with it.
loginctl enable-linger "$U" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do [ -S /run/user/1000/bus ] && break; sleep 1; done
if [ -S /run/user/1000/bus ]; then
  ok "systemd --user is running for $U (lingering), so this session has a bus and an app.slice"
else
  note "no user manager here: the containment checks below can only be asked of one"
fi
install -d -o "$U" -g "$U" -m 700 /run/user/1000
cat > /tmp/start-hypr.sh <<'EOF'
export XDG_RUNTIME_DIR=/run/user/1000
export LIBSEAT_BACKEND=seatd
export XDG_CURRENT_DESKTOP=Hyprland

# The session bus, which exists here only because the harness lingers the user
# above. mako, notify-send and everything else that speaks D-Bus find the bus
# through this variable and nothing else: without it a notification is dropped
# with no error anywhere, which reads as "the notification code is broken".
[ -S "$XDG_RUNTIME_DIR/bus" ] && export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

# PATH comes from the same file systemd --user would read, not from a
# convenient reimplementation of it. This session is started by hand and so has
# no systemd user manager to apply environment.d -- but if the test invents its
# own PATH, it proves the PATH the test invented, which is how a broken
# environment.d link survived a green run.
ENVD="$HOME/.config/environment.d/10-ergon-path.conf"
if [ -r "$ENVD" ]; then
  set -a; . "$ENVD"; set +a
else
  echo "WARNING: $ENVD missing; ergon-* will not be on PATH" >&2
fi

# The same argument for uwsm's env files, which a greetd login gets from uwsm
# and this one does not (ERGON-64: GNOME_DESKTOP_SESSION_ID). Loaded as uwsm
# loads them -- env, then env-<desktop name, lowercased>, each followed by its
# .d/ drop-ins, with `.` and NO set -a: uwsm keeps only what a file exports.
for f in env "env-$(printf %s "$XDG_CURRENT_DESKTOP" | tr '[:upper:]' '[:lower:]')"; do
  for g in "$HOME/.config/uwsm/$f" "$HOME/.config/uwsm/$f.d"/*; do [ -f "$g" ] && [ -r "$g" ] && . "$g"; done
done

exec Hyprland -c "$HOME/.config/hypr/hyprland.lua"
EOF
chmod +x /tmp/start-hypr.sh
# ERGON-15: make this session a FIRST login, so autostart's welcome has to open
# its window. The disk is reused for weeks, and the last run's stamp would turn
# the assertion below into a check of a login that opens nothing.
WELCOME_STAMP="$H/.local/state/ergon/welcome-shown"
rm -f "$WELCOME_STAMP"
# `su -` (login shell), not `su`: supplementary groups are established at
# session setup, so a non-login su keeps the OLD group set and the usermod above
# would have no effect until the next real login.
setsid su - "$U" -c "bash /tmp/start-hypr.sh" > /tmp/hypr.log 2>&1 &

# Wait for the IPC socket rather than sleeping a fixed amount.
for _ in $(seq 1 30); do
  [ -n "$(find /run/user/1000/hypr -name '.socket.sock' 2>/dev/null | head -1)" ] && break
  sleep 2
done

export XDG_RUNTIME_DIR=/run/user/1000
SIG=$(ls /run/user/1000/hypr 2>/dev/null | head -1)
if [ -z "$SIG" ]; then
  bad "Hyprland never created an IPC socket"
  echo "   --- hypr.log ---"; tail -25 /tmp/hypr.log | sed 's/^/     /'
  finish
fi
export HYPRLAND_INSTANCE_SIGNATURE="$SIG"
ok "Hyprland is running (instance $SIG)"

# ERGON-64, from the process rather than the file: what the compositor -- and
# so everything it launches -- actually carries. Set, and empty.
_henv=$(tr '\0' '\n' < "/proc/$(pgrep -x Hyprland | head -1)/environ" 2>/dev/null)
if grep -qx 'GNOME_DESKTOP_SESSION_ID=' <<<"$_henv"; then
  ok "the compositor carries GNOME_DESKTOP_SESSION_ID, empty, from the shipped uwsm drop-in"
else
  bad "the compositor's GNOME_DESKTOP_SESSION_ID is '$(grep '^GNOME_DESKTOP_SESSION_ID' <<<"$_henv" || echo absent)', not set and empty"
fi

# -s /bin/bash, not the user's login shell.
#
# `su -c` runs the command THROUGH the target user's shell, which here is zsh.
# A Lua dispatch argument -- hl.dsp.focus({workspace = 3}) -- is then parsed by
# zsh before hyprctl ever sees it: the parens are glob qualifiers and the braces
# are a brace expansion. What comes back is a zsh error ("unknown sort
# specifier", "number expected") that reads exactly like Hyprland rejecting the
# syntax, and sends you off rewriting a call that was correct.
hq() { su "$U" -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl $*" 2>&1; }

# Every graphical client below needs the SAME environment a real session gets,
# and getting it wrong fails in a way that reads as a product bug: waybar says
# "cannot open display", foot says "no compositor running?", grim says nothing
# at all -- none of which mention the variable that is missing.
#
# WAYLAND_DISPLAY is discovered, not assumed. It is wayland-1 on a fresh boot
# and wayland-0 or wayland-2 whenever it is not, and hard-coding it turns a
# second compositor start into an unexplained hang.
WLD=""
for _s in /run/user/1000/wayland-*; do
  case "$_s" in *.lock) continue ;; esac
  [ -S "$_s" ] && { WLD=${_s##*/}; break; }
done
[ -n "$WLD" ] && ok "wayland socket is $WLD" || bad "no wayland socket in /run/user/1000"

# The PATH a session really gets, from the file systemd --user really reads.
SESSION_PATH=$(HOME="$H" bash -c '
  set -a; . "$HOME/.config/environment.d/10-ergon-path.conf" 2>/dev/null; set +a; echo "$PATH"')
case "$SESSION_PATH" in
  *"$H/ergonOS/bin"*) ok "session PATH includes the repo bin" ;;
  *) bad "session PATH does not include $H/ergonOS/bin — every ergon-* click is a no-op" ;;
esac

# Run something as the user, inside the session, the way the session would.
usr() {
  su - "$U" -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/1000 \
                DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
                HYPRLAND_INSTANCE_SIGNATURE=$SIG \
                WAYLAND_DISPLAY=$WLD \
                XDG_CURRENT_DESKTOP=Hyprland \
                PATH='$SESSION_PATH' $*"
}

# Dump the compositor log on ANY failure. An instance directory exists as soon
# as Hyprland starts, so "socket present" does not mean "came up" -- without the
# log a crash right after startup is indistinguishable from a broken hyprctl.
dump_log() {
  # Hyprland writes its real log to $XDG_RUNTIME_DIR/hypr/<sig>/hyprland.log,
  # NOT to stdout. Tailing the redirect of the launch command gives an empty
  # file and no clue at all -- which is exactly what happened the first time.
  echo "   --- hyprland.log (tail) ---"
  tail -40 /run/user/1000/hypr/*/hyprland.log 2>/dev/null | sed 's/^/     /'
  echo "   --- launch stdout/stderr ---"
  tail -15 /tmp/hypr.log 2>/dev/null | sed 's/^/     /'
  echo "   --- DRM cards ---"
  ls -l /dev/dri/ 2>/dev/null | sed 's/^/     /'
  echo "   --- outputs seen by DRM ---"
  for c in /sys/class/drm/card*/status; do [ -r "$c" ] && echo "     $c: $(cat "$c")"; done
}

if hq version | grep -q Hyprland; then
  ok "hyprctl responds"
else
  bad "hyprctl does not respond"
  echo "   hyprctl said: $(hq version | head -3)"
  dump_log
fi

# The binds are the thing two API bugs would have silently emptied.
NB=$(hq binds -j 2>/dev/null | grep -c '"key"' || true)
NB=${NB:-0}
if [ "$NB" -gt 20 ]; then ok "$NB keybindings registered"; else bad "only $NB keybindings registered"; fi

# --- ERGON-15: the first login opens the welcome, once ----------------------
# A window mapping, not a string in autostart.lua. The stamp is the other half:
# only the page itself writes it, from inside the window, once it has a
# terminal to draw on -- so a stamp beside a window proves the page ran there.
# Closed again straight away: every check below was written for a screen with
# nothing on it, and the screenshot is meant to show the desktop.
welcome_n() { hq clients -j 2>/dev/null | jq '[.[] | select(.class == "ergon-tui-ergon-welcome")] | length' 2>/dev/null || echo 0; }
for _ in $(seq 1 30); do [ "$(welcome_n)" -ge 1 ] && break; sleep 1; done
if [ "$(welcome_n)" -ge 1 ]; then
  ok "the first login opened the welcome window"
else
  bad "the first login opened no welcome window (autostart: ergon-welcome --first-run)"
  usr "makoctl list" 2>&1 | head -8 | sed 's/^/     mako: /'
fi
[ -e "$WELCOME_STAMP" ] && ok "  and the page, running in it, wrote the stamp" \
                        || bad "no stamp at $WELCOME_STAMP — the next login would open it again"
# What the hermetic test can only stub: the page carries the live compositor's
# own keybinds, the first thing someone at a fresh login needs.
_wel=$(usr "ergon-welcome" </dev/null 2>&1); _wkeys=$(usr "ergon-keys --print" 2>/dev/null)
[ -n "$_wkeys" ] && [[ $_wel == *"$_wkeys"* ]] && ok "the welcome page carries what ergon-keys prints in this session" \
  || bad "the welcome page does not carry ergon-keys' output: $(grep -A2 '^## Keys' <<<"$_wel" | tr '\n' ' ')"
welcome_close() {
  for _p in $(hq clients -j 2>/dev/null | jq -r '.[] | select(.class == "ergon-tui-ergon-welcome") | .pid'); do kill "$_p"; done
  for _ in $(seq 1 10); do [ "$(welcome_n)" = 0 ] && break; sleep 1; done
}
welcome_close
[ "$(welcome_n)" = 0 ] && ok "  closed before the checks that want a clear screen" \
                       || bad "the welcome window would not close"
# The next login, asked only once the window is gone: while it is open,
# ergon-launch-tui focuses it instead of opening another, so asking earlier
# stayed green with the one-shot stamp check deleted.
usr "ergon-welcome --first-run" >/dev/null 2>&1
for _ in $(seq 1 5); do [ "$(welcome_n)" = 0 ] || break; sleep 1; done
[ "$(welcome_n)" = 0 ] && ok "a second --first-run (the next login) opens nothing" \
  || { bad "a second --first-run (the next login) opened the welcome again"; welcome_close; }

# The cheatsheet, through the real ergon-keys pipeline -- this used to grep the
# JSON for the word "description", and passed while the screenshot, media and
# night-light keys were registered, undescribed, and missing from the list.
# Every bind a person can press must come out as a row; switch: binds (the
# lid) are events rather than keys, and may be absent.
KEYS_OUT=$(usr "ergon-keys --print" 2>/tmp/keys.err) || true
KEYS_ROWS=$(printf '%s\n' "$KEYS_OUT" | grep -c . || true)
KEYS_WANT=$(hq binds -j | jq '[.[] | select(.description != "" or (.key | startswith("switch:") | not))] | length' 2>/dev/null || echo "?")
if [ "$KEYS_ROWS" -gt 20 ] && [ "$KEYS_ROWS" = "$KEYS_WANT" ]; then
  ok "ergon-keys lists all $KEYS_ROWS pressable binds the compositor has"
else
  bad "ergon-keys lists $KEYS_ROWS rows; the compositor has $KEYS_WANT pressable binds"
  hq binds -j | jq -r '.[] | select(.description == "" and (.key | startswith("switch:") | not))
                      | "     undescribed: modmask \(.modmask), key \(.key)"' 2>/dev/null
  sed 's/^/     /' /tmp/keys.err | head -5
fi

# Workspaces and the scratchpad are bound by KEYCODE, so they can be pressed on
# any layout. The JSON cannot show that -- under Lua it reports such a bind as
# key "" and keycode 0 -- so read the plain form, which prints the bind as it
# was written, and check each sits on its physical key.
if KC_OUT=$(hq binds | awk '
    /^\tkey: /         { k = substr($0, 7) }
    /^\tdescription: / { d = substr($0, 15); want = 0
      if (d ~ /^(Move to w|W)orkspace [1-9]$/) want = 9 + substr(d, length(d))
      if (d == "Toggle scratchpad" || d == "Send to scratchpad") want = 49
      if (want) { n++; if (k !~ ("code:" want "$")) { wrong = 1; print "     " d ": " k } } }
    END { exit (n == 20 && !wrong) ? 0 : 1 }'); then
  ok "workspace and scratchpad binds are on keycodes 10-18 and 49"
else
  bad "workspace/scratchpad binds are not all on keycodes 10-18 and 49"
  printf '%s\n' "$KC_OUT"
fi
# ...and the cheatsheet names those keys as each layout labels them.
#
# "A Workspace 1 row and no code: anywhere" proved nothing: on us, the fallback
# ergon-keys uses when it has no keymap prints the same 1 a working keymap
# does. So switch the compositor through the layouts the keys were moved for
# and require what the key really types on each. The key left of 1 differs on
# all four, and from the fallback's "key left of 1". Each layout is read twice:
# through the compositor's own keymap, and with no Wayland display, which makes
# ergon-keys compile one from the layout `hyprctl devices` reports.
#
# `hyprctl keyword` does not work on a Lua config; eval does. The keymap is
# applied on the compositor's next loop iteration, so wait for the keyboard to
# report it rather than sleeping.
kb_main() { hq devices -j | jq -r '((.keyboards | map(select(.main)) + .)[0] // {}) | "\(.layout // "")\t\(.variant // "")"'; }
set_layout() {
  hq "eval 'hl.config({ input = { kb_layout = \"$1\", kb_variant = \"${2:-}\" } })'" >/dev/null
  for _ in $(seq 1 20); do
    [ "$(kb_main)" = "$1"$'\t'"${2:-}" ] && return 0
    sleep 0.25
  done
  return 1
}
key_of() { printf '%s\n' "$1" | awk -F'  +' -v d="$2" '$2 == d { sub(/^SUPER \+ /, "", $1); print $1 }'; }
IFS=$'\t' read -r KB0 KV0 < <(kb_main)
# KEYS_OUT is captured with `|| true` above, so an ergon-keys that died leaves it
# empty -- and "no raw code:N" was then true of no rows at all rather than of the
# cheatsheet. An empty answer is a failure, not a clean one.
if [ -z "$KEYS_OUT" ]; then bad "ergon-keys printed nothing, so 'no raw code:N' would be a claim about no rows"
elif grep -q 'code:' <<<"$KEYS_OUT"; then bad "ergon-keys shows a raw code:N"
else ok "ergon-keys shows no raw code:N"; fi
# Without this, a dead first source would pass below as "session" on the fallback.
# Captured, not piped into grep -q. Under pipefail, grep -q exits at the first
# match, the dump (~70K) dies of SIGPIPE mid-write, and the pipeline reports a
# failure for a keymap that arrived perfectly well.
_km=$(usr "timeout 2 xkbcli dump-keymap-wayland" 2>&1); _km_rc=$?
if [ "$_km_rc" = 0 ] && grep -q 'xkb_symbols' <<<"$_km"; then
  ok "the compositor hands clients its keymap (ergon-keys' first source)"
else
  bad "xkbcli dump-keymap-wayland got no keymap (rc=$_km_rc: $(head -c 200 <<<"$_km" | tr '\n' ' '))"
fi
for want in 'us 1 `' 'latam 1 |' 'es 1 º' 'fr & ²'; do
  read -r L W1 SP <<<"$want"
  if ! set_layout "$L"; then bad "could not switch the compositor to $L (it reports '$(kb_main | tr '\t' ' ')')"; continue; fi
  for src in session compiled; do
    if [ "$src" = session ]; then out=$(usr "ergon-keys --print" 2>/dev/null)
    else out=$(usr "WAYLAND_DISPLAY=none ergon-keys --print" 2>/dev/null); fi
    got="$(key_of "$out" "Workspace 1") $(key_of "$out" "Toggle scratchpad")"
    if [ "$got" = "$W1 $SP" ]; then
      ok "ergon-keys on $L, $src keymap: SUPER + $W1 is workspace 1, SUPER + $SP the scratchpad"
    else
      bad "ergon-keys on $L, $src keymap: workspace 1 and the scratchpad are on '$got', want '$W1 $SP'"
    fi
  done
done
set_layout "${KB0:-us}" "${KV0:-}" || bad "could not restore the layout to '${KB0:-us}'"
# Hyprland fires EVERY bind that matches, so a chord bound twice is two actions
# on one press. ergon-lint catches the literal ones; this catches the chords
# built at runtime (the workspace loop, the help key chosen by layout).
KEYS_DUPS=$(printf '%s\n' "$KEYS_OUT" | awk -F'  +' 'NF { print toupper($1) }' | sort | uniq -d)
if [ -z "$KEYS_DUPS" ]; then ok "no chord is bound twice"; else bad "chords bound twice: ${KEYS_DUPS//$'\n'/, }"; fi

# ERGON-24/23: SUPER+SHIFT+E must open the session menu now, not exit
# instantly, and XF86PowerOff must reach it too but NOT as a `locked` bind --
# fuzzel cannot draw over hyprlock, and on the Framework 13 that key IS the
# fingerprint reader, so a locked bind there would queue an invisible menu
# that pops up right after a fingerprint unlock. hyprctl cannot report WHAT a
# Lua bind dispatches (every one shows dispatcher "__lua"), so the wiring
# itself (SUPER+SHIFT+E / XF86PowerOff -> ergon-session) is only checked in
# source below; description, key and locked are real Hyprland-side bind
# properties that DO survive and are checked against the live compositor.
# Code lines only: binds.lua's own comment records what the bind USED to be.
# The file first: `grep -v <file> | grep <pattern>` exits non-zero both when
# binds.lua is clean AND when it is missing, unreadable or empty, so an install
# that never linked the compositor config read as "no direct hl.dsp.exit() left".
# (`grep ... >/dev/null` and not `grep -q`: -q leaves on the first match, the
# left grep takes SIGPIPE, and under pipefail a match comes back as a miss.)
_binds_lua="$H/.config/hypr/common/binds.lua"
if [ ! -s "$_binds_lua" ]; then
  bad "no binds.lua at $_binds_lua — the session has no binds, and nothing was checked"
elif grep -v '^[[:space:]]*--' "$_binds_lua" | grep 'hl\.dsp\.exit()' >/dev/null; then
  bad "binds.lua still calls hl.dsp.exit() directly -- SUPER+SHIFT+E must open the session menu instead"
else
  ok "no direct hl.dsp.exit() left in binds.lua"
fi
# `key` and `locked` are real Hyprland bind properties (mods/key/flags handed
# to the native bind API at registration), unlike `dispatcher`/`arg` which are
# meaningless under the Lua closure -- so, paired with `description`, they can
# be checked LIVE instead of only in source. A source grep alone would still
# pass if one of the two binds silently failed to register (a key-name
# mismatch, a Lua error after this line) -- exactly the parses-but-registers-
# nothing class ergon explain desktop-config warns about, and the one failure
# this block exists to catch.
_binds=$(hq binds -j 2>/dev/null)
_e_bind=$(printf '%s' "$_binds" | jq -c '[.[] | select((.description // "") == "Session menu" and ((.key // "") | ascii_downcase) == "e")] | .[0] // empty' 2>/dev/null)
_pwr_bind=$(printf '%s' "$_binds" | jq -c '[.[] | select((.description // "") == "Session menu" and ((.key // "") | ascii_downcase) == "xf86poweroff")] | .[0] // empty' 2>/dev/null)

[ -n "$_e_bind" ] \
  && ok "hyprctl reports a live 'Session menu' bind on key E (SUPER+SHIFT+E registered)" \
  || bad "no live bind on key E describes itself 'Session menu' -- SUPER+SHIFT+E may not have registered"
[ -n "$_pwr_bind" ] \
  && ok "hyprctl reports a live 'Session menu' bind on XF86PowerOff (registered)" \
  || bad "no live bind on XF86PowerOff describes itself 'Session menu' -- it may not have registered"

if [ -n "$_pwr_bind" ]; then
  if printf '%s' "$_pwr_bind" | jq -e '.locked == true' >/dev/null 2>&1; then
    bad "XF86PowerOff's live bind is locked=true -- fuzzel cannot draw over hyprlock, and this is the Framework fingerprint reader"
  else
    ok "XF86PowerOff's live bind is not locked (a queued menu cannot pop up right after an unlock)"
  fi
else
  bad "XF86PowerOff's live bind was not found -- cannot check its locked flag"
fi

# Source-level wiring, kept as a second signal alongside the live checks above
# (which prove registration but, like the rest of hyprctl under Lua, cannot
# show WHAT a bind runs -- only description, key and locked survive).
grep -qE '^bind\("SUPER \+ SHIFT \+ E".*ergon-session' "$H/.config/hypr/common/binds.lua" \
  && ok "SUPER+SHIFT+E runs ergon-session" || bad "SUPER+SHIFT+E is not wired to ergon-session"
grep -qE '^bind\("XF86PowerOff".*ergon-session' "$H/.config/hypr/common/binds.lua" \
  && ok "XF86PowerOff runs ergon-session" || bad "XF86PowerOff is not wired to ergon-session"

# Hibernate must appear in `ergon session --list` exactly when ergon-hardware
# -- the one place that decision is made -- says hibernation is ready. This VM
# is s2idle-only with working hibernation (see the lid assertions above), so
# it must appear here; a machine without that must not offer an entry that
# would fail the moment it is chosen.
_hwd=$(usr "ergon-hardware detect" 2>&1)
_sl=$(usr "ergon-session --list" 2>&1)
if printf '%s\n' "$_hwd" | grep -Eq 'hibernation:[[:space:]]+yes'; then
  printf '%s\n' "$_sl" | grep -qx hibernate \
    && ok "ergon session --list offers hibernate (ergon-hardware says it is ready)" \
    || bad "hibernation is ready but ergon session --list does not offer it"
else
  printf '%s\n' "$_sl" | grep -qx hibernate \
    && bad "ergon session --list offers hibernate but ergon-hardware says it is not ready" \
    || ok "ergon session --list correctly omits hibernate (not ready)"
fi

# Window rules and monitors.
hq monitors -j | grep -q '"name"' && ok "a monitor is present" || bad "no monitors"

# waybar should map a layer surface. This is the one config no parser checks.
#
# autostart.lua execs waybar from the compositor, so it is already running and
# already has the right environment. The test used to start a SECOND one beside
# it, with an incomplete environment: that copy died on "cannot open display"
# while the real one worked, and the assertion passed on the real one -- so the
# log carried a fatal-looking waybar error that meant nothing. Wait for the one
# the session started; only start one here if the session did not.
for _ in $(seq 1 20); do hq layers | grep -q waybar && break; sleep 1; done
if ! hq layers | grep -q waybar; then
  echo "     autostart did not bring up waybar; starting one by hand"
  usr "waybar -c $H/.config/waybar/config.jsonc -s $H/.config/waybar/style.css" >/tmp/waybar.log 2>&1 &
  sleep 6
fi
if hq layers | grep -q waybar; then
  ok "waybar mapped a layer surface"
else
  bad "waybar did not map a layer surface"
  tail -12 /tmp/waybar.log 2>/dev/null | sed 's/^/     /'
fi

# ergon-doctor is the bug-report format for a public distro, so it has to work
# on a machine it has never seen. Assert it RUNS and that its JSON parses --
# a health check that dies is worse than none, because it dies exactly when
# something is already wrong.
# A doctor FAILURE on a machine this test has just proven healthy is a bug in
# doctor, not news about the machine. That distinction was worth making: the
# first version reported "rollback: kernel cmdline pins a subvolume" as a hard
# failure on a disk whose rollback had been rehearsed successfully, and "no pre
# snapshots" while an assertion twenty lines earlier counted seven.
#
# So: crashing is a failure, and so is reporting a failure here.
if usr "ergon-doctor --json" > /tmp/doctor.json 2>/tmp/doctor.err; then
  ok "ergon-doctor reports no failures on a machine this run proved healthy"
elif [ -s /tmp/doctor.json ]; then
  bad "ergon-doctor reports failures on a healthy machine — a false signal"
  python3 -c 'import json;[print("      ",c["name"],c["note"]) for c in json.load(open("/tmp/doctor.json"))["checks"] if c["state"]=="fail"]' 2>/dev/null
else
  bad "ergon-doctor crashed"
  sed 's/^/     /' /tmp/doctor.err
fi
if python3 -c 'import json,sys; d=json.load(open("/tmp/doctor.json")); sys.exit(0 if d["checks"] else 1)' 2>/dev/null; then
  ok "ergon-doctor --json parses ($(python3 -c 'import json;print(len(json.load(open("/tmp/doctor.json"))["checks"]))') checks)"
else
  bad "ergon-doctor --json is not valid JSON"
  head -3 /tmp/doctor.json | sed 's/^/     /'
fi
# ERGON-29: a check that silently never runs is the same as one never written,
# and both of these depend on rebuild-detector and packages/aur being reachable
# from a real installed machine.
for row in aur aur-pins; do
  if python3 -c "import json,sys; d=json.load(open('/tmp/doctor.json')); sys.exit(0 if any(c['name']=='$row' for c in d['checks']) else 1)" 2>/dev/null; then
    ok "ergon-doctor reports a '$row' row"
  else
    bad "ergon-doctor has no '$row' row — the foreign-package check did not run"
  fi
done
printf '   --   doctor says:\n'
usr ergon-doctor 2>&1 | sed 's/^/        /'

# Figure provenance has to be AUTOMATIC or it is worthless -- a helper you must
# remember to call is one you will not. So assert the whole chain: a plain
# script that knows nothing about ergon saves a figure, and the provenance is
# in it. Anything less tests the helper rather than the promise.
cat > /tmp/prov_plot.py <<'PLOT'
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
plt.plot([0, 1], [0, 1])
plt.savefig("/tmp/prov.png")
PLOT
chown "$U" /tmp/prov_plot.py
if usr "\$HOME/.local/share/pyfleet/bin/python /tmp/prov_plot.py" >/tmp/prov.err 2>&1; then
  if usr "ergon-fig whence /tmp/prov.png" > /tmp/prov.out 2>&1; then
    ok "figures carry provenance with no code change ($(grep -c . /tmp/prov.out) fields)"
  else
    bad "the figure saved but carries no provenance"
    sed 's/^/     /' /tmp/prov.out
  fi
else
  bad "a plain matplotlib script failed — the savefig patch broke saving"
  tail -6 /tmp/prov.err | sed 's/^/     /'
fi

# --- do the clicks actually do anything? ------------------------------------
# The whole point, and the thing nothing here ever asked. "waybar mapped a layer
# surface" stayed true throughout a week in which the bar was unusable: every
# module rendered, every module highlighted on hover, and every click went
# nowhere. No test in this repo had ever executed a single on-click command, so
# nothing noticed.
#
# Two levels, because they fail in different places:
#   1. does every on-click RESOLVE to something that exists on the session PATH
#   2. does a synthetic click on a real pixel produce a real effect
# (1) is cheap and covers every module at once. (2) is the only thing that can
# prove the pointer path works end to end.

echo "--- click targets ---"

resolves() { PATH="$SESSION_PATH" bash -c 'command -v "$1" >/dev/null' _ "$1"; }

# jq cannot read config.jsonc (it has comments) and stripping them would be its
# own source of bugs, so pull the values out textually. The file is ours and the
# shape is fixed.
# An empty extraction must FAIL, not pass. "no missing commands" and "no
# commands found" are the same empty string, and the second one is a broken
# test reporting success -- the exact shape of every bug this file has had.
CLICKS=$(grep -oE '"on-click[a-z-]*"[[:space:]]*:[[:space:]]*"[^"]+"' \
  "$H/.config/waybar/config.jsonc" 2>/dev/null | sed 's/.*:[[:space:]]*"//; s/"$//')
N_CLICKS=$(printf '%s\n' "$CLICKS" | grep -c . || true)
[ "${N_CLICKS:-0}" -ge 5 ] || bad "only $N_CLICKS on-click handlers found in waybar config — extraction is broken"

MISSING=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  first=${line%% *}
  # `activate` and `mode` are waybar-internal, not commands.
  case "$first" in activate|mode|"") continue ;; esac
  resolves "$first" || MISSING="$MISSING $first"
done <<EOF
$CLICKS
EOF
if [ -n "$MISSING" ]; then
  bad "waybar on-click commands missing from the session PATH:$MISSING"
else
  ok "every waybar on-click resolves on the session PATH"
fi

# The same question for the config's own commands. `hyprctl binds` cannot
# answer it under a Lua config: every bind reports dispatcher "__lua" with an
# integer arg, because the action is a Lua closure rather than a dispatch
# string. The introspection that existed for hyprland.conf is simply gone, so
# check the source instead.
#
# Two things, both narrow enough to have no false positives:
#   - every ergon-* referenced anywhere in the desktop config must exist and
#     resolve. This is the exact failure that made the bar inert.
#   - every daemon autostart.lua execs must resolve, or the session comes up
#     missing a piece with nothing but a line in the compositor log.
# Only tokens that are actually commands. `ergon-float` is a WINDOW CLASS -- it
# appears in binds.lua as `wezterm start --class ergon-float` and in windows.lua as
# the rule that floats it -- so a scan for the ergon- prefix alone reports it as a
# missing binary on every run. The repo knows which ergon-* are commands: they are
# the files in bin/.
MISSING=""
ERGREFS=$(grep -rhoE '\bergon-[a-z-]+' "$H/.config/hypr" "$H/.config/waybar" \
         "$H/.config/fuzzel" 2>/dev/null | sort -u \
         | while read -r t; do [ -f "$H/ergonOS/bin/$t" ] && echo "$t"; done)
N_ERG=$(printf '%s\n' "$ERGREFS" | grep -c . || true)
[ "${N_ERG:-0}" -ge 3 ] || bad "only $N_ERG ergon-* references found in the desktop config — extraction is broken"
for j in $ERGREFS; do resolves "$j" || MISSING="$MISSING $j"; done
if [ -n "$MISSING" ]; then
  bad "ergon-* referenced by the desktop config but not on the session PATH:$MISSING"
else
  ok "every ergon-* the desktop config names resolves ($N_ERG of them)"
fi

MISSING=""
EXECS=$(grep -hoE 'hl\.exec_cmd\("[^"]+"' "$H/.config/hypr/common/autostart.lua" 2>/dev/null \
        | sed 's/.*("//; s/"$//' | awk '{print $1}' | sort -u)
N_EXECS=$(printf '%s\n' "$EXECS" | grep -c . || true)
[ "${N_EXECS:-0}" -ge 5 ] || bad "only $N_EXECS autostart commands found — extraction is broken"
for e in $EXECS; do resolves "$e" || MISSING="$MISSING $e"; done
if [ -n "$MISSING" ]; then
  bad "autostart commands missing from the session PATH:$MISSING"
else
  ok "every autostart daemon resolves ($N_EXECS of them)"
fi

# --- a synthetic click on a real pixel --------------------------------------
# ydotool injects through uinput, so the compositor sees a genuine input device
# and takes the genuine path: libinput -> cursor -> surface -> GTK. A Wayland
# client cannot fake that for another client, which is why this needs a kernel
# device rather than a protocol call.
echo "--- synthetic clicks ---"
modprobe uinput >/dev/null 2>&1 || true
YSOCK=/tmp/.ydotool_socket
if [ ! -e /dev/uinput ]; then
  bad "no /dev/uinput — cannot test clicks"
elif ! command -v ydotoold >/dev/null; then
  bad "ydotoold not installed — cannot test clicks"
else
  setsid ydotoold --socket-path="$YSOCK" \
    --socket-own="$(id -u "$U"):$(id -g "$U")" >/tmp/ydotoold.log 2>&1 &
  for _ in $(seq 1 20); do [ -S "$YSOCK" ] && break; sleep 0.5; done

  if [ ! -S "$YSOCK" ]; then
    bad "ydotoold never created its socket"
    sed 's/^/     /' /tmp/ydotoold.log
  else
    # Hyprland must actually adopt the new device, or every click lands nowhere
    # and the failure looks exactly like the bug being tested for.
    seen=0
    for _ in $(seq 1 20); do
      hq devices 2>/dev/null | grep -qi ydotool && { seen=1; break; }
      sleep 0.5
    done
    [ "$seen" = 1 ] && ok "Hyprland adopted the synthetic pointer" \
                    || bad "Hyprland never saw the ydotool device"

    # Prove the cursor can be placed AT ALL before drawing conclusions from
    # clicks that land wherever it happened to be. The first version of this
    # test reported "clicking did nothing across the whole left edge" while the
    # cursor sat at 640,400 the entire time -- it had never moved, so nothing
    # had been clicked and the finding was about the harness.
    hq "dispatch 'hl.dsp.cursor.move({x = 100, y = 15})'" >/tmp/movecursor.out 2>&1
    sleep 0.5
    CPOS=$(hq cursorpos 2>/dev/null | tr -d ' ')
    if [ "$CPOS" = "100,15" ]; then
      ok "the cursor can be placed (movecursor works)"
    else
      bad "movecursor did not move the cursor: asked for 100,15, got '$CPOS'"
      echo "     hyprctl said: $(cat /tmp/movecursor.out)"
    fi

    click_at() {
      hq "dispatch 'hl.dsp.cursor.move({x = $1, y = $2})'" >/dev/null 2>&1
      sleep 0.4
      usr "YDOTOOL_SOCKET=$YSOCK ydotool click 0xC0" >/tmp/ydotool.out 2>&1
      sleep 1
    }

    # Workspace buttons. Their width depends on the font, so probe across the
    # left edge of the bar rather than hard-coding a pixel that is right on one
    # machine only. Starting workspace is 1; ANY button but the first must
    # change it.
    hq "dispatch 'hl.dsp.focus({workspace = 1})'" >/dev/null 2>&1; sleep 1
    HIT=""
    for x in 6 18 30 42 54 66 78 90 102 114 126 138 150; do
      click_at "$x" 15
      ws=$(hq activeworkspace -j 2>/dev/null | jq -r '.id // empty')
      [ -n "$ws" ] && [ "$ws" != 1 ] && { HIT="x=$x switched to workspace $ws"; break; }
    done
    if [ -n "$HIT" ]; then
      ok "clicking a workspace button switches workspace ($HIT)"
    else
      bad "clicking the workspace buttons did nothing across the whole left edge"
      echo "     cursor ended at: $(hq cursorpos 2>/dev/null)"
      echo "     ydotool said:    $(cat /tmp/ydotool.out 2>/dev/null)"
      echo "     active ws:       $(hq activeworkspace 2>/dev/null | head -1)"
      echo "     --- waybar layer surfaces ---"
      hq layers 2>/dev/null | grep -A3 waybar | sed 's/^/     /'
      echo "     --- input devices hyprland sees ---"
      hq devices 2>/dev/null | sed -n '/Mice:/,$p' | sed 's/^/     /'
    fi

    # The keycode binds, PRESSED, on each layout they were moved for. Above,
    # they are only shown to be registered on code:10-18 and 49. Under Lua a
    # code:N bind is matched by a different branch of Hyprland's keybind
    # manager than a hyprlang one -- the branch hyprctl cannot even report (key
    # "", keycode 0) -- and a bind that registers and never fires is exactly
    # what nothing else here would notice. So the keys go in through uinput, as
    # a keyboard's do, with the compositor set (set_layout, above) to layouts
    # on which they type &, |, º or ² rather than 1 and grave. evdev codes:
    # LEFTMETA 125, KEY_2 3, GRAVE 41; xkb keycode = evdev + 8, so these are
    # code:11 and code:49.
    super_key() { usr "YDOTOOL_SOCKET=$YSOCK ydotool key 125:1 $1:1 $1:0 125:0" >/tmp/ydotool.out 2>&1; sleep 0.6; }
    special() { hq monitors -j 2>/dev/null | jq -r '[.[] | select(.focused)][0].specialWorkspace.name // ""'; }
    if ! hq devices -j 2>/dev/null | jq -e '.keyboards[] | select(.name | test("ydotool"))' >/dev/null; then
      bad "Hyprland has no ydotool keyboard, so the keycode binds cannot be pressed"
    else
      for L in us latam es fr; do
        if ! set_layout "$L"; then bad "could not switch the compositor to $L"; continue; fi
        hq "dispatch 'hl.dsp.focus({workspace = 1})'" >/dev/null 2>&1; sleep 0.5
        ws0=$(hq activeworkspace -j 2>/dev/null | jq -r '.id // empty')
        super_key 3;  ws=$(hq activeworkspace -j 2>/dev/null | jq -r '.id // empty')
        super_key 41; sp_open=$(special)
        super_key 41; sp_shut=$(special)
        if [ "$ws0" = 1 ] && [ "$ws" = 2 ] && [ "$sp_open" = special:scratch ] && [ -z "$sp_shut" ]; then
          ok "on $L, SUPER + the 2 key goes to workspace 2 and SUPER + the key left of 1 toggles the scratchpad"
        else
          bad "on $L: from workspace '$ws0', SUPER + the 2 key gave '$ws' (want 2); the key left of 1 opened '$sp_open' (want special:scratch), then left '$sp_shut' open (want nothing)"
          echo "     ydotool said: $(cat /tmp/ydotool.out 2>/dev/null)"
          [ "$sp_shut" != special:scratch ] || hq "dispatch 'hl.dsp.workspace.toggle_special(\"scratch\")'" >/dev/null 2>&1
        fi
      done
      set_layout "${KB0:-us}" "${KV0:-}" || bad "could not restore the layout to '${KB0:-us}'"
    fi

    # A module whose on-click is a shell command. ergon-launch-tui is the one every
    # broken module went through, and a window appearing is proof the whole
    # chain ran: PATH, terminal fallback, window rules.
    before=$(hq clients -j 2>/dev/null | jq 'length')
    usr "ergon-launch-tui btop" >/tmp/launchtui.log 2>&1 &
    for _ in $(seq 1 20); do
      hq clients -j 2>/dev/null | grep -q 'ergon-tui-btop' && break
      sleep 1
    done
    if hq clients -j 2>/dev/null | grep -q 'ergon-tui-btop'; then
      ok "ergon-launch-tui opens a window (the bar's click handlers work)"
    else
      bad "ergon-launch-tui opened nothing — clients went $before -> $(hq clients -j 2>/dev/null | jq 'length')"
      tail -8 /tmp/launchtui.log | sed 's/^/     /'
    fi
  fi
fi

# Only dump the log when something actually failed. An unconditional dump makes
# a passing run look like a failing one and buries the next real failure.
# --- a look at the actual desktop --------------------------------------
# Everything above is an assertion. This is the part you can LOOK at: open a
# couple of windows, let them settle, and have the compositor screenshot itself.
# /out is a writable 9p share, so the PNG lands outside the VM.
if [ -d /out ] || mkdir -p /out 2>/dev/null; then
  mount -t 9p -o trans=virtio,version=9p2000.L out /out 2>/dev/null || true
fi

if mountpoint -q /out 2>/dev/null; then
  usr foot >/dev/null 2>&1 &
  sleep 4
  usr fuzzel >/dev/null 2>&1 &
  sleep 3
  # -o <output>, not the whole logical space. qemu's virtio-gpu presents more
  # than one output and a bare `grim` captures every one of them, then blocks
  # forever on the one that never presents a frame under software rendering. It
  # hung the entire test for six minutes before this had a timeout, which read
  # as the compositor having died.
  MON=$(hq monitors -j 2>/dev/null | jq -r '.[0].name // empty')
  if timeout 60 su - "$U" -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$SIG WAYLAND_DISPLAY=$WLD grim -o '$MON' /out/desktop.png" >/tmp/grim.log 2>&1; then
    chmod 666 /out/desktop.png 2>/dev/null || true
    ok "screenshot written to the out share"
  else
    # grim needs a working dmabuf path, and aquamarine cannot get one in the
    # VM -- the compositor log fills with
    #     [EGL] eglCreateImageKHR ... EGL_BAD_ALLOC: createImageFromDmaBufs failed
    # and wlr-screencopy then blocks until the timeout kills it. That is the
    # emulated GPU, not the desktop: on hardware with a real driver this works.
    #
    # So it is only a SKIP when the log actually shows that, and a real failure
    # otherwise -- a screenshot regression on a machine that can render must
    # still fail rather than hide behind a VM excuse.
    if grep -q "createImageFromDmaBufs failed" /run/user/1000/hypr/*/hyprland.log 2>/dev/null; then
      note "grim cannot capture: no dmabuf path in the VM (see docs/testing-the-desktop.md)"
    else
      bad "grim could not capture the desktop"
      sed 's/^/     /' /tmp/grim.log 2>/dev/null
    fi
  fi
else
  bad "the writable out share did not mount"
fi

# Leave greetd RUNNING. The test disables it to get the display to itself, but
# a VM you cannot log into is useless for looking at, and the greeter is the
# real entry point -- the same one the Framework will boot to.
systemctl enable greetd >/dev/null 2>&1 || true
ok "greetd left enabled for interactive use"

# --- things that made the desktop useless and nothing asserted ------------
# A RUNNING daemon is not the claim worth making: the bar's profile button did
# nothing for a whole session while power-profiles-daemon was active the entire
# time, because waybar's module did not cycle on click in this build. So assert
# the switch itself.
if systemctl is-active --quiet power-profiles-daemon; then
  ok "power-profiles-daemon is running"
  # Assert the POLICY, not the switch.
  #
  # Switching needs an active seat session: power-profiles-daemon's polkit
  # action is allow_active, so `su - user` -- which has no logind session -- is
  # correctly refused with
  #   AccessDenied: Not Authorized: ...PowerProfiles.switch-profile
  # This harness drives the compositor through seatd without logind, so it has
  # no active session either. A test that performs the switch here would fail on
  # a machine where the button works perfectly, which is worse than no test.
  #
  # What CAN be checked without a seat: that the profile list has something to
  # cycle to, and that the polkit action permits an active session to do it.
  _n=$(su - "$U" -c 'powerprofilesctl list' 2>/dev/null | grep -cE '^[* ]*[a-z-]+:')
  [ "${_n:-0}" -ge 2 ] && ok "$_n power profiles to cycle between" \
                       || bad "only ${_n:-0} power profile — the button has nothing to switch to"
  # Read the value, then judge it. As one pipeline, "pkaction is not installed"
  # and "polkit REFUSES an active session" were the same non-zero status and both
  # came out as a note -- so a policy that had stopped permitting the switch would
  # have been reported as a thing this run could not ask about. Only a missing
  # pkaction, or an action polkit does not know, is a note now; an answer that is
  # not a grant is a failure.
  _pk_active=$(pkaction --action-id org.freedesktop.UPower.PowerProfiles.switch-profile --verbose 2>/dev/null \
    | sed -n 's/^[[:space:]]*implicit active:[[:space:]]*//p' | tr -d '[:space:]')
  case "$_pk_active" in
    "")                                 note "could not read the polkit policy for switch-profile (pkaction missing?)" ;;
    yes|auth_admin_keep|auth_self_keep) ok "polkit lets an active session switch profile ($_pk_active)" ;;
    *)                                  bad "polkit's implicit active for switch-profile is '$_pk_active' — the profile button cannot work even from a real session" ;;
  esac
else
  bad "power-profiles-daemon is not running — clicking the profile icon does nothing"
fi
# The rule provisioning writes (bin/provision-arch.sh, 49-ergon-desktop.rules)
# grants suspend and hibernate to wheel regardless of session, and
# deliberately stops there. BOTH halves are asserted: a rule that quietly
# widened to the two actions that end every job on the machine must fail here.
#
# `su -` has no seat, which is exactly the session-less caller the rule exists
# for -- the same shape as anything the compositor launches under uwsm.
# pkcheck exits 0 only when the action is authorized outright; a challenge
# ("authentication required") or a refusal is non-zero, which is what reboot
# and power-off must still be.
if ! command -v pkcheck >/dev/null 2>&1; then
  note "pkcheck missing — cannot check what the desktop may do without a session"
else
  for _act in suspend hibernate; do
    if usr "pkcheck --action-id org.freedesktop.login1.$_act --process \$\$" >/dev/null 2>&1; then
      ok "polkit: a session-less wheel process may $_act"
    else
      bad "polkit refuses $_act from a session-less process — the session menu cannot $_act"
    fi
  done
  for _act in reboot power-off; do
    if usr "pkcheck --action-id org.freedesktop.login1.$_act --process \$\$" >/dev/null 2>&1; then
      bad "polkit grants $_act unauthenticated — the rule was meant to stop at suspend/hibernate"
    else
      ok "polkit still asks before $_act"
    fi
  done
fi
# Assert the thing that survives a REBOOT, not the rmmod we just did. The first
# version of this checked /dev/fd0 in the same boot that removed the module by
# hand: it passed, and the prompt was still there on the next boot, because the
# module comes back from the initramfs. The cmdline is the durable fact.
grep -q 'modprobe.blacklist=floppy' /proc/cmdline 2>/dev/null \
  && ok "floppy blacklisted on the running cmdline" \
  || { grep -q 'modprobe.blacklist=floppy' /boot/grub/grub.cfg 2>/dev/null \
       && ok "floppy blacklisted in grub.cfg (takes effect next boot)" \
       || bad "nothing blacklists floppy on the cmdline — the prompt returns every boot"; }
[ -e /dev/fd0 ] \
  && note "/dev/fd0 still present in this boot (it predates the blacklist)" \
  || ok "no floppy device"

# --- the shell -------------------------------------------------------------
# zsh is the login shell and the OS now ships its configuration, so a broken
# one is not cosmetic: it is every terminal, every ssh command and the greeter's
# own environment. A config that errors on startup still "works" interactively,
# which is why this asserts a CLEAN start rather than a start.
[ "$(getent passwd "$U" | cut -d: -f7)" = /bin/zsh ] \
  && ok "zsh is the login shell" || bad "login shell is not zsh"
# stdin a pipe ON PURPOSE: that is what made zplug warn once per plugin, and
# this suite only reproduced it by accident, through the `echo pw | sudo -S`
# that launches it.
zerr=$(echo | su - "$U" -c 'zsh -i -c "exit" 2>&1' 2>&1 | grep -vE '^\s*$' | head -3)
[ -z "$zerr" ] && ok "an interactive zsh starts with no output" \
               || bad "zsh prints on startup: $zerr"
su - "$U" -c 'zsh -c "command -v ergon-wallpaper"' >/dev/null 2>&1 \
  && ok "zsh resolves the ergon commands" || bad "ergon-* not on zsh's PATH"

# --- the bar's commands actually resolve ----------------------------------
# waybar and autostart exec ergon-* BY NAME. If PATH does not carry them the bar
# still draws and every click silently does nothing -- reported three times from
# a real session before it was believed, and invisible to a test that only asks
# whether a window opened in ITS OWN session, which has a correct PATH.
#
# So assert the thing a login actually depends on: that the commands resolve for
# a plain login shell, the way the greeter's session will find them.
for c in ergon-launch-tui ergon-wallpaper ergon-brightness ergon ergon-battery; do
  if su - "$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)" -c "command -v $c" >/dev/null 2>&1; then
    ok "$c resolves on the login PATH"
  else
    bad "$c is not on the login PATH — the bar will draw and do nothing"
  fi
done

# --- the wallpaper --------------------------------------------------------
# hyprpaper.conf points at a GENERATED png, and for the life of this project
# nothing generated it: hyprpaper logged, exited, and the desktop fell back to
# the compositor's background_color. The fallback is deliberate and it looks
# fine, so every machine quietly had a flat colour instead of the wallpaper it
# ships, and no assertion here noticed.
W="$(getent passwd "$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)" | cut -d: -f6)/.local/share/ergon/wallpaper.png"
[ -s "$W" ] && ok "wallpaper generated ($(du -h "$W" | cut -f1))" \
            || bad "no wallpaper at $W — hyprpaper will exit and the desktop falls back to a flat colour"
# The file existing is not the point; hyprpaper actually putting a surface on
# the background layer is. A file that hyprpaper cannot read looks identical
# from the outside to one that is not there.
# Polled. hyprpaper is started by ergon-wallpaper during autostart and has to
# render before it maps anything, so a single check here races it -- this
# reported "background layer is empty" while the diagnosis printed immediately
# below showed the layer present and full-screen a second later.
_bg=0
for _ in $(seq 15); do
  if hq layers | awk '/Layer level 0/{b=1;next} /Layer level 1/{b=0} b && /hyprpaper/{f=1} END{exit !f}'; then
    _bg=1; break
  fi
  sleep 1
done
# The evidence the GPU-less VM branch below needs, gathered up front. Tested for
# being non-empty, never by exit status: under pipefail, grep leaving early
# kills dmesg with SIGPIPE and a match reads as a miss.
_hp=$(sed 's/\x1b\[[0-9;]*m//g' /run/user/1000/hyprpaper.log 2>/dev/null)
_k=$({ dmesg; journalctl -k -b --no-pager; } 2>/dev/null | grep -oE 'features: [-+]virgl.*' | head -1)
_egl=$(grep -m1 'failed to create dri2 screen' <<<"$_hp")
_gbm=$(grep -m1 'Failed to allocate a GBM buffer' <<<"$_hp")
if [ "$_bg" = 1 ]; then
  ok "hyprpaper mapped a background layer"
elif grep -q "createImageFromDmaBufs failed" /run/user/1000/hypr/*/hyprland.log 2>/dev/null; then
  # Same VM limitation that stops grim capturing, and for the same reason:
  # QEMU's virtio-gpu has no working dmabuf path, so EGL refuses the import
  # (EGL_BAD_ALLOC) and hyprpaper cannot allocate a buffer for the background.
  # On hardware with a real driver it can.
  #
  # A SKIP only when the log actually shows that failure, and a hard failure
  # otherwise -- a wallpaper regression on a machine that can render must still
  # fail rather than hide behind a VM excuse. Same rule as the grim check above.
  note "wallpaper cannot be composited: no dmabuf path in the VM (see docs/testing-the-desktop.md)"
elif ! pgrep -x hyprpaper >/dev/null && [[ $_k == *-virgl* ]] && [ -n "$_egl" ] && [ -n "$_gbm" ]; then
  # The GPU-less VM (checo's runner has no render node, so the guest gets a
  # virtio-gpu with 3D off). hyprpaper draws with GL through hyprtoolkit; there
  # is no hardware driver for EGL to load, Mesa falls back to kms_swrast, and
  # kms_swrast needs dumb buffers, which the device hyprpaper opened refuses
  # (DRM_IOCTL_MODE_CREATE_DUMB: Permission denied, as a render node does). It
  # cannot allocate a single buffer and exits. The compositor draws on the same
  # device because it holds the primary node.
  #
  # A SKIP only when all three are in evidence: the kernel says this virtio-gpu
  # has no virgl, and hyprpaper's own log shows EGL failing and the allocation
  # failing. On hardware there is no virtio-gpu line; on the render-node VM it
  # reads +virgl. Either way a hyprpaper that exits is a failure there.
  note "hyprpaper cannot draw: the VM's GPU has no 3D and hyprpaper needs GL"
  note "  kernel:    $_k"
  note "  hyprpaper: $_egl"
  note "  hyprpaper: $_gbm"
else
  bad "background layer is empty — the wallpaper is not actually on screen"
  # What hyprpaper said is in the log ergon-wallpaper keeps for it; what it
  # accepts over IPC is asked below. Both are printed in the run that fails,
  # because this failure was diagnosed by guesswork for as long as neither was.
  echo "     --- hyprpaper diagnosis ---"
  pgrep -x hyprpaper >/dev/null && echo "     running: yes (pid $(pgrep -x hyprpaper | head -1))" \
                                || echo "     running: NO — it exited"
  echo "     kernel: ${_k:-no virtio-gpu feature line}"
  if [ -f /run/user/1000/hyprpaper.log ]; then
    tail -20 /run/user/1000/hyprpaper.log | sed 's/^/     hyprpaper: /'
  else
    echo "     no /run/user/1000/hyprpaper.log — ergon-wallpaper never started it"
  fi
  grep -iE 'hyprpaper|wallpaper' /run/user/1000/hypr/*/hyprland.log 2>/dev/null \
    | grep -viE 'exec_cmd' | tail -8 | sed 's/^/     log: /'
  for req in "listloaded" "listactive"; do
    printf '     %s -> %s\n' "$req" "$(hq hyprpaper $req 2>&1 | head -2 | tr '\n' ' ')"
  done
  # The two candidate spellings, with the error text kept rather than discarded.
  printf '     preload  -> %s\n' "$(hq hyprpaper preload "$W" 2>&1 | head -1)"
  printf '     wallpaper-> %s\n' "$(hq hyprpaper wallpaper ",$W" 2>&1 | head -1)"
  printf '     reload   -> %s\n' "$(hq hyprpaper reload ",$W" 2>&1 | head -1)"
  sleep 1
  hq layers | awk '/Layer level 0/{b=1;next} /Layer level 1/{b=0} b' | sed 's/^/     after: /'
  echo "     --- end ---"
fi

# --- a runaway job must not take the session with it (ERGON-19) ------------
# The acceptance no parser and no stub can reach: allocate until the machine is
# under memory pressure, and see what is still alive afterwards. bin/test-oom.sh
# has the files, the scope and the doctor rows; this has a compositor to kill.
echo "--- out-of-memory containment ---"

# Everything these assertions are made of, printed ONCE when any of them fails.
# Every line of it was worked out by hand on the run that failed, from a report
# that said only "ManagedOOMMemoryPressure=auto": the drop-in on disk, the
# property in the manager and the cgroup oomd is watching are three different
# claims, and none of them proves either of the others. What provisioning itself
# said about the stage is in here because /tmp/prov.log is printed only when
# provisioning FAILS, and this stage warns rather than failing -- so on that run
# every word of its account was thrown away.
oom_diag_shown=0
oom_diag() {
  [ "$oom_diag_shown" = 0 ] || return 0
  oom_diag_shown=1
  echo "     --- out-of-memory diagnosis ---"
  for f in /etc/systemd/user/app.slice.d/10-ergon-oomd.conf \
           /etc/systemd/user/wayland-wm@.service.d/10-ergon-oom.conf \
           /etc/systemd/oomd.conf.d/10-ergon.conf; do
    if [ -r "$f" ]; then
      grep -vE '^[[:space:]]*(#|$)' "$f" | sed "s|^|     $f: |"
    else
      echo "     $f: MISSING — provisioning never wrote it"
    fi
  done
  # DropInPaths is the manager saying which files it has actually read. Without
  # it, a drop-in that was never written and one the manager never re-read give
  # the same 'auto'.
  usr "systemctl --user show app.slice -p ManagedOOMMemoryPressure -p ActiveState -p DropInPaths" \
    2>&1 | sed 's/^/     manager: /'
  echo "     oomd: $(systemctl is-active systemd-oomd 2>&1)"
  # The socket the USER manager connects to in order to report app.slice to
  # oomd. No socket, no report, whatever the manager holds.
  ls -l /run/systemd/oom/io.systemd.ManagedOOM 2>&1 | sed 's/^/     socket: /'
  # And what oomd is monitoring, which is the only end-to-end answer here.
  command -v oomctl >/dev/null && oomctl 2>&1 | sed 's/^/     oomctl: /'
  journalctl -b -u systemd-oomd --no-pager -n 15 2>&1 | sed 's/^/     journal: /'
  # The kernel's own killer fires minutes late and picks the biggest task on the
  # machine: a line here means nothing contained the run, not that something did.
  journalctl -b -k --no-pager 2>/dev/null \
    | grep -iE 'out of memory|oom-kill|killed process' | tail -5 | sed 's/^/     kernel: /'
  grep -iE 'oom|user manager' /tmp/prov.log 2>/dev/null | tail -10 | sed 's/^/     prov: /'
  echo "     --- end ---"
}

if systemctl is-active --quiet systemd-oomd; then
  ok "systemd-oomd is running (provisioning enabled it)"
else
  bad "systemd-oomd is not running — nothing watches memory pressure"
  systemctl status systemd-oomd --no-pager -l 2>&1 | tail -8 | sed 's/^/     /'
  oom_diag
fi

# The policy as the USER MANAGER holds it, which is the only form that reaches
# oomd: a drop-in under /etc/systemd/user that no manager has read is a policy
# this machine does not have yet. There is a manager to ask because the harness
# lingers the user before it starts anything (see "starting Hyprland"), which is
# what turned this from a note that asserted nothing into an assertion.
#
# Two ways this reads 'auto' and they need telling apart, which is what
# oom_diag is for: the manager started before the drop-in existed and has not
# re-read it (DropInPaths empty, file present), or provisioning never wrote the
# file at all. The first is the one that shipped -- provisioning's reload could
# not reach the manager from the session-less shell it runs in, warned, and the
# warning went into a log nobody prints.
oom_app=$(usr "systemctl --user show -p ManagedOOMMemoryPressure --value app.slice" 2>/dev/null | tr -d '\r')
case "$oom_app" in
  kill) ok "app.slice is monitored by oomd in this session" ;;
  *)    bad "app.slice ManagedOOMMemoryPressure='${oom_app:-no user manager to ask}' — oomd is allowed to kill nothing"
        oom_diag ;;
esac

# A REAL ALLOCATION, run the way `ergon watch` runs one: through the user
# manager, under app.slice, with MemoryHigh forcing the scope to reclaim hard so
# that the pressure oomd acts on actually builds.
#
# The OUTER unit is a transient service rather than a scope, and that is this
# harness's shape rather than a shortcut. cgroup v2 refuses a migration unless
# the mover can write the cgroup.procs of the COMMON ANCESTOR of source and
# destination; everything here descends from a root-owned serial-console cgroup
# rather than from user@1000.service, so `systemd-run --user --scope` -- which
# is what both `ergon watch` and uwsm-app use -- cannot move its own caller in,
# and fails before running anything. A service is started BY the manager, inside
# its own tree, so nothing is migrated. `ergon watch` then runs from inside
# user@1000.service, where its scope IS allowed, and the cgroup, the slice, the
# pressure and the kill below are all the real ones.
cat > /tmp/eat-memory.py <<'PY'
# bytearray, not a reservation: it writes zeroes, so every page is resident and
# the cgroup is really under pressure rather than merely over-committed.
blocks = []
while True:
    blocks.append(bytearray(64 * 1024 * 1024))
PY
HYPR_BEFORE=$(pgrep -x Hyprland | head -1)
OOMUNIT=ergon-vm-oom-probe
usr "systemctl --user reset-failed $OOMUNIT.service" >/dev/null 2>&1 || true
# The unit is started BY the user manager, so it inherits the manager's
# environment and not usr()'s -- and the manager has no DBUS_SESSION_BUS_ADDRESS
# unless the session imported one. libnotify talks over GDBus, which has no
# $XDG_RUNTIME_DIR/bus fallback, so notify-send failed to reach mako and
# ergon-watch's `|| true` swallowed it: the kill happened, hist recorded it, and
# the one thing the card promises -- the machine SAYING what it killed -- was
# missing for a reason that only exists in this harness. A terminal in the real
# session carries both.
usr "timeout 300 systemd-run --user --quiet --wait --unit=$OOMUNIT --slice=app.slice \
     --setenv=PATH='$SESSION_PATH' \
     --setenv=XDG_RUNTIME_DIR=/run/user/1000 \
     --setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus -- \
     ergon watch --name oom-probe --mem 256M -- python3 /tmp/eat-memory.py" \
  >/tmp/oomprobe.log 2>&1
rc=$?
# timeout kills systemd-run --wait, never the unit it is waiting on, so an
# unkilled allocation would go on eating the VM for the rest of the suite.
usr "systemctl --user stop $OOMUNIT.service" >/dev/null 2>&1 || true

# THE MECHANISM, not the mortality. Any non-zero exit used to count as a pass
# here, so `python3` missing (127), `ergon` off the PATH (127) or a typo in the
# allocator (1) all read as "the machine ended it" -- and so did a run that
# nothing contained at all, because MemoryHigh only throttles and an unkilled
# job climbs until the GLOBAL kernel OOM killer picks the biggest task on the
# machine, which also exits 137. The manager's verdict on the scope is the one
# answer that separates those: oom-kill, from ergon-watch's own scope, is the
# thing this card claims to have built.
# Captured rather than piped into `grep -q`: grep leaves on the first match, su
# takes SIGPIPE for the rest, and this file's `set -o pipefail` then hands back
# 141 for the very output that matched.
hist=$(usr "ergon hist --json --name oom-probe" 2>/dev/null)
case "$hist" in
  *'"oom": 1'*)
    ok "ergon watch's own scope was killed for memory, and hist says so rather than exit 137" ;;
  *)
    bad "the run was not recorded as an OOM kill — nothing contained it, or the kill was not attributed"
    printf '%s\n' "$hist" | tail -20 | sed 's/^/     /'
    tail -10 /tmp/oomprobe.log | sed 's/^/     /'
    oom_diag ;;
esac
case "$rc" in
  0)   bad "the allocation returned 0 — it was never stopped"; oom_diag ;;
  # MemoryHigh only throttles, so an unwatched scope reclaims and stalls
  # forever: 124 is the signature of app.slice not being monitored at all.
  124) bad "nothing killed the run in 300s; the timeout ended it, which proves no containment at all"
       oom_diag ;;
esac
usr "systemctl --user reset-failed $OOMUNIT.service" >/dev/null 2>&1 || true

HYPR_AFTER=$(pgrep -x Hyprland | head -1)
if [ -n "$HYPR_BEFORE" ] && [ "$HYPR_BEFORE" = "$HYPR_AFTER" ]; then
  ok "the compositor is the same process it was (PID $HYPR_AFTER)"
else
  bad "Hyprland PID changed: $HYPR_BEFORE -> ${HYPR_AFTER:-gone}"
  dump_log
fi
# A PID survives a compositor that has stopped answering, so ask it something.
hq version | grep -q Hyprland && ok "and it still answers hyprctl" \
                              || bad "the compositor is alive but not answering"

# mako holds a critical notification until it is dismissed (mako/config), so if
# the daemon is there the message is still on screen. The window the job ran in
# may have died with it, which is what makes this the only place the machine
# says WHAT it killed.
if usr "pgrep -x mako" >/dev/null 2>&1; then
  # makoctl's own status, kept. Swallowed inside the command substitution, a
  # makoctl that could not reach the daemon was indistinguishable from a mako
  # holding nothing, and both were reported as the second -- which sends the
  # next reader to the notification code over a broken bus address.
  _mako=$(usr "makoctl list" 2>/dev/null); _mako_rc=$?
  case "$_mako" in
    *oom-probe*) ok "a notification names the run that was killed" ;;
    *) if [ "$_mako_rc" != 0 ]; then
         bad "makoctl could not read mako back (exit $_mako_rc) — whether a notification names the run is untested"
       else
         bad "mako is running but holds no notification naming the run"
         # Which half is broken: ergon-watch never calling notify-send, or a bus
         # that cannot carry it. Send one DIRECTLY and look again -- if this
         # arrives, delivery works and the caller is at fault; if it does not,
         # nothing ergon-watch does could have arrived either.
         echo "     --- notify-send on the session PATH ---"
         usr "command -v notify-send" 2>&1 | sed 's/^/     /'
         echo "     --- a notification sent directly ---"
         usr "notify-send -u critical 'ergon probe' 'direct oom-probe delivery test'" 2>&1 | sed 's/^/     /'
         echo "     rc=$?"
         usr "makoctl list" 2>&1 | head -30 | sed 's/^/     /'
         echo "     --- what ergon watch itself printed ---"
         tail -20 /tmp/oomprobe.log 2>/dev/null | sed 's/^/     /'
       fi ;;
  esac
else
  note "mako is not running here, so the notification cannot be read back"
fi

# The path a person actually takes, and the one thing this harness cannot walk:
# SUPER+RETURN goes through uwsm-app, which is `systemd-run --user --scope` and
# so hits the same migration rule as above from a compositor that logind never
# put inside user@1000.service. Reported rather than skipped silently, so that a
# harness that one day starts the session through greetd turns it into a pass.
if usr "systemd-run --user --scope --quiet --collect --slice=app.slice -p MemoryHigh=64M -- true" >/dev/null 2>&1; then
  ok "a user scope can be created from this session, so uwsm-app's terminals are contained here too"
else
  note "no user scope from a serial console (cgroup v2 refuses the migration), so the uwsm-app half of the terminal path is covered only by bin/test-oom.sh and by ergon-doctor's shell-slice row on real hardware"
fi

# --- a palette switch reaches the desktop that is already up (ERGON-33) ----
# NOTE, because it cost a run to learn: this suite tests COMMITTED work. The
# copy of the repo it provisions from is `git clean -qfd`ed above, for the
# reasons given there, so an untracked file is gone by the time anything below
# runs -- while a gitignored one (every rendered config) survives. A new
# template being tested before it is committed therefore looks exactly like a
# renderer that skipped it.
# The renderer runs on every one of these runs, because install.sh calls it.
# What had never been exercised is CHANGING palette on a desktop that is
# already drawn, which is the half that can only fail live: a surface themed
# at install time and stale afterwards is indistinguishable from a working one
# until someone presses the keybind.
#
# What is honestly assertable here, and what is not, is worth writing down.
# mako exposes no colours on its bus -- makoctl has list, reload and mode, and
# nothing else -- and swayosd-server exposes none either. Pixels are out: checo
# has no render node, so grim degrades to a note on exactly the weekly runs
# this exists to gate. So the claims below are the three that are real: the
# COMPOSITOR's own value changed, the file each daemon reads carries the new
# palette, and each daemon survived being told about it.
#
# foot is missing from that list on purpose. Recolouring an open terminal is
# escape sequences written down its pty, which needs no compositor at all:
# bin/test-theme.sh opens a real pty with script(1) and reads the sequences
# back out of it, which is a stronger claim than anything available here.
_pal_before_bg=$(hq "getoption -j misc:background_color")
# Every daemon the apply step touches, read before it is touched. Without a
# before-state, a daemon the switch KILLS is indistinguishable from one that
# was never running, and the branch for the second is a note -- so the worst
# outcome of this change would have been reported as neither a pass nor a
# failure. btop matters most: ergon-theme signals it with SIGUSR2, upstream
# #860 is open against exactly that path, and the btop this suite opened
# further up is the only live one this project ever signals.
_pal_before_osd=$(usr "pgrep -x swayosd-server" 2>/dev/null | head -1)
_pal_before_mako=$(usr "pgrep -x mako" 2>/dev/null | head -1)
_pal_before_btop=$(usr "pgrep -x btop" 2>/dev/null | head -1)
_pal_before_bar=$(usr "pgrep -x waybar" 2>/dev/null | head -1)
_pal_repo="$H/ergonOS"

if usr "ergon-theme gruvbox" > /tmp/palette.log 2>&1; then
  ok "a palette switch runs in the session"
else
  bad "ergon theme gruvbox failed in the session"
  tail -20 /tmp/palette.log 2>/dev/null | sed 's/^/     /'
fi

_pal_after_bg=$(hq "getoption -j misc:background_color")
# hq folds stderr into stdout, so "Couldn't connect to ... .socket.sock" is a
# non-empty string that differs from the JSON captured before it -- a dead
# compositor would have read as proof that it re-read its colours. Require an
# answer that is shaped like one.
_pal_answered=0
case "$_pal_after_bg" in '{'*) _pal_answered=1 ;; esac
if [ -z "$_pal_before_bg" ]; then
  bad "hyprctl could not read misc:background_color before the switch"
elif [ "$_pal_answered" = 0 ]; then
  bad "hyprctl did not answer with an option after the switch — the compositor may be gone"
  printf '%s\n' "$_pal_after_bg" | head -3 | sed 's/^/     /'
elif [ "$_pal_after_bg" != "$_pal_before_bg" ]; then
  ok "the compositor re-read its own colours (misc:background_color changed)"
else
  bad "misc:background_color is unchanged — hyprctl reload did not pick up the rendered config"
  echo "     before: $_pal_before_bg"
  echo "     after:  $_pal_after_bg"
fi

# Read through ~/.config, not through the checkout: that proves the symlink
# install.sh made AND the render behind it, in one assertion.
_pal_bg1=$(sed -n 's/^COOL_BG1=\(#[0-9A-Fa-f]\{6\}\).*/\1/p' "$_pal_repo/theme/gruvbox.env" | head -1)
_pal_act=$(sed -n 's/^COOL_ACTIVE=\(#[0-9A-Fa-f]\{6\}\).*/\1/p' "$_pal_repo/theme/gruvbox.env" | head -1)
# An empty needle makes every grep below match anything at all -- the shape a
# drift guard takes when it stops guarding, and it would go quiet on exactly
# the drift it is here for: a role renamed out of the palette file.
if [ -z "$_pal_bg1" ] || [ -z "$_pal_act" ]; then
  bad "could not read COOL_BG1/COOL_ACTIVE out of theme/gruvbox.env — the checks below would pass against any file"
fi
grep -q "background-color=$_pal_bg1" "$H/.config/mako/config" 2>/dev/null \
  && ok "the config mako reads carries the new palette" \
  || bad "$H/.config/mako/config does not carry gruvbox's $_pal_bg1"
if [ -e "$H/.config/swayosd/style.css" ]; then
  # Anchored on the declaration. The template renders @COOL_ACTIVE@ into the
  # comment that documents the rule as well as into the rule, so a bare colour
  # match passes with the rule deleted -- and the OSD falls through to
  # upstream's grey, which is the exact failure the template's header warns
  # about. This is the only assertion anywhere that looks at the OSD in a real
  # session.
  if grep -qi "background: $_pal_act;" "$H/.config/swayosd/style.css" 2>/dev/null; then
    ok "the stylesheet swayosd reads carries the new palette"
  else
    bad "$H/.config/swayosd/style.css does not carry gruvbox's $_pal_act"
    # Three things can produce this and they need different fixes: the link
    # points somewhere unexpected, the template never reached this machine, or
    # the render skipped it. Print all three rather than sending the next
    # reader to guess between them.
    echo "     --- the path, and what it resolves to ---"
    ls -l "$H/.config/swayosd/style.css" 2>&1 | sed 's/^/     /'
    printf '     -> %s\n' "$(readlink -f "$H/.config/swayosd/style.css" 2>&1)"
    echo "     --- what the repo holds ---"
    ls -l "$_pal_repo/swayosd/" 2>&1 | sed 's/^/     /'
    echo "     --- the colours the file actually carries ---"
    grep -aoE '#[0-9A-Fa-f]{6}' "$H/.config/swayosd/style.css" 2>/dev/null \
      | sort -u | tr '\n' ' ' | sed 's/^/     /'
    echo
    echo "     --- what the palette switch printed ---"
    tail -25 /tmp/palette.log 2>/dev/null | sed 's/^/     /'
  fi
else
  bad "no $H/.config/swayosd/style.css — the OSD is drawing in whatever GTK theme is set"
  ls -l "$H/.config/swayosd/" 2>&1 | sed 's/^/     /'
  tail -25 /tmp/palette.log 2>/dev/null | sed 's/^/     /'
fi

# A before-state, like swayosd gets. Without one, a switch that KILLS mako is
# indistinguishable here from a mako that was never running -- and the branch
# for the second is a note, so the worst outcome of this change would have
# been reported as neither a pass nor a failure.
if [ -n "$_pal_before_mako" ] && ! usr "pgrep -x mako" >/dev/null 2>&1; then
  bad "mako was running before the switch and is gone after it — the reload killed the notification daemon"
elif usr "pgrep -x mako" >/dev/null 2>&1; then
  if _pal_out=$(usr "makoctl reload" 2>&1); then
    ok "mako accepted a reload of the config it was just handed"
  else
    bad "makoctl reload failed, so the running daemon kept the old palette"
    printf '%s\n' "$_pal_out" | sed 's/^/     /'
  fi
  # The regression that adding a reload invites is a daemon that survives the
  # command and then delivers nothing.
  # The distinguishing text goes in the SUMMARY, not the body: makoctl list
  # prints the summary and the app name and nothing else, which is the same
  # thing ergon-watch's header says about why the run's name is its summary.
  # Matching on a body here reported a notification that had arrived as
  # missing, with the notification visible in the diagnostic right below it.
  usr "notify-send 'ergon palette delivered' 'after the switch'" >/dev/null 2>&1
  sleep 1
  case "$(usr "makoctl list" 2>/dev/null)" in
    *"ergon palette delivered"*) ok "  and still delivers notifications afterwards" ;;
    *)
      bad "  but nothing arrives through it afterwards"
      echo "     --- is mako still the same process ---"
      usr "pgrep -x mako" 2>&1 | sed 's/^/     /'
      echo "     --- what it is holding ---"
      usr "makoctl list" 2>&1 | head -30 | sed 's/^/     /'
      echo "     --- sending one directly, and its exit ---"
      usr "notify-send -u critical 'ergon palette probe' 'second attempt'" 2>&1 | sed 's/^/     /'
      printf '     rc=%s\n' "$?"
      sleep 1
      usr "makoctl list" 2>&1 | head -30 | sed 's/^/     /' ;;
  esac
else
  note "mako is not running here, so the reload cannot be read back"
fi

# Polled, not sampled. hyprctl dispatch returns as soon as the compositor
# accepts it; the process then has to initialise GTK4 and gtk4-layer-shell on
# llvmpipe, which is the slowest thing in this VM. Reading the pid immediately
# reported the OSD as dead, and vm.yml now wakes a phone on that.
_pal_after_osd=""
for _ in $(seq 1 20); do
  _pal_after_osd=$(usr "pgrep -x swayosd-server" 2>/dev/null | head -1)
  [ -n "$_pal_after_osd" ] && [ "$_pal_after_osd" != "$_pal_before_osd" ] && break
  sleep 1
done
if [ -z "$_pal_before_osd" ]; then
  # Not a note. autostart.lua execs swayosd-server with the session, and
  # nothing else in this suite checks that it came up -- so a note here is the
  # difference between "the OSD is stale" and "there is no OSD", reported as
  # green.
  bad "swayosd-server was not running before the switch — autostart.lua never brought the OSD up"
elif [ -z "$_pal_after_osd" ]; then
  bad "swayosd-server is gone after the switch rather than restarted — the OSD is dead until next login"
elif [ "$_pal_after_osd" != "$_pal_before_osd" ]; then
  ok "swayosd-server was restarted, which is the only way it re-reads its CSS"
else
  bad "swayosd-server kept pid $_pal_after_osd, so it is still drawing the old palette"
fi

# btop was sent SIGUSR2 by the apply step. Upstream #860 aborts on the redraw
# that follows a reload when the GPU box is shown; ergon-theme reads btop.conf
# to avoid that, and the config this machine installs has no shown_boxes line
# at all, so the signal really was delivered here. Whether the process survived
# it is a thing only a live btop can say, and this is the only one there is.
if [ -z "$_pal_before_btop" ]; then
  note "no btop was open across the switch, so the SIGUSR2 path is unobserved here"
elif usr "pgrep -x btop" >/dev/null 2>&1; then
  ok "btop survived being signalled for the new palette"
else
  bad "btop is gone after the palette switch — SIGUSR2 killed it (btop#860)"
fi

# The bar is asserted by PID, not by presence. A layer surface outlives the
# client that owns it for as long as teardown takes, so "waybar is in hq
# layers" a second after the kill can be the DYING bar, still drawn with the
# old stylesheet -- which is the staleness this section exists to disprove.
_pal_after_bar=""
for _ in $(seq 1 20); do
  _pal_after_bar=$(usr "pgrep -x waybar" 2>/dev/null | head -1)
  [ -n "$_pal_after_bar" ] && [ "$_pal_after_bar" != "$_pal_before_bar" ] && break
  sleep 1
done
if [ -z "$_pal_before_bar" ]; then
  bad "waybar was not running before the switch — the session never had a bar"
elif [ -z "$_pal_after_bar" ]; then
  bad "waybar is gone after the palette switch — the desktop has no bar"
elif [ "$_pal_after_bar" = "$_pal_before_bar" ]; then
  bad "waybar kept pid $_pal_after_bar, so it is still drawing the old stylesheet"
else
  ok "waybar was restarted, which is the only thing that recolours the bar"
fi

for _ in $(seq 1 20); do hq layers | grep -q waybar && break; sleep 1; done
hq layers | grep -q waybar \
  && ok "  and mapped its layer surface again" \
  || bad "the restarted waybar never mapped a layer surface — the desktop has no bar"

# Back to the shipped palette, which is also the switch nobody tests: the one
# that has to undo the first.
usr "ergon-theme cool" > /tmp/palette-restore.log 2>&1
if [ "$(hq "getoption -j misc:background_color")" = "$_pal_before_bg" ]; then
  ok "switching back restores the palette the machine shipped with"
else
  bad "switching back to cool did not restore misc:background_color"
  # The forward switch keeps its log for this reason; so does this one now.
  # Without it the only thing the job log and the phone carry is the sentence
  # above, and "the render failed" and "hyprctl reload did not take" look the
  # same from there.
  tail -25 /tmp/palette-restore.log 2>/dev/null | sed 's/^/     /'
fi

# --- what the OS hands its agents -----------------------------------------
# Every one of these is installed by a step that WARNS rather than fails, so
# provisioning stays green whatever happens here and nothing else in this suite
# would notice. That is exactly why they need asserting: this ran green once
# with the whole block silently doing nothing, and the count was identical.
U=$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)
H=$(getent passwd "$U" | cut -d: -f6)

# ergon-explain prefers /usr/share over the checkout, and both skills tell an
# agent the body lives there.
n=$(ls -1 /usr/share/ergon/knowledge/*.md 2>/dev/null | wc -l)
[ "$n" -ge 1 ] && ok "knowledge installed system-wide ($n topics)" \
               || bad "no topics at /usr/share/ergon/knowledge — ergon explain falls back to a checkout"
[ -f /usr/share/ergon/AGENTS.md ] && ok "machine AGENTS.md installed" \
                                  || bad "no /usr/share/ergon/AGENTS.md"

# Claude Code has no machine-wide AGENTS.md; the managed policy file is its one
# OS-level hook, and it must point AT ours rather than be a copy that drifts.
if [ "$(readlink -f /etc/claude-code/CLAUDE.md 2>/dev/null)" = /usr/share/ergon/AGENTS.md ]; then
  ok "claude code: managed policy -> the machine AGENTS.md"
else
  bad "/etc/claude-code/CLAUDE.md does not resolve to /usr/share/ergon/AGENTS.md"
fi

# One SKILL.md, both harnesses. A skill that reaches only one of them is the
# failure this is here to catch.
for d in "$H/.claude/skills" "$H/.codex/skills"; do
  s=$(ls -1d "$d"/ergon-* 2>/dev/null | wc -l)
  [ "$s" -ge 1 ] && ok "skills linked into ${d#"$H"/} ($s)" \
                 || bad "no ergon skills in $d"
done
[ -e "$H/.codex/AGENTS.md" ] && ok "codex: global AGENTS.md linked" \
                             || bad "no $H/.codex/AGENTS.md"
# Readable through the link, not merely present: a dangling symlink satisfies
# -e on its own target check but gives an agent nothing.
grep -q 'ergon explain' "$H/.codex/AGENTS.md" 2>/dev/null \
  && ok "codex AGENTS.md reads through to the content" \
  || bad "$H/.codex/AGENTS.md is present but unreadable or empty"

# The off-disk backup: provisioning installed it, and it round-trips.
# shellcheck source=guest-backup.sh
. "$SHARE/test/arch-vm/guest-backup.sh"

[ "$F" -gt 0 ] && dump_log
finish
