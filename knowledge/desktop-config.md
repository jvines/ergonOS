# Editing the desktop config

Hyprland here is configured in **Lua**, not hyprlang. `hypr/hyprland.lua` is the
entry point; the rest is `hypr/common/*.lua`. This is a young format with almost
no public corpus, so most of what an agent or a person "knows" about Hyprland
config does not apply, and the failure mode is silence rather than an error.

Everything below cost real time to find.

## The API

**`hl.config({...})` is the only form.** One call, nested tables:

    hl.config({
      general    = { border_size = 2, gaps_in = 4 },
      decoration = { rounding = 8 },
      input      = { kb_layout = "us" },
      misc       = { disable_hyprland_logo = true },
    })

`hl.general{}`, `hl.decoration{}`, `hl.input{}`, `hl.misc{}` and
`hl.animations{}` **do not exist**. Calling one is a nil-index error at load,
and depending on where it sits you get a config that half-applied.

**Dispatchers are namespaced.** Not strings:

    hl.dsp.window.close()
    hl.dsp.window.move({ workspace = 3 })
    hl.dsp.window.drag()
    hl.dsp.focus({ direction = "l" })
    hl.dsp.focus({ workspace = 3 })
    hl.dsp.workspace.toggle_special()
    hl.dsp.cursor.move({ x = 100, y = 15 })
    hl.dsp.exec_cmd("wezterm")
    hl.dsp.exit()

`hl.dsp.exec_raw("<classic dispatcher string>")` is the escape hatch for
anything without a typed form.

**Bind options**: `locked`, `repeating`, `mouse`, `description`. It is
`repeating`, **not** `repeat` — `repeat` is a Lua keyword and using it is a
parse error, not a warning.

Every bind should carry `description`. `hyprctl binds -j` reports it, and
`ergon keys` builds the cheatsheet from that, so there is no second list to
drift.

**Events**: `hl.on("hyprland.start", fn)`, `hl.on("monitor.added", fn)`,
`hl.on("monitor.removed", fn)`.

**Rules**: `hl.window_rule({ match = {...}, float = true, ... })` and
`hl.layer_rule({ match = { namespace = "waybar" }, no_anim = true })`.

## The trap that matters most

**A Lua-configured Hyprland evaluates the `dispatch` IPC payload AS LUA.**

    hyprctl dispatch workspace 3

arrives as `return hl.dispatch(workspace 3)` and dies on a syntax error. The
caller sees it; nothing else does. Almost no script checks a dispatch's exit
status, so it presents as *nothing happening at all*.

Correct forms, all verified against a running compositor:

    hyprctl dispatch 'hl.dsp.exec_raw("workspace 3")'      # the general escape
    hyprctl dispatch 'hl.dsp.focus({workspace = 3})'
    hyprctl dispatch 'hl.dsp.cursor.move({x = 100, y = 15})'

`ergon-lint` fails on any classic `hyprctl dispatch <word>` in the repo. Run it.

This is also why **waybar must be `waybar-git`** (see `packages/aur`): waybar
0.15.0 sends the classic string when you click a workspace, so the buttons
highlight and do nothing. Fixed upstream in Alexays/Waybar#5013, which is on
master and not yet in a release.

## Introspection is reduced under Lua

`hyprctl binds -j` reports `"dispatcher": "__lua"` with an integer `arg` for
every bind, because the action is a closure rather than a dispatch string. You
**cannot** read what a bind runs from the compositor. `description` survives and
is the only thing that does, which is why every bind carries one.

## Verifying a change

`Hyprland --verify-config` proves the config PARSES. It does not prove the
compositor starts, that the binds registered, or that waybar mapped a surface —
two API bugs in this repo produced a compositor with zero keybindings and a
config that verified perfectly.

    ergon-lint                     # static traps
    Hyprland --verify-config       # parse
    ./bin/test-hypr-session.sh     # the real thing, in a VM, ~12 min

The session test starts the compositor, asserts the binds register, waybar maps,
every `on-click` and every `ergon-*` resolves on the session PATH, and that a
**synthetic click** through `/dev/uinput` actually changes workspace.

## Session PATH

`environment.d/10-ergon-path.conf` is what puts the repo's `bin/` on the PATH of
the systemd user manager, which is what launches the session under uwsm. Without
it every `ergon-*` in waybar and in the keybinds resolves to nothing: the module
fires, the command is not found, and there is no visible error anywhere.

Changes need `systemctl --user daemon-reload` **and a new session**. The running
manager does not re-read it.
