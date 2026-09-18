# Ergon

This machine's own knowledge is a command, not a file. Run it:

    ergon explain --list          # topics
    ergon explain desktop-config  # the Hyprland Lua API and its traps
    ergon explain troubleshooting # failure signatures, symptom first

**Read the relevant topic before editing the desktop config or diagnosing a
broken session.** The Hyprland Lua format is young and has almost no public
corpus, so general Hyprland knowledge is mostly wrong here and fails silently
rather than erroring.

## Ground truth is queryable — do not restate it

    ergon --list                  # every command, from its own header
    ergon keys                    # every keybind, from the compositor
    ergon-bundle list             # what is installed
    ergon-doctor                  # machine health

Prose describing any of the above is a second list that drifts. Query it.

## Before claiming a desktop change works

    ergon-lint                    # static traps, including the dispatch one
    Hyprland --verify-config      # proves it PARSES, and nothing more
    ./bin/test-hypr-session.sh    # proves it works. ~12 min, in a VM

`--verify-config` passing has coexisted with a compositor that registered zero
keybindings. Asserting a string is not asserting a behaviour.
