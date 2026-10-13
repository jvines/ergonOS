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

-- Input method (ERGON-79): fcitx5, started by common.autostart, which is how
-- press-and-hold accents reach an application (the omacento addon). What each
-- toolkit needs in order to hand it the keys:
--
--   XWayland  XMODIFIERS names the XIM server fcitx5 runs. Tk, Java and
--             anything else under X11 has no other route.
--   Qt        QT_IM_MODULE=fcitx loads fcitx5-qt's plugin. Qt5 speaks only
--             text-input-v2, which Hyprland does not implement, so this is
--             Qt5's only route; Qt6 takes the same one rather than two.
--   GTK       deliberately NOT set. GTK3 and GTK4 on Wayland use text-input-v3
--             by themselves, which is the protocol fcitx5's Wayland frontend
--             answers and where the accent popup is positioned by the
--             compositor. GTK_IM_MODULE=fcitx would force the D-Bus module
--             instead, and fcitx5 itself warns about it: its Wayland
--             self-check (modules/wayland, selfDiagnose) puts up a notification
--             asking for the variable to be unset whenever it sees one on a
--             compositor that has the Wayland input method protocol. A GTK app
--             that lands under XWayland does not need it either: fcitx5-gtk's
--             module registers for every locale ("ja:ko:zh:*", gtk3/fcitxim.c),
--             so GTK picks it there by itself.
--   Chromium and Electron  a command-line flag, not a variable: see binds.lua
--             (SUPER + D) and install.sh (electron-flags.conf).
hl.env("XMODIFIERS", "@im=fcitx")
hl.env("QT_IM_MODULE", "fcitx")

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
