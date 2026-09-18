-- GENERATED from looknfeel.lua.in — edit the .in, then run: ergon theme
--
-- Appearance and input.
--
-- Every setting goes through hl.config(). There are no per-section functions:
-- hl.general{}, hl.decoration{}, hl.input{}, hl.misc{} and hl.animations{} do
-- not exist in the Lua API and a config calling them dies at load. Multiple
-- hl.config() calls are fine — each one merges into what came before, which is
-- why this file can be split into readable blocks.

-- The active border is the cool ramp itself: cyan at one corner, magenta at the
-- other, the same two endpoints as every colorbar this machine draws.
local active_border = {
  colors = { "rgba(40FFFFee)", "rgba(FF40FFee)" },
  angle = 45,
}
local inactive_border = "rgba(3A3A4Eaa)"

hl.config({
  general = {
    gaps_in = 4,
    gaps_out = 8,
    border_size = 2,
    layout = "dwindle",
    resize_on_border = true,
    allow_tearing = false,
    col = {
      active_border = active_border,
      inactive_border = inactive_border,
    },
  },

  decoration = {
    rounding = 4,
    -- Both off: they cost battery continuously and buy nothing on a screen that
    -- is text in a terminal ~95% of the time.
    blur = { enabled = false },
    shadow = { enabled = false },
    -- Slight transparency on unfocused windows only. Enough to see which window
    -- has the keyboard without reading the border.
    active_opacity = 1.0,
    inactive_opacity = 0.96,
  },

  group = {
    col = {
      border_active = active_border,
      border_inactive = inactive_border,
    },
    groupbar = {
      font_family = "JetBrainsMono Nerd Font",
      font_size = 11,
      height = 18,
      indicator_height = 2,
      text_color = "rgb(EDEDF8)",
      col = {
        active = "rgb(2A2A3E)",
        inactive = "rgb(1A1A2E)",
      },
    },
  },

  dwindle = {
    preserve_split = true,
    -- Split along the longer edge. On a 2880x1920 3:2 panel the default
    -- always-vertical split gives you two tall slivers for side-by-side code.
    smart_split = false,
    force_split = 2,
  },

  input = {
    -- kb_layout is NOT set here: it is per machine, scaffolded into
    -- hosts/<host>/hyprland.lua from the keymap chosen at install.
    -- Hardcoding "us" gave every non-US user the wrong layout, and
    -- unlike a wrong locale you discover it by typing your password wrong.
    follow_mouse = 1,
    -- Focus follows the mouse but does NOT raise or warp. Passing the pointer
    -- over a window while reading should never reorder anything.
    mouse_refocus = false,
    touchpad = {
      natural_scroll = true,
      disable_while_typing = true,
      clickfinger_behavior = true,
      scroll_factor = 0.4,
    },
  },

  cursor = {
    -- The laptop is s2idle-only; anything that keeps the GPU awake matters.
    no_hardware_cursors = false,
    inactive_timeout = 5,
  },

  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    -- 0 = never lower the refresh rate on battery. VRR already handles idle,
    -- and a forced drop makes scrolling code feel broken.
    vrr = 1,
    focus_on_activate = true,
    background_color = "rgb(1A1A2E)",
  },

  animations = {
    enabled = true,
  },

  -- VFR is the single biggest idle-power win on a laptop, and it lives under
  -- `debug`, not `misc`, in current Hyprland -- misc:vfr no longer exists and is
  -- rejected as an unknown key. It defaults to on; set explicitly so a future
  -- default change does not quietly cost battery.
  debug = {
    vfr = true,
  },
})

-- Native since 0.51. hyprgrass is not a package (only hyprgrass-git, which
-- depends on hyprland-git and would replace the official build).
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
