-- Hardware keys: volume, brightness, media, colour temperature.
--
-- Every binding here is `locked = true`, which is the whole point of the file:
-- these must work while hyprlock is up. Turning the volume down on a laptop
-- that started blaring on a locked screen should not require typing a
-- passphrase first.
--
-- `repeating = true` (not `repeat` — that is a Lua keyword) makes held keys
-- ramp instead of stepping once.
--
-- Everything routes through swayosd-client rather than wpctl/brightnessctl
-- directly, so the change draws an on-screen indicator. swayosd applies the
-- change itself; calling both would double-step.

local osd = "swayosd-client "

-- -- volume -----------------------------------------------------------------
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd(osd .. "--output-volume raise"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd(osd .. "--output-volume lower"), { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd(osd .. "--output-volume mute-toggle"), { locked = true })
hl.bind("XF86AudioMicMute",     hl.dsp.exec_cmd(osd .. "--input-volume mute-toggle"),  { locked = true })

-- Fine steps. Useful on headphones, where one 5% step is the difference
-- between too quiet and too loud.
hl.bind("ALT + XF86AudioRaiseVolume", hl.dsp.exec_cmd(osd .. "--output-volume +1"), { locked = true, repeating = true })
hl.bind("ALT + XF86AudioLowerVolume", hl.dsp.exec_cmd(osd .. "--output-volume -1"), { locked = true, repeating = true })

-- -- brightness -------------------------------------------------------------
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd(osd .. "--brightness raise"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(osd .. "--brightness lower"), { locked = true, repeating = true })
hl.bind("ALT + XF86MonBrightnessUp",   hl.dsp.exec_cmd(osd .. "--brightness +1"), { locked = true, repeating = true })
hl.bind("ALT + XF86MonBrightnessDown", hl.dsp.exec_cmd(osd .. "--brightness -1"), { locked = true, repeating = true })

-- External monitor, over DDC/CI. The hardware keys cannot touch it: an
-- external display has no /sys/class/backlight entry, so brightnessctl and
-- swayosd both silently do nothing. SUPER is the "other screen" modifier.
hl.bind("SUPER + XF86MonBrightnessUp",   hl.dsp.exec_cmd("ergon-brightness +10 --external"), { locked = true })
hl.bind("SUPER + XF86MonBrightnessDown", hl.dsp.exec_cmd("ergon-brightness -10 --external"), { locked = true })

-- Keyboard backlight. No OSD for it — you can see the keyboard.
hl.bind("XF86KbdBrightnessUp",   hl.dsp.exec_cmd("brightnessctl -d tpacpi::kbd_backlight set +1"), { locked = true })
hl.bind("XF86KbdBrightnessDown", hl.dsp.exec_cmd("brightnessctl -d tpacpi::kbd_backlight set 1-"), { locked = true })

-- -- media ------------------------------------------------------------------
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd(osd .. "--playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd(osd .. "--playerctl play-pause"), { locked = true })
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd(osd .. "--playerctl next"),       { locked = true })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd(osd .. "--playerctl previous"),   { locked = true })

-- -- colour temperature -----------------------------------------------------
-- hyprsunset runs from autostart at 6500K. These are manual steps rather than a
-- sunset schedule on purpose: your working hours are not the sun's, and a
-- daemon that warms the panel on its own schedule is actively wrong when you
-- are reading a colour-mapped plot at midnight.
hl.bind("SUPER + SHIFT + N", hl.dsp.exec_cmd("hyprctl hyprsunset temperature 3500"))
hl.bind("SUPER + SHIFT + M", hl.dsp.exec_cmd("hyprctl hyprsunset temperature 6500"))
hl.bind("SUPER + SHIFT + B", hl.dsp.exec_cmd("hyprctl hyprsunset identity"))
