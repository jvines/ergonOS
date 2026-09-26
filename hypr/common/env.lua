-- Environment. Set here rather than in the shell profile because these have to
-- exist before the first client connects, and a graphical app launched from the
-- launcher never sources ~/.zshrc.

-- Cursor. One size everywhere; a mismatch between XCURSOR and HYPRCURSOR is why
-- the pointer changes size when it crosses from a GTK app into the compositor.
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-- Toolkits: Wayland first, XWayland only as a fallback.
hl.env("GDK_BACKEND", "wayland,x11,*")
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("QT_QPA_PLATFORMTHEME", "gtk3")
hl.env("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1")
hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")
hl.env("SDL_VIDEODRIVER", "wayland")
hl.env("MOZ_ENABLE_WAYLAND", "1")

-- Electron. discord is Electron and defaults to XWayland, where it renders
-- blurry on a scaled 2.8K panel and cannot do fractional scale at all.
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "wayland")

hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

-- Emacs is the pgtk build (packages/pacman: emacs-wayland), so it is a native
-- Wayland client and must not be pushed through XWayland by the GDK setting
-- above. Nothing to do here beyond not breaking it — noted because the obvious
-- "fix" for a blurry Emacs is GDK_BACKEND=x11, which is exactly wrong.

-- NVIDIA. bin/ergon-hardware writes this only where a Turing-or-newer NVIDIA
-- card drives the display and its driver is installed, and removes it when
-- that stops being true; elsewhere it is absent and pcall makes that a no-op.
-- Measured on 0.56.2: require takes an absolute path, hl.env is in effect as
-- soon as the file has run, and an error inside it still reaches the overlay
-- and --verify-config (exit 1), as ~/.config/ergon/user.lua's does.
pcall(require, "/etc/ergon/hypr/nvidia")
