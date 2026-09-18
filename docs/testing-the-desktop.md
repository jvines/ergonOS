# Testing the desktop

There is no second machine to boot this on, and there will not be one until the
Framework arrives. Everything below runs in a VM on checo.

## The three commands

```sh
./bin/test-arch-vm.sh --keep    # ~15 min, once.  Installs Arch from the real
                                # ISO under OVMF: LUKS, btrfs subvolumes, GRUB,
                                # snapper. Keeps the disk afterwards.

./bin/test-hypr-session.sh      # ~12 min, after changing anything that
                                # provisions or installs. Runs
                                # provision-arch.sh and install.sh in that disk,
                                # starts the real compositor, and asserts.

./bin/hypr-vm                   # ~1 min.  Boots that disk with a display on
                                # VNC and logs you in at the greeter.
```

`hypr-vm` re-syncs the repo into the VM and re-runs `install.sh` on every boot
(`test/arch-vm/guest-sync.sh`), so a config change only costs a reboot of the
VM — not a reinstall. Package or `/etc` changes still need
`test-hypr-session.sh`, because that is the only thing that runs provisioning.

## Connecting

`hypr-vm` prints a `vnc://` URL on the tailnet and a password. On the Mac:
Finder → Go → Connect to Server. macOS Screen Sharing speaks VNC; there is
nothing to install, and nothing that wants an account.

The VNC password is capped at 8 characters by the protocol, not by a typo. It is
not the security boundary — binding to the tailnet is.

## What the session test actually asserts

The point of this file. Every one of these exists because something passed
without it:

| assertion | what it caught |
|---|---|
| `install.sh` linked `environment.d/10-ergon-path.conf` | the test used to stage `~/.config` by hand, so the session PATH was never exercised and every `ergon-*` in the bar was a no-op |
| every waybar `on-click` resolves on the session PATH | the bar rendered, highlighted on hover and did nothing — except bluetooth, whose handler is a real binary |
| every exec keybind resolves on the session PATH | "86 keybindings registered" says nothing about the command on the other end |
| a synthetic click changes workspace | the only thing that proves the pointer path works end to end |
| `ergon-launch-tui` opens a window | covers PATH, terminal fallback and window rules in one |
| the greetd command matches the packaged `hyprland-uwsm.desktop` | greetd authenticated and then ran `uwsm start -S hyprland-uwsm.desktop`, which is uwsm asked to start uwsm, with a flag that does not exist |

Clicks are injected with `ydotool` through `/dev/uinput`, so the compositor sees
a real input device and takes the real path: libinput → cursor → surface → GTK.
A Wayland client cannot fake that for another client.

## Things that are not real

- **Rendering is software.** `aquamarine` cannot get a dmabuf path in the VM and
  floods the log with `EGL_BAD_ALLOC`. Layout, colour, fonts and behaviour are
  accurate; smoothness is not. Do not judge animations here.
- **The floppy.** qemu always emulates one. `udiskie` notices and asks polkit to
  mount it.
- **The GPU is virtio-vga.** `virtio-gpu-pci` gives the guest a DRM device with
  no VGA scanout, so VNC shows a black screen while the compositor runs
  perfectly behind it. That cost an evening.
- **The pointer is a USB tablet.** The default PS/2 mouse is a relative device
  and VNC can only send absolute coordinates; qemu converts, the guest pointer
  drifts from yours, and you click one thing and hit another.

## Keyboard over VNC

`SUPER + SPACE` (the launcher) does not arrive from a Mac. macOS swallows
`Cmd + Space` for Spotlight before Screen Sharing can forward it — and it
swallows it even when Spotlight does not visibly open, which is what makes it
look like the guest is ignoring the key rather than never receiving it.

Test with `SUPER + RETURN` (terminal) first: if a window opens, keys are
arriving and only that one combination is being eaten. To get it back, turn off
the Spotlight shortcut in System Settings → Keyboard → Keyboard Shortcuts →
Spotlight for as long as you are in the VM.

`SUPER + SHIFT + ALT + RETURN` opens foot, which is the escape hatch for a
machine where wezterm is missing or mid-rebuild.
