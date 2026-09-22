#!/usr/bin/env bash
# ERGON-20: what provisioning writes to /etc/nftables.conf and
# /etc/docker/daemon.json, and what ergon-doctor says about them.
#
#   ./bin/test-firewall.sh
#
# Seconds, no root, no network, no Arch, no VM, and it never loads a ruleset --
# `nft -f` needs CAP_NET_ADMIN and would rewrite the netfilter state of whatever
# machine ran the suite. The files are extracted from the heredocs provisioning
# writes them from, so this is the bytes an installed machine gets rather than a
# second copy of them kept in a fixture.
#
# The one that matters, and the reason this file exists at all: the ruleset must
# never contain `flush ruleset`. Docker's rules reach the kernel through
# iptables-nft, which is the SAME nf_tables backend -- so a flush on reload
# destroys the DOCKER and DOCKER-USER chains of a running daemon and every
# container loses its networking, with nothing in any log to say why. The
# packaged nftables.service already stops with exactly that command, which is
# why the unit drop-in is asserted here too.
#
# COVERS: the scoped teardown, the input policy, every exception the card names
# and the two it does not (DHCPv4, and iifname rather than iif for an interface
# that may not exist at load time), mDNS still being closed, docker's forwarding
# being left alone, daemon.json's binding and log caps AND what the merge that
# writes them keeps of the file already on the machine, and every state of the
# two doctor rows -- including the two that used to be one branch: no root, and
# root finding no table at all.
#
# DOES NOT COVER: whether the kernel accepts the ruleset, whether dockerd
# restarts cleanly, or where a published port really binds. Those are in
# test/arch-vm/guest-desktop.sh, which has a booted machine to ask.
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
has()  { grep -qE -- "$2" "$1"; }
not()  { ! "$@"; }

command -v jq >/dev/null \
  || { echo "jq is missing; it is in packages/pacman and daemon.json is parsed with it"; exit 1; }

# --- the files provisioning writes ------------------------------------------
# Pulled out of the heredocs rather than kept beside them. A fixture copy is a
# second source of truth that passes forever after the real one is edited.
heredoc() {  # heredoc <delimiter> <out>
  sed -n "/<<'$1'\$/,/^$1\$/p" "$REPO/bin/provision-arch.sh" | sed '1d;$d' > "$2"
  [ -s "$2" ]
}
check "the nftables ruleset is still written by provisioning"  heredoc NFT      "$T/nftables.conf"
# Not a file this time: provisioning MERGES its keys into whatever daemon.json
# the machine already has, so what comes out of the heredoc is the jq program
# that does it. Running the real program is the only way to assert the merge.
check "daemon.json's merge is still driven by provisioning"    heredoc DOCKERD  "$T/daemon.jq"
check "the nftables.service drop-in is still written by provisioning" heredoc UNIT "$T/drop-in.conf"
# Everything below asserts about these three files, so an extraction that came
# back empty would turn the whole suite green while proving nothing.
[ -s "$T/nftables.conf" ] && [ -s "$T/daemon.jq" ] && [ -s "$T/drop-in.conf" ] || {
  echo "   cannot read what provisioning writes; the heredoc delimiters moved" >&2
  printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
}

# nft comments start with #, and this file argues with itself about `flush
# ruleset` at length. Assert over the RULES.
grep -vE '^[[:space:]]*(#|$)' "$T/nftables.conf" > "$T/rules"

# --- the caveat -------------------------------------------------------------
check "the ruleset does not flush the whole ruleset" \
  not has "$T/rules" 'flush[[:space:]]+ruleset'
# Scoped: the only thing it tears down is its own table. A `destroy table inet
# filter` here would take the packaged workstation ruleset with it, and a bare
# `delete table` would fail the whole file on a machine that has not loaded it
# yet -- which is every first boot.
check "it destroys exactly one table, its own" \
  test "$(grep -cE '^(destroy|delete|flush)' "$T/rules")" = 1
