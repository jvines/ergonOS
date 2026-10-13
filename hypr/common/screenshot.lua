-- Screenshots. Ported from the old hypr/screenshot.conf; the SHELL PIPELINE IS
-- UNCHANGED, byte for byte, and must stay that way.
--
-- Captures go to ~/Pictures/Screenshots, or to SCREENSHOT_DIR from
-- hosts/<host>/host.env, which install.sh hands to the session as
-- ERGON_SCREENSHOT_DIR (ERGON-39). That knob exists for a host where something
-- watches the folder: this author's machines mirror every capture to another
-- box through a systemd .path unit on ~/screenshots-outgoing, which used to be
-- every machine's directory. Switching to hyprshot or the XDPH screenshot
-- portal would bypass such a watcher silently.
--
-- grim writes the file; wl-copy puts it on the clipboard in the same pipeline,
-- because the sync script's clipboard step is a fallback for tools that do not
-- do it themselves — doing it here keeps the paste instant rather than waiting
-- on the watcher.
--
-- Needs: grim slurp wl-clipboard jq satty

local shotdir = os.getenv("ERGON_SCREENSHOT_DIR")
if shotdir == nil or shotdir == "" then
  shotdir = os.getenv("HOME") .. "/Pictures/Screenshots"
end
local stamp   = "$(date +%Y%m%d-%H%M%S).png"

local function shot(grab)
  return "mkdir -p " .. shotdir .. " && grim " .. grab ..
         "- | tee " .. shotdir .. "/" .. stamp .. " | wl-copy --type image/png"
end

-- Annotate: grim into satty instead of into tee. satty (packages/pacman) has
-- been installed "for screenshot annotation" since the base list existed,
-- with nothing calling it -- ERGON-38. -f - reads the capture off stdin and
-- -o writes wherever satty's own save action lands, both confirmed against
-- `satty --man` (0.22.0): NOTHING here duplicates grim's write the way `shot`
-- duplicates into wl-copy, because until the shot is actually saved there is
-- nothing to duplicate. Pointed at the SAME shotdir and stamp as every other
-- bind here for the reason the header gives: a watcher on that folder only
-- knows to look there.
local function annotate(grab)
  return "mkdir -p " .. shotdir .. " && grim " .. grab ..
         "- | satty -f - -o " .. shotdir .. "/" .. stamp
end

-- Descriptions only were added below: `ergon keys` lists only described binds,
-- and the capture key used most was missing from it.

-- Region select — the everyday one.
hl.bind("SUPER + SHIFT + S", hl.dsp.exec_cmd(shot([==[-g "$(slurp)" ]==])),
  { description = "Screenshot region" })

-- Whole output.
hl.bind("SUPER + SHIFT + CTRL + S", hl.dsp.exec_cmd(shot("")),
  { description = "Screenshot whole screen" })

-- Active window only.
hl.bind("SUPER + ALT + S", hl.dsp.exec_cmd(shot(
  [==[-g "$(hyprctl activewindow -j | jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')" ]==])),
  { description = "Screenshot active window" })

-- Annotate a region. Two chords for the one action: Print because it is what
-- a Print Screen key is for on every keyboard that has one (unlike the digit
-- row, its keysym does not change with layout, so it needs no code: form --
-- see binds.lua's workspace loop for a key where that matters), SUPER+SHIFT+
-- ALT+S to keep it reachable without one and beside the other capture binds.
-- Region rather than whole-screen: what gets annotated here is a figure or a
-- plotting bug, and that is normally one window or less, not the desktop.
hl.bind("SUPER + SHIFT + ALT + S", hl.dsp.exec_cmd(annotate([==[-g "$(slurp)" ]==])),
  { description = "Screenshot region, annotate" })
hl.bind("Print", hl.dsp.exec_cmd(annotate([==[-g "$(slurp)" ]==])),
  { description = "Screenshot region, annotate" })
