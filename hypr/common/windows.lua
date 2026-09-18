-- Window rules.  https://wiki.hypr.land/Configuring/Basics/Window-Rules/
--
-- Rules are evaluated in order and later ones win, so the generic entries are
-- first and the per-app exceptions follow.

-- hl.window_rule takes one flat table with the selector under `match`. This
-- wrapper only exists so a rule reads as (what to match, what to do).
local function win(match, rules)
  rules = rules or {}
  rules.match = type(match) == "string" and { class = match } or match
  hl.window_rule(rules)
end

-- ---------------------------------------------------------------------------
-- Generic

-- Apps that ask to be maximized on launch get ignored. In a tiling layout
-- "maximize" means "cover your siblings", which is never what was wanted.
win(".*", { suppress_event = "maximize" })

-- XWayland windows with no class AND no title are drag placeholders, not real
-- windows. Letting them take focus is what makes a drag out of a browser
-- occasionally steal the keyboard and strand the drag.
win({ class = "^$", title = "^$", xwayland = true, float = true, fullscreen = false, pin = false },
    { no_focus = true })

-- ---------------------------------------------------------------------------
-- Dialogs: float and centre, never tile.
-- A file chooser tiled into a quarter of the screen is unusable, and the GTK
-- portal chooser is the one dialog you hit constantly.
win({ title = "^(Open|Save|Save As|Select|Choose|Open File|Open Folder).*$" },
    { float = true, center = true, size = { 1000, 700 } })

win({ class = "^(xdg-desktop-portal-gtk)$" }, { float = true, center = true })
win({ class = "^(org.gnome.Nautilus|blueman-manager|nm-connection-editor|pavucontrol)$" },
    { float = true, center = true, size = { 900, 600 } })

-- The scratch/floating terminal from binds.lua. Matched on its own app_id so
-- the float is a property of THAT window rather than of whatever had focus
-- when the keybind fired.
win("^(ergon-float)$", { float = true, center = true, size = { 1100, 700 } })

-- ---------------------------------------------------------------------------
-- Picture-in-picture. Pinned so it survives a workspace switch, aspect locked
-- so dragging a corner does not letterbox it, and parked top-right where the
-- bar's status group already draws the eye.
win({ title = "(Picture.?in.?[Pp]icture)" }, {
  float = true,
  pin = true,
  size = { 600, 338 },
  keep_aspect_ratio = true,
  border_size = 0,
  move = { "(monitor_w-window_w-24)", "(monitor_h*0.05)" },
})

-- ---------------------------------------------------------------------------
-- Media: hold the screen awake while they are fullscreen, and only then.
-- `idle_inhibit = "focus"` would keep the panel lit whenever the window merely
-- had focus, which defeats hypridle for the rest of the session.
win("^(mpv|imv)$",                          { float = true, center = true, size = { 1280, 800 },
                                              idle_inhibit = "fullscreen" })
win("^(com.moonlight_stream.Moonlight)$",   { idle_inhibit = "fullscreen" })

-- Moonlight is a latency-sensitive stream; let it tear rather than wait for the
-- next vblank. Global allow_tearing stays off — this is the only client that
-- benefits and the only one permitted to.
win("^(com.moonlight_stream.Moonlight)$",   { immediate = true })

-- ---------------------------------------------------------------------------
-- The named apps
--
-- Workspace assignments are deliberately few. 9 is the "away" workspace: chat
-- and anything else that is allowed to want attention but must never appear on
-- top of what you are reading.
win("^(discord)$",       { workspace = "9 silent" })
win("^(zathura)$",       { opacity = "1 1" })   -- never dim a paper you are reading
win("^(firefox)$",       { opacity = "1 1" })

-- Emacs is the pgtk build and draws its own everything. Rounding clips the
-- mode line; transparency makes a text buffer harder to read for no gain.
win("^(emacs)$", { opacity = "1 1", rounding = 0 })

-- Terminals keep full opacity too. The inactive_opacity in looknfeel is for
-- telling GUI windows apart, and 0.96 over a terminal is just worse contrast.
win("^(org.wezfurlong.wezterm)$", { opacity = "1 1" })

-- ---------------------------------------------------------------------------
-- Layer rules: the surfaces that are not windows.

-- Blur is already disabled globally in looknfeel, so there is no per-layer
-- no_blur rule here -- and it would not work anyway: no_blur is a valid window
-- rule but NOT a valid hl.layer_rule field, which Hyprland reports as
-- "unknown field" at config load.

-- The launcher should appear instantly rather than fading in; a 150ms fade on
-- something you summon and type into immediately reads as lag.
hl.layer_rule({ match = { namespace = "^(launcher)$" }, no_anim = true, animation = "none" })
