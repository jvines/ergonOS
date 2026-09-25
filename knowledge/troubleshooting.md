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

## No keybind does anything, and Hyprland says SUPER + Q is all there is

    Emergency mode tripped: A lua config error resulted in no binds being
    registered. Emergency binds active: SUPER + Q

**That message is Hyprland's, not this repo's.** It means the Lua config raised
an error before a single `hl.bind` ran, so nothing was registered and the
compositor fell back to a config built into the binary. It advertises one bind
and actually installs three:

| chord | what the binary binds it to |
|---|---|
| SUPER + Q | the first of kitty, alacritty, **foot**, wezterm, gnome-terminal, xterm that is installed |
| SUPER + R | `hyprland-run` |
| SUPER + M | exit the compositor |

`foot` is in `packages/pacman`, so **SUPER + Q gets you a terminal**. Use it
before reaching for a TTY.

### Reading it

    hyprctl configerrors
    tail -60 $XDG_RUNTIME_DIR/hypr/*/hyprland.log

The shape of the error tells you which kind it is, and **count entries, not
lines**: every config problem Hyprland records is ONE entry printed as one
`file:line: message` line — five bad keys print five lines. Lua errors are the
exception, and that exception is the whole diagnostic:

- **two dozen lines of `no file '.../common/<name>.lua'`** — Lua's "module not
  found", which is ONE entry whose text lists every path it tried (27 lines from
  a top-level require, 24 from one inside another module). A file is absent.
- **`cannot open .../hyprland.lua: No such file or directory`** — the entry
  point itself is gone, so no Lua ran at all. On a machine where
  `~/.config/hypr` is a symlink into the checkout, that means the checkout is
  mid-replacement.
- **two lines naming a file and a line number** — a syntax error, or a value
  Hyprland rejected, in a file that is there.
- **N separate `file:line:` lines** — N genuinely distinct problems. That is
  *not* a missing module, and if it comes with zero binds then something in
  `common.env` or `common.looknfeel` both failed a lot of keys AND raised a
  hard Lua error before `common.binds` was reached.

`debug:error_limit` caps how many are displayed, so a long list on screen may be
truncated with a "... more" — `hyprctl configerrors` is the full one.

### Fixing it

Nine times in ten the absent file is `hypr/common/looknfeel.lua`: it is the only
file in the compositor's require chain that is **generated and gitignored**, so
it is the only one that can be missing on a machine that has the repo. It goes
absent when a render fails, on a fresh clone or `git worktree` before
`install.sh` has run, and — before 2026-09-24 — while the VM harness replaced
the checkout underneath a live session.

    ergon theme                                   # re-render the palette
    ls -l ~/.config/hypr/common/looknfeel.lua     # it must exist
    hyprctl reload                                # Hyprland reads the config ONCE

The reload is not optional and not cosmetic: fixing the file on disk does
nothing at all to the running compositor, which read it at startup and will not
look again.

Since 2026-09-24 `hypr/hyprland.lua` loads each module through `need()`, which
pcalls, and loads `common.binds` second — so one missing generated file costs
you the theme and not the keyboard. If you are in emergency mode on current
`main`, it is **not** a missing `looknfeel.lua`: read the error, because
something in `common.env` or `common.binds` itself is broken.

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

## Discord asks you to log in after every session

Or VS Code says encryption is not available and an OS keyring couldn't be
identified, or an **Unlock Login Keyring** dialog sits in front of the first
Electron app you start. One cause, ERGON-64: Chromium does not know "Hyprland"
as a desktop and keeps the key in plaintext or memory, unless
`GNOME_DESKTOP_SESSION_ID` is set — `uwsm/env-hyprland.d/ergon-keyring` sets
it, **empty** — and the keyring it then uses must already be unlocked, which the
`pam_gnome_keyring` lines provisioning adds to `/etc/pam.d/greetd` do at login
(and the one in `/etc/pam.d/passwd` keeps it on your password).

    systemctl --user show-environment | grep GNOME_DESKTOP_SESSION_ID  # present, empty
    grep pam_gnome_keyring /etc/pam.d/greetd /etc/pam.d/passwd  # auth, session ... auto_start, password
    journalctl -b | grep gkr-pam                   # "unlocked login keyring"
    cat ~/.local/share/keyrings/default            # login, or no such file
    <app> --enable-logging=stderr --vmodule=key_storage_util_linux=1 2>&1 \
      | grep 'Password storage detected desktop environment'   # GNOME, not (unknown)
    #   for code add --verbose, or this prints nothing, fixed or not
    secret-tool search --all application <app>     # its key: discord, code-oss, ...

Find the key by `application`, not by label: every one of them is labelled
`Chromium Safe Storage`.

- **The first command prints nothing.** The session did not start through
  uwsm (tuigreet's plain "Hyprland" entry, a TTY, ssh), or
  `~/.config/uwsm/env-hyprland.d/ergon-keyring` is not linked — `install.sh`
  does that, and leaves your own `env-hyprland` alone.
- **It prints a value.** It must stay empty: a value makes every xdg-utils script
  decide this is GNOME, and `xdg-open <dir>` then fails. And not in
  `environment.d`, whose generator drops an empty assignment with a line in the
  journal and nothing else.
- **The dialog comes anyway, and `default` names another keyring.** An app made
  that one the default before this fix; apps still store there, and PAM
  unlocks only `login`. Point the alias at login, then log in again; the other
  keyring keeps what it holds, behind its own password:
  `busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service SetAlias so default /org/freedesktop/secrets/collection/login`
- **The dialog comes anyway, and `default` is login or absent.** Its password
  is not your login password: made by hand, set with `sudo passwd` (root
  cannot re-key it), or changed before provisioning gave `passwd` its keyring
  line. Move `~/.local/share/keyrings/login.keyring` aside — its secrets go
  with it — and log in again; PAM makes a new one with your password.
- **The first login after an install**, or after that, creates the keyring,
  and gnome-keyring does not serve it over D-Bus until the next login: apps
  cannot encrypt for that one session.

Side effect, by design: with the variable set, Chromium takes its proxy from
gsettings `org.gnome.system.proxy` and ignores `http_proxy` and `https_proxy`.

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

## A keybinding does nothing, and you cannot tell why

Three different causes present identically — the key does nothing, no error, no
window — and they need opposite fixes. Establish which one you have **before**
changing any config. All three were hit in sequence on one afternoon, and two
wrong fixes were shipped on the way.

**1. The key never reaches the machine.** Remote sessions eat modifiers. Over
VNC or RDP the client's own desktop claims SUPER before the guest sees it, and
on macOS `Option`+letter is composed into a dead-key character client-side, so
the letter is never transmitted at all — `CTRL+ALT+K` arrives as CTRL and ALT
and nothing else. `RETURN` and plain letters survive that path; SUPER and
ALT+letter do not.

**2. The key cannot be pressed on this keyboard.** `/` is its own key on a US
layout and `SHIFT+7` on the Latin American, Spanish, German and French ones. A
bind on `SLASH` cannot be matched there: the SHIFT the layout requires is a
modifier the bind does not carry. This is why the help binding is chosen from
`hypr/keymap-to-xkb` rather than hardcoded — see `hypr/common/layout.lua`.

**3. The bind fires and the command fails silently.** Anything launched from a
bind has no terminal attached, so a script that writes to stdout produces
nothing visible, and one that dies under `set -e` produces nothing at all.

**Tell them apart by measuring, not by reasoning.** Read the keyboard device
directly — this needs root and no extra packages:

    cat /dev/input/by-path/platform-i8042-serio-0-event-kbd > /tmp/keys.raw
    # press the combination, then:
    od -An -tu2 -w24 -v /tmp/keys.raw | awk '$9==1 { print $10, $11 }'

Each line is `keycode value` (1 = press, 0 = release). Useful codes: LEFTCTRL
29, LEFTALT 56, LEFTSHIFT 42, LEFTMETA 125, ENTER 28, SLASH 53, K 37.

- Modifiers appear but the letter does not → cause 1, the client. Nothing in
  the OS fixes it; use a client with a keyboard grab, or accept the
  `CTRL+ALT+RETURN` hatch and work from a shell.
- Everything appears → the compositor has it. `hyprctl binds -j` shows whether
  the bind is registered, and running the command with stdout redirected to a
  file reproduces cause 3.

**Do not use `od` to capture.** It buffers stdout when it is a file, so a short
burst of keypresses never reaches disk and the capture reads as "no keys
pressed" — which looks exactly like cause 1 and is not.

**`hyprctl keyword` does not work on a Lua config.** It answers "keyword can't
work with non-legacy parsers"; use `hyprctl eval 'hl.config({ ... })'`.
