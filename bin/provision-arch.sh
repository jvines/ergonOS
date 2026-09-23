#!/usr/bin/env bash
# Take a freshly-bootstrapped Arch box to "one of Jose's machines".
#
#   ./provision-arch.sh                          # run locally on the new box
#   ./provision-arch.sh --remote <ssh-target>    # drive it over ssh from here
#
# The Arch counterpart to provision-debian.sh: everything AFTER the installer.
# arch-bootstrap.sh made it bootable; this makes it usable. Idempotent — every
# step checks first, so a re-run is a no-op.
#
# Structurally parallel to provision-debian.sh and deliberately shares none of
# its code. Three things from that script must NEVER appear here:
#   - the exoautomata worker-recovery stage. It installs a timer that fires
#     every 10 minutes forever; provision-debian.sh's own header says "a laptop
#     wants the first and not the second".
#   - the fdfind/batcat shims. Arch names them fd and bat.
#   - unattended-upgrades. There is no Arch equivalent and there must not be.
# And never run enroll-debian-node.sh against this machine: its net-watchdog
# stage is gated on running infra containers, which a laptop fails, so enrolling
# it installs a daemon whose job is to reboot the machine when it cannot reach
# the LAN.
set -euo pipefail

if [ "${1:-}" = "--remote" ]; then
  T="${2:?usage: provision-arch.sh --remote <ssh-target>}"
  echo "== copying provisioner to $T"
  scp -q "$0" "$T:/tmp/provision-arch.sh"
  exec ssh -t "$T" 'bash /tmp/provision-arch.sh; rm -f /tmp/provision-arch.sh'
fi

ERGON="${ERGON:-$HOME/ergonOS}"
export PATH="$HOME/.local/bin:$PATH"
say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ok  %s\n' "$*"; }
skip() { printf '   ·   %s\n' "$*"; }
warn() { printf '   !!  %s\n' "$*" >&2; }

[ -f /etc/arch-release ] || { echo "not an Arch system" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "run as your user, not root (makepkg refuses root)" >&2; exit 1; }

# Same helper install.sh uses: strip comments, blank lines and trailing space.
_pkglist() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]*$//' "$1"; }

# The list of paths this script reads, shared with ergon-sync and ergon-doctor
# so all three ask the same question. See the file for why it is not written
# out here.
# shellcheck source=../lib/provision-inputs.sh
. "$ERGON/lib/provision-inputs.sh"

# ---------------------------------------------------------------------------
say "system packages"
# informant, once installed, hooks pacman and ABORTS any transaction while there
# is unread Arch news -- it exits with the number of unread items, and the hook
# propagates that. That is exactly what it is for, and it means this script
# fails on its second run and every run after until the news is read.
#
# It is NOT cleared automatically here. Marking the news read on your behalf
# would silently discard the manual-intervention notices that are the only
# reason informant is in packages/pacman at all. Show them and stop; the
# override is explicit.
if command -v informant >/dev/null && ! informant check >/dev/null 2>&1; then
  warn "unread Arch news is blocking pacman:"
  informant list -r --unread 2>/dev/null | head -10 | sed 's/^/     /'
  if [ "${ERGON_SKIP_NEWS:-0}" = 1 ]; then
    warn "ERGON_SKIP_NEWS=1 — marking the news read"
    # sudo, and VERIFIED.
    #
    # informant's read state lives under /var, so this needs root. It used to
    # run as the user with `|| true`, which silently did nothing: the flag
    # claimed to skip the gate, provisioning continued past it, and then
    # pacman's informant HOOK aborted the first transaction that actually had
    # something to install. It looked like the flag worked for as long as every
    # package happened to be up to date.
    sudo informant read --all >/dev/null 2>&1 || true
    if informant check >/dev/null 2>&1; then
      ok "news marked read; pacman is unblocked"
    else
      warn "could not clear the news — pacman's hook will abort the first transaction"
      warn "run:  sudo informant read"
      exit 1
    fi
  else
    echo
    echo "   Read it, then re-run:   informant read" >&2
    echo "   Or, to skip:            ERGON_SKIP_NEWS=1 $0" >&2
    exit 1
  fi
fi

# -Syu, in ONE transaction -- and only on a run that actually has something to
# install.
#
# The comment that stood here argued that refreshing the database and
# installing together is the partial-upgrade footgun, and had it backwards. The
# footgun is -Sy WITHOUT -u: it points the database at today's versions while
# the installed packages stay at whatever day they were installed, so the next
# package pulled in links against a libfoo.so.N that the old, unupgraded libfoo
# does not provide. Installing anything at all therefore means -Syu.
#
# Which is exactly why this asks first whether anything is missing. `ergon
# sync` now re-runs provisioning for a change to grub/ or a hardware profile,
# and a machine that already has every package does not need a transaction for
# that -- least of all a months-deep unattended upgrade under a live session,
# where the linux package takes /usr/lib/modules/$(uname -r) with it and mesa
# is replaced under the running compositor. Upgrading is `ergon update`, which
# checks the four preconditions this script does not.
mapfile -t PKGS < <(_pkglist "$ERGON/packages/pacman")
# Also guards the -T below: with no targets it reads STDIN, so an empty
# manifest would hang provisioning rather than report anything.
[ "${#PKGS[@]}" -gt 0 ] || { echo "packages/pacman is empty" >&2; exit 1; }
# -T prints the targets that are NOT satisfied and exits 127 when there are
# any, which set -e would otherwise take as fatal.
mapfile -t MISSING < <(pacman -T "${PKGS[@]}" 2>/dev/null || true)
if [ "${#MISSING[@]}" -gt 0 ]; then
  warn "${#MISSING[@]} package(s) missing — installing them upgrades the system (pacman -Syu)"
  sudo pacman -Syu --needed --noconfirm "${PKGS[@]}"
  ok "${#PKGS[@]} packages"
else
  ok "${#PKGS[@]} packages already installed; nothing to upgrade here (use: ergon update)"
fi

# ---------------------------------------------------------------------------
say "snapshots"
# arch-bootstrap.sh created the snapper config; this is the part that is safe to
# re-apply and easy to get wrong. The 10/10/10/10 timeline defaults are tuned
# for a fileserver and will fill a laptop that also carries a large swapfile.
if [ -f /etc/snapper/configs/root ]; then
  sudo sed -i \
    -e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' \
    -e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' \
    -e 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' \
    -e 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' \
    -e 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' \
    /etc/snapper/configs/root
  ok "snapper timeline trimmed"
else
  warn "no snapper root config — did arch-bootstrap.sh run?"
fi
# paccache keeps the last 3 versions. That cache lives on its own subvolume
# precisely so a rollback can still reach the packages needed to fix itself.
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer \
                            paccache.timer grub-btrfsd >/dev/null 2>&1 || true
