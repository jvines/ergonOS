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
# container loses its networking, with nothing in any log to say why. Upstream's
# nftables.service stops with exactly that command, which is why the unit
# drop-in is asserted here too -- and every directive that drop-in RELIES on the
# unit having, because Arch's unit is a three-line file that has none of them.
#
# COVERS: the scoped teardown, the input policy, every exception the card names
# and the two it does not (DHCPv4, and iifname rather than iif for an interface
# that may not exist at load time), mDNS admitted to its two multicast groups
# and nowhere else, docker's forwarding being left alone, daemon.json's binding
# and log caps AND what the merge that writes them keeps of the file already on
# the machine, and every state of the three doctor rows -- including the two
# that used to be one branch: no root, and root finding no table at all.
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

# mDNS: driverless printer discovery and this machine's own *.local name
# (ERGON-40). Scoped by DESTINATION, not source or interface -- 224.0.0.251 and
# ff02::fb are link-local multicast groups no conforming router forwards past
# the local segment, so admitting them is not the same as opening the port: a
# unicast query straight at this host's own address must still hit the policy.
check "mDNS v4 is admitted, to the multicast group only" \
  has "$T/rules" '^[[:space:]]*udp dport 5353 ip daddr 224\.0\.0\.251 accept$'
check "mDNS v6 is admitted, to the multicast group only" \
  has "$T/rules" '^[[:space:]]*udp dport 5353 ip6 daddr ff02::fb accept$'
check "  and there is no bare accept a unicast query on 5353 could hit" \
  not has "$T/rules" '^[[:space:]]*udp dport 5353 accept$'
# The check above only rules out THAT one exact literal -- `udp dport 5353
# counter accept` added right next to the real two rules passed all three
# checks above unchanged (reproduced: 65/65 still green with it in place).
# Counting every rule line that mentions the port closes that: the two checks
# above already pin what those two lines must say, so a third match of any
# shape is a widened rule this suite has not approved.
check "  and 5353 appears in exactly those two rules, nowhere else" \
  test "$(grep -cE '5353' "$T/rules")" = 2
check "and the card that opened it is named" has "$T/nftables.conf" 'ERGON-40'

# Docker's DNAT delivers a published port through FORWARD. A forward chain here
# with a drop policy would break container networking outright; an output chain
# would break the machine in a way nothing in this card asks for.
check "forwarding is left to docker" not has "$T/rules" 'hook forward'
check "outbound is not filtered"     not has "$T/rules" 'hook output'

# --- stopping the service is the same hazard ---------------------------------
# UPSTREAM's ExecStop is `nft flush ruleset` -- Debian's, and what this drop-in
# was written against. So `systemctl restart nftables`, which is what anyone
# does after editing a ruleset, wipes docker's chains on the way down there
# however well scoped the file is.
check "the drop-in clears ExecStop before replacing it" \
  has "$T/drop-in.conf" '^ExecStop=$'
check "  because systemd appends to the list otherwise, and the flush would still run" \
  test "$(grep -c '^ExecStop=' "$T/drop-in.conf")" = 2
check "the stop it puts back destroys only our table" \
  has "$T/drop-in.conf" '^ExecStop=/usr/bin/nft destroy table inet ergon$'

# ARCH's unit is not upstream's, and assuming otherwise cost a whole VM run. The
# packaged file there is Type=oneshot and ExecStart= and nothing else: no
# RemainAfterExit=, no ExecReload=, no ExecStop=. systemd runs a oneshot's stop
# commands the moment ExecStart exits unless RemainAfterExit=yes is set, so the
# scoped ExecStop above destroyed the table the unit had just loaded, on every
# start, and the machine sat unfiltered with the service reading "inactive" and
# provisioning reporting ok. A drop-in must OWN every directive it depends on
# rather than narrow one it assumes the package ships.
check "the drop-in keeps the unit active after nft exits" \
  has "$T/drop-in.conf" '^RemainAfterExit=yes$'
check "  and the file says why, so the next reader does not take it back out" \
  has "$T/drop-in.conf" '^# .*oneshot'
# Provisioning reloads the unit when the ruleset changed. Arch's packaged unit
# has no ExecReload at all, so that verb fails outright there -- the pair has to
# agree here rather than in a 35-minute VM run.
check "the drop-in supplies an ExecReload, which Arch's unit does not have" \
  has "$T/drop-in.conf" '^ExecReload=/usr/bin/nft -f /etc/nftables\.conf$'
check "  cleared first, for the distro that does ship one" \
  test "$(grep -c '^ExecReload=' "$T/drop-in.conf")" = 2
check "and provisioning is what reloads it" \
  grep -q 'systemctl reload nftables' "$REPO/bin/provision-arch.sh"

# `systemctl enable --now` returned zero on the machine that was left with
# nothing filtering inbound, and truthfully: the ruleset loaded, and the unit's
# own stop destroyed it again a moment later. No exit code can see that, so the
# stage has to ask the kernel.
check "provisioning checks the loaded chain, not just systemctl's exit status" \
  grep -q 'nft list chain inet ergon input' "$REPO/bin/provision-arch.sh"

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
# Only the questions doctor asks, each keyed on the UNIT so the firewall row
# and the printing row cannot answer for each other. Anything else succeeds,
# so an unrelated check further down cannot fail this suite.
case " $* " in
  *" is-active "*" cups.socket "*)   [ "${STUB_CUPS_ACTIVE:-active}"   = active  ] ;;
  *" is-enabled "*" cups.socket "*)  [ "${STUB_CUPS_ENABLED:-enabled}" = enabled ] ;;
  *" is-active "*)                   [ "${STUB_NFTABLES:-active}"     = active  ] ;;
  *) exit 0 ;;
