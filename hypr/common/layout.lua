-- What keyboard is this, and which keys can actually be pressed on it.
--
-- Read at config load from /etc/vconsole.conf -- the answer the installer was
-- given -- rather than from hl.config, because hosts/<host>.lua sets kb_layout
-- and loads AFTER common.binds. The install-time answer is available to both.
--
-- This exists because a keybind is only as good as the keyboard it is pressed
-- on. SUPER+SLASH was the help binding, and on the Latin American layout its
-- own author types on, '/' is SHIFT+7 -- so the one binding a lost user reaches
-- for was the one they could not press, and it failed silently: nothing happens
-- and there is no way to tell that from a broken command.

local M = {}

local function read_keymap()
  local f = io.open("/etc/vconsole.conf")
  if not f then return nil end
  local keymap
  for line in f:lines() do
    -- Last KEYMAP= wins, matching how systemd reads the file.
    local v = line:match('^%s*KEYMAP%s*=%s*"?([^"%s]+)"?')
    if v then keymap = v end
  end
  f:close()
  return keymap
end

-- hypr/keymap-to-xkb, the same table bin/provision-arch.sh reads. Resolved
-- relative to this file's directory so it works from the linked ~/.config/hypr
-- as well as from a checkout.
local function read_table()
  local dir = (debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../"
  local f = io.open(dir .. "keymap-to-xkb")
  if not f then return {} end
  local t = {}
  for line in f:lines() do
    if not line:match("^%s*#") then
      local console, xkb, slash = line:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s*$")
      if console then t[console] = { xkb = xkb, slash = (slash == "yes") } end
    end
  end
  f:close()
  return t
end

M.console = read_keymap() or "us"

local row = read_table()[M.console]

-- Absent from the table: map the layout to itself and assume '/' needs SHIFT.
-- Wrong in the safe direction -- it picks a function key for help rather than
-- one that cannot be pressed.
M.xkb = row and row.xkb or M.console
M.slash_unshifted = row and row.slash or false

return M
