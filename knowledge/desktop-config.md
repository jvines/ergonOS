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

## Generated configs, and where your own edits go

**Do not edit a themed config. It is generated, and your edit has a short life.**

Seventeen files are rendered from a `.in` template beside them by
`ergon theme`, which expands the active palette into `@COOL_*@` placeholders:

    waybar/style.css      mako/config        hypr/hyprlock.conf
    gtk/gtk.css           fuzzel/fuzzel.ini  hypr/common/looknfeel.lua
    foot/foot.ini         newsboat/config    gtk/settings.ini
    yazi/theme.toml       lnav/config.json   lazygit/config.yml
    lazydocker/config.yml wezterm/wezterm.lua btop/themes/ergon.theme
    bat/themes/ergon.tmTheme  swayosd/style.css

They are **gitignored**, and `install.sh` renders them before it links anything.
That is why switching palette no longer leaves the repo dirty — and it is also
why a fresh clone has none of them until something renders.

To change a colour, edit `theme/<palette>.env`. To change the structure, edit
the `.in`. Editing the output changes your desktop until the next install.

### What checks them, and what does not

Rendered configs are gitignored, so nobody reads them in a diff. The only thing
standing between a template and a surface that silently stops being themed is a
parser, and `foot` proved that is not theoretical: `[colors]` stopped being a
section name foot knew, an unknown section takes every key inside it, and
sixteen ANSI slots were being discarded with no error anywhere.

    ./bin/test-hypr-config.sh      # what the list below is, run for real

`./bin/test-hypr-config.sh` loads ten files through the parser that will
actually read each one: `hypr/hyprland.lua` (which is what pulls in the
rendered `looknfeel.lua`), `fuzzel.ini`, `foot.ini`, `wezterm/wezterm.lua`,
`newsboat/config`, `mako/config`, `hypridle.conf`, `hyprlock.conf`, and the two
stylesheets — `waybar/style.css` through GTK3 and `swayosd/style.css` through
GTK4, because those two CSS engines do not accept the same file.
`waybar/config.jsonc` is exercised functionally instead: the VM session suite
starts a real bar and asserts it maps a layer surface, which is stronger than
parsing it.

`wezterm` is an AUR git build present on no machine this repo tests on, so the
container installs Arch `[extra]`'s released wezterm instead — a different
build of the same config schema, which is all a schema check needs. Its own
`ls-fonts` is not a `--check-config`: measured against a Lua syntax error, an
unknown field and a wrong-typed value, wezterm exits 0 on all three and prints
its own defaults, exactly the silent-fallback shape that hid the foot bug. Each
one does log an ERROR line to stderr, which is what the check reads instead of
`$?`.

`newsboat` has no `--check-config` flag either, but does not need one: an
unrecognised directive (measured against a renamed `color` target) is a fatal
parse error on stderr with exit 1, before curses starts or a feed is fetched,
so `-x print-unread` against a placeholder URL file is a real check.

**Eight of the seventeen rendered files are checked by nothing** — a known
gap, ERGON-52: `gtk/gtk.css`, `gtk/settings.ini`, `yazi/theme.toml`,
`lnav/config.json`, `lazygit/config.yml`, `lazydocker/config.yml`, `btop`'s
theme and `bat`'s tmTheme. Two things are worth knowing about that list: `bat`
compiles its tmTheme (`bat cache --build`, which `install.sh` already runs), so
a broken one is at least loud on a real install; and `lnav -C` exits 0 on a
config it cannot use, so it is not a check.

The GTK check has a limit worth knowing: it validates syntax, property names
and value grammar, and it catches an unexpanded `@COOL_*@`. It does **not**
validate selectors — `#worksaces` parses perfectly.

### Your own settings: `~/.config/ergon/`

Each surface that *can* include another file includes one from there, and
nothing in this repo ever writes those files — `ergon-lint` enforces that, and
`lib/user-config.sh` is the only code allowed to create one.