sudo install -Dm644 /dev/stdin /etc/conf.d/pacman-contrib <<'EOF'
PACCACHE_ARGS='-rk3'
EOF
ok "snapshot + cache timers"

# Snapshots being bootable is worth little if recovering from a broken update
# needs someone who knows to pick one at the GRUB menu, on a machine that just
# failed to boot. The guard makes the machine do it: two boots that never reach
# the default target and the third boots the last one that did. It needs the
# EFI partition (its counter lives there, because GRUB must write it before the
# kernel runs) and snapper's layout, and says so and skips when either is
# missing -- a desktop installed some other way is unaffected.
"$ERGON/bin/ergon-boot-guard" install || warn "boot guard not installed (see the message above)"

# Snapshots live on the disk they protect. The backup timers go in now; they do
# nothing until `ergon backup init REPO` says where, and ergon doctor warns
# until then -- a repository and its key are the one step that cannot be
# chosen for you.
sudo "$ERGON/bin/ergon-backup" install || warn "backup timers not installed (see the message above)"

# ---------------------------------------------------------------------------
say "no floppy controller"
# Nothing made since the 1990s has one, but the emulated i440fx machine presents
# an empty drive, the kernel binds it, udiskie sees removable media and polkit
# puts an authentication dialog about a FLOPPY DISK in front of you on every
# single boot.
#
# Blacklisting the module is the fix that works everywhere. Doing it with a qemu
# flag was tried first and is wrong twice over: -global isa-fdc.driveA= does not
# exist in qemu 10 and broke the boot outright, and it would only ever have
# helped inside this one harness -- a real machine with a stray fdc in firmware
# would still prompt.
sudo install -Dm644 /dev/stdin /etc/modprobe.d/ergon-no-floppy.conf <<'EOF'
# Written by provision-arch.sh. No machine this OS targets has a floppy
# controller; an emulated one only produces a polkit prompt about mounting it.
blacklist floppy
install floppy /bin/false
EOF
# /etc/modprobe.d is NOT enough on its own, and believing it was is why this
# came back: the module is loaded from the INITRAMFS, before the root filesystem
# holding that file is mounted. The blacklist there is read far too late.
#
# modprobe.blacklist= on the kernel command line applies from the first module
# load, initramfs included. That is what actually removes the drive.
_g=/etc/default/grub
if [ -f "$_g" ]; then
  _cur=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$_g")
  case " $_cur " in
    *" modprobe.blacklist=floppy "*) ok "floppy already blacklisted on the cmdline" ;;
    *)
      sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${_cur:+$_cur }modprobe.blacklist=floppy\"|" "$_g"
      sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 \
        && ok "floppy blacklisted on the kernel cmdline" \
        || warn "cmdline written but grub-mkconfig failed"
      ;;
  esac
else
  warn "no /etc/default/grub; the floppy will come back on the next boot"
fi
# Rebuild the initramfs too, so its copy of modprobe.d carries the blacklist.
sudo mkinitcpio -P >/dev/null 2>&1 || warn "mkinitcpio failed; the cmdline still covers this"
# And take it away on THIS boot, so the prompt stops now rather than after a
# reboot. This is the convenience, not the fix.
sudo rmmod floppy 2>/dev/null || true
[ -e /dev/fd0 ] && warn "/dev/fd0 is still present on this boot; it is gone after the next one" \
                || ok "no floppy device"

# ---------------------------------------------------------------------------
say "firewall and container publishing"
# ERGON-20. Nothing filtered inbound on this machine at all -- no ufw, no
# nftables, no iptables anywhere in the repo -- and this is a laptop that joins
# conference and observatory Wi-Fi, where every other host on the subnet is a
# stranger.
#
# Two halves, because the ruleset alone does not cover the second one. A
# published container port is DNAT'd in the nat hook and delivered through
# FORWARD, so it never passes the input chain: `docker run -p 8080:80` on a
# firewalled machine is still open to the room. The daemon binding it to
# loopback is what closes that, and the two are written together here so
# neither can be applied without the other.
#
# _changed rather than the unconditional `install` every other /etc file in
# this script uses: applying daemon.json means restarting dockerd, which stops
# every running container. A re-provision must not do that for bytes that did
# not move.
_changed() {  # _changed <path> < content -- true when the file now differs
  local p=$1 t; t=$(mktemp)
  cat > "$t"
  if sudo cmp -s "$t" "$p" 2>/dev/null; then rm -f "$t"; return 1; fi
  # set -e does not apply to a function called as an `if` condition, so a write
  # that failed would otherwise return "unchanged" and the caller would report
  # a policy it never applied.
  sudo install -Dm644 "$t" "$p" || { rm -f "$t"; warn "could not write $p"; return 1; }
  rm -f "$t"
}

if _changed /etc/nftables.conf <<'NFT'
#!/usr/bin/nft -f
# Written by provision-arch.sh. Loaded by nftables.service.
#
# There is no "flush ruleset" in this file and there must never be one.
# nftables.service re-runs this file on every reload, and Docker's rules live
# in the same nf_tables backend through iptables-nft -- so a flush wipes the
# DOCKER and DOCKER-USER chains out from under a running daemon and every
# container loses its networking until dockerd is restarted. This file owns one
# table and destroys exactly that one. `destroy` rather than `delete` because
# destroy does not fail when the table is not there yet, which is every first
# boot.
destroy table inet ergon

table inet ergon {
	chain input {
		type filter hook input priority filter; policy drop;

		iif "lo" accept
		ct state established,related accept
		ct state invalid drop

		# Every ICMP type, not a hand-picked list. The list is where this goes
		# wrong, and it goes wrong silently: without ICMPv6 neighbour
		# discovery IPv6 does not work at all, and without packet-too-big the
		# path MTU black-holes -- a connection that opens, moves a few KB and
		# then hangs forever, which is the worst thing to debug from an
		# observatory. Echo is in deliberately: a laptop nobody can ping is
		# harder to diagnose than one they can.
		meta l4proto icmp accept
		meta l4proto ipv6-icmp accept

		# DHCP, both families. Conntrack does not cover the v4 client:
		# NetworkManager's internal client does DISCOVER/OFFER over AF_PACKET,
		# which never reaches this hook, but a rebinding renewal is broadcast
		# and its reply has no outbound entry to match -- so the lease renews
		# for as long as the original server answers and the link then dies
		# hours into a conference day. DNS needs nothing here; a reply to a
		# query this machine sent is established.
		udp dport 68 udp sport 67 accept
		udp dport 546 udp sport 547 accept

		# The tailnet is trusted -- the fleet reaches this machine over it.
		# iifname, NOT iif: iif resolves the name to an interface index when
		# the ruleset LOADS, so the whole file fails when tailscaled has not
		# brought tailscale0 up yet, which is the boot order on every reboot.
		iifname "tailscale0" accept
		# Direct WireGuard. Without it tailscale still works, through a DERP
		# relay, which is slower for no reason anyone can see.
		udp dport 41641 accept
		# ssh from the LAN is dropped with everything else. That is the intended
		# answer: sshd is not enabled on a fresh install, and the fleet reaches
		# this machine over the tailnet, which the rule above already trusts.

		# mDNS stays CLOSED. It is what network printer discovery needs, and
		# printing is card G22, which owns opening it -- to the LAN only, and
		# only when printing is enabled:
		#   udp dport 5353 ip daddr 224.0.0.251 accept
		#   udp dport 5353 ip6 daddr ff02::fb accept
		#
		# Traffic from the docker bridges is dropped with everything else, so a
		# container reaching back to the host gateway (host.docker.internal,
		# --add-host ...:host-gateway) hangs. That is deliberate and it is in
		# knowledge/security.md; opening it belongs in this file, not in a
		# rule someone adds by hand that the next reload discards.
	}

	# No forward chain and no output chain, on purpose. Docker owns forwarding
	# through DOCKER-USER and DOCKER-ISOLATION, and a second forward chain with
	# a drop policy here would break container networking outright. Outbound is
	# unrestricted; that trade is recorded in knowledge/security.md.
}
NFT
then _nft_new=1; else _nft_new=0; fi

