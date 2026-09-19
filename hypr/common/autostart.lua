-- What starts with the session.
--
-- Daemons are exec'd straight into the compositor's scope; GUI apps launched
-- from a keybind go through uwsm-app so they get their own systemd scope and
-- survive a compositor reload. Both matter: a daemon in its own scope outlives
-- a Hyprland restart and you end up with two waybars.

hl.on("hyprland.start", function()
  -- Hand the session environment to systemd --user and to D-Bus before anything
  -- else starts. Without it, D-Bus-activated apps launch with an environment
  -- from before the compositor existed, which shows up as portals failing and
  -- apps taking several seconds to appear.
  hl.exec_cmd("systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE")
  hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE")

  -- Secrets. Firefox and discord both want a Secret Service; without one they
  -- fall back to storing credentials in plaintext or re-asking every launch.
  hl.exec_cmd("gnome-keyring-daemon --start --components=secrets")

  -- Authentication prompts for anything that calls polkit.
  hl.exec_cmd("systemctl --user start hyprpolkitagent.service")

  -- The desktop surfaces.
  hl.exec_cmd("waybar")
  hl.exec_cmd("mako")
  hl.exec_cmd("hyprpaper")
  -- Renders the wallpaper if it is missing and applies it over hyprpaper's IPC
  -- by absolute path. hyprpaper.conf alone was not enough: it reads its config
  -- only at startup, so a machine whose wallpaper did not exist yet came up
  -- with a flat background and never looked again -- which was every machine,
  -- because nothing generated the file. Cheap on later boots: it skips the
  -- render when the png is newer than theme/cool.env.
  hl.exec_cmd("ergon-wallpaper")
  hl.exec_cmd("hypridle")
  hl.exec_cmd("swayosd-server")

  -- Clipboard history. Two watchers, because wl-paste only reports one MIME
  -- class per invocation; without the image one, a screenshot is absent from
  -- history even though it is on the clipboard.
  hl.exec_cmd("wl-paste --type text  --watch cliphist store")
  hl.exec_cmd("wl-paste --type image --watch cliphist store")

  -- Removable media. No tray icon — waybar already owns that corner.
  hl.exec_cmd("udiskie --automount --notify --no-tray")

  -- Colour temperature daemon. Starts neutral; SUPER+SHIFT+N steps it warm.
  -- Useful at a telescope for the obvious reason, and at 2am for the ordinary
  -- one. See media.lua for the bindings.
  hl.exec_cmd("hyprsunset --temperature 6500")
end)