| your file | included by | if it is missing |
|---|---|---|
| `waybar.css` | `waybar/style.css` | **no bar theming at all** — GTK discards the whole stylesheet |
| `mako` | `mako/config` | **no notification daemon** — mako exits 1 |
| `fuzzel.ini` | `fuzzel/fuzzel.ini` | fails `--check-config` |
| `foot.ini` | `foot/foot.ini` | fails `--check-config` |
| `newsboat.conf` | `newsboat/config` | **newsboat will not start** |
| `gtk.css` | `gtk/gtk.css` | a warning on stderr |
| `hyprlock.conf` | `hypr/hyprlock.conf` | nothing; it is optional by design |
| `user.lua` | `hypr/hyprland.lua` | nothing; `pcall` covers it |

The first five are why creation lives with the renderer rather than in a
separate install step: the run that writes the include line is the run that
guarantees the file it points at.

**Your file is included last, everywhere, on purpose.** All of these formats
resolve conflicts by source order, so last is the only position where what you
write beats what the template wrote. One exception, and it is mako's, not a
choice: `include` is legal only before the first `[criteria]` block, so the
generated `[urgency=critical]` and friends are parsed *after* yours and win on
any key both set. You can add criteria the repo does not define; you cannot
restyle the ones it does.

Nine surfaces have **no** include mechanism and cannot be overridden this way:
`gtk/settings.ini`, `yazi/theme.toml`, `lnav/config.json`, `lazygit/config.yml`,
`lazydocker/config.yml`, `btop`'s theme, `bat`'s tmTheme,
`wezterm/wezterm.lua`, and `swayosd/style.css` — that last one because
`~/.config/swayosd/style.css` **is** swayosd's user-override slot, and this
repo has taken it; swayosd loads the package's own sheet first and this one
over the top. For those, change the template. (`lazygit` and `lnav` can
take a second config on the command line — `--use-config-file`, `-I` — which is
a launcher change, not a file include.)

### The Lua seam is an explicit path, and has to be

    pcall(require, "~/.config/ergon/user")

Not `require("user")`. Hyprland seeds `package.path` from `hyprland.lua`'s own
directory, and that directory is `~/.config/hypr` — **a symlink into the
checkout** — so a bare module name resolves back into the repo, which is the one
place an untracked override must not live. The `~/` form bypasses `package.path`
and needs Hyprland 0.56; on anything older it simply does not resolve and
`pcall` swallows it.

`pcall` returning true does **not** mean your file loaded cleanly. If it exists
but has an error, Hyprland records the error internally and hands `require` an
empty table, so the failure shows up in the compositor's config-error overlay
and in `Hyprland --verify-config`, not at the call site.

### Why a missing rendered file is not a cosmetic problem

A Lua config is **one chunk**, so an error anywhere in it stops every line after
it. `hypr/hyprland.lua` used to `require` its eight modules unguarded, and
`common.looknfeel` — the generated one — came second. A session that loaded
while that file was absent never reached `windows`, `binds`, `media`, `lid`,
`screenshot` or `autostart`, and Hyprland answered with its own guard:

    Emergency mode tripped: A lua config error resulted in no binds being
    registered. Emergency binds active: SUPER + Q

No terminal, no launcher, no session menu, no keybind list — over a colour
scheme. Paid for on 2026-09-24, in the VM.

Now every module is loaded through `need()`, which `pcall`s: a module that fails
takes itself down and nothing else, and **`common.binds` is loaded second**, so
the escape hatch exists before anything cosmetic can fail.
`bin/test-hypr-config.sh` keeps it that way — it deletes `looknfeel.lua` and
asserts that execution still reaches the last line of `binds.lua`.

What `pcall` costs is the report, and its two halves are not the same. Measured
against 0.56.2, both ways:

| the module | does Hyprland record it? |
|---|---|
| exists, has an error | **yes** — overlay and `--verify-config`, pcall or not |
| missing entirely | **no** — an ordinary Lua "module not found", which pcall eats whole |

So the missing case is reported by this repo instead, from the bottom of
`hypr/hyprland.lua`: red borders first, because they need no daemon and no bus
and are on screen the instant a window is drawn; then a line in
`~/.local/state/ergon/config-failures.log`; then a critical notification once
mako exists. An unthemed desktop otherwise looks like a palette someone chose.

`install.sh` still renders before it links and still exits non-zero if the
render fails, and that must not change: the guard above keeps a broken desktop
**usable**, it does not make it correct.
