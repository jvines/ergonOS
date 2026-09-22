# Security trade-offs this repo makes on purpose

Every knob here weakens something to buy convenience. Each entry says what it
weakens, what it buys, and what stays true either way, so the choice is one
you made rather than one that happened to you by default.

## The docker group is passwordless root

Membership in the `docker` group lets any process bind-mount `/` and chroot
into it through the socket. That is not "root for the human at the
keyboard" -- it is root for every process in the session: a coding agent
following a prompt-injected instruction, a `pip install` with a malicious
build step, anything that can reach `/var/run/docker.sock`. What it defeats
is the sudo password gate, and faillock with it. LUKS still protects the disk
at rest; that threat is unrelated and this changes nothing about it.

`DOCKER_GROUP=0|1` in `hosts/<host>/host.env`, default 0:

- **0** -- provisioning never adds the group. `docker` needs `sudo`, which
  needs no new plumbing: the daemon itself enables unconditionally either
  way. Rootless Docker is the eventual answer for a host where even `sudo
  docker` is too much, once the VM suite shows compose working under cgroup
  v2 delegation -- nothing here sets that up yet.
- **1** -- provisioning adds you, and `ergon doctor` warns on every run
  naming DOCKER_GROUP=1 as the reason, so the trade-off stays visible instead
  of fading into "that's just how this machine is."

Provisioning only ever ADDS for this knob, never removes: flipping it back to
0 does not undo a membership granted while it was 1, because a reprovision
that silently drops your own session's docker access is a worse surprise than
the one the knob exists to fix. `ergon doctor`'s `docker-group` check reports
actual `groups` membership, not host.env's opinion of it, so a machine
provisioned before this knob existed, or one someone `usermod`'d by hand, is
still told the truth: DOCKER_GROUP=1 warns naming it as the chosen
trade-off, DOCKER_GROUP=0 with membership anyway warns as drift, with the
`gpasswd -d` command to undo it.

That check reads membership with an explicit username (`groups "$(id -un)"`),
not the bare `groups` provisioning also uses internally. Bare `groups`
answers for the CALLING PROCESS's cached supplementary groups from its last
login, not a live `/etc/group` lookup -- coreutils says so in its own
`--help`. A terminal, tmux pane or ssh master left open across a `usermod`
would otherwise have doctor echo its own stale answer back at it: "not in the
group," on a machine where a fresh process already has it.

## Inbound is dropped, and Docker publishes to localhost

This laptop joins conference and observatory Wi-Fi, where every other host on
the subnet is a stranger, and until ERGON-20 nothing filtered inbound at all.
Provisioning now writes `/etc/nftables.conf` and enables `nftables.service`:
one table, `inet ergon`, whose input chain drops by default.

What stays open, and why each one is not optional:

- loopback, and anything established or related -- which is what makes DNS
  replies, and every connection this machine opens, keep working.
- **all** of ICMP and ICMPv6, not a hand-picked type list. Drop ICMPv6
  neighbour discovery and IPv6 stops working entirely; drop packet-too-big and
  the path MTU black-holes, which presents as a transfer that starts, moves a
  few KB and then hangs forever.
- the DHCP client, v4 as well as v6. Conntrack does not cover v4:
  NetworkManager's internal client does DISCOVER/OFFER over `AF_PACKET`, which
  never reaches the input hook at all, but a rebinding renewal is broadcast and
  its reply matches no conntrack entry.
- `tailscale0`, and UDP 41641 so tailscale can connect directly instead of
  relaying through DERP. The tailnet is trusted; the LAN is not. ssh from the
  LAN is dropped along with everything else, which is the intended answer --
  sshd is not enabled on a fresh install, and the fleet reaches this machine
  over the tailnet.

mDNS stays closed. It is what network printer discovery needs, and printing is
card G22, which owns opening it to the LAN.

### The ruleset must never flush the whole ruleset

Docker's rules reach the kernel through iptables-nft, which is the **same**
nf_tables backend. `flush ruleset` therefore destroys the `DOCKER` and
`DOCKER-USER` chains of a running daemon, and every container loses its
networking with nothing in any log to say why. Ours destroys one table by name.

The packaged `nftables.service` stops with exactly that command
(`ExecStop=/usr/sbin/nft flush ruleset`), so `systemctl restart nftables` --
what anyone does after editing a ruleset -- would have wiped Docker's chains
however well scoped the file is. Provisioning writes a drop-in that narrows the
stop to `nft destroy table inet ergon`.

### Published container ports bind 127.0.0.1

A published port is DNAT'd and delivered through FORWARD, so the input chain
never sees it: `docker run -p 8080:80` on a firewalled machine is still open to
the room. `/etc/docker/daemon.json` sets `"ip": "127.0.0.1"`, so the default
bind is loopback and publishing off-box is something you say out loud:

    docker run -p 0.0.0.0:8080:80 ...        ports: ["0.0.0.0:8080:80"]

**What this costs:** a compose service another fleet host reaches today stops
answering until its port is republished that way. Traffic from the docker
bridges is dropped with everything else too, so a container reaching back to
the host gateway (`host.docker.internal`, `--add-host ...:host-gateway`) hangs;
opening that belongs in `/etc/nftables.conf` through provisioning, not in a
rule added by hand that the next reload discards.

The same file caps container logs at 10 MB x 5. `json-file` has no default cap
at all, and one chatty container fills `/` -- at which point everything on the
machine fails at once, and it reads as a disk fault rather than as a container.

Provisioning **merges** those four keys with `jq` rather than writing the file.
Every other `/etc` file it owns is ergon policy that nothing else touches, but
`daemon.json` is where a machine keeps its own state -- `data-root` on `/home`
because `/` is small, an `insecure-registries` entry for the registry chiki
hosts, a proxy stanza. A whole-file write discards that and restarts dockerd in
the same breath, and the daemon comes back on `/var/lib/docker` where none of
the machine's images, containers or volumes are. A `daemon.json` that does not
parse is left alone with a warning: it is someone's half-finished edit, dockerd
is not running with it either way, and the file is the only copy.

`ergon doctor` carries both halves: `firewall` fails when nftables is not
active, and `docker-publish` fails when daemon.json does not set the binding.
The chain's policy needs `CAP_NET_ADMIN` to read, so as your own user doctor
says it cannot check that without root rather than inventing an answer;
`docker-publish` is a file read and answers either way.

Doctor probes for root separately from asking for the policy, because those are
two different facts and merging them hid the worst state. `nftables.service` is
`Type=oneshot RemainAfterExit=yes`, so it is still *active* after someone types
`nft flush ruleset` while debugging -- and a `firewall` row that read a failed
`nft list` as "I am not root" reported ok, to root, on a machine with an empty
ruleset. An active unit with no `inet ergon` table is now a hard failure.
