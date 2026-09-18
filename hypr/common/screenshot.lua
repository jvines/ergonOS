-- Screenshots. Ported from the old hypr/screenshot.conf; the SHELL PIPELINE IS
-- UNCHANGED, byte for byte, and must stay that way.
--
-- The point of writing to ~/screenshots-outgoing rather than the usual place is
-- the systemd .path unit watching it (screenshot-sync.path): every capture is
-- mirrored to checo automatically, so anything running there can read it.
-- Changing the output directory, or switching to hyprshot or the XDPH
-- screenshot portal, silently bypasses that watcher.
--
-- grim writes the file; wl-copy puts it on the clipboard in the same pipeline,
-- because the sync script's clipboard step is a fallback for tools that do not
-- do it themselves — doing it here keeps the paste instant rather than waiting
-- on the watcher.
--
-- Needs: grim slurp wl-clipboard jq

local shotdir = os.getenv("HOME") .. "/screenshots-outgoing"
local stamp   = "$(date +%Y%m%d-%H%M%S).png"

local function shot(grab)
  return "mkdir -p " .. shotdir .. " && grim " .. grab ..
         "- | tee " .. shotdir .. "/" .. stamp .. " | wl-copy --type image/png"
end

-- Region select — the everyday one.
hl.bind("SUPER + SHIFT + S", hl.dsp.exec_cmd(shot([==[-g "$(slurp)" ]==])))

-- Whole output.
hl.bind("SUPER + SHIFT + CTRL + S", hl.dsp.exec_cmd(shot("")))

-- Active window only.
hl.bind("SUPER + ALT + S", hl.dsp.exec_cmd(shot(
  [==[-g "$(hyprctl activewindow -j | jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')" ]==])))
