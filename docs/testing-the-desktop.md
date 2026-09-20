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

- **Rendering is software ONLY WITHOUT A RENDER NODE.** This was written up for a
  long time as a permanent property of "the VM". It is not. Given a host with
  `/dev/dri/renderD128`, the guest gets real GL and a working dmabuf path, the
  wallpaper composites and `grim` captures. Three things had to be true at once,
  and all three were bugs rather than limits:
    * the qemu image installed `qemu-system-x86` with `--no-install-recommends`,
      which drops `qemu-system-gui` -- so there was no `virtio-*-gl` device and
      no display backend but `none` and `curses`;
    * `libegl1`/`libgbm1`/`libgl1-mesa-dri` were missing, so `-display
      egl-headless` exited with `Couldn't open libEGL.so.1`;
    * qemu adds a DEFAULT VGA adapter on top of the `-device` you ask for, so the
      guest had two DRM cards -- `bochs-drm` on card0 with no render node and the
      real GPU on card1. `aquamarine` opened the first and every dmabuf import
      failed. `-vga none` removes it.
  checo has no render node (its iGPU is deliberately unbound), so the suites fall
  back to software there and skip those assertions. Run them on chiki, which has
  one. Smoothness is still not representative.
- **The GPU device differs by harness.** `bin/hypr-vm` uses `virtio-vga-gl`
  because VNC needs VGA scanout; `virtio-gpu-gl-pci` gives a DRM device with no
  scanout, so VNC shows a black screen while the compositor runs perfectly
  behind it. The headless suites use the `-pci` variant, which is correct for
  them. Both pass `-vga none`.
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
