#!/usr/bin/env bash
# Runs INSIDE the provisioned system, as root, at the end of the session test.
# Arms the next boot (ERGON-123) to show what a laptop shows: Plymouth's
# graphical unlock screen on the display, then greetd's automatic login.
#
# The harness's own cmdline has console=ttyS0, and Plymouth then puts its
# prompt on the serial line in text, which is what every other boot here
# types into. For this one boot a one-shot entry boots the same UKI with
# plymouth.ignore-serial-consoles, so the prompt is drawn on the virtio-gpu
# display and the harness types it on the emulated keyboard (qemu sendkey).
# systemd-boot passes the entry's options to the UKI because Secure Boot is
# off; the kernel console stays on serial for the log and the shell.
set -euo pipefail
ESP=/efi
[ -s "$ESP/EFI/ergon/linux.efi" ] || { echo "SHOT_ARMED=no (no UKI)"; exit 1; }
opts="$(cat /etc/kernel/cmdline) plymouth.ignore-serial-consoles systemd.show_status=1"
printf 'title    ergonOS (VM screenshot boot)\nsort-key ergon-zz\nuki      /EFI/ergon/linux.efi\noptions  %s\n' "$opts" \
  > "$ESP/loader/entries/ergon-shot.conf"
bootctl set-oneshot ergon-shot.conf
# The session test stopped greetd to have the display to itself; it must run
# at the next boot, which it does because it is enabled.
systemctl is-enabled greetd >/dev/null && echo "GREETD_ENABLED=yes"
grep -A3 '^\[initial_session\]' /etc/greetd/config.toml || echo "NO_INITIAL_SESSION"
echo "SHOT_ARMED=yes"