# The packaged unit's ExecStop is `nft flush ruleset` -- the very thing this
# file refuses to do. So `systemctl restart nftables`, which is what anyone
# does after editing a ruleset, takes Docker's chains with it on the way down
# even though the ruleset itself is scoped. Narrow the stop to our table too,
# or the caveat this card exists for is one systemctl verb away from biting.
if _changed /etc/systemd/system/nftables.service.d/10-ergon-scope.conf <<'UNIT'
# Written by provision-arch.sh.
#
# The packaged nftables.service stops with `nft flush ruleset`, which destroys
# Docker's iptables-nft chains along with ours. Empty ExecStop= first, because
# systemd APPENDS to a list-valued directive otherwise and the upstream flush
# would still run.
[Service]
ExecStop=
ExecStop=/usr/bin/nft destroy table inet ergon
UNIT
then
  sudo systemctl daemon-reload
fi

if sudo systemctl enable --now nftables >/dev/null 2>&1; then
  # `enable --now` does nothing to a unit that is already running, so a changed
  # ruleset on an installed machine reaches the kernel only through the reload.
  if [ "$_nft_new" = 1 ] && ! sudo systemctl reload nftables >/dev/null 2>&1; then
    warn "the new ruleset did not load; run sudo nft -c -f /etc/nftables.conf to see why. The machine is still filtered by the old one"
  else
    ok "nftables: input drops by default (lo, established, ICMP, DHCP, tailscale0)"
  fi
else
  warn "nftables.service would not start -- NOTHING filters inbound on this machine"
fi

# "ip" is the address `docker run -p 8080:80` binds when the command does not
# name one. Docker's default is 0.0.0.0, which on this machine means every
# conference network it has ever joined, and the ruleset above cannot help
# because the DNAT bypasses the input hook.
#
# The cost is real: a compose service another fleet host reaches today stops
# answering. Publishing off-box is now a thing you say out loud --
#   docker run -p 0.0.0.0:8080:80 ...      ports: ["0.0.0.0:8080:80"] in compose
#
# log-opts because json-file has no default cap at all: one chatty container
# fills / and then everything on the machine fails at once, which reads as a
# disk problem rather than as a container.
#
# MERGED into what is already there, not written over it. Every other /etc file
# this script owns is ergon policy that nothing else writes, but daemon.json is
# where a machine keeps its own state: "data-root" on /home because / is small,
# the insecure-registries entry for the registry chiki hosts, a proxy stanza. A
# whole-file heredoc discards all of it and the restart below then brings
# dockerd up on the default data-root, where every image, container and volume
# the machine had is simply not there -- and provisioning prints ok. So set
# four keys and leave everything else alone.
#
# jq -S because the bytes have to be stable: unsorted, the merge would reorder
# the file on every run and _changed would restart dockerd -- stopping every
# container -- for content that did not move. A file someone hand-indented is
# rewritten once, which is a real change and costs one restart.
_dj_old=$(sudo cat /etc/docker/daemon.json 2>/dev/null || true)
# Missing or empty carries no state worth preserving, and jq on empty input
# prints nothing at all -- which the guard below would read as a refusal,
# leaving the machine publishing to 0.0.0.0 forever.
[ -n "${_dj_old//[[:space:]]/}" ] || _dj_old='{}'
_dj_jq=$(cat <<'DOCKERD'
.ip = "127.0.0.1"
| ."log-driver" = "json-file"
| ."log-opts"."max-size" = "10m"
| ."log-opts"."max-file" = "5"
DOCKERD
)
_dj_new=$(printf '%s\n' "$_dj_old" | jq -S "$_dj_jq" 2>/dev/null) || _dj_new=
if ! command -v jq >/dev/null 2>&1; then
  # jq is in packages/pacman and installed by the stage at the top of this
  # script, so this is only reachable on a machine that never got the package
  # list. Refusing beats falling back to a whole-file write.
  warn "jq is missing, so daemon.json cannot be merged -- leaving it alone. Published ports still bind 0.0.0.0"
elif [ -z "$_dj_new" ]; then
  # jq fails, and prints nothing, on anything that is not an object: a
  # truncated edit, a stray array, a file half-written by something else.
  # dockerd is not running with that file either way, and overwriting it would
  # destroy the only copy of whatever someone was in the middle of.
  warn "/etc/docker/daemon.json is not a JSON object -- leaving it alone. Published ports still bind 0.0.0.0; fix the file and re-run"
elif _changed /etc/docker/daemon.json <<<"$_dj_new"; then
  if systemctl is-active --quiet docker; then
    sudo systemctl restart docker \
      && ok "docker publishes to 127.0.0.1 only (-p 0.0.0.0:PORT:PORT to publish off-box); dockerd restarted" \
      || warn "daemon.json written but dockerd would not restart; it applies on the next boot"
  else
    ok "docker publishes to 127.0.0.1 only (-p 0.0.0.0:PORT:PORT to publish off-box)"
  fi
else
  skip "docker publishing policy unchanged"
fi

say "services"
# power-profiles-daemon belongs here and was missing: it is installed by
# packages/pacman and was never enabled, so waybar's power-profiles-daemon
# module had no daemon to talk to and clicking it did nothing at all. TLP is
# deliberately absent -- the two conflict.
for u in NetworkManager docker tailscaled bluetooth fwupd power-profiles-daemon; do
  if systemctl list-unit-files "$u.service" >/dev/null 2>&1; then
    sudo systemctl enable --now "$u" >/dev/null 2>&1 && ok "$u" || skip "$u (not installed)"
  fi
done
# Group membership, NOT the daemon, is gated on DOCKER_GROUP (see "docker
# group" below, after hosts/$HOST/host.env exists to read it from) -- the
# daemon enables unconditionally because sudo docker needs it running either
# way, and that is the documented path when the knob is off.

