# Which bootloader this machine uses, and where its kernel command line lives.
# Sourced, never run.
#
# Two layouts exist (ERGON-123):
#
#   systemd-boot  installs from ERGON-123 on. The ESP is unencrypted and holds
#                 systemd-boot and one UKI per kernel; the cmdline lives in
#                 /etc/kernel/cmdline and is baked into the UKIs, so a change
#                 means rebuilding them (mkinitcpio -P).
#   grub          installs before that. /boot is inside LUKS2, GRUB unlocks it,
#                 and the cmdline lives in /etc/default/grub. These machines
#                 keep GRUB until ERGON-125 migrates them.
#
# Every function takes the root to look under as its first argument ("" for
# the running system; ERGON_BOOTROOT when omitted), and ERGON_ESP overrides
# where the ESP is, so the tests can point both at a fixture.

ergon_boot_layout() {  # ergon_boot_layout [root] -> systemd-boot | grub | none
  local r="${1-${ERGON_BOOTROOT:-}}"
  if [ -f "$r/etc/kernel/cmdline" ]; then echo systemd-boot
  elif [ -f "$r/etc/default/grub" ]; then echo grub
  else echo none; fi
}

# The ESP's mountpoint, for the running system.
ergon_esp() {
  local m
  [ -z "${ERGON_ESP:-}" ] || { printf "%s\n" "$ERGON_ESP"; return 0; }   # tests
  for m in /efi /boot/efi /boot; do
    [ "$(findmnt -no FSTYPE "$m" 2>/dev/null)" = vfat ] || continue
    printf '%s\n' "$m"; return 0
  done
  return 1
}

ergon_cmdline_get() {  # ergon_cmdline_get [root] -> the persisted default cmdline
  local r="${1-${ERGON_BOOTROOT:-}}"
  case $(ergon_boot_layout "$r") in
    systemd-boot) sed 's/#.*//' "$r/etc/kernel/cmdline" | tr -s ' \t\n' '   ' | sed 's/^ //; s/ $//' ;;
    grub) sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$r/etc/default/grub" ;;
    *) return 1 ;;
  esac
}

ergon_cmdline_set() {  # ergon_cmdline_set <root> <cmdline>; writes with sudo
  local r="$1" new="$2"
  case $(ergon_boot_layout "$r") in
    systemd-boot)
      printf '%s\n' "$new" | sudo tee "$r/etc/kernel/cmdline" >/dev/null ;;
    grub)
      sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"|" "$r/etc/default/grub" ;;
    *) return 1 ;;
  esac
  [ "$(ergon_cmdline_get "$r")" = "$new" ]
}

# Make the persisted cmdline reach the next boot. grub: grub.cfg. systemd-boot:
# the UKIs carry it, and the snapshot entries copy it.
ergon_boot_regen() {  # ergon_boot_regen [root]
  local r="${1-${ERGON_BOOTROOT:-}}"
  case $(ergon_boot_layout "$r") in
    systemd-boot)
      sudo mkinitcpio -P >/dev/null 2>&1 || return 1
      if [ -z "$r" ] && command -v ergon-boot-entries >/dev/null 2>&1; then
        sudo ergon-boot-entries sync >/dev/null 2>&1 || true
      fi ;;
    grub) sudo grub-mkconfig -o "$r/boot/grub/grub.cfg" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Add parameters that are not there yet. Prints what it added. Returns 0 when
# something was added, 2 when everything was already present, 1 on failure.
ergon_cmdline_add() {  # ergon_cmdline_add <root> <param>...
  local r="$1"; shift
  local cur new a added=()
  cur=$(ergon_cmdline_get "$r") || return 1
  new=$cur
  for a in "$@"; do
    case " $new " in *" $a "*) ;; *) new="${new:+$new }$a"; added+=("$a") ;; esac
  done
  [ "${#added[@]}" -gt 0 ] || return 2
  ergon_cmdline_set "$r" "$new" || return 1
  printf '%s\n' "${added[*]}"
}

# True when this process can read and write the ESP: root, or a test pointing
# ERGON_ESP at a fixture. Callers re-exec through sudo otherwise.
ergon_esp_access() { [ "$(id -u)" = 0 ] || [ -n "${ERGON_ESP:-}" ]; }
