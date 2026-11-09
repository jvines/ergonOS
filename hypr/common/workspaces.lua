-- Per-monitor workspaces (ERGON-91): every monitor owns its own workspaces
-- 1-10, as Niri gives every output its own, and they survive an unplug.
--
-- Hyprland numbers workspaces globally, so each monitor owns a BLOCK of ten:
-- block 0 is ids 1-10, block 1 is 11-20. SUPER+3 goes to the third workspace of
-- the focused monitor's block. The primary monitor (the internal panel, else
-- the one showing workspace 1) is always block 0, which is what keeps this a
-- no-op until a second monitor appears: with one monitor SUPER+N is workspace N
-- exactly as before, and no state is written. Other monitors get the lowest
-- free block, remembered by make/model/serial in $XDG_STATE_HOME so a monitor
-- gets the same block back every time. The connector would be wrong: a dock
-- renames them between plugs.
--
-- Unplug: Hyprland moves the monitor's workspaces onto another one, keeping
-- their ids, which are then unreachable by SUPER+N. They are renumbered into
-- the remaining monitor's block (after its own) and the original id is
-- remembered. Replug: they go back, under their old numbers.
--
-- The waybar workspace module is not block-aware yet (labels and persistent
-- buttons assume 1-9 on every output).

local SLOTS = 10
local M = {}

local dir = (os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")) .. "/ergon"
local BLOCKS, MERGED = dir .. "/monitor-blocks", dir .. "/monitor-merged"

-- key<TAB>number lines; `numeric` reads the keys as numbers. Missing file is an empty map.
local function read_map(path, numeric)
  local map, f = {}, io.open(path, "r")
  if not f then return map end
  for line in f:lines() do
    local k, v = line:match("^(.+)\t(%d+)$")
    if k then map[numeric and tonumber(k) or k] = tonumber(v) end
  end
  f:close()
  return map
end

local function write_map(path, map)
  local keys = {}
  for k in pairs(map) do keys[#keys + 1] = k end
  table.sort(keys)
  local lines = {}
  for _, k in ipairs(keys) do lines[#lines + 1] = k .. "\t" .. map[k] .. "\n" end
  local f = io.open(path, "w")
  if not f then os.execute("mkdir -p '" .. dir .. "'"); f = io.open(path, "w") end
  if f then f:write(table.concat(lines)); f:close() end
end

local function block_of(id) return (id - 1) // SLOTS end
local function regular(ws) return ws and not ws.special and ws.id > 0 end

local function internal(m)
  return m.name:match("^eDP") or m.name:match("^LVDS") or m.name:match("^DSI")
end

-- Monitors that show workspaces of their own; `gone` is one Hyprland still
-- lists while it reports the monitor's removal.
local function connected(gone)
  local out = {}
  for _, m in ipairs(hl.get_monitors()) do
    if not m.is_mirror and m.name ~= gone then out[#out + 1] = m end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- Make, model and serial; twins (no serial) are told apart by connector order.
local function identities_of(monitors)
  local ids, seen = {}, {}
  local sorted = { table.unpack(monitors) }
  table.sort(sorted, function(a, b) return a.name < b.name end)
  for _, m in ipairs(sorted) do
    local base = (m.description and m.description ~= "") and m.description or m.name
    local n, id = 1, base
    while seen[id] do n = n + 1; id = base .. " #" .. n end
    seen[id], ids[m.name] = true, id
  end
  return ids
end

-- connector -> block. Nothing is read or written for a lone monitor.
local function assign(monitors)
  local by = {}
  if #monitors <= 1 then
    if monitors[1] then by[monitors[1].name] = 0 end
    return by
  end

  local primary
  for _, m in ipairs(monitors) do
    if internal(m) then primary = m; break end
  end
  if not primary then
    local one = hl.get_workspace(1)
    for _, m in ipairs(monitors) do
      if one and one.monitor and one.monitor.name == m.name then primary = m end
    end
    primary = primary or monitors[1]
  end
  by[primary.name] = 0

  local blocks, ids = read_map(BLOCKS), identities_of(monitors)
  local before, used, taken = {}, { [0] = true }, {}
  local here = {}
  for _, id in pairs(ids) do here[id] = true end
  for k, v in pairs(blocks) do
    before[k] = v
    if not here[k] then taken[v] = true end
  end
  for _, m in ipairs(monitors) do
    local b = blocks[ids[m.name]]
    if m.name ~= primary.name and b and b >= 1 and not used[b] then used[b] = true; by[m.name] = b end
  end
  for _, m in ipairs(monitors) do
    if not by[m.name] then
      local b = 1
      while used[b] or taken[b] do b = b + 1 end
      used[b], by[m.name], blocks[ids[m.name]] = true, b, b
    end
  end
  for id, v in pairs(blocks) do if before[id] ~= v then write_map(BLOCKS, blocks); break end end
  return by
end

local function id_for(monitor, slot, by)
  return (by[monitor.name] or 0) * SLOTS + slot
end

function M.workspace_id(monitor, slot)
  return id_for(monitor, slot, assign(connected()))
end

-- Give a workspace another id, carrying where it came from with it.
local function renumber(ws, id, merged)
  local old = ws.id
  hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(old), id = id }))
  if merged[old] then merged[id], merged[old] = merged[old], nil end
end

local function move_to(ws, monitor)
  hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(ws.id), monitor = monitor.name }))