# ---------------------------------------------------------------------------
say "graphics"
# The Vulkan ICD is chosen from what is on the PCI bus, not assumed.
#
# packages/pacman carries mesa and the loader, which every machine needs; the
# per-vendor driver is decided here so an AMD laptop does not drag in Intel and
# Nouveau for nothing. Hyprland without an ICD still starts and renders through
# llvmpipe, which feels broken in a way that reads as a compositor bug rather
# than a missing package -- so this is not optional polish.
GPUS=$(/sbin/lspci -nn 2>/dev/null | grep -iE 'vga|3d controller|display controller' || true)
GFX=""
printf '%s' "$GPUS" | grep -qiE 'amd|ati|radeon' && GFX="$GFX vulkan-radeon"
printf '%s' "$GPUS" | grep -qi 'intel'            && GFX="$GFX vulkan-intel intel-media-driver"
printf '%s' "$GPUS" | grep -qiE 'nvidia'          && {
  # Deliberately the open kernel modules and NOT the proprietary blob: nouveau
  # cannot drive modern cards, and nvidia-open is what upstream now recommends
  # for Turing and later. Anything older needs a human decision, so say so
  # rather than installing something that will not work.
  GFX="$GFX nvidia-open-dkms nvidia-utils"
  warn "nvidia detected — nvidia-open-dkms covers Turing and later."
  warn "  Older cards need the legacy driver chosen by hand; Wayland support varies."
}
if [ -n "$GFX" ]; then
  # shellcheck disable=SC2086
  sudo pacman -S --needed --noconfirm $GFX >/dev/null && ok "graphics:$GFX" \
    || warn "some graphics packages failed:$GFX"
else
  skip "no GPU recognised on the PCI bus — mesa software rendering only"
fi

# ---------------------------------------------------------------------------
say "hardware"
# Quirks that belong to ONE machine, selected by matching DMI rather than by
# assuming. This used to be inline here, behind conditionals reading "or not
# FW13" -- fine for one laptop, and exactly the "works on my laptop" shape for
# a distro: the first person to install this on a ThinkPad with Nvidia would
# inherit decisions made about a panel they do not have.
#
# See hardware/README.md. A profile that matches nothing is inert.
#
# ERGON_HARDWARE=<name> forces one, which is how the VM test exercises the
# Framework profile on a machine whose DMI says QEMU.
"$ERGON/bin/ergon-hardware" apply || warn "hardware profile failed to apply"

# ---------------------------------------------------------------------------
say "login policy"
# Login lockout: Arch ships deny=3, unlock_time=600.
#
# Three typos locks you out of your own laptop for ten minutes. On a machine
# that already demands a LUKS passphrase at boot, that is punishment rather than
# security -- the attacker who has the powered-off disk is not the one being
# slowed down, you are, at an observatory at 3am with cold hands.
#
# 10 attempts, 2 minutes, and the counter forgets after 15. Still bounded
# against someone sitting at an unlocked-but-logged-out machine, which is the
# only threat this control actually addresses.
sudo install -Dm644 /dev/stdin /etc/security/faillock.conf <<'EOF'
deny = 10
unlock_time = 120
fail_interval = 900
EOF
ok "login lockout relaxed (10 tries, 2 min)"
# ---------------------------------------------------------------------------
say "wifi regulatory domain"
# ArchWiki rates the RZ717/MT7925 "poor support" and notes throughput is very
# limited until the regdomain is set -- without it you can end up pinned to
# 2.4 GHz. Set it in provisioning, not by hand at an observatory.
#
# Derived from the system timezone rather than hardcoded. This said CL, which
# is right for exactly one person: transmit power and which channels exist are
# legally determined by where the machine is, and shipping a distro that
# silently tells a German laptop it is in Chile is both wrong and unlawful
# there. zoneinfo already carries the timezone-to-country mapping.
TZ_NOW=$(timedatectl show -p Timezone --value 2>/dev/null || readlink -f /etc/localtime | sed 's|.*/zoneinfo/||')
REGDOM=$(awk -v t="$TZ_NOW" '$1 !~ /^#/ && $3 == t { print $1; exit }' \
           /usr/share/zoneinfo/zone.tab 2>/dev/null | cut -c1-2)
[ -n "$REGDOM" ] || REGDOM=00     # 00 is the world-safe fallback domain
sudo install -Dm644 /dev/stdin /etc/modprobe.d/cfg80211.conf <<EOF
options cfg80211 ieee80211_regdom=$REGDOM
EOF
ok "regdom=$REGDOM (from $TZ_NOW)"

# ---------------------------------------------------------------------------
say "desktop session"
# greetd + tuigreet, launching Hyprland through uwsm.
#
# uwsm matters more than the greeter does: without it every app you open is a
# child process of the compositor, so a Hyprland crash or reload takes the whole
# session's apps with it. Under uwsm the session is a systemd slice and apps get
# their own scopes. hyprland-uwsm.desktop is shipped by the hyprland package
# itself, not by uwsm.
# The --cmd is what tuigreet runs AFTER authenticating, and getting it wrong
# gives a greeter that accepts your password and then returns to the greeter --
# which is what this did. Two mistakes were in the original:
#
#   * it pointed uwsm at hyprland-uwsm.desktop, whose own Exec is
#     "uwsm start -e -D Hyprland hyprland.desktop" -- so uwsm was being asked
#     to start uwsm. Point it at the PLAIN hyprland.desktop.
#   * -S is not a uwsm flag. uwsm start takes -D -a -e -N -C -U -t -T -F -g -G
#     -o -n, and errors on anything else.
#
# This line now matches, exactly, what the packaged hyprland-uwsm.desktop runs.
sudo install -Dm644 /dev/stdin /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-user-session --asterisks --cmd 'uwsm start -e -D Hyprland hyprland.desktop'"
user = "greeter"
EOF
sudo systemctl enable greetd >/dev/null 2>&1 || true
ok "greetd + tuigreet on vt1"

# Group membership, both of which are silent failures rather than errors:
#   video  -- brightnessctl writes /sys/class/backlight; without it the
#             brightness keys do nothing and report no error at all.
#   input  -- swayosd's libinput backend reads /dev/input for caps-lock state.
for g in video input; do
  groups | grep -qw "$g" || { sudo usermod -aG "$g" "$USER"; ok "added $USER to $g (re-login required)"; }
done

# Caps-lock / num-lock OSD. A SYSTEM service (it reads /dev/input), unlike
# swayosd-server which autostart.lua runs in the session.
sudo systemctl enable --now swayosd-libinput-backend.service >/dev/null 2>&1 \
  && ok "swayosd libinput backend" || skip "swayosd backend (not installed yet)"

