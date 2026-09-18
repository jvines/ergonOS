-- wezterm. The daily terminal, and the only reason it is built from the AUR
-- rather than taken from extra/ (see packages/aur) is `tmux -CC`.
--
-- Control mode is the whole point: tmux stops drawing panes as text and instead
-- TELLS the terminal what the panes are, so they become real wezterm panes with
-- real scrollback, real selection, and real mouse handling. Attach to a tmux on
-- kira or predator over ssh and its panes open as native panes here. That is
-- the iTerm behaviour, and wezterm is the only Linux terminal that implements
-- it -- which is why `foot` in packages/pacman is labelled an escape hatch and
-- not a replacement.
--
-- Colours come from theme/cool.env via bin/ergon-theme; edit wezterm.lua.in, never
-- wezterm.lua.
local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- ---------------------------------------------------------------------------
-- Type
config.font = wezterm.font_with_fallback({
  "JetBrainsMono Nerd Font",  -- packages/pacman: ttf-jetbrains-mono-nerd
  "Symbols Nerd Font Mono",
  "Noto Color Emoji",
})
config.font_size = 11.0
-- A tiling compositor owns the window geometry. Without this, every font-size
-- change asks Hyprland to resize a tiled window, which it refuses, and the
-- terminal and the compositor disagree about the size from then on.
config.adjust_window_size_when_changing_font_size = false
config.warn_about_missing_glyphs = false

-- ---------------------------------------------------------------------------
-- Window
config.enable_wayland = true
-- Hyprland draws the border and rounds the corners (see looknfeel). A second
-- set of decorations from the terminal would sit inside them.
config.window_decorations = "NONE"
config.window_padding = { left = 10, right = 10, top = 8, bottom = 6 }
config.window_background_opacity = 1.0
config.audible_bell = "Disabled"
config.scrollback_lines = 50000

-- ---------------------------------------------------------------------------
-- Tab bar
--
-- Under `tmux -CC` the tabs are TMUX's windows, forwarded by control mode. That
-- is the point of the whole arrangement, so the bar stays -- but it is the
-- retro one, which is a row of text in the terminal's own font rather than a
-- second GTK-looking widget above a bar that is already there.
config.use_fancy_tab_bar = false
config.hide_tab_bar_if_only_one_tab = true
config.tab_bar_at_bottom = false
config.tab_max_width = 32

-- ---------------------------------------------------------------------------
-- Updates
--
-- The package is AUR-managed and its wrapper already sets DISABLE_UPDATES=1.
-- An update check that cannot act on its answer is a network request and a
-- notification for nothing.
config.check_for_updates = false

-- TERM is deliberately left at wezterm's default rather than set to "wezterm".
-- The wezterm terminfo does not exist on the fleet's Debian boxes or on the
-- Macs, so every `ssh kira` would land in a shell that cannot clear the screen.
-- tmux.conf already declares RGB and extended keys for xterm-256color.

-- ---------------------------------------------------------------------------
-- Colours -- generated, do not hand-edit the rendered file
config.color_scheme = nil
config.colors = {
  foreground    = "#EDEDF8",
  background    = "#1A1A2E",
  cursor_bg     = "#40FFFF",
  cursor_fg     = "#1A1A2E",
  cursor_border = "#40FFFF",
  selection_bg  = "#3A3A4E",
  selection_fg  = "#EDEDF8",
  scrollbar_thumb = "#3A3A4E",
  split         = "#9494B0",

  -- The palette is a cyan->magenta ramp, so there is no honest red or green in
  -- it. The ANSI slots are mapped by ROLE instead: whatever a program means by
  -- "error" gets the urgent tint, "success" gets the mint, and the rest are
  -- steps along the ramp. Consistent with waybar and mako, which do the same.
  ansi = {
    "#2A2A3E",     -- black
    "#FF40FF",  -- red     -> urgent
    "#D0FFEA",    -- green   -> good
    "#EBC2FF",    -- yellow  -> warn
    "#C2EBFF",       -- blue
    "#FFADFF",       -- magenta
    "#ADFFFF",       -- cyan
    "#D6D6FF",     -- white
  },
  brights = {
    "#3A3A4E",
    "#FF40FF",
    "#D0FFEA",
    "#EBC2FF",
    "#D6D6FF",
    "#FFE0FF",
    "#40FFFF",
    "#EDEDF8",
  },

  tab_bar = {
    background = "#1A1A2E",
    active_tab   = { bg_color = "#3A3A4E", fg_color = "#40FFFF", intensity = "Bold" },
    inactive_tab = { bg_color = "#1A1A2E", fg_color = "#A6A6BC" },
    inactive_tab_hover = { bg_color = "#2A2A3E", fg_color = "#D6D6FF" },
    new_tab       = { bg_color = "#1A1A2E", fg_color = "#A6A6BC" },
    new_tab_hover = { bg_color = "#2A2A3E", fg_color = "#EDEDF8" },
  },
}

-- ---------------------------------------------------------------------------
-- Keys
--
-- SUPER belongs to Hyprland (see hypr/common/binds.lua: "the terminal owns
-- everything else"), and CTRL+A belongs to tmux. So wezterm's own bindings stay
-- on CTRL+SHIFT, and there are deliberately few of them: under `tmux -CC` the
-- splits, tabs and navigation are TMUX's, and a wezterm binding for the same
-- gesture would silently do something subtly different depending on whether
-- control mode happened to be attached.
config.keys = {
  { key = "c", mods = "CTRL|SHIFT", action = wezterm.action.CopyTo("Clipboard") },
  { key = "v", mods = "CTRL|SHIFT", action = wezterm.action.PasteFrom("Clipboard") },
  { key = "f", mods = "CTRL|SHIFT", action = wezterm.action.Search({ CaseInSensitiveString = "" }) },
  { key = "k", mods = "CTRL|SHIFT", action = wezterm.action.ClearScrollback("ScrollbackAndViewport") },
  -- Font size, with the window size pinned (see above).
  { key = "=", mods = "CTRL", action = wezterm.action.IncreaseFontSize },
  { key = "-", mods = "CTRL", action = wezterm.action.DecreaseFontSize },
  { key = "0", mods = "CTRL", action = wezterm.action.ResetFontSize },
}

return config