check "and that table is inet ergon" \
  has "$T/rules" '^destroy table inet ergon$'
check "the table it then defines is the same one" \
  has "$T/rules" '^table inet ergon \{$'
check "it is a -f script the service can run" \
  has "$T/nftables.conf" '^#!/usr/bin/nft -f$'

# --- the policy and its exceptions ------------------------------------------
check "input drops by default" \
  has "$T/rules" 'type filter hook input priority filter; policy drop;'
check "loopback is accepted"    has "$T/rules" '^[[:space:]]*iif "lo" accept$'
check "replies to what this machine sent are accepted (DNS included)" \
  has "$T/rules" 'ct state established,related accept'
# Both families, and NOT a hand-picked type list: no ICMPv6 neighbour discovery
# means no IPv6 at all, and no packet-too-big means PMTU black-holes -- a
# transfer that starts, moves a few KB and hangs.
check "ICMP is accepted"        has "$T/rules" 'meta l4proto icmp accept'
check "ICMPv6 is accepted whole, so ND and PMTU survive" \
  has "$T/rules" 'meta l4proto ipv6-icmp accept'
# The card names the DHCPv6 client. v4 is here because NetworkManager's
# internal client rebinds by broadcast, and a broadcast reply matches no
# conntrack entry: without this the lease renews until the first server stops
# answering and the link then dies mid-conference.
check "the DHCPv4 client can be answered" has "$T/rules" 'udp dport 68 udp sport 67 accept'
check "the DHCPv6 client can be answered" has "$T/rules" 'udp dport 546 udp sport 547 accept'
check "the tailnet is accepted"           has "$T/rules" 'iifname "tailscale0" accept'
# iif resolves a name to an interface INDEX when the ruleset loads, so the whole
# file fails on a boot where tailscaled has not brought the interface up yet --
# which is every boot. iifname resolves per packet.
check "  by name, not by an index that does not exist at boot" \
  not has "$T/rules" 'iif "tailscale0"'
check "direct WireGuard is accepted, so tailscale need not relay" \
  has "$T/rules" 'udp dport 41641 accept'

# mDNS is what network printer discovery needs and printing is card G22. Closed
# until that card opens it, and the file has to say so -- a commented-out rule
# with no owner is one somebody uncomments.
check "mDNS is closed"          not has "$T/rules" '5353'
check "and the card that owns opening it is named" has "$T/nftables.conf" 'G22'

# Docker's DNAT delivers a published port through FORWARD. A forward chain here
# with a drop policy would break container networking outright; an output chain
# would break the machine in a way nothing in this card asks for.
check "forwarding is left to docker" not has "$T/rules" 'hook forward'
check "outbound is not filtered"     not has "$T/rules" 'hook output'

# --- stopping the service is the same hazard ---------------------------------
# The packaged unit's ExecStop is `nft flush ruleset`. So `systemctl restart
# nftables`, which is what anyone does after editing a ruleset, wipes docker's
# chains on the way down however well scoped the file is.
check "the drop-in clears ExecStop before replacing it" \
  has "$T/drop-in.conf" '^ExecStop=$'
check "  because systemd appends to the list otherwise, and the flush would still run" \
  test "$(grep -c '^ExecStop=' "$T/drop-in.conf")" = 2
check "the stop it puts back destroys only our table" \
  has "$T/drop-in.conf" '^ExecStop=/usr/bin/nft destroy table inet ergon$'

# --- what docker publishes to ------------------------------------------------
merge() { jq -S -f "$T/daemon.jq"; }  # stdin: the daemon.json a machine has
isjson() { jq -e . "$1" >/dev/null; }
# A machine that has no daemon.json at all: provisioning feeds the merge {}.
printf '{}\n' | merge > "$T/daemon.json"
check "a machine with no daemon.json gets valid JSON" isjson "$T/daemon.json"
check "published ports default to loopback" \
  test "$(jq -r '.ip' "$T/daemon.json")" = 127.0.0.1
