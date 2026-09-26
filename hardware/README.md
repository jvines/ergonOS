# Hardware

    ergon hardware detect          # what this machine has, and which profile matches
    ergon hardware apply           # act on both (provisioning runs this)
    ERGON_HARDWARE=<name> ...      # force a profile, for a VM or for debugging

## Capabilities first

Most hardware support is decided by what the machine **has**, read from sysfs,
not by what it **is**. The same install does the right thing on a Framework, a
ThinkPad, a desktop or a VM:

| capability | detected from | what is done |
|---|---|---|
| s2idle-only firmware and working hibernation | `/sys/power/mem_sleep` without `deep`; `disk` in `/sys/power/state`, `resume=` on the cmdline, active swap | lid → suspend-then-hibernate |
| a built-in panel on amdgpu | `card*-eDP-*` whose driver is amdgpu | power-profiles-daemon may not desaturate it (ABM) |
| fprintd | its unit exists | fprintd restarted after resume |
| an ambient light sensor and a backlight | `in_illuminance_*` under iio; `/sys/class/backlight/*` (the `raw` one preferred) | illuminanced on, with a generated config |
| an NVIDIA card, Turing or newer | a PCI display controller, vendor `0x10de`, device `>= 0x1e00` | the open module, prebuilt for each kernel in `/usr/lib/modules/*/pkgbase` (dkms and headers if any kernel has none); Hyprland's env in `/etc/ergon/hypr/nvidia.lua`. Older cards: nothing installed, the legacy driver named |
| NVIDIA beside another GPU | a display controller of another vendor too | `prime-run` (nvidia-prime) instead of the global env |

Every file written for a capability carries a marker line, and is removed when
the capability goes away. A file without the marker is never removed.

`ergon-sleep check` reports what the machine does when it sleeps.
`ergon-sleep cycle N` measures whether it wakes up.

## Profiles: only what one model needs

A quirk goes into a profile only when it cannot be expressed as a capability.
Say why in the file.

    match       KEY=substring, one per line. ALL must match, against the
                corresponding file in /sys/class/dmi/id/. Matching is
                case-insensitive substring, not equality, because vendors
                revise product_name between batches.
    packages    extra pacman packages, one per line, same format as
                packages/pacman
    cmdline     kernel parameters, one per line, added to GRUB's default
                cmdline (next boot). Never removed automatically.
    etc/        copied into / preserving structure, mode 644
    apply.sh    anything that is not a file drop. Runs with sudo available.
                Must be idempotent -- provisioning re-runs.

A profile that matches nothing is inert, so shipping profiles for hardware you
do not own is safe and is how this grows.
