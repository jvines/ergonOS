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
