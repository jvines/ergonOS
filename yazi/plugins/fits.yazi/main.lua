-- ERGON-62: bridge FITS to yazi's preview like the bundled magick.lua bridges
-- other formats to `magick` -- render into yazi's cache once, then hand that
-- PNG to yazi's normal image display. See yazi.toml for why (yazi's built-in
-- image previewer cannot read FITS) and lib/ergon_fits_thumbnail.py for the
-- render itself.
local M = {}

-- $ERGON fallback matches zsh/zshenv's; a plugin has no BASH_SOURCE trick.
local function ergon_root()
	return os.getenv("ERGON") or ((os.getenv("HOME") or "") .. "/ergonOS")
end

-- Same venv lookup as bin/erg-peek: astropy and matplotlib live there
-- (packages/python), not in any python that happens to be on PATH.
local function pyfleet_python()
	local venv = os.getenv("PYFLEET_VENV")
	if not venv or venv == "" then
		venv = (os.getenv("XDG_DATA_HOME") or ((os.getenv("HOME") or "") .. "/.local/share")) .. "/pyfleet"
	end
	return venv .. "/bin/python"
end

function M:peek(job)
	local cache = ya.file_cache(job)
	if not cache then
		return
	end

	local ok, err = self:preload(job)
	if not ok or err then
		return ya.preview_widget(job, err)
	end

	local _, show_err = ya.image_show(cache, job.area)
	ya.preview_widget(job, show_err)
end

function M:seek() end

function M:preload(job)
	local cache = ya.file_cache(job)
	-- fs.cha, not fs.stat -- yazi has no fs.stat (ERGON-62 review: calling it
	-- raised "attempt to call a nil value (field 'stat')" on every hover,
	-- reproduced in a real yazi 26.9.1 pty). magick.lua uses fs.cha too.
	if not cache or fs.cha(cache) then
		return true
	end

	local side = tostring(math.max(rt.preview.max_width, rt.preview.max_height))
	local script = ergon_root() .. "/lib/ergon_fits_thumbnail.py"
	local status, err = Command(pyfleet_python())
		:arg { script, tostring(job.file.path), tostring(cache), "--size", side }
		:status()

	if not status then
		return true, Err("Failed to start the FITS thumbnailer, error: %s", err)
	elseif not status.success then
		return true, Err("No image HDU to preview")  -- e.g. a table-only FITS
	end
	return true
end

return M
