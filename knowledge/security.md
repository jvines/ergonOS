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

## sudo is full and password-gated; faillock is what happens when you fail it

`%wheel ALL=(ALL:ALL) ALL` -- wheel, which on a single-user laptop is you, can
run anything as root, and a password is asked every time. There is no
NOPASSWD anywhere on a real install; the only place that string appears in
this repo is `test/arch-vm/*`, writing it inside a disposable VM harness so a
scripted test run needs no one to type a password into a pipe. Shipping that
line to a real machine would be the exact mistake this paragraph exists to
make someone notice.

Arch's own default for the gate behind that password -- `pam_faillock`,
`deny = 3`, `unlock_time = 600` -- is tuned for a login shared by people who
might be guessing, and on a single-user laptop it mostly locks out the one
person who is allowed to be there: three mistyped characters during a
debugging session, or cold hands at an observatory at 3am, cost ten minutes on
a machine that already demanded a LUKS passphrase once to get this far.
Provisioning writes `/etc/security/faillock.conf` with `deny = 10`,
`unlock_time = 120`, `fail_interval = 900` -- still bounded against someone
sitting at an unlocked, logged-out session, which is the only threat this
control actually addresses here, without being the thing that locks you out
of your own laptop. `faillock --user <name> --reset` clears a lockout that
still happens; see `ergon explain troubleshooting`.

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

mDNS (UDP 5353) is open, for driverless printer discovery and for this
machine resolving a `*.local` name of its own (ERGON-40). Scoped by
DESTINATION, not source or interface -- a laptop with no fixed name for "the
LAN" the way `tailscale0` is a fixed name for the tailnet. 224.0.0.251 and
`ff02::fb` are link-local multicast groups that no conforming router forwards
past the local segment (RFC 5771; `ff02::` is link-local IPv6 scope by
definition), so a packet reaching the input hook addressed to either one was
necessarily sent on whichever network this machine is on right now. A
unicast query straight at this host's own address on 5353 still hits the
drop policy this section opened with.

### The ruleset must never flush the whole ruleset

Docker's rules reach the kernel through iptables-nft, which is the **same**
nf_tables backend. `flush ruleset` therefore destroys the `DOCKER` and
`DOCKER-USER` chains of a running daemon, and every container loses its
networking with nothing in any log to say why. Ours destroys one table by name.

Upstream's `nftables.service` stops with exactly that command
(`ExecStop=/usr/sbin/nft flush ruleset`), so on the distros that ship it --
Debian is one -- `systemctl restart nftables`, what anyone does after editing a
ruleset, would wipe Docker's chains however well scoped the file is.
Provisioning writes a drop-in that narrows the stop to
`nft destroy table inet ergon`.

**Arch's unit is not upstream's**, and writing that drop-in against the wrong
one is what left the first real Arch machine with nothing filtering inbound.
Arch ships three lines -- `Type=oneshot` and
`ExecStart=/usr/bin/nft -f /etc/nftables.conf` -- with no `RemainAfterExit=`, no
`ExecReload=` and no `ExecStop=`. systemd runs a oneshot's stop commands the
moment `ExecStart` exits unless `RemainAfterExit=yes` is set, so adding an
`ExecStop` to that unit destroyed the table it had just loaded, on every start,
while `systemctl enable --now` still returned zero. The drop-in therefore sets
all three directives rather than narrowing one the package is assumed to have,
and the provisioning stage asks the kernel for the loaded chain instead of
trusting an exit status.

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
`Type=oneshot`, and the drop-in above makes it `RemainAfterExit=yes` -- which is
also what makes `is-active` worth asking at all here, and why the row cannot
stop there: the unit is still *active* after someone types
`nft flush ruleset` while debugging -- and a `firewall` row that read a failed
`nft list` as "I am not root" reported ok, to root, on a machine with an empty
ruleset. An active unit with no `inet ergon` table is now a hard failure.

## What LUKS actually protects, and the keyfile that doesn't weaken it

Full-disk encryption answers a stolen or lost laptop, not a process already
running on it: `cryptsetup open` at boot is the last question this machine
asks about the disk, so a compromised session or a malicious extension already
have everything the passphrase would otherwise hide. What stays protected is
exactly the powered-off case -- the bag left on a train, the laptop lifted at
an observatory.