# json-file has no default cap at all: one chatty container fills / and then
# everything on the machine fails at once, which reads as a disk fault.
check "container logs are capped at 10m"  test "$(jq -r '."log-opts"."max-size"' "$T/daemon.json")" = 10m
check "and kept to five files"            test "$(jq -r '."log-opts"."max-file"' "$T/daemon.json")" = 5

# daemon.json is the one /etc file this card touches that carries a MACHINE's
# state rather than ergon's policy. The stanza was a whole-file heredoc and this
# is what that cost: a laptop with a small root keeps "data-root" on /home, and
# provisioning discarded it and restarted dockerd in the same breath -- the
# daemon came back on /var/lib/docker, where every image, container and volume
# the machine had is simply not there, and provisioning printed ok.
kept=$(printf '{"data-root":"/home/jose/docker","insecure-registries":["registry.jvines.cl:5000"],"log-opts":{"labels":"owner"}}\n' | merge)
check "an operator's data-root survives the merge" \
  test "$(printf '%s' "$kept" | jq -r '."data-root"')" = /home/jose/docker
check "  and the insecure-registries entry for the fleet registry" \
  test "$(printf '%s' "$kept" | jq -r '."insecure-registries"[0]')" = registry.jvines.cl:5000
# Under a key the merge itself writes into, which is where a shallow merge
# quietly drops things.
check "  and a log-opt beside the two the merge sets" \
  test "$(printf '%s' "$kept" | jq -r '[."log-opts".labels,."log-opts"."max-size"] | join(" ")')" = "owner 10m"
# Preserving is not deferring: the binding is the card, so it wins over a
# published-to-the-world setting someone left in the file.
check "a 0.0.0.0 binding set by hand is still replaced" \
  test "$(printf '{"ip":"0.0.0.0"}\n' | merge | jq -r '.ip')" = 127.0.0.1

# Applying daemon.json means restarting dockerd, which stops every container on
# the machine. If the merge did not produce the same bytes from its own output,
# every provision would look like a change and do exactly that.
once=$(printf '{"data-root":"/srv/docker"}\n' | merge)
check "merging twice changes nothing, so a re-provision does not restart dockerd" \
  test "$(printf '%s' "$once" | merge)" = "$once"

# Refuse rather than clobber. An unparseable daemon.json is someone's
# half-finished edit -- dockerd is not running with it either way, and the file
# is the only copy. Provisioning's guard is "the merge produced nothing", so
# that is the claim here.
check "a daemon.json that does not parse produces nothing to write" \
  test -z "$(printf '{ "ip"\n' | merge 2>/dev/null)"
check "  nor does one that parses but is not an object" \
  test -z "$(printf '[]\n' | merge 2>/dev/null)"

# --- what ergon-doctor says about a machine ----------------------------------
mkdir -p "$T/stub" "$T/ergon/lib" "$T/sysroot/etc/docker" "$T/home"
# ergon-doctor sources this unconditionally, so the fixture has to carry it.
cp "$REPO/lib/provision-inputs.sh" "$T/ergon/lib/"
cat > "$T/stub/systemctl" <<'EOF'
#!/usr/bin/env bash
# Only the question doctor asks. Anything else succeeds, so an unrelated check
# further down cannot fail this suite.
case " $* " in
  *" is-active "*) [ "${STUB_NFTABLES:-active}" = active ] ;;
  *) exit 0 ;;
esac
EOF
cat > "$T/stub/nft" <<'EOF'
#!/usr/bin/env bash
# `nft list chain inet ergon input`. STUB_CHAIN=open drops the policy line,
# which is a chain that loaded and is accepting everything -- the state a check
# that only asked "is the service running" would call healthy. STUB_CHAIN=missing
# is what real nft does once the table is gone: nothing on stdout, non-zero.
if [ "${STUB_CHAIN:-drop}" = missing ]; then
  echo "Error: No such file or directory" >&2
  exit 1