end

-- The first id after the highest in use in a block, else any free one. Nil when
-- all ten are taken, and the workspace stays a guest.
local function append_slot(block)
  local top = block * SLOTS
  for _, ws in ipairs(hl.get_workspaces()) do
    if regular(ws) and block_of(ws.id) == block and ws.id > top then top = ws.id end
  end
  if top < block * SLOTS + SLOTS then return top + 1 end
  for id = block * SLOTS + 1, block * SLOTS + SLOTS do
    if not hl.get_workspace(id) then return id end
  end
end

-- Put every workspace with windows on its owner, and adopt those whose owner is
-- unplugged into the block of the monitor they are on.
function M.reconcile(gone)
  local monitors = connected(gone)
  if not gone and #monitors < 2 and not next(read_map(MERGED, true)) then return end
  local by = assign(monitors)
  local merged = read_map(MERGED, true)
  local window = hl.get_active_window and hl.get_active_window()

  local function owner(id)
    for _, m in ipairs(monitors) do
      if by[m.name] == block_of(id) then return m end
    end
  end

  -- Replug: bring back what an unplug folded into another block.
  local news = {}
  for id in pairs(merged) do news[#news + 1] = id end
  table.sort(news)
  for _, id in ipairs(news) do
    local ws, home = hl.get_workspace(id), owner(merged[id])
    if not regular(ws) then
      merged[id] = nil
    elseif home then
      local orig = merged[id]
      merged[id] = nil
      if ws.monitor.name ~= home.name then move_to(ws, home) end
      if not hl.get_workspace(orig) then renumber(ws, orig, merged) end
    end
  end

  local list = {}
  for _, ws in ipairs(hl.get_workspaces()) do
    if regular(ws) and ws.monitor and (ws.windows or 0) > 0 then list[#list + 1] = ws end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  for _, ws in ipairs(list) do
    local home = owner(ws.id)
    if home and home.name ~= ws.monitor.name then
      move_to(ws, home)
    elseif not home and by[ws.monitor.name] then
      local id, old = append_slot(by[ws.monitor.name]), ws.id
      if id then
        merged[old] = merged[old] or old
        renumber(ws, id, merged)
      end
    end
  end

  write_map(MERGED, merged)
  if window and hl.get_window and hl.get_window("address:" .. window.address) then
    hl.dispatch(hl.dsp.focus({ window = "address:" .. window.address }))
  end
end

-- Bind actions. A lone monitor takes the plain dispatch, so SUPER+N is the
-- dispatch it always was.
function M.focus(slot)
  return function()
    local monitor, monitors = hl.get_active_monitor(), connected()
    if #monitors < 2 or not monitor then
      return hl.dispatch(hl.dsp.focus({ workspace = tostring(slot) }))
    end
    local id = M.workspace_id(monitor, slot)
    local ws = hl.get_workspace(id)
    -- Bring a guest over with a move; focusing it would swap two monitors' views.
    if ws and ws.monitor and ws.monitor.name ~= monitor.name then move_to(ws, monitor) end
    hl.dispatch(hl.dsp.focus({ workspace = tostring(id) }))
  end
end

function M.move_window(slot)
  return function()
    local monitor, monitors = hl.get_active_monitor(), connected()
    local id = (#monitors < 2 or not monitor) and slot or M.workspace_id(monitor, slot)
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(id), follow = false }))
  end
end

hl.on("hyprland.start", function()
  os.remove(MERGED)
  M.reconcile()
end)
hl.on("monitor.added",   function() M.reconcile() end)
hl.on("monitor.removed", function(m) M.reconcile(m and m.name) end)

return M
