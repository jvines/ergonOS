# Using Ergon

What this machine does for you without being asked, where the things you make
land, and which files are yours to edit. Concepts only — every list here
drifts the moment it is written down, so it is not written down: `ergon keys`,
`ergon --list`, `ergon bundle list` and `ergon <command> --help` are the real
ones, generated from what is actually installed and bound right now.

## Snapshots undo a bad update; backup survives a dead disk

`snap-pac` hooks `pacman` directly, so every transaction — not just ones run
through `ergon update` — gets a btrfs snapshot first, and two boots that never
reach the default boot target make GRUB boot the last one that worked, on its
own, using that snapshot's own kernel. `ergon rollback` does the same by hand,
from a number you pick with `ergon rollback --list`.

That protects you from an update, not from the disk. A snapshot lives on the
same device as the data it is a snapshot of, so a dead SSD takes all of them
with it. `ergon backup` sends `/home` somewhere else entirely — encrypted,
deduplicated, restorable file by file — and the one thing it cannot protect is
its own key: `ergon backup init` prints it once, and keeping the only copy on
this laptop defeats the entire point.

## Bundles are what you asked for, and nothing you didn't

The base install is deliberately small. Everything past it — inference,
astronomy, a GPU stack, a second editor — is a bundle, added and removed
without reprovisioning, and recorded in `hosts/<host>/host.env` so a
reprovision reproduces exactly the machine you have. What exists, what is
installed on this one, and what each costs is `ergon bundle list`, not a table
here; `ergon bundle info <name>` before adding one you don't recognise.

## Sleep, hibernate, updates

`ergon sleep check` says what the hardware actually offers — not every laptop
firmware supports real (S3) sleep, only the shallower s2idle — and whether the
last suspend reached it. Hibernate needs the swapfile and resume offset that
`arch-bootstrap.sh` sets up at install time, on by default; a machine installed
with it turned off will not resume from one now.

`ergon update` is `pacman -Syu` with the four preconditions that make Arch
boring instead of exciting, checked before anything is written: disk space,
a fresh keyring, unread manual-intervention news, and a rollback point.
`ergon update --check` answers "would this go through" without changing
anything.

## Where things land

- **Screenshots** go to `~/screenshots-outgoing`
  (`hypr/common/screenshot.lua`); a systemd `.path` unit mirrors each one to
  checo, the author's own machine, as it is written. That destination is not
  yet a per-host setting — the base install still assumes this fleet.
- **Recordings** go to `~/recordings` (`ergon record`, `$ERGON_RECORD_DIR` to
  move it).
- **Figures** get their provenance stamped automatically by the shared Python
  (`lib/ergon_figprov.py`) — which script, which commit, `-dirty` if the tree
  wasn't clean. `ergon fig whence plot.png` reads it back.
- **A project scaffolded with `ergon new`** gets `figures/` tracked,
  `data/` and `scratch/` gitignored, and a locked environment — `uv` for
  Python, `renv` for R. **Notebooks are marimo** by default (plain `.py`, so
  they diff, and reactive, so there is no stale cell); Jupyter is a bundle
  for anyone who wants `.ipynb` instead, not the thing you have to remove.

## Your own settings vs. the generated ones

Seventeen desktop surfaces — the bar, the launcher, the terminal, the Lua
config itself — are rendered from a template on every `ergon theme` run and on
every `install.sh`, so anything typed directly into one of those files is gone
at the next render. What survives is `~/.config/ergon/`: one file per themed
surface, created once if it does not already exist and never touched again by
anything shipped here — `lib/user-config.sh` and `lib/ergon_arxiv.py` are the
only two writers, both create-if-absent, and `ergon-lint` holds everything
else in the repo to that rule. That is where a hand-written waybar rule, your
own Hyprland binds, or an enrolled fingerprint block belongs. The exact file
for each surface, and what breaks if it goes missing, is
`ergon explain desktop-config`.

## The security model

LUKS, the docker-group trade-off, the firewall, faillock and what `sudo` can
do are their own topic, not repeated here: `ergon explain security`.

## Getting help

`ergon --help` for every command; `ergon <command> --help` for one of them.
`ergon explain --list` for what else this machine knows about itself, and
`ergon doctor` for when something is quietly wrong rather than loudly broken.
