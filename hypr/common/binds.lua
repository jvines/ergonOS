-- Keybindings.
--
-- SUPER throughout: the terminal owns everything else, and tmux/Emacs already
-- claim most of ALT and CTRL. Nothing here uses a chord a compositor would have
-- to steal from a TUI.
--
-- The dispatcher API is NAMESPACED — hl.dsp.window.close(), not
-- hl.dsp.killactive(). The flat hyprlang-style names do not exist in Lua and a
-- config using them dies at load with no bindings at all.
--
-- Every bind carries a description. That is not decoration: `hyprctl binds -j`
-- reports them, which is what makes bin/ergon-keys a real cheatsheet rather than a
-- second list that drifts out of sync with this file.

-- bin/ergon-term, not "wezterm" directly. wezterm is an AUR git build (see
-- packages/aur) and so is the package most likely to be absent or mid-rebuild;
-- naming it here meant SUPER+RETURN opened NOTHING on any machine without it --
-- no error, no window, and no terminal from which to find out why. That is
-- every test VM, and the first boot of every freshly provisioned machine.
-- ergon-term falls back to foot.
local term    = "ergon-term"
local launch  = "uwsm-app -- "        -- own systemd scope; survives a Hyprland reload

-- Small wrapper so every line reads (keys, what it does, how).
local function bind(keys, desc, dispatcher, opts)
  opts = opts or {}
  opts.description = desc
  if type(dispatcher) == "string" then dispatcher = hl.dsp.exec_cmd(dispatcher) end
  hl.bind(keys, dispatcher, opts)
end

-- ---------------------------------------------------------------------------
-- Session
bind("SUPER + RETURN",       "Terminal",            term)
-- Floating via a WINDOW RULE keyed on a distinct app_id, not via a chained
-- `hyprctl dispatch togglefloating` -- that runs the moment the command is
-- issued, against whatever currently has focus, which is a race the new window
-- usually loses. See windows.lua for the rule.
bind("SUPER + SHIFT + RETURN", "Floating terminal",  "ergon-term --class ergon-float")
-- Escape hatch, kept even though ergon-term now falls back automatically: that
-- fallback triggers on wezterm being ABSENT, and cannot help when wezterm is
-- present but broken. This one names foot directly. Deliberately an awkward
-- chord -- it should never be reached by accident.
bind("SUPER + SHIFT + ALT + RETURN", "Terminal (fallback)", "foot")
bind("SUPER + SPACE",        "Launcher",            "fuzzel")
bind("SUPER + ESCAPE",       "Lock",                "loginctl lock-session")
bind("SUPER + SHIFT + E",    "Exit Hyprland",       hl.dsp.exit())
bind("SUPER + SLASH",        "Keybindings",         "ergon-keys")

-- ---------------------------------------------------------------------------
-- Windows
bind("SUPER + Q",            "Close window",        hl.dsp.window.close())
bind("SUPER + V",            "Toggle floating",     hl.dsp.window.float({ action = "toggle" }))
bind("SUPER + F",            "Fullscreen",          hl.dsp.window.fullscreen({ action = "toggle" }))
bind("SUPER + P",            "Pseudo-tile",         hl.dsp.window.pseudo({ action = "toggle" }))

-- Focus. hjkl because every other tool on this machine uses them.
bind("SUPER + H", "Focus left",  hl.dsp.focus({ direction = "left"  }))
bind("SUPER + J", "Focus down",  hl.dsp.focus({ direction = "down"  }))
bind("SUPER + K", "Focus up",    hl.dsp.focus({ direction = "up"    }))
bind("SUPER + L", "Focus right", hl.dsp.focus({ direction = "right" }))

bind("SUPER + SHIFT + H", "Move window left",  hl.dsp.window.move({ direction = "left"  }))
bind("SUPER + SHIFT + J", "Move window down",  hl.dsp.window.move({ direction = "down"  }))
bind("SUPER + SHIFT + K", "Move window up",    hl.dsp.window.move({ direction = "up"    }))
bind("SUPER + SHIFT + L", "Move window right", hl.dsp.window.move({ direction = "right" }))