# ~/Pictures, ~/Downloads and friends. The GTK file chooser falls back to $HOME
# for everything without them, so every save dialog opens in the wrong place.
command -v xdg-user-dirs-update >/dev/null && xdg-user-dirs-update && ok "xdg user dirs"

# GTK4 reads the theme from gsettings rather than settings.ini. gtk/settings.ini
# is linked by install.sh and covers GTK3 plus a fresh machine; this covers GTK4
# on a machine that has a session bus. Over ssh there is none, hence the guard.
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v gsettings >/dev/null; then
  gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
  gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
  gsettings set org.gnome.desktop.interface icon-theme 'Papirus-Dark'
  gsettings set org.gnome.desktop.interface cursor-theme 'Adwaita'
  gsettings set org.gnome.desktop.interface font-name 'Noto Sans 11'
  ok "GTK4 dark theme"
else
  skip "gsettings (no session bus — re-run from a graphical login)"
fi

# The wallpaper is derived from the palette at the panel's resolution and lives
# outside the repo. Generating it here is what makes a fresh install come up
# with a desktop rather than a black screen.
if command -v magick >/dev/null; then
  "$ERGON/bin/ergon-wallpaper" >/dev/null 2>&1 && ok "wallpaper" || skip "wallpaper (run ergon wallpaper from a session)"
else
  skip "wallpaper (imagemagick not installed)"
fi

# The themed configs are generated from theme/cool.env and committed. Rendering
# here would dirty the tree on every provision; checking costs nothing.
if ! "$ERGON/bin/ergon-theme" --check >/dev/null 2>&1; then
  warn "themed configs are stale in the repo — run 'ergon theme' and commit"
fi

# ---------------------------------------------------------------------------
say "AUR packages"
# Three packages does not justify a helper. Clone, review once, makepkg.
#
# ERGON_SKIP_AUR=1 skips only the packages whose line in packages/aur is marked
# "(slow build)". It exists because these build from SOURCE: wezterm-git alone is
# a long Rust build, intolerable in a VM test and unwelcome the first time you
# provision a machine you want to start using. binds.lua carries a foot escape
# hatch precisely so a machine without wezterm still has a terminal.
#
# It used to skip the stage ENTIRELY, which was fine while the only AUR package
# that mattered was a nicer terminal. It stopped being fine when waybar moved
# here: a desktop without waybar-git has a bar whose workspace buttons do
# nothing, so "skip the slow builds" and "skip the desktop working" became the
# same flag. Hence the marker -- the distinction is per package, not per stage.
_aurlist() {
  awk -v skipslow="${ERGON_SKIP_AUR:-0}" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { if (skipslow == "1" && $0 ~ /\(slow build\)/) next
      print $1 }' "$1"
}
if [ "${ERGON_SKIP_AUR:-0}" = 1 ]; then
  skip "slow AUR builds (ERGON_SKIP_AUR=1) -- run again without it for wezterm"
fi
AURDIR="$HOME/.cache/aur"; mkdir -p "$AURDIR"
while read -r pkg; do
  if AURDIR="$AURDIR" "$ERGON/bin/ergon-aur" "$pkg"; then
    ok "$pkg"
  else
    warn "$pkg FAILED to build — see $AURDIR/$pkg"
  fi
done < <(_aurlist "$ERGON/packages/aur")

# A git package can fail to build on any given day, and waybar is the one whose
# absence is not survivable: no bar at all, on a desktop with no other status
# surface. Fall back to the repo build, which works in every respect except the
# one that put waybar in packages/aur -- clicking a workspace.
if ! command -v waybar >/dev/null 2>&1; then
  warn "waybar-git is not installed; falling back to extra/waybar"
  warn "  the bar will work EXCEPT that clicking a workspace does nothing"
  warn "  (Alexays/Waybar#5013 — see packages/aur)"
  sudo pacman -S --needed --noconfirm waybar || warn "extra/waybar failed too"
fi

# ---------------------------------------------------------------------------
say "per-host directory"
# The hostname is chosen at install time (arch-bootstrap.sh prompts for it and
# writes /etc/hostname), so hosts/<name>/ cannot be pre-committed. Scaffold it
# here from the template; it stays untracked until you commit it.
HOST=$(hostname -s 2>/dev/null || cat /etc/hostname)
if [ -d "$ERGON/hosts/$HOST" ]; then
  skip "hosts/$HOST already exists"
else
  mkdir -p "$ERGON/hosts/$HOST"
  sed -e 's/^GRAPHICAL=0/GRAPHICAL=1/' -e 's/^PROFILE=server/PROFILE=laptop/' \
      "$ERGON/hosts/_template/host.env" > "$ERGON/hosts/$HOST/host.env"
  # The keyboard layout the installer was told about. hypr/common/looknfeel.lua
  # used to hardcode kb_layout = "us", which silently gave every non-US user a
  # US graphical layout no matter what they answered at install -- and unlike a
  # wrong locale, you find out by typing your password wrong.
  #
  # /etc/vconsole.conf is written by arch-bootstrap.sh from the chosen KEYMAP,
  # so this reads the answer rather than asking again.
  KB=$(awk -F= '/^KEYMAP=/ { gsub(/"/, "", $2); print $2 }' /etc/vconsole.conf 2>/dev/null)
  KB=${KB:-us}
  # Console keymap names and xkb layout names are different vocabularies: the
  # console calls it la-latin1 and xkb calls it latam, and passing the console
  # name straight through gives Hyprland a layout it does not know -- which it
  # answers by falling back to US, silently, so the user who answered the
  # keymap question correctly still gets an American keyboard.
  #
  # hypr/keymap-to-xkb is the mapping, shared with hypr/common/layout.lua so
  # the compositor and the provisioner cannot disagree about the keyboard.
  _xkb=$(awk -v k="$KB" '$1 !~ /^#/ && $1 == k { print $2; exit }' \
           "$ERGON/hypr/keymap-to-xkb" 2>/dev/null)
  # An unlisted keymap maps to itself, which is right far more often than not:
  # the two vocabularies agree for most single-word names (es, it, pl).
  KB=${_xkb:-$KB}
  cat > "$ERGON/hosts/$HOST/hyprland.lua" <<HYPRHOST
-- Machine-specific Hyprland config. Loaded by hypr/hyprland.lua via
--   pcall(require, "hosts." .. hostname)
-- so this file is optional and a syntax error in it cannot take down the base.

-- Keyboard, from the keymap chosen at install (/etc/vconsole.conf).
-- The console keymap and the Wayland layout are different settings with
-- different vocabularies; if yours needs a variant, set it here.
hl.config({ input = { kb_layout = "$KB" } })

HYPRHOST
  cat >> "$ERGON/hosts/$HOST/hyprland.lua" <<'HYPRHOST'