fi
printf 'table inet ergon {\n\tchain input {\n'
[ "${STUB_CHAIN:-drop}" = drop ] && printf '\t\ttype filter hook input priority filter; policy drop;\n'
printf '\t}\n}\n'
EOF
cat > "$T/stub/sudo" <<'EOF'
#!/usr/bin/env bash
# doctor asks with -n, and STUB_SUDO=deny is a machine whose user cannot become
# root without typing a password -- which is how doctor is normally run.
[ "${1:-}" = -n ] && shift
[ "${STUB_SUDO:-allow}" = allow ] || exit 1
exec "$@"
EOF
chmod +x "$T/stub"/*
export PATH="$T/stub:$PATH" ERGON="$T/ergon" HOME="$T/home" ERGON_SYSROOT="$T/sysroot"
unset WAYLAND_DISPLAY
DJ="$T/sysroot/etc/docker/daemon.json"
cp "$T/daemon.json" "$DJ"

doctor() {  # doctor <check> -> that check's JSON object
  "$REPO/bin/ergon-doctor" --json 2>/dev/null | grep -o "{\"name\":\"$1\"[^}]*}"
}

check "an inactive nftables.service is a failure" \
  has <(STUB_NFTABLES=dead doctor firewall) '"state":"fail"'
check "  and it says nothing is filtering inbound" \
  has <(STUB_NFTABLES=dead doctor firewall) 'nothing filters inbound'
check "a loaded chain with policy drop is ok" \
  has <(doctor firewall) '"state":"ok".*policy drop'
# The state a "is the service running" check would call healthy.
check "a loaded chain that is NOT policy drop is a failure" \
  has <(STUB_CHAIN=open doctor firewall) '"state":"fail"'
# The snapper pattern: `nft list` is CAP_NET_ADMIN-only, and doctor runs as the
# user. Saying so beats inventing an answer -- reporting a failure it cannot see
# is how a check becomes one people scroll past.
check "without root it says the policy cannot be read, rather than guessing" \
  has <(STUB_SUDO=deny doctor firewall) '"state":"ok".*without root'
check "  and it still catches a service that is not running" \
  has <(STUB_SUDO=deny STUB_NFTABLES=dead doctor firewall) '"state":"fail"'

# The state the row had no test for, and got wrong. nftables.service is
# Type=oneshot RemainAfterExit=yes, so it stays "active" after someone types
# `nft flush ruleset` while debugging -- and asking for the policy and reading
# any non-zero as "I am not root" made root-with-no-table green, under a note
# telling root to re-run as root, on a machine where nothing filters inbound.
check "root finding no ergon table is a failure, not 'cannot check'" \
  has <(STUB_CHAIN=missing STUB_SUDO=allow doctor firewall) '"state":"fail"'
check "  and it says the table is not loaded" \
  has <(STUB_CHAIN=missing STUB_SUDO=allow doctor firewall) 'is not loaded'
# The same machine seen by a user who cannot ask: still honest about not knowing.
check "  while without root it is still 'cannot check', not a guess either way" \
  has <(STUB_CHAIN=missing STUB_SUDO=deny doctor firewall) '"state":"ok".*without root'

check "daemon.json with the loopback binding is ok" \
  has <(doctor docker-publish) '"state":"ok"'
check "  and it says how to publish a port off-box on purpose" \
  has <(doctor docker-publish) '0\.0\.0\.0:PORT'
printf '{"log-opts":{"max-size":"10m"}}\n' > "$DJ"
check "daemon.json without the ip setting is a failure" \
  has <(doctor docker-publish) '"state":"fail"'
rm -f "$DJ"
check "no daemon.json at all is a failure, not a skip" \
  has <(doctor docker-publish) '"state":"fail"'
# It is a file read, so this is the row that answers on a machine where doctor
# has no sudo at all -- and it is the half the ruleset cannot cover.
check "  even with no root anywhere" \
  has <(STUB_SUDO=deny doctor docker-publish) '"state":"fail"'

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