esac
EOF
cat > "$T/stub/lpstat" <<'EOF'
#!/usr/bin/env bash
# `lpstat -h ... -p`, in the shapes a real cupsd hands back and the one doctor
# must not confuse with either. STUB_LPSTAT_DEAD reproduces a scheduler doctor
# cannot reach -- measured directly: killing cupsd mid-request and pointing
# ServerName at nothing both print exactly this line and exit 1.
if [ "${STUB_LPSTAT_DEAD:-0}" = 1 ]; then
  echo "lpstat: Scheduler is not running." >&2
  exit 1
fi
n="${STUB_QUEUES:-0}"
if [ "$n" -eq 0 ]; then
  # Real cupsd exits 1 here too ("No destinations added.") -- doctor has to
  # tell this apart from STUB_LPSTAT_DEAD by the TEXT, since the exit code
  # alone (measured: both are 1) cannot.
  echo "lpstat: No destinations added." >&2
  exit 1
fi
# `lpstat -p`'s printer lines are gettext-translated (cups ships cups_es.po,
# cups_de.po in the package); measured against a real cupsd under
# LANG=es_ES.UTF-8, "printer q1 is idle" becomes "la impresora q1 está
# inactiva" and doctor's `^printer ` match goes to zero on a queue that is
# actually configured and running. Standing in for a real locale here rather
# than installing one: anything but the LC_ALL=C doctor is supposed to force
# gets the translated line instead.
if [ "${LC_ALL:-}" = C ]; then
  for i in $(seq 1 "$n"); do printf 'printer q%d is idle.\n' "$i"; done
else
  for i in $(seq 1 "$n"); do printf 'la impresora q%d está inactiva.\n' "$i"; done
fi
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

# --- ERGON-40: what doctor says about printing -------------------------------
# cups.socket, once enabled, stays "active (listening)" permanently -- that is
# what a listening socket unit IS. So unlike cups.service (asleep until
# something asks), "not active" here is not idle, it is broken: the socket
# stopped and `enable --now` did not survive. Only "not enabled" (provisioning
# never ran, or someone turned it off) is the other unconditional failure.
check "cups.socket not enabled is a failure -- provisioning never turned it on" \
  has <(STUB_CUPS_ENABLED=disabled doctor printing) '"state":"fail"'
check "enabled but not active is a failure too -- it should be listening" \
  has <(STUB_CUPS_ACTIVE=dead doctor printing) '"state":"fail"'
# The stub answers this one in Spanish unless LC_ALL=C reaches it, which is
# exactly the bug it catches: a real es_CL/de_DE install (offered at the
# locale prompt) would report 2 queues configured as 0, forever, and this
# check would go from "2 queue" to "0 queue" if ergon-doctor's LC_ALL=C were
# ever dropped.
check "enabled and active is ok, with the queue count" \
  has <(STUB_QUEUES=2 doctor printing) '"state":"ok".*2 queue'
check "  including zero queues -- that is not a failure" \
  has <(STUB_QUEUES=0 doctor printing) '"state":"ok".*0 queue'
# A dead/unreachable scheduler exits the same way lpstat does with zero queues
# genuinely configured (measured: both are exit 1) -- doctor has to read the
# TEXT to tell "nothing to print to" from "nothing configured", and get this
# one wrong instead: reproduced (see the review on this card) with a plain
# `lpstat -p 2>/dev/null | grep -c` that reported "ok, 0 queues" while cupsd
# was down.
check "an unreachable scheduler is not 'ok, 0 queues' -- it is a failure" \
  not has <(STUB_LPSTAT_DEAD=1 doctor printing) '"state":"ok"'

# --- the check that reported an open machine about a filtered one -------------
# `nft list chain inet ergon input | grep -q 'policy drop'` returns 141 under
# `set -o pipefail`: grep leaves on the first match and nft takes SIGPIPE
# writing the rest. Reproduced against a real loaded ruleset -- 141 through the
# pipe, 0 through a variable -- after it cost a VM run, reporting "NOTHING
# filters inbound" about a machine whose chain was loaded with policy drop the
# whole time. Asserted statically because no stub can catch it: a stub's output
# fits in one write, so the stub exits before grep closes the pipe and the bug
# does not reproduce.
check "provisioning does not pipe the chain into a grep that leaves early" \
  not grep -qE 'nft list chain[^|]*\| *grep -q' "$REPO/bin/provision-arch.sh"
check "  nor does the VM suite" \
  not grep -qE 'nft list chain[^|]*\| *grep -q' "$REPO/test/arch-vm/guest-desktop.sh"
check "  and provisioning still asks the kernel rather than an exit code" \
  grep -q 'nft list chain inet ergon input' "$REPO/bin/provision-arch.sh"

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
