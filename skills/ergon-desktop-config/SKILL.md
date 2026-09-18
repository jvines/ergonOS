---
name: ergon-desktop-config
description: Read before editing the Hyprland/waybar desktop config on Ergon. The config is Lua, not hyprlang, and the API differs from every public example — hl.config only, namespaced dispatchers, and external `hyprctl dispatch` is parsed as Lua so the classic string syntax fails silently. Use when touching hypr/*.lua, waybar, keybinds, window rules, or anything that dispatches to Hyprland.
---

Run `ergon explain desktop-config` and follow it.

The body is deliberately not duplicated here: it is plain markdown installed at
`/usr/share/ergon/knowledge/` so every harness and every human reads the same
bytes. See `AGENTS.md`.

Verify with `ergon-lint`, then `Hyprland --verify-config`, then
`./bin/test-hypr-session.sh`. The first two cannot tell you the binds
registered.
