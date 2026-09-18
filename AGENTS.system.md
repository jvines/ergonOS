# Ergon

This machine runs Ergon. Installed at `/usr/share/ergon/AGENTS.md` and read by
whatever agent you are; it describes the machine, not any project on it.

Kept short on purpose: harnesses truncate instruction files against a budget,
and a long file here is paid for on every turn in every project.

## The machine describes itself — query it, do not restate it

    ergon explain --list          # what the system knows about itself
    ergon --list                  # every command, from its own header
    ergon keys                    # every keybinding, from the compositor
    ergon bundle list             # what is installed and what is available
    ergon doctor                  # what is quietly wrong, and the format a bug report takes

Prose describing any of the above is a second copy that drifts. Run the command.

## Python

`uv`, always. Arch's system python belongs to pacman: `pip install` outside a
venv is how you break the package manager, and there is no "just this once".

    ergon new <name>              # a project: locked env, LSP, git, directories
    uv run ...                    # inside one

numpy and scipy link OpenBLAS, which takes every core. A multiprocessing pool
on top of that oversubscribes cores², and the result runs *slower* than a single
thread while the machine looks pegged. `ergon doctor` checks for it.

## Before claiming something works

    ergon-lint                    # static traps in shell and desktop config
    ergon doctor                  # machine health

Editing the desktop? Read `ergon explain desktop-config` first. Hyprland here is
configured in **Lua**, not hyprlang, and the failure mode is silence rather than
an error — so general Hyprland knowledge is confidently wrong. Diagnosing a
broken session? `ergon explain troubleshooting`, symptom first.

## Snapshots are not a licence

Every pacman transaction is snapshotted, and two boots that never reach the
default target make the machine boot the last good snapshot by itself
(`ergon rollback --list`). That makes system changes recoverable. It does not
make them yours to make unasked.
