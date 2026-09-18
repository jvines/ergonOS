-- Hyprland entry point.
--
-- Hyprland's config language has been Lua since 0.55 (hyprlang is frozen and
-- slated for removal), which is why hypr/screenshot.conf is gone: it was
-- hyprlang and would not load on any current build. The satellite daemons —
-- hyprlock, hypridle, hyprpaper — are the exception and still parse hyprlang,
-- which is why their configs here are .conf and not .lua.
--
-- `require` resolves relative to THIS file, i.e. ~/.config/hypr/, which is why
-- install.sh links the whole hypr/ DIRECTORY rather than a single file.
--
-- ORDER MATTERS. env must run before autostart, or the daemons it launches
-- inherit an environment without WAYLAND_DISPLAY and silently fall back to
-- XWayland. Everything after that is independent.

require("common.env")
require("common.looknfeel")
require("common.windows")
require("common.binds")
require("common.media")
require("common.lid")
require("common.screenshot")
require("common.autostart")

local f = io.open("/etc/hostname")
local host = f and f:read("l") or ""
if f then f:close() end

-- hosts/<hostname>.lua — monitor layout, scaling, anything that is a property
-- of one machine. Nothing here is fleet-shared.
--
-- pcall, and require rather than dofile, for the same reason install.sh's
-- link() treats a missing host file as a no-op: on a rolling compositor a
-- broken per-host override must never take the base config down with it.
pcall(require, "hosts." .. host)
