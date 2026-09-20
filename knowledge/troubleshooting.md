# When the desktop is broken

Failure signatures, each one paid for. Every entry is *symptom first*, because
that is what you have when you start.

## Read these before theorising

    ergon-doctor                                  # machine health
    ergon-lint                                    # static traps in the repo
    tail -40 $XDG_RUNTIME_DIR/hypr/*/hyprland.log # THE compositor log
    journalctl --user -b -p warning

**The compositor log is not where you think.** Hyprland writes to
`$XDG_RUNTIME_DIR/hypr/<signature>/hyprland.log`. The stdout of whatever
launched it is empty, so tailing that gives no clue at all — which is exactly
what happened the first time.

An instance directory exists as soon as Hyprland starts, so "the socket is
there" does not mean "it came up".

---

## Clicks do nothing, but the bar looks fine

Two independent causes, and it was both at once:

**Workspace buttons highlight but do not switch.** waybar 0.15.0 sends the
classic `dispatch workspace 3` string, and a Lua-configured Hyprland parses that
as Lua and fails. Install `waybar-git` (see `packages/aur`). Fixed upstream in
Alexays/Waybar#5013, not yet in a tagged release.

**A module fires and nothing happens.** Its `on-click` is not on the session
PATH. The tell: bluetooth works and nothing else does, because its handler is
`blueman-manager`, a real binary, while the rest call `ergon-launch-tui`. Cause
is almost always `environment.d/10-ergon-path.conf` not linked — `install.sh`
does that, and a machine where configs were copied by hand never got it.

    ls -l ~/.config/environment.d/10-ergon-path.conf
    systemctl --user show-environment | grep PATH

## The greeter accepts the password and returns to the greeter

`/etc/greetd/config.toml` must run the session the way the packaged desktop file
does:

    command = "tuigreet ... --cmd 'uwsm start -e -D Hyprland hyprland.desktop'"

`uwsm start -S hyprland-uwsm.desktop` is doubly wrong: `-S` is not a uwsm flag,
and `hyprland-uwsm.desktop` **is** the uwsm launcher, so it asks uwsm to start
uwsm. greetd authenticates and then runs nonsense.

Note the greetd package ships its own `config.toml`, so "the file exists" proves
nothing. Grep for `tuigreet` and for the command above.

## "The account is locked"

`pam_faillock`. Arch defaults to `deny=3`, `unlock_time=600`, so three typos
during a debugging session locks you out for ten minutes.

    faillock --user <name> --reset

`/etc/security/faillock.conf` is provisioned with `deny = 10`,
`unlock_time = 120`.

## SUPER+RETURN does nothing

`wezterm` is an AUR **git** build and is the package most likely to be absent or
mid-rebuild — provisioning skips it under `ERGON_SKIP_AUR=1`. `ergon-term` falls
back to foot automatically. `SUPER+SHIFT+ALT+RETURN` is the explicit escape
hatch and names foot directly, for when wezterm is present but broken.

## A window never appears when a bar module is clicked

`ergon-launch-tui` goes through `uwsm-app` only when a uwsm session unit is
active, and falls back to a plain exec otherwise. Outside a uwsm session
`uwsm-app` fails and the window never appears, which from the bar is
indistinguishable from the click not registering.

## A polkit prompt that no password will answer

The session was started by hand rather than by logind, so polkit sees no active
local session. Not a wrong credential. Does not happen on real hardware, where
greetd gives a proper session — only in a harness that starts the compositor
directly.

---

## In a VM

**Black screen over VNC, compositor apparently fine.** `virtio-gpu-pci` gives
the guest a DRM device with no VGA scanout, so qemu has nothing to show. Use
`-device virtio-vga`.

**Clicks land somewhere other than the cursor.** The default PS/2 mouse is a
*relative* device and VNC only sends absolute coordinates. Add
`-device qemu-xhci -device usb-tablet`.

**`grim` hangs.** It captures every output and blocks forever on one that never
presents a frame under software rendering. Capture one: `grim -o <monitor>`.

**`EGL_BAD_ALLOC ... createImageFromDmaBufs failed` flooding the log.** The
emulated GPU has no dmabuf path. Rendering falls back to software. Layout,
colour and behaviour are accurate; smoothness is not, and screenshots do not
work. Not a desktop bug.

**`Cmd+Space` never reaches the guest from a Mac.** macOS takes it for Spotlight
before Screen Sharing forwards it, and takes it even when Spotlight does not
visibly open. Test with `SUPER+RETURN` first to confirm keys arrive at all.

---

## Packages

**An AUR package builds and then is not installed.** It conflicts with a repo
package, pacman asks `Remove <x>? [y/N]`, and `--noconfirm` takes the default —
No — then aborts with "unresolvable package conflicts". The build succeeded, the
install did not, and the only trace is one line in a log. `ergon-aur` clears
declared conflicts first; use it rather than bare `makepkg -si`.

## Recovering a machine that will not boot

`ergon-rollback` swaps the `@` subvolume for a snapshot. It **refuses to run
from `@`** — boot the Arch ISO, unlock the disk, and run it from there.
`snapper rollback` does not work on this layout and is not the tool.

## Suspend drains the battery, or the machine does not come back

Measure before changing anything. Resume workarounds are published per
platform, mostly as forum reports, and most of them cost other machines.

    ergon-sleep check                  # sleep modes, lid, hibernation, last hardware sleep
    ergon-sleep cycle 5                # suspend 5 times on an RTC alarm, count resumes
    ergon-sleep cycle 3 --hibernate    # the same through hibernate

- **"never reached hardware sleep":** suspend happened, but the SoC stayed out of
  its deepest state, so the battery drained as if the lid were open. Something
  kept it awake: a device, a driver or firmware.
- **A hibernate attempt reported as "did NOT resume":** the machine cold-booted
  instead of restoring. On the Ryzen AI 300 Framework 13 this has been reported
  on some AGESA versions, with `echo 0 > /sys/power/pm_async` as the workaround.
  That is one forum thread and it slows resume everywhere, so apply it only
  where `cycle --hibernate` shows the failure.
- **The lid handling is chosen, not fixed.** `ergon-hardware detect` shows
  whether the firmware is s2idle-only and whether hibernation is set up. Both
  together mean suspend-then-hibernate; anything else keeps logind's default.

## Wi-Fi vanished and will not come back

`pcie_aspm.policy=powersupersave` on the kernel cmdline makes the MediaTek
MT7925 (in the AMD RZ717 card) fail with "driver own failed" until the machine is
fully powered off. A reboot or a module reload does not clear it. Do not set that
policy; if it is set, remove it and power off.

## A desktop action is refused by polkit, with no prompt

**Symptom.** A bar button, a mount, or anything else that changes system state
does nothing at all. No error, no authentication dialog. Running the same
command in a terminal prints

    AccessDenied: Not Authorized: <some action id>

while `loginctl` insists the session is `Active=yes` on `seat0`, the policy says
`implicit active: yes`, and an authentication agent is running.

**Cause.** uwsm runs the compositor as `wayland-wm@hyprland.service` under
`user@<uid>.service`, so everything the desktop launches lives in

    /user.slice/user-<uid>.slice/user@<uid>.service/session.slice/...

and **not** in a logind session scope. `sd_pid_get_session()` fails for those
processes, so polkit resolves them to *no session at all*. An action whose
policy reads `implicit inactive: no` is then refused outright — and `no` is a
hard refusal rather than a question, which is why no agent prompt appears.

Every part of this looks correct in isolation. The session really is active; the
process simply is not in it.

**Confirm it in one command**, from inside the session rather than over `su -`
(which has no seat and will fail for a different reason):

    pkcheck --action-id <action id> --process $$   # "Not authorized." = this

and compare `cat /proc/self/cgroup` against `loginctl list-sessions`.

**Fix.** Grant the action by GROUP rather than by session activeness, in
`/etc/polkit-1/rules.d/`. provision-arch.sh ships
`49-ergon-desktop.rules` doing exactly that for power-profile switching. Add
entries there as they are demonstrated, not speculatively: each one grants the
action regardless of session, which includes over ssh.

**Do not** chase the authentication agent, the policy file, or the session's
Active state. All three are already correct.
