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
-- Used to be hl.dsp.exit() with no confirmation, right next to record (R) and
-- OCR (T) -- one slip on E ended every terminal job. ergon-session asks first,
-- and can lock, suspend, hibernate, log out, reboot or shut down.
bind("SUPER + SHIFT + E",    "Session menu",        "ergon-session")
-- The physical power key opens the same menu. Deliberately NOT `locked = true`
-- (contrast lid.lua and media.lua, where it is): fuzzel cannot draw over
-- hyprlock, so a locked bind here would not show a menu at all -- it would
-- queue one, invisibly, to pop up right after the screen unlocks. On the
-- Framework 13 this key IS the fingerprint reader, so that is not a corner
-- case: it is what happens on every successful unlock. logind ignores the raw
-- keypress everywhere (bin/ergon-hardware), so leaving this unlocked costs
-- nothing while the session is locked.
bind("XF86PowerOff",         "Session menu",        "ergon-session")
-- The help binding ADAPTS to the keyboard, because a fixed one is wrong for
-- half the world. '/' is its own key on a US layout and SHIFT+7 on the Latin
-- American, Spanish, German and French ones -- and a bind on SLASH cannot be
-- pressed at all there, since the SHIFT the layout requires is a modifier the
-- bind does not match. Binding it anyway meant the one thing a lost user
-- reaches for was the one thing they could not press, silently.
--
-- F1 is the fallback because function keys sit at the same scancode on every
-- Latin-script layout. See hypr/common/layout.lua and hypr/keymap-to-xkb.
local layout = require("common.layout")
local help_key, help_alt
if layout.slash_unshifted then
  help_key, help_alt = "SUPER + SLASH", "SUPER + F1"
else
  help_key, help_alt = "SUPER + F1", "SUPER + SHIFT + SLASH"
end
bind(help_key,               "Keybindings",         "ergon-keys")
bind(help_alt,               "Keybindings (alternate)", "ergon-keys")

-- ESCAPE HATCH. Everything above is behind SUPER, which is the right default
-- and a total lockout when SUPER never arrives: no terminal, no launcher, no
-- help, no way to close a window, and nothing on screen saying why. That is not
-- hypothetical. A VNC or RDP client grabs SUPER before the guest sees it, which
-- is how most remote sessions behave and which several clients offer no way to
-- turn off; a Mac keyboard puts it where Command lives; some compact and KVM
-- keyboards do not have the key at all.
--
-- CTRL+ALT because it is the one chord that reliably traverses a remote session
-- and is not claimed by a TUI, so it does not violate the rule at the top of
-- this file. These are aliases, not a second way of working: a terminal and the
-- keybind list are enough to reach everything else.
-- RETURN, not a letter. A remote client is the main reason SUPER goes missing,
-- and the same clients mangle the alternative: on macOS, Option+<letter> is
-- composed into a dead-key character before it is ever sent, so CTRL+ALT+K
-- delivers CTRL and ALT and no K at all. Measured off /dev/input in the VM:
-- ENTER survives that path, letters do not. One hatch that reliably opens a
-- terminal is worth more than three that might not, because everything else is
-- reachable from a shell.
bind("CTRL + ALT + RETURN",  "Terminal (no-Super)", term)
bind("CTRL + ALT + K",       "Keybindings (no-Super)", "ergon-keys")

-- CTRL+ALT+F1 is deliberately NOT bound as a third hatch: on Linux that chord
-- is a VT switch and logind takes it before the compositor sees it.

-- Palette. Stepping is bound rather than only named because choosing between
-- palettes means flipping the desktop in front of you between them; comparing
-- screenshots, or retyping a name, is not comparing them.
bind("SUPER + T",            "Next palette",        "ergon-theme --next")
bind("SUPER + ALT + T",      "Previous palette",    "ergon-theme --prev")

-- Background, separately from palette. They are two different choices: a
-- palette recolours every application, a background changes one image. Binding
-- them together would mean you could not keep a palette and try another photo.
bind("SUPER + SHIFT + B",    "Next background",     "ergon-wallpaper --next")
bind("SUPER + CTRL + B",     "Previous background", "ergon-wallpaper --prev")

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