-- Machine-specific Hyprland config. Loaded by hypr/hyprland.lua via
--   pcall(require, "hosts." .. hostname)
-- so this file is optional and a syntax error in it cannot take down the base.
--
-- Fill in once you can see the panel. `hyprctl monitors` gives the real names
-- and modes. The Framework 13 2.8K panel is 2880x1920; scale 2 gives 1440x960
-- logical and integer scaling, which keeps GTK3 apps (including emacs-wayland,
-- which is pgtk-on-GTK3 and has no wp-fractional-scale-v1) sharp.
-- hl.monitor("eDP-1", { mode = "2880x1920@120", position = "0x0", scale = 2 })
HYPRHOST
  ok "scaffolded hosts/$HOST (untracked — commit it)"
fi

# ---------------------------------------------------------------------------
say "docker group"
# usermod -aG docker used to be unconditional in "services" above. That group
# is effectively passwordless root -- anything that can reach the socket can
# bind-mount / and chroot into it -- so it is opt-in per host now, read the
# same way GRAPHICAL is: from hosts/<host>/host.env, default 0. This is the
# first stage that can ask, because the file did not necessarily exist until
# the "per-host directory" stage just above scaffolded it.
DOCKER_GROUP=0
HOSTENV="$ERGON/hosts/$HOST/host.env"
# shellcheck disable=SC1090
[ -f "$HOSTENV" ] && . "$HOSTENV"
# $(id -un), not $USER: `groups` with no argument answers for THIS PROCESS's
# cached supplementary groups, not a live /etc/group lookup -- coreutils says
# so in its own --help. Naming the user forces the live read here too, same
# reason bin/ergon-doctor's docker-group check does.
ME="$(id -un)"
if [ "${DOCKER_GROUP:-0}" = 1 ]; then
  groups "$ME" | grep -qw docker || { sudo usermod -aG docker "$ME"; ok "added $ME to docker (re-login required) -- DOCKER_GROUP=1 in $HOSTENV"; }
else
  # Never REMOVE membership: a reprovision that silently drops your own
  # session's docker access is a worse surprise than the one this knob fixes.
  # If it is 0 and you are in the group anyway, that is ergon doctor's
  # business to report, not this script's to undo.
  groups "$ME" | grep -qw docker && skip "in the docker group despite DOCKER_GROUP=0 -- ergon doctor" \
                                  || skip "DOCKER_GROUP=0 -- docker needs sudo"
fi

# ---------------------------------------------------------------------------
say "bundles"
# Optional package groups: inference, astronomy, ml, gpu, julia, latex,
# notebooks. See packages/bundles/README.md.
#
# The choice is ASKED once and RECORDED in hosts/<host>/host.env, so
# reprovisioning reproduces the machine and `ergon-bundle add` works the same way
# afterwards. Nobody knows at partition time whether they will want the ML stack
# in March, so the installer prompt is a convenience wrapper around a command
# that keeps working, not a one-shot gate.
#
# ERGON_BUNDLES=... answers non-interactively; ERGON_BUNDLES=none takes none.
# It takes sources too (github:me/overlay//fleet@v1), with --yes: naming one in
# the environment IS the answer, since there is nobody at a terminal to ask.
if [ -n "${ERGON_BUNDLES:-}" ]; then
  if [ "$ERGON_BUNDLES" = none ]; then
    skip "bundles (ERGON_BUNDLES=none)"
  else
    # A bundle that fails to install must not take the whole provision with it,
    # any more than a failed AUR build does. The machine is still usable; the
    # bundle is a choice, and the user needs to be told which one did not land
    # rather than handed "provision-arch.sh failed" twenty minutes in.
    # shellcheck disable=SC2086
    "$ERGON/bin/ergon-bundle" add --yes $ERGON_BUNDLES || warn "some bundles failed to install"
  fi
elif [ -t 0 ]; then
  echo
  "$ERGON/bin/ergon-bundle" list
  echo
  echo "   Which bundles? (space separated, empty for none — ergon-bundle add <name> later)"
  printf '   > '
  read -r _bundles
  if [ -n "$_bundles" ]; then
    # shellcheck disable=SC2086
    "$ERGON/bin/ergon-bundle" add $_bundles || warn "some bundles failed to install"
  else
    skip "no bundles chosen"
  fi
else
  # Non-interactive and unanswered: apply whatever host.env already declares
  # rather than silently installing nothing on a reprovision.
  "$ERGON/bin/ergon-bundle" sync || warn "some bundles failed to install"
fi

# ---------------------------------------------------------------------------
say "editor tooling"
# Isolated per-tool venvs, matching the Macs. NOT the AUR basedpyright, which
# has depends=('nodejs') and would tie an LSP server to the system node.
for t in basedpyright ruff; do
  if command -v "$t" >/dev/null 2>&1 || [ -x "$HOME/.local/bin/$t" ]; then
    skip "$t"
  else
    uv tool install "$t" >/dev/null && ok "$t"
  fi
done

# Tree-sitter grammars are per-machine (they live outside the repo in
# ~/.emacs.d/tree-sitter), so they have to be built here, not synced.
if command -v emacs >/dev/null && [ -f "$HOME/.emacs.d/init.el" ]; then
  emacs --batch -l "$HOME/.emacs.d/init.el" --eval '(my/treesit-install-missing)' \
    >/dev/null 2>&1 && ok "tree-sitter grammars" || warn "grammar build failed — run M-x my/treesit-install-missing"
fi

say "polkit for the desktop"
# uwsm runs the compositor as wayland-wm@hyprland.service under user@.service,
# so everything the desktop launches lives in
#   /user.slice/user-1000.slice/user@1000.service/session.slice/...
# and NOT in a logind session scope. sd_pid_get_session() therefore fails for
# those processes, polkit resolves them to no session at all, and every action
# whose policy is "implicit active: yes / implicit inactive: no" is refused
# outright -- without even prompting, because inactive is a hard no.
#
# Demonstrated with power-profiles-daemon: a session reporting Active=yes on
# seat0, an authentication agent running, a correct policy, and
#   pkcheck --action-id ...switch-profile --process $$  ->  Not authorized.
# The bar's profile button did nothing for that reason and no other.
#
# Not every action here is a hard refusal: the login1 ones below come back as
# "authentication required" instead, and an agent does prompt for them. They
# are granted for a different reason, spelled out in the rule itself.
#
# The trade: this grants wheel members the action regardless of session, which
# includes over ssh. On a single-user laptop that is the difference between a
# working button and a broken one; on a shared machine, narrow it.
sudo install -Dm644 /dev/stdin /etc/polkit-1/rules.d/49-ergon-desktop.rules <<'EOF'
// Written by provision-arch.sh.
//
// Actions a desktop user must be able to take, granted by GROUP rather than by
// session activeness -- under uwsm the compositor's children are not in a
// logind session scope, so polkit's implicit-active rules never match them.
//
// Deliberately a short list. Every entry here is one a person sitting at this
// machine would otherwise be refused silently, or asked for a password to do
// something the hardware already does unauthenticated.
//
// suspend and hibernate, but NOT reboot or power-off. Those two read
// auth_admin_keep for a session-less caller, so the session menu gets a PROMPT
// rather than a silent refusal -- measured on 2026-09-22 with
//   pkcheck --action-id org.freedesktop.login1.power-off --process $$ -u
// from a SUPER+RETURN terminal, and the dialog does appear. Closing the lid
// already suspends with no authentication at all (logind handles
// HandleLidSwitch itself; polkit never sees it), so demanding an admin
// password to press the menu entry for that same act protects nothing. Reboot
// and shutdown are different: they end every job on the machine, they happen
// once a day at most, and a prompt is a reasonable last check. They stay
// behind it, and test/arch-vm/guest-desktop.sh asserts that they do.
polkit.addRule(function(action, subject) {
    if (!subject.isInGroup("wheel")) {
        return null;
    }
    switch (action.id) {
        case "org.freedesktop.UPower.PowerProfiles.switch-profile":
        case "org.freedesktop.login1.suspend":
        case "org.freedesktop.login1.hibernate":
            return polkit.Result.YES;
    }
});
EOF
if sudo systemctl reload polkit 2>/dev/null || sudo systemctl restart polkit 2>/dev/null; then
  ok "polkit: wheel may switch power profiles, suspend and hibernate"
