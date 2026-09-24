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
-- ORDER MATTERS, and so does what happens when one of these does not load.
--
-- env must run before autostart, or the daemons it launches inherit an
-- environment without WAYLAND_DISPLAY and silently fall back to XWayland.
--
-- binds comes SECOND, ahead of everything cosmetic, and every module is loaded
-- through need() rather than require(). Both are the same lesson, paid on
-- 2026-09-24. A Lua config is ONE CHUNK: an error anywhere in it stops every
-- line after it. common.looknfeel is GENERATED and gitignored, and the VM
-- harness deletes and re-copies the whole repo under a session that may already
-- be starting (test/arch-vm/guest-sync.sh), so there is a window at boot in
-- which that file does not exist. A session that loads in that window got
--
--     module 'common.looknfeel' not found
--
-- from line 17 -- a 27-line error, because Lua lists every path it tried --
-- with windows, binds, media, lid, screenshot and autostart never reached.
-- Hyprland then trips its own guard:
--
--     Emergency mode tripped: A lua config error resulted in no binds being
--     registered. Emergency binds active: SUPER + Q
--
-- No terminal, no launcher, no session menu, no keybind list, and the file that
-- was missing was a COLOUR SCHEME.
--
-- need() pcalls, so a module that fails takes itself down and nothing else --
-- the same argument binds.lua already makes for CTRL+ALT+RETURN and for the
-- foot fallback: the escape hatch must not depend on the thing that broke.
--
-- What pcall costs is the report, and the two halves of that are NOT the same,
-- which is measured rather than assumed (0.56.2, both ways):
--
--   a module that EXISTS and errors  is recorded by Hyprland's own loader and
--   appears in the config-error overlay and in `Hyprland --verify-config` even
--   when the require is pcall'ed -- that is how a broken
--   ~/.config/ergon/user.lua has always shown up;
--
--   a module that is MISSING raises an ordinary Lua "module not found", which
--   pcall swallows whole: nothing in the overlay, nothing in --verify-config,
--   nothing anywhere.
--
-- Silence is the one outcome this repo does not accept, so the block at the
-- bottom of this file is the report, and it is not decoration.
local failed = {}

local function need(mod)
  local ok, err = pcall(require, mod)
  if not ok then failed[#failed + 1] = { mod = mod, err = tostring(err) } end
  return ok
end

need("common.env")
-- Second on purpose: the binds are how you fix whatever else is broken.
need("common.binds")
need("common.looknfeel")
need("common.windows")
need("common.media")
need("common.lid")
need("common.screenshot")
need("common.autostart")

-- The report. Three channels, because the thing being reported is a desktop
-- that may have no notification daemon and no terminal.
if #failed > 0 then
  local names = {}
  for _, f in ipairs(failed) do names[#names + 1] = f.mod end
  local msg = table.concat(names, " ")

  -- 1. RED BORDERS, first and unconditionally. They need no daemon, no bus and
  -- no session: they are on screen the moment the compositor draws a window.
  -- Everything else here can fail to arrive. This cannot, and it is the signal
  -- that matters, because a desktop missing common.looknfeel is simply an
  -- UNTHEMED desktop -- which looks like a palette someone chose, not like a
  -- fault.
  hl.config({ general = { col = { active_border = "rgba(ff0000ee)" } } })

  hl.on("hyprland.start", function()
    -- 2. A line on disk, for the person reading this afterwards -- including
    -- the VM harness and `ergon doctor`, neither of which is looking at the
    -- screen.
    hl.exec_cmd("sh -c 'mkdir -p ~/.local/state/ergon && echo \"$(date -Is) config modules failed to load: " ..
                msg .. "\" >> ~/.local/state/ergon/config-failures.log'")
    -- 3. A notification, for the person in front of it. Deferred, because mako
    -- is started by common.autostart from a handler registered before this one:
    -- without the wait there is no notification daemon yet and the message goes
    -- nowhere. `|| true` because there may be no daemon even then, and a failed
    -- report must not be the loudest thing in the log.
    hl.exec_cmd("sh -c \"sleep 4; notify-send -u critical 'ergon: desktop config degraded' " ..
                "'did not load: " .. msg .. ". Fix with: ergon theme, then hyprctl reload' || true\"")
  end)
end

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

-- Yours. Last, so an hl.config() here wins over everything above it.
--
-- The explicit path is the whole point and a bare require("user") would be a
-- silent bug: Hyprland seeds package.path from THIS file's directory, which is
-- ~/.config/hypr -- a symlink into the checkout -- so a plain module name
-- resolves back into the repo, which is the one place an untracked override
-- must not live. A path starting with ~/ bypasses package.path entirely and is
-- resolved against $HOME. That form needs Hyprland 0.56; on anything older the
-- name simply does not resolve and pcall swallows it, which is the right
-- outcome for a file that is optional anyway.
--
-- One thing this does NOT catch: if the file exists but has an error in it,
-- Hyprland records that error internally and hands require an empty table, so
-- pcall reports success. It shows up in the compositor's config-error overlay,
-- not here. `Hyprland --verify-config` will also exit 1 on it.
pcall(require, "~/.config/ergon/user")
