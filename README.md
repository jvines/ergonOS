# Ergon

An Arch-based OS for doing data science, with a Hyprland desktop.

*Ergon* — ἔργον, the work; in Aristotle, the function proper to a thing. This is
a workbench.

## What it is

A base system that stays small — Arch, `uv`, and enough Python to check an order
of magnitude — plus **bundles** you choose from, and a set of tools for the
parts of computational science that nothing else does for you.

```
ergon peek data.parquet        schema, nulls, summaries — parquet, FITS, HDF5, CSV, npy
ergon fig whence plot.png      which script and which commit made this figure
ergon cite 10.1086/670067      BibTeX into the project's .bib
ergon new analysis             locked env, LSP, git, the directories
ergon ship kira -- python fit.py    same environment, another machine
ergon watch -- python fit.py   stay awake, journal it, say when it ends
ergon doctor                   what is quietly wrong with this machine
```

`ergon --list` for all of them; `ergon explain --list` for what the system knows
about itself.

## Install

Boot the Arch ISO, put this repo on it, and run the bootstrap. The ISO has no
keys and no checkout, so the clone has to be one a stranger could run:

```sh
pacman -Sy --noconfirm git
git clone https://github.com/jvines/ergonOS.git
./ergonOS/bin/arch-bootstrap.sh /dev/nvme0n1   # LUKS, btrfs subvolumes, GRUB, snapshots
```

`arch-bootstrap.sh` copies the checkout it is running from into the installed
system. After the reboot the repo is already at `~/ergonOS`, owned by you —
nothing to clone, no key to arrange, and the machine is provisioned by exactly
the tree that installed it:

```sh
~/ergonOS/bin/provision-arch.sh          # packages, desktop, hardware quirks, bundles
~/ergonOS/install.sh                     # link the desktop into $HOME
```

Installing somewhere with no usable network is a different problem: `pacstrap`
has to reach a mirror regardless. Copy the repo onto the USB alongside the ISO
and run it from there — the copy into the new system needs no network, only the
package download does.

## Bundles

The base is deliberately minimal. Everything a particular kind of work needs is
a bundle, addable and removable at any time — nobody knows at partition time
whether they will want the ML stack in March.

```
ergon bundle list
ergon bundle add inference astronomy
```

Recorded in `hosts/<host>/host.env`, so re-provisioning reproduces the machine.

## What makes it different

- **Snapshots before every update, bootable from GRUB.** btrfs subvolumes,
  `snap-pac`, and `ergon rollback` for when a boot goes wrong.
- **Provenance by default.** Every figure records the script, the commit and the
  environment that made it. Every long run is journalled.
- **The exoplanet characterization pipeline**, wired together in one bundle:
  ARIADNE → LACHESIS → Nereus, on DAEDALUS underneath.
- **Tested, not asserted.** The suite installs from the real ISO under OVMF,
  provisions, starts the compositor, and clicks a workspace button with a
  synthetic input event to check that it switches. See
  `docs/testing-the-desktop.md`.
