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
-- Needs: grim slurp wl-clipboard jq satty

local shotdir = os.getenv("HOME") .. "/screenshots-outgoing"
local stamp   = "$(date +%Y%m%d-%H%M%S).png"

local function shot(grab)
  return "mkdir -p " .. shotdir .. " && grim " .. grab ..
         "- | tee " .. shotdir .. "/" .. stamp .. " | wl-copy --type image/png"
end

-- Annotate: grim into satty instead of into tee. satty (packages/pacman:156)
-- has been installed "for screenshot annotation" since the base list existed,
-- with nothing calling it -- ERGON-38. -f - reads the capture off stdin and
-- -o writes wherever satty's own save action lands, both confirmed against
-- `satty --man` (0.22.0): NOTHING here duplicates grim's write the way `shot`
-- duplicates into wl-copy, because until the shot is actually saved there is
-- nothing to duplicate. Pointed at the SAME shotdir and stamp as every other
-- bind here for exactly the reason the header above gives: the sync watcher
-- only knows to look there, and ERGON-39 is where that directory becomes
-- configurable, not this card.
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
