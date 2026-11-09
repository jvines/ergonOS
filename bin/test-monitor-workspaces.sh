#!/usr/bin/env bash
# ERGON-91: the per-monitor workspace mapping, against a stubbed `hl`.
#
#   ./bin/test-monitor-workspaces.sh
#
# Asserts the mapping and the unplug/replug round trip, not that Hyprland honours
# the dispatches: only a second real monitor proves that. Runs hypr/common/
# workspaces.lua under plain Lua in a throwaway container (no runtime on the host).
set -euo pipefail
ERGON="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)"
. "$ERGON/lib/docker-cmd.sh"
ergon_resolve_docker || exit 1

"${DOCKER[@]}" run --rm -i --label cl.jvines.owner=ergon-91 -v "$ERGON:/df:ro" archlinux:latest \
  bash -c 'pacman -Sy --noconfirm lua >/dev/null 2>&1 && lua - /df' <<'LUA'
local root = arg[1]
local state = os.tmpname(); os.remove(state); os.execute("mkdir -p " .. state)
local function exists(p) local f = io.open(p); if f then f:close() end return f ~= nil end
local fails = 0
local function eq(name, got, want)
  if got == want then print("   ok   " .. name)
  else print("   FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want)); fails = fails + 1 end
end

-- A compositor in 40 lines. Workspaces: id -> { id, monitor, windows }.
local mons, wss, log, handlers = {}, {}, {}, {}
local function monref(name) return { name = name } end
local function node(id) local w = wss[id]; return w and { id = w.id, windows = w.windows, monitor = monref(w.monitor) } end
os.getenv = (function(real) return function(k) if k == "XDG_STATE_HOME" then return state end return real(k) end end)(os.getenv)
hl = {
  on = function(ev, fn) handlers[ev] = fn end,
  get_monitors = function() local o = {} for _, m in ipairs(mons) do o[#o + 1] = m end return o end,
  get_monitor = function(n) for _, m in ipairs(mons) do if m.name == n then return m end end end,
  get_active_monitor = function() return mons[#mons] end,
  get_workspace = function(id) return node(id) end,
  get_workspaces = function() local o = {} for id in pairs(wss) do o[#o + 1] = node(id) end return o end,
  dispatch = function(d)
    log[#log + 1] = d.op .. ":" .. (d.a.workspace or d.a.monitor or "")
    if d.op == "move" then wss[tonumber(d.a.workspace)].monitor = d.a.monitor
    elseif d.op == "change_id" then local w = wss[tonumber(d.a.workspace)]; wss[tonumber(d.a.workspace)] = nil; w.id = d.a.id; wss[d.a.id] = w end
  end,
  dsp = { focus = function(a) return { op = "focus", a = a } end,
          window = { move = function(a) return { op = "winmove", a = a } end },
          workspace = { move = function(a) return { op = "move", a = a } end,
                        change_id = function(a) return { op = "change_id", a = a } end } },
}
package.path = root .. "/hypr/?.lua;" .. package.path
local M = require("common.workspaces")
local function ids() local o = {} for id, w in pairs(wss) do o[#o + 1] = id .. "@" .. w.monitor end table.sort(o) return table.concat(o, " ") end

local panel = { id = 0, name = "eDP-1", description = "BOE 0x0BCA" }
local ext   = { id = 1, name = "DP-5",  description = "Dell U2723QE ABC123" }

print("== one monitor: exactly today")
mons = { panel }; wss = { [1] = { id = 1, monitor = "eDP-1", windows = 1 } }
handlers["hyprland.start"]()
M.focus(3)()
eq("SUPER+3 is workspace 3", log[#log], "focus:3")
M.move_window(4)()
eq("SUPER+SHIFT+4 moves to 4", log[#log], "winmove:4")
eq("no state written", exists(state .. "/ergon/monitor-blocks"), false)

print("== second monitor")
mons = { panel, ext }
wss = { [1] = { id = 1, monitor = "eDP-1", windows = 1 }, [2] = { id = 2, monitor = "eDP-1", windows = 2 } }
handlers["monitor.added"]({ name = "DP-5" })
eq("panel SUPER+3 -> 3", M.workspace_id(panel, 3), 3)
eq("external SUPER+3 -> 13", M.workspace_id(ext, 3), 13)
M.focus(3)()
eq("focus follows the focused monitor", log[#log], "focus:13")

print("== unplug folds the external's windows into the panel")
wss[11] = { id = 11, monitor = "DP-5", windows = 1 }; wss[12] = { id = 12, monitor = "DP-5", windows = 1 }
mons = { panel }
for _, id in ipairs { 11, 12 } do wss[id].monitor = "eDP-1" end   -- what Hyprland does itself
handlers["monitor.removed"]({ name = "DP-5" })
eq("renumbered after the panel's own", ids(), "1@eDP-1 2@eDP-1 3@eDP-1 4@eDP-1")

print("== replug returns them under their old numbers")
mons = { panel, ext }
handlers["monitor.added"]({ name = "DP-5" })
eq("restored", ids(), "11@DP-5 12@DP-5 1@eDP-1 2@eDP-1")

print("== the dock renames its connector; same monitor, same block")
ext.name = "DP-7"
eq("external keeps block 1", M.workspace_id(ext, 1), 11)

os.execute("rm -rf " .. state)
os.exit(fails == 0 and 0 or 1)
LUA