else
  warn "polkit rule written but the daemon was not reloaded; it applies after a reboot"
fi

# ---------------------------------------------------------------------------
say "out-of-memory containment"
# ERGON-19. A sampler that exhausted memory used to cost the whole session, and
# every link in that chain is a default nobody chose.
#
# uwsm runs the compositor as wayland-wm@hyprland.service with Slice=session.slice,
# no Delegate= and no OOMPolicy=, so it takes the manager default OOMPolicy=stop
# -- and the unit carries OnFailure=wayland-session-shutdown.target with
# OnFailureJobMode=replace-irreversibly. One process killed by the kernel inside
# that unit therefore stops the unit, and stopping it ends the session: every
# terminal, every Emacs buffer, every unsaved notebook. Terminals used to be
# started straight from a keybind, which put them and everything they ran in
# exactly that unit.
#
# Three files, each answering a different half:
#
#   oomd.conf.d   act on memory PRESSURE. The kernel OOM killer only fires when
#                 an allocation actually fails, which on a machine with swap is
#                 minutes after it stopped being usable.
#   app.slice.d   where systemd-oomd is allowed to act.
#   wayland-wm@   the kernel killing something that IS still in the compositor's
#                 unit must not end the session.
#
# app.slice and NOT app-graphical.slice, worked out rather than copied from
# Omarchy: systemd-oomd(8) says only DESCENDANTS of a monitored cgroup are
# candidates, the monitored unit itself never is, and "only leaf cgroups and
# cgroups with memory.oom.group set to 1 are eligible candidates". uwsm puts
# each uwsm-app launch in its own scope under app-graphical.slice, which is a
# child of app.slice -- so monitoring app.slice reaches each app's scope
# individually, two levels down, and can never kill app-graphical.slice as a
# whole because a slice with children is not a leaf. app.slice also covers the
# transient scope `ergon watch` puts each run in; app-graphical.slice would not,
# since `systemd-run --user` defaults to the ROOT slice (ergon-watch asks for
# --slice=app.slice for that reason). The compositor is in session.slice, which
# is monitored by nothing here and is the point of the whole arrangement.
#
# zram is deliberately NOT part of this. It changes what hibernation resumes
# from, and bin/test-hibernate.sh needs a VM to say whether that still works.
_oomd_reload=0; _user_reload=0
if _changed /etc/systemd/oomd.conf.d/10-ergon.conf <<'OOMD'
# Written by provision-arch.sh.
#
# oomd.conf(5) defaults to 60% pressure sustained for 30s. On a laptop that is
# half a minute in which nothing redraws and no keystroke lands -- the state
# this is supposed to prevent, arrived at on the way to preventing it. 50%/20s
# is the same pair Omarchy settled on.
#
# SwapUsedLimit= is left at its default on purpose: it only governs cgroups with
# ManagedOOMSwap=kill, and nothing here sets that. Swap on this machine is where
# the hibernation image goes, so "swap is full" is not by itself a reason to
# kill anything.
[OOM]
DefaultMemoryPressureLimit=50%
DefaultMemoryPressureDurationSec=20s
OOMD
then _oomd_reload=1; fi

if _changed /etc/systemd/user/app.slice.d/10-ergon-oomd.conf <<'OOMAPP'
# Written by provision-arch.sh.
#
# Everything uwsm-app starts -- every terminal, every launcher hit, and the
# scope `ergon watch` wraps a run in -- lands under this slice, so this is the
# one line that decides whether a runaway job is killed on its own or takes the
# machine with it. The compositor is in session.slice and is deliberately not
# covered: it must never be a candidate.
[Slice]
ManagedOOMMemoryPressure=kill
OOMAPP
then _user_reload=1; fi

if _changed /etc/systemd/user/wayland-wm@.service.d/10-ergon-oom.conf <<'OOMWM'
# Written by provision-arch.sh.
#
# uwsm's unit sets no OOMPolicy=, so it gets the default, stop -- and it stops
# with a failure, which its own OnFailure=wayland-session-shutdown.target turns
# into the end of the session. Anything still started inside the compositor's
# unit (an exec-once daemon, the foot escape hatch, anything forked from either)
# would therefore cost the whole desktop the moment the kernel picked it.
# continue logs the kill and keeps the session.
[Service]
OOMPolicy=continue
OOMWM
then _user_reload=1; fi

if sudo systemctl enable --now systemd-oomd >/dev/null 2>&1; then
  # Restart only when the config moved: this runs on every provision, and
  # bouncing the daemon for bytes that did not change costs a window in which
  # nothing is watching pressure at all.
  [ "$_oomd_reload" = 0 ] || sudo systemctl restart systemd-oomd >/dev/null 2>&1 || true
  ok "systemd-oomd watches memory pressure; a runaway app is killed, the session is not"
else
  # Not fatal. A kernel without PSI, or a container, has no pressure to watch --
  # and the rest of this script has nothing to do with that.
  warn "systemd-oomd would not start; nothing contains a run that exhausts memory"
fi
# The user manager has already read app.slice; a drop-in it has not reloaded is
# a policy this machine does not have yet. There is no user bus during a
# provision from a serial console, hence the fallback message rather than a
# failure.
if [ "$_user_reload" = 1 ]; then
  systemctl --user daemon-reload >/dev/null 2>&1 \
    && ok "user units reloaded (ergon doctor says whether this session's manager took it)" \
    || warn "no user manager to reload here; the oomd policy applies at the next login"
fi

