-- Lid and monitor hotplug.
--
-- `locked = true` throughout: the lid is the one input that must still be
-- handled while hyprlock is up. Closing the lid on a locked laptop and having
-- nothing happen is how you put a machine in a bag with the panel still lit.
--
-- The switch device name is not stable across kernels or chassis. Hyprland
-- matches on the libinput device name, and `hyprctl devices` is the way to find
-- the real one if these stop firing — "Lid Switch" is what the Framework 13
-- AMD reports, and it is the common case.

hl.bind("switch:on:Lid Switch",  hl.dsp.exec_cmd("ergon-lid close"), { locked = true })
hl.bind("switch:off:Lid Switch", hl.dsp.exec_cmd("ergon-lid open"),  { locked = true })

-- Hotplug. Re-running the per-host monitor config on connect is what makes
-- docking work without a logout: the host file owns the real layout, this just
-- tells Hyprland to apply it again once the output exists.
local f = io.open("/etc/hostname")
local host = f and f:read("l") or ""
if f then f:close() end

-- package.loaded must be cleared first. `require` memoises: calling it a second
-- time returns the cached module and re-executes NOTHING, so the obvious
-- version of this handler silently does nothing at all on every hotplug.
local function reapply_host_monitors()
  package.loaded["hosts." .. host] = nil
  pcall(require, "hosts." .. host)
end

hl.on("monitor.added",   reapply_host_monitors)
hl.on("monitor.removed", reapply_host_monitors)