The passphrase is typed once, at GRUB, not twice. `/boot` lives *inside* the
LUKS2 volume rather than on the unencrypted ESP, which is what lets GRUB boot a
rollback snapshot's own kernel instead of whatever the live system currently
has -- `ergon rollback`'s entire reason to exist -- and it means GRUB itself
must decrypt the volume to read a kernel at all. The initramfs GRUB then hands
off to would need to decrypt that same volume again, prompting a second long
passphrase on every boot and every hibernate resume. `arch-bootstrap.sh` adds a second key
instead: a random keyfile (`/etc/cryptsetup-keys.d/cryptroot.key`) embedded in
the initramfs image, which `systemd-cryptsetup` finds automatically. That is
not a weaker unlock left somewhere less protected -- the initramfs is itself
inside the encrypted volume, so the keyfile is encrypted at rest along with
the kernel and everything else. An attacker holding the powered-off disk still
has neither key; the shortcut only removes a SECOND prompt for a volume that
was already unlocked once, this boot, by the real passphrase.

## TRIM passes through the disk encryption

dm-crypt drops every discard unless the mapping allows them, and until ERGON-34
nothing here allowed them: btrfs switches on its async discard by itself, at
mount, only for a device that takes discards, so the SSD under
`/dev/mapper/cryptroot` was never told which blocks were free -- write speed
and wear, lost over months.

**What it weakens:** which blocks are free becomes visible on the raw disk, so
someone holding it powered off can tell roughly how full it is and guess the
filesystem. **What stays true:** not one byte of what the used blocks hold, and
nothing about the passphrase.

New installs boot with `rd.luks.options=discard`. Provisioning also writes
`allow-discards` into the LUKS2 header (`cryptsetup refresh --persistent`,
unlocked with the boot keyfile, so it never prompts), which reaches machines
installed before that and every later opener, the rescue ISO included.
`fstrim.timer` runs weekly on top. There is no knob: provisioning puts the flag
back if it is removed. `ergon doctor`'s `trim` row fails when the mapper shows
DISC-MAX 0 -- over a disk that takes no discards at all, too.

## VS Code extensions run as you, outside pacman

The vscode bundle installs `code` with pacman, and pacman's part ends there.
Extensions come from Open VSX into `~/.vscode-oss/extensions`, where neither
the bundle ledger nor any review in this repo reaches. An extension is
ordinary code in the extension host with your privileges. There is no
sandbox: Workspace Trust can keep one off in a folder you have not trusted,
and changes nothing once it runs. `extensions.autoUpdate` is on by default, so
what runs tomorrow is whatever its publisher shipped tonight.

Open VSX is also a weaker gate than Microsoft's marketplace. A namespace
belongs to whoever created it first, and only a *verified* one has had its
owner confirmed, so a vendor's name that the vendor never registered there
can be anyone's. What it buys is the extensions people already know -- ruff,
Jupyter, the debugger -- for a build that Microsoft's marketplace terms
exclude.

What stays true either way: ergon installs no extension. `ergon new` writes
`.vscode/extensions.json`, VS Code offers what it lists, and you say yes. Every
ID it recommends is in a verified namespace and installed cleanly with
`code --install-extension` on 1.138. `ergon-bundle remove vscode` takes `code`
and leaves `~/.vscode-oss` to you.

### Copilot Chat is built in

`code` 1.138 ships GitHub Copilot Chat 0.66.0 as a built-in extension -- about
300 MB of the package -- with a Copilot agent host beside it, and its
`product.json` marks the extension to update itself. Checked on a fresh
profile, not signed in, two minutes idle under a headless compositor:

- the extension never activated. The agent host started and looked up a proxy
  for `api.githubcopilot.com`, and no DNS query or connection followed.
- the only traffic was Electron fetching its en-US spellcheck dictionary from
  `redirector.gvt1.com`, and the update check for `github.copilot-chat`
  against `open-vsx.org`, whose GitHub namespace carries no Copilot -- so
  today it finds nothing. If it ever does, that update bypasses pacman too.

Signing in to GitHub is what turns it on. To take it out of the interface
instead, set `"chat.disableAIFeatures": true` in
`~/.config/Code - OSS/User/settings.json`: with it the agent host does not
start at all. The update check still runs.