say "shell"
# oh-my-zsh and zplug are git clones, not packages. Deliberately not from the
# AUR: both are a checkout and a source line, and an AUR wrapper would add a
# build step and a maintainer between this machine and two `git clone`s.
#
# zsh itself is in packages/pacman and arch-bootstrap.sh already creates the
# user with /bin/zsh as their shell.
for _repo in \
  "https://github.com/ohmyzsh/ohmyzsh.git|$HOME/.oh-my-zsh" \
  "https://github.com/zplug/zplug.git|$HOME/.zplug"
do
  _url=${_repo%%|*}; _dir=${_repo##*|}
  if [ -d "$_dir/.git" ]; then
    skip "$(basename "$_dir") already cloned"
  elif git clone --depth 1 -q "$_url" "$_dir" 2>/dev/null; then
    ok "$(basename "$_dir")"
  else
    warn "could not clone $_url — the shell works without it, with no prompt theme"
  fi
done
unset _repo _url _dir

say "commands on the system PATH"
# waybar's click handlers and hypr/common/autostart.lua exec `ergon-*` BY NAME,
# so they resolve through PATH. PATH reaches a graphical session only through
# environment.d, which `systemd --user` reads when it starts and not again -- and
# that manager outlives logouts. So on any machine whose user manager predates
# the install, every ergon-* in the bar and in autostart resolves to nothing.
#
# The symptom is precise and was reported three times before it was believed: a
# bar that draws perfectly, where clicking volume, network or the CPU does
# nothing at all, while bluetooth works -- because bluetooth calls
# blueman-manager, a system binary, and the rest call ergon-launch-tui. The
# wallpaper is the same fault: autostart execs ergon-wallpaper and gets nothing.
#
# /usr/local/bin is on the default PATH for every user, shell and session, so
# linking here removes the dependency on environment.d propagating at all.
#
# `$ERGON/bin/ergon` IS IN THIS LIST, and it is not covered by the ergon-*
# glob -- there is no hyphen after it. It was left out for exactly that reason,
# so the dispatcher was the one command missing from every non-login
# environment: present when you type it in a terminal, absent to waybar and to
# every keybind. `ergon theme --next` on SUPER+T therefore did nothing at all,
# while `ergon-theme --next` worked, and the difference is invisible by
# inspection. Verified by asking the compositor to print its own PATH.
sudo install -d /usr/local/bin
_linked=0
for c in "$ERGON"/bin/ergon "$ERGON"/bin/ergon-* "$ERGON"/bin/erg-*; do
  [ -x "$c" ] || continue
  sudo ln -sfn "$c" "/usr/local/bin/$(basename "$c")" && _linked=$((_linked+1))
done
if [ "$_linked" -gt 0 ]; then
  ok "$_linked commands linked into /usr/local/bin"
else
  warn "no commands linked into /usr/local/bin — the bar's click handlers will do nothing"
fi

say "system knowledge"
# ergon-explain prefers /usr/share/ergon/knowledge over the checkout, and both
# shipped skills tell an agent the body lives there -- but nothing ever put it
# there, so the documented path did not exist and only the checkout fallback
# worked. Installing it means every user on the machine, and every agent,
# reads the same bytes whether or not they have a checkout.
sudo install -d /usr/share/ergon/knowledge
if sudo install -m644 "$ERGON"/knowledge/*.md /usr/share/ergon/knowledge/; then
  ok "$(ls -1 "$ERGON"/knowledge/*.md | wc -l) topics at /usr/share/ergon/knowledge"
else
  warn "could not install the knowledge base; ergon explain falls back to the checkout"
fi

# The machine's own AGENTS.md. Every current coding agent reads AGENTS.md, so
# this is the one file that describes Ergon to all of them rather than to one
# vendor's format. System-wide, so it is the same bytes for every user and for
# an agent working in a project that has nothing to do with this checkout.
# install.sh points each agent's global location at it.
if sudo install -m644 "$ERGON/AGENTS.system.md" /usr/share/ergon/AGENTS.md; then
  ok "machine AGENTS.md at /usr/share/ergon/AGENTS.md"
else
  warn "could not install /usr/share/ergon/AGENTS.md"
fi

# Claude Code has no machine-wide AGENTS.md: it discovers AGENTS.md only in the
# working directory and above, and its user-level slot is ~/.claude/CLAUDE.md,
# which belongs to the user. Its one OS-level hook is the managed policy file,
# /etc/claude-code/CLAUDE.md on Linux. Symlinked, so there is still exactly one
# source of truth and no second copy to drift.
#
# Additive by design: the docs are explicit that a managed CLAUDE.md and the
# user's own ~/.claude/CLAUDE.md "don't count, and keep loading alongside
# AGENTS.md" -- so this suppresses neither the user's file nor a project's.
#
# Note it cannot be filtered out with claudeMdExcludes. For a file that only
# describes the machine that is the point; deleting it is the way out.
CLAUDE_POLICY=/etc/claude-code/CLAUDE.md
if [ -e "$CLAUDE_POLICY" ] && [ ! -L "$CLAUDE_POLICY" ]; then
  warn "$CLAUDE_POLICY is a real file, left alone — Ergon's is /usr/share/ergon/AGENTS.md"
else
  sudo install -d /etc/claude-code
  sudo ln -sfn /usr/share/ergon/AGENTS.md "$CLAUDE_POLICY" \
    && ok "claude code: $CLAUDE_POLICY -> /usr/share/ergon/AGENTS.md" \
    || warn "could not link $CLAUDE_POLICY"
fi

say "provisioning record"
# What this machine was provisioned FROM, so that something can later ask
# whether it still matches the repo. Nothing could, before: `ergon sync`
# fast-forwards the checkout and re-runs install.sh, which is the USER-level
# layer, so a package added to packages/pacman, a polkit rule or a GRUB setting
# reached fresh installs and nothing else -- machines drifted apart by the date
# each happened to be installed.
#
# Every input gets a digest, not just this script and packages/pacman: with two
# of them recorded, doctor was answering a strictly smaller question than sync
# asked, and called a machine current while sync was saying it was not.
#
# Written last, because it claims every stage above it ran; this script is
# set -e, so reaching here is that claim.
#
# /var/lib/ergon and world-readable, like ergon-backup's status file, because
# `ergon doctor` runs as the user and "cannot check without root" is no answer
# to "is this machine current".
_prov_commit=$(git -C "$ERGON" rev-parse HEAD 2>/dev/null || echo unknown)
{
  echo "# Written by provision-arch.sh; read by ergon sync and ergon doctor."
  echo "commit=$_prov_commit"
  echo "at=$(date +%s)"
  ergon_input_digests "$ERGON"
} | sudo install -Dm644 /dev/stdin /var/lib/ergon/provisioned
ok "provisioned at ${_prov_commit:0:7}, recorded in /var/lib/ergon/provisioned"

say "done"
cat <<'EOF'

  Next:
    ~/ergonOS/install.sh
    re-login for the docker group

  NOT to run here: enroll-debian-node.sh. See the header.
EOF
