-- Hardware keys: volume, brightness, media, colour temperature.
--
-- Every hardware key here is `locked = true`, which is the whole point of the
-- file: these must work while hyprlock is up. Turning the volume down on a
-- laptop that started blaring on a locked screen should not require typing a
-- passphrase first.
--
-- `repeating = true` (not `repeat` — that is a Lua keyword) makes held keys
-- ramp instead of stepping once.
--
-- Everything routes through swayosd-client rather than wpctl/brightnessctl
-- directly, so the change draws an on-screen indicator. swayosd applies the
-- change itself; calling both would double-step.

local osd = "swayosd-client "

-- Every bind carries a description, as in binds.lua: `ergon keys` lists only
-- described binds, and these were missing from it -- the cheatsheet did not
-- know the night light existed. The option tables are copied rather than
-- written into, so `locked` and `ramp` stay exactly what their names say.
local function bind(keys, desc, cmd, opts)
  local o = { description = desc }
  for k, v in pairs(opts or {}) do o[k] = v end
  hl.bind(keys, hl.dsp.exec_cmd(cmd), o)
end
local locked = { locked = true }
local ramp   = { locked = true, repeating = true }

-- -- volume -----------------------------------------------------------------
bind("XF86AudioRaiseVolume", "Volume up",         osd .. "--output-volume raise",       ramp)
bind("XF86AudioLowerVolume", "Volume down",       osd .. "--output-volume lower",       ramp)
bind("XF86AudioMute",        "Mute",              osd .. "--output-volume mute-toggle", locked)
bind("XF86AudioMicMute",     "Mute microphone",   osd .. "--input-volume mute-toggle",  locked)

-- Fine steps. Useful on headphones, where one 5% step is the difference
-- between too quiet and too loud.
bind("ALT + XF86AudioRaiseVolume", "Volume up 1%",   osd .. "--output-volume +1", ramp)
bind("ALT + XF86AudioLowerVolume", "Volume down 1%", osd .. "--output-volume -1", ramp)

-- -- brightness -------------------------------------------------------------
bind("XF86MonBrightnessUp",         "Brightness up",      osd .. "--brightness raise", ramp)
bind("XF86MonBrightnessDown",       "Brightness down",    osd .. "--brightness lower", ramp)
bind("ALT + XF86MonBrightnessUp",   "Brightness up 1%",   osd .. "--brightness +1",    ramp)
bind("ALT + XF86MonBrightnessDown", "Brightness down 1%", osd .. "--brightness -1",    ramp)

-- External monitor, over DDC/CI. The hardware keys cannot touch it: an
-- external display has no /sys/class/backlight entry, so brightnessctl and
-- swayosd both silently do nothing. SUPER is the "other screen" modifier.
bind("SUPER + XF86MonBrightnessUp",   "External monitor brighter", "ergon-brightness +10 --external", locked)
bind("SUPER + XF86MonBrightnessDown", "External monitor dimmer",   "ergon-brightness -10 --external", locked)

-- Keyboard backlight. No OSD for it — you can see the keyboard.
--
-- Found by what the LED does, not by who made it. The kernel names an LED
-- <device>:<colour>:<function>, and the device part is whatever the platform
-- driver calls itself: tpacpi on a ThinkPad, something else on a Framework or
-- a Dell. Naming tpacpi made these keys do nothing on every other laptop.
-- brightnessctl matches -d with fnmatch(3), so the pattern selects the LED
-- whose function is kbd_backlight, whatever its device and colour fields say.
local kbd = "brightnessctl -c leds -d '*:kbd_backlight' "
bind("XF86KbdBrightnessUp",   "Keyboard backlight up",   kbd .. "set +1", locked)
bind("XF86KbdBrightnessDown", "Keyboard backlight down", kbd .. "set 1-", locked)

-- -- media ------------------------------------------------------------------
bind("XF86AudioPlay",  "Play/pause",     osd .. "--playerctl play-pause", locked)
bind("XF86AudioPause", "Play/pause",     osd .. "--playerctl play-pause", locked)
bind("XF86AudioNext",  "Next track",     osd .. "--playerctl next",       locked)
bind("XF86AudioPrev",  "Previous track", osd .. "--playerctl previous",   locked)

-- -- colour temperature -----------------------------------------------------
-- hyprsunset runs from autostart at 6500K. These are manual steps rather than a
-- sunset schedule on purpose: your working hours are not the sun's, and a
-- daemon that warms the panel on its own schedule is actively wrong when you
-- are reading a colour-mapped plot at midnight.
bind("SUPER + SHIFT + N", "Night light (3500K)", "hyprctl hyprsunset temperature 3500")
bind("SUPER + SHIFT + M", "Daylight (6500K)",    "hyprctl hyprsunset temperature 6500")
-- Identity: no colour transform at all. This was SUPER+SHIFT+B, which is also
-- "Next background" in binds.lua; Hyprland fires every bind that matches, so
-- one press changed the wallpaper AND reset the panel. CTRL+N keeps it beside
-- the other night-light key. ergon-lint now refuses a chord bound twice.
bind("SUPER + CTRL + N",  "Colour temperature off", "hyprctl hyprsunset identity")
