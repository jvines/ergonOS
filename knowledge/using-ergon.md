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

- **Screenshots** go to `~/Pictures/Screenshots` and the clipboard, in one
  pipeline (`hypr/common/screenshot.lua`). To put them elsewhere, set
  `SCREENSHOT_DIR` in `hosts/<host>/host.env` (a plain absolute path), run
  `ergon sync`, and log in again.
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
  A project carries marimo itself, as a locked dev dependency, because the base
  marimo cannot import your project: open its notebooks from the project with
  `uv run marimo edit notebooks/starter.py` (ERGON-67).

## Backgrounds

The backgrounds are computed, not photographs: each is a field from a
simulation in `wallpaper/`, coloured by whichever palette is active, so a
palette switch recolours them too. All 69 approved backgrounds arrive with the
install: `install.sh` fetches their fields (about 0.6 GB, sha256-checked) and
colours them for the active palette at your panel's size, so the images exist
before the first login. The first background you see is the approved
**flame-0**; the gradient only appears when flame-0 is not there yet (offline
install), and the next login fetches what is missing in the background. A
failed fetch is printed as a warning block, never swallowed.

Switching palette redraws the SAME background in the new palette. The lock
screen shows the current wallpaper, blurred (never a screenshot, which would
leak what is on screen); it follows wallpaper and palette changes through
`~/.local/share/ergon/lock-background.png`, which `ergon-wallpaper` keeps
pointing at the image on screen.

`SUPER + SHIFT + B` and `SUPER + CTRL + B` step through them.
`ergon-wallpaper-gen --fetch` gets any that are missing and recolours;
`--ensure` is the cheap login-time version; `ergon-wallpaper-gen GENERATOR SEED`
computes a new one from scratch. Your own images go in
`~/.config/ergon/backgrounds/`. `ERGON_BACKGROUNDS=0` skips the install-time
fetch.

## Accents: hold the key

Hold a letter instead of tapping it and a numbered popup offers its accents,
the way macOS does it: hold e, press 1, get é. Esc keeps the plain letter, and
a tap is still just the letter. Spanish is first in line, so the accents it
uses sit on 1 and 2 (á é í ó ú ñ ü); ¿ and ¡ are on a held ?, 1 and 2 — let go
of Shift before the digit. The hold is a timer of its own, a quarter of a
second, and has nothing to do with key repeat, which is why a held vowel no
longer repeats.

It is an input method doing it — fcitx5 with the omacento addon — so it works
wherever an application takes text from one: GTK and Qt apps, Firefox,
terminals, and Chromium or Electron apps started with `--enable-wayland-ime`
(Discord through its launcher entry, VS Code and other apps on Arch's electron
through `~/.config/electron-flags.conf`). It never changes your keyboard layout.

It is on everywhere, terminals included, until you say otherwise:

    ergon accents                 what is in effect, and whether fcitx5 has it
    ergon accents skip            not in the focused window: a held key repeats
    ergon accents unskip          ...and back
    ergon accents off | on        the whole thing
    ergon accents hold 400        a longer hold before the popup (100 to 1000 ms)

`skip` with nothing after it means the window you are typing in, so running
it in a terminal gives that terminal its key repeat back — vim's held `u`,
`n` and `e`. It takes window classes too (`ergon accents skip foot`). Your
choices are kept in `~/.config/ergon/accents` and survive every sync; the
table itself is the repo's, in `fcitx5/omacento.conf`, so a change to it still
reaches you. When it does not happen at all, `ergon explain troubleshooting`.

## Your own settings vs. the generated ones

Every themed desktop surface — the bar, the launcher, the terminal, the Lua
config itself — is rendered from a template on every `ergon theme` run and on
every `install.sh`, so anything typed directly into one of those files is gone
at the next render. What survives is `~/.config/ergon/`: an include file for
each surface that has somewhere to put one, created once if it does not
already exist and never touched again by anything shipped here —
`lib/user-config.sh` and `lib/ergon_arxiv.py` are the only two writers, both
create-if-absent, and `ergon-lint` holds everything else in the repo to that
rule. (One file there is a command's own: `~/.config/ergon/accents`, which
`ergon accents` changes when you run it, a key at a time, keeping the rest.)
That is where a hand-written waybar rule, your own Hyprland binds, or an
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
