#!/usr/bin/env bash
# Runs INSIDE the freshly installed system, from the ISO, before the first boot.
#
# Added by the test harness, never by arch-bootstrap.sh. GRUB renders to the EFI
# console and the installed kernel logs to tty0, so without this a headless
# second boot is completely silent: no menu, no kernel log, no login prompt, and
# no way to tell a failed LUKS unlock from a hung kernel.
#
# A real laptop must NOT carry this — it pins a console that does not exist and
# slows every boot waiting on it.
set -euo pipefail

sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT="|GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8 |' /etc/default/grub
cat >> /etc/default/grub <<'EOF'

# added by test/arch-vm — serial console for the headless VM test
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200"
EOF

grub-mkconfig -o /boot/grub/grub.cfg
systemctl enable serial-getty@ttyS0.service

# Autologin on the serial console.
#
# HARNESS ONLY. This is not about convenience -- it removes login(1) from the
# test entirely, and with it three separate sources of flakiness that have
# nothing to do with what is under test:
#
#   * "Password: " is printed with no newline and with echo disabled, and expect
#     did not reliably see it promptly -- the password landed after login's own
#     60s timeout, which then fed it to the NEXT login prompt as a username.
#   * the login shell is zsh, so a first login opens zsh-newuser-install instead
#     of a prompt.
#   * every credential prompt is one more thing to match in a pty stream that is
#     already full of escape sequences.
#
# A real install must NEVER have this: it hands a root-capable shell to anyone
# who opens the lid. It is written here, in the harness's own script, and not in
# arch-bootstrap.sh, for exactly that reason.
VMUSER=$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)
if [ -n "$VMUSER" ]; then
  install -d /etc/systemd/system/serial-getty@ttyS0.service.d
  cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\\\u' --autologin $VMUSER --keep-baud 115200,57600,38400,9600 - \$TERM
EOF
  # A zero-byte .zshrc is what actually suppresses zsh-newuser-install. zsh runs
  # that wizard whenever the user has no zsh dotfiles, so autologin on its own
  # still lands on "Type one of the keys in parentheses" rather than a prompt.
  # The real machine gets its .zshrc from install.sh; this VM never runs it.
  install -m 644 -o "$VMUSER" -g "$VMUSER" /dev/null "/home/$VMUSER/.zshrc"
  # Prove it rather than assume it. The previous run wrote this file, reported
  # success, and still booted to a login prompt -- so print what systemd will
  # actually see.
  echo "--- drop-in written to: ---"
  ls -l /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf
  # cat the file, NOT `systemctl cat`: there is no running systemd in a chroot,
  # so that call fails, its grep matches nothing, returns 1, and set -e kills
  # the whole script -- which is exactly what happened and cost a run.
  echo "--- contents: ---"
  cat /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf
  echo "autologin configured for $VMUSER"
else
  echo "no uid-1000 user found — autologin not configured" >&2
  exit 1
fi
