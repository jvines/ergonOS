---
name: ergon-troubleshoot
description: Diagnose a broken Ergon desktop — dead clicks, a greeter that loops, a locked account, a black screen over VNC, a keybind that does nothing, an AUR package that built but did not install. Carries the specific failure signatures and where the logs actually are. Use when something on the desktop is broken and before theorising about causes.
---

Run `ergon explain troubleshooting` and follow it, symptom first.

Gather before theorising: `ergon-doctor`, `ergon-lint`,
`tail -40 $XDG_RUNTIME_DIR/hypr/*/hyprland.log` (the compositor log is NOT the
stdout of whatever launched it), `journalctl --user -b -p warning`.

The body lives at `/usr/share/ergon/knowledge/troubleshooting.md`. See
`AGENTS.md`.