-- Resize without a submap: hold CTRL and use the same hjkl. A submap is a mode
-- you can be stuck in, and there is no bar indicator worth the risk.
bind("SUPER + CTRL + H", "Shrink width",  hl.dsp.window.resize({ x = -60, y =   0 }), { repeating = true })
bind("SUPER + CTRL + L", "Grow width",    hl.dsp.window.resize({ x =  60, y =   0 }), { repeating = true })
bind("SUPER + CTRL + K", "Shrink height", hl.dsp.window.resize({ x =   0, y = -60 }), { repeating = true })
bind("SUPER + CTRL + J", "Grow height",   hl.dsp.window.resize({ x =   0, y =  60 }), { repeating = true })

-- Mouse. mouse:272 is left button, 273 is right.
bind("SUPER + mouse:272", "Drag window",   hl.dsp.window.drag(),   { mouse = true })
bind("SUPER + mouse:273", "Resize window", hl.dsp.window.resize(), { mouse = true })

-- ---------------------------------------------------------------------------
-- Workspaces
for i = 1, 9 do
  bind("SUPER + " .. i,         "Workspace " .. i,         hl.dsp.focus({ workspace = tostring(i) }))
  bind("SUPER + SHIFT + " .. i, "Move to workspace " .. i, hl.dsp.window.move({ workspace = tostring(i), follow = false }))
end

bind("SUPER + mouse_down", "Next workspace",     hl.dsp.focus({ workspace = "e+1" }))
bind("SUPER + mouse_up",   "Previous workspace", hl.dsp.focus({ workspace = "e-1" }))

-- Scratchpad. One toggle for the thing you keep pulling up and dismissing —
-- a shell on the cluster, usually.
bind("SUPER + grave",         "Toggle scratchpad",    hl.dsp.workspace.toggle_special("scratch"))
bind("SUPER + SHIFT + grave", "Send to scratchpad",   hl.dsp.window.move({ workspace = "special:scratch", follow = false }))

-- ---------------------------------------------------------------------------
-- Apps. Short list on purpose: everything that is not a GUI starts from a shell
-- that is already open.
bind("SUPER + B", "Browser",    launch .. "firefox")
bind("SUPER + E", "Files",      term .. " yazi")
bind("SUPER + D", "Discord",    launch .. "discord")
bind("SUPER + M", "Moonlight",  launch .. "moonlight")
bind("SUPER + N", "Notes",      term .. " emacs -nw")

-- ---------------------------------------------------------------------------
-- Clipboard. cliphist stores; fuzzel picks; wl-copy puts it back.
-- `--no-run-if-empty` stops an empty selection from clearing the clipboard.
bind("SUPER + SHIFT + V", "Clipboard history",
  "cliphist list | fuzzel --dmenu --prompt 'clip  ' | cliphist decode | wl-copy")
bind("SUPER + SHIFT + X", "Clear clipboard history", "cliphist wipe")

-- ---------------------------------------------------------------------------
-- Capture. Screenshots live in screenshot.lua — they have their own sync
-- pipeline and must not be touched. These are the two that do not.
bind("SUPER + SHIFT + T", "OCR region to clipboard", "ergon-ocr")
bind("SUPER + SHIFT + P", "Pick colour",             "hyprpicker -a")
bind("SUPER + SHIFT + R", "Record screen (toggle)",  "ergon-record")

-- ---------------------------------------------------------------------------
-- Notifications
bind("SUPER + SHIFT + D",     "Dismiss notification",     "makoctl dismiss")
bind("SUPER + SHIFT + CTRL + D", "Dismiss all",           "makoctl dismiss --all")
bind("SUPER + SHIFT + A",     "Restore notification",     "makoctl restore")
