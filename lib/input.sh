# Input devices found by capability, never by name (ERGON-93/138/143).
# udev flags a touchpad ID_INPUT_TOUCHPAD=1 and a touchscreen ID_INPUT_TOUCHSCREEN=1
# whatever the vendor called it. ERGON_SYS is a test seam for /sys.

ergon_input_sys() { printf '%s' "${ERGON_SYS:-/sys}"; }

# ergon_input_nodes touchpad|touchscreen -> "<sysfs input dir>|<device name>" per match
ergon_input_nodes() {
  local prop d
  case "$1" in
    touchpad)    prop=ID_INPUT_TOUCHPAD ;;
    touchscreen) prop=ID_INPUT_TOUCHSCREEN ;;
    *) return 2 ;;
  esac
  for d in "$(ergon_input_sys)"/class/input/input*; do
    [ -e "$d/name" ] || continue
    udevadm info -q property -p "$d" 2>/dev/null | grep -qx "$prop=1" || continue
    printf '%s|%s\n' "$d" "$(cat "$d/name")"
  done
}

# Hyprland names a device as libinput does, lowercased with spaces as dashes.
ergon_input_hypr_name() { printf '%s' "$1" | tr 'A-Z ' 'a-z-'; }
