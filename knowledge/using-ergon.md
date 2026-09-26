# Using Ergon

What this machine does for you without being asked, where the things you make
land, and which files are yours to edit. Concepts only — every list here
drifts the moment it is written down, so it is not written down: `ergon keys`,
`ergon --list`, `ergon bundle list` and `ergon <command> --help` are the real
ones, generated from what is actually installed and bound right now.

## Snapshots undo a bad update; backup survives a dead disk

`snap-pac` hooks `pacman` directly, so every transaction — not just ones run
through `ergon update` — gets a btrfs snapshot first, and two boots in a row
that never reach the default target make GRUB boot the last snapshot that did,
on its own. That fallback is not sticky: the next boot that reaches the
desktop clears it again, so it buys you one boot to fix things in, not a
standing rollback. `sudo ergon rollback N` makes one permanent, replacing `@`
outright — `sudo ergon rollback --list` shows the candidates — but it refuses
to run FROM `@` itself; boot the snapshot from the GRUB submenu, or the Arch
ISO, first.

That protects you from an update, not from the disk. A snapshot lives on the
same device as the data it is a snapshot of, so a dead SSD takes all of them
with it. `ergon backup` sends `/home` somewhere else entirely — encrypted,
deduplicated, restorable file by file — but it does nothing at all until
`ergon backup init REPO` names a destination; the timers provisioning installs
sit inert until then. The one thing it cannot protect is its own key:
`ergon backup key` prints it whenever you ask, and keeping the only copy on
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

- **Screenshots** go to `~/screenshots-outgoing` and the clipboard, in one
  pipeline (`hypr/common/screenshot.lua`). That directory name is a leftover
  of the author's own setup, where a separate script — not part of ergonOS —
  watches it and mirrors captures elsewhere; a stock install ships no such
  watcher, so the files simply accumulate there until ERGON-39 makes the
  destination a real per-host setting.
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

Every themed desktop surface — the bar, the launcher, the terminal, the Lua
config itself — is rendered from a template on every `ergon theme` run and on
every `install.sh`, so anything typed directly into one of those files is gone
at the next render. What survives is `~/.config/ergon/`: an include file for
each surface that has somewhere to put one, created once if it does not
already exist and never touched again by anything shipped here —
`lib/user-config.sh` and `lib/ergon_arxiv.py` are the only two writers, both
create-if-absent, and `ergon-lint` holds everything else in the repo to that
rule. That is where a hand-written waybar rule, your own Hyprland binds, or an
enrolled fingerprint block belongs. Not every surface has this escape hatch —
the exact set, and what breaks on each one if its file goes missing, is
`ergon explain desktop-config`.

## The security model

LUKS, the docker-group trade-off, the firewall, faillock and what `sudo` can
do are their own topic, not repeated here: `ergon explain security`.

## Getting help

`ergon --help` for every command; `ergon <command> --help` for one of them.
`ergon explain --list` for what else this machine knows about itself, and
`ergon doctor` for when something is quietly wrong rather than loudly broken.
