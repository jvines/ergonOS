#!/usr/bin/env bash
# Exercise ergon-hardware and ergon-sleep against fake machines.
#
#   ./bin/test-hardware.sh
#
# Seconds, no root, no VM. Each machine is a directory standing in for / --
# sysfs, /proc and the systemd unit directory -- plus a destination tree that
# /etc and /boot are written into. sudo, pacman, systemctl and grub-mkconfig
# are stubs that log, so the assertions are about exactly what would have run.
#
# COVERS: every capability on and off (s2idle-only + hibernation,
# amdgpu panel, fprintd, light sensor + backlight), removal of a config whose
# capability went away (and never of a hand-written one), kernel parameters from
# a profile, DMI matching, and ergon-sleep check's readings.
#
# DOES NOT COVER: real sysfs, logind, fprintd or illuminanced, or an actual
# suspend. test-hypr-session.sh covers the lid on a VM made s2idle-only.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
has()  { grep -qF -- "$2" "$1" 2>/dev/null; }
hasx() { grep -qxF -- "$2" "$1" 2>/dev/null; }
not()  { ! "$@"; }

E=$T/ergon
mkdir -p "$E/bin" "$T/stub" "$T/log"
cp "$REPO/bin/ergon-hardware" "$REPO/bin/ergon-sleep" "$E/bin/"
cp -r "$REPO/hardware" "$E/"
for s in sudo pacman systemctl grub-mkconfig; do
  printf '#!/usr/bin/env bash\n' > "$T/stub/$s"
done
cat >> "$T/stub/sudo" <<'EOF'
exec "$@"
EOF
cat >> "$T/stub/pacman" <<'EOF'
printf '%s\n' "$*" >> "$TEST_ROOT/log/pacman"
EOF
cat >> "$T/stub/systemctl" <<'EOF'
printf '%s\n' "$*" >> "$TEST_ROOT/log/systemctl"
EOF
cat >> "$T/stub/grub-mkconfig" <<'EOF'
printf '%s\n' "$*" >> "$TEST_ROOT/log/grub"
EOF
chmod +x "$T/stub"/*
export TEST_ROOT=$T ERGON=$E PATH="$T/stub:$PATH"
unset ERGON_HARDWARE
[ "$(command -v sudo)" = "$T/stub/sudo" ] || { echo "stubs are not first on PATH; refusing to run"; exit 1; }

EH="$E/bin/ergon-hardware"
reset_logs() { rm -f "$T"/log/*; }
# apply <machine>: run against $T/<machine>/root, writing into $T/<machine>/dest
apply() { ERGON_SYSROOT="$T/$1/root" ERGON_DESTROOT="$T/$1/dest" "$EH" apply > "$T/out" 2>&1; }
put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }

# --- three machines -------------------------------------------------------------
# A Framework-like AMD laptop: s2idle only, hibernation set up, amdgpu eDP,
# a light sensor, two backlight interfaces of which only the raw one works.
R=$T/fw/root; D=$T/fw/dest
put "$R/sys/power/mem_sleep" "[s2idle]"
put "$R/sys/power/state" "freeze mem disk"
put "$R/proc/cmdline" "BOOT_IMAGE=/vmlinuz-linux root=/dev/mapper/cryptroot resume=/dev/mapper/cryptroot resume_offset=533760 quiet"
printf 'Filename\tType\tSize\tUsed\tPriority\n/swap/swapfile\tfile\t33554428\t0\t-2\n' > "$R/proc/swaps"
printf 'MemTotal:       32000000 kB\nSwapTotal:      33554428 kB\n' > "$R/proc/meminfo"
put "$R/sys/class/power_supply/BAT1/type" "Battery"
put "$R/sys/class/power_supply/ACAD/type" "Mains"
mkdir -p "$R/sys/class/drm/card1-eDP-1" "$R/sys/class/drm/card1/device"
ln -s ../../../../bus/pci/drivers/amdgpu "$R/sys/class/drm/card1/device/driver"
put "$R/sys/bus/iio/devices/iio:device3/in_illuminance_raw" "142"
put "$R/sys/class/backlight/acpi_video0/brightness" "0"; put "$R/sys/class/backlight/acpi_video0/type" "firmware"
put "$R/sys/class/backlight/amdgpu_bl1/brightness" "120"; put "$R/sys/class/backlight/amdgpu_bl1/type" "raw"
put "$R/sys/class/backlight/amdgpu_bl1/max_brightness" "255"
put "$R/usr/lib/systemd/system/fprintd.service" ""
put "$R/usr/lib/systemd/system/power-profiles-daemon.service" ""
put "$R/sys/class/dmi/id/sys_vendor" "Framework"
put "$R/sys/class/dmi/id/product_name" "Laptop 13 (AMD Ryzen AI 7 350 w/ Radeon 860M)"
put "$D/etc/default/grub" 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"'

# An Intel laptop: S3 available, i915 panel, no light sensor, a reader.
R=$T/tp/root; D=$T/tp/dest
put "$R/sys/power/mem_sleep" "s2idle [deep]"
put "$R/sys/power/state" "freeze mem disk"
put "$R/proc/cmdline" "root=/dev/nvme0n1p2 resume=/dev/nvme0n1p3"
printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/nvme0n1p3\tpartition\t16000000\t0\t-2\n' > "$R/proc/swaps"
put "$R/sys/class/power_supply/BAT0/type" "Battery"
mkdir -p "$R/sys/class/drm/card0-eDP-1" "$R/sys/class/drm/card0/device"
put "$R/usr/lib/systemd/system/power-profiles-daemon.service" ""
ln -s ../../../../bus/pci/drivers/i915 "$R/sys/class/drm/card0/device/driver"
put "$R/sys/class/backlight/intel_backlight/brightness" "500"; put "$R/sys/class/backlight/intel_backlight/type" "raw"
put "$R/usr/lib/systemd/system/fprintd.service" ""
put "$R/sys/class/dmi/id/sys_vendor" "LENOVO"; put "$R/sys/class/dmi/id/product_name" "21HM"
put "$D/etc/default/grub" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'

# An AMD desktop: S3, amdgpu on an external DP port, no battery, no sensor,
# no backlight, no fprintd.
R=$T/desk/root; D=$T/desk/dest
put "$R/sys/power/mem_sleep" "s2idle [deep]"
put "$R/sys/power/state" "freeze mem disk"
put "$R/proc/cmdline" "root=/dev/sda2"
printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$R/proc/swaps"
mkdir -p "$R/sys/class/drm/card0-DP-1" "$R/sys/class/drm/card0/device"
ln -s ../../../../bus/pci/drivers/amdgpu "$R/sys/class/drm/card0/device/driver"
put "$R/sys/class/dmi/id/sys_vendor" "ASUS"; put "$R/sys/class/dmi/id/product_name" "System Product Name"
put "$D/etc/default/grub" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'

echo "== a Framework-like AMD laptop"
reset_logs; apply fw; D=$T/fw/dest
check "apply succeeds" test "$?" -eq 0
check "lid: suspend-then-hibernate" hasx "$D/etc/systemd/logind.conf.d/10-lid.conf" "HandleLidSwitch=suspend-then-hibernate"
check "  with the hibernate delay" hasx "$D/etc/systemd/sleep.conf.d/10-hibernate.conf" "HibernateDelaySec=45min"
check "amdgpu panel: ABM blocked" has "$D/etc/systemd/system/power-profiles-daemon.service.d/10-no-abm.conf" "--block-action=amdgpu_panel_power"
check "fprintd: restarted after resume" hasx "$D/etc/systemd/system/ergon-fprintd-resume.service" "ExecStart=/usr/bin/systemctl try-restart fprintd.service"
check "  and enabled" hasx "$T/log/systemctl" "enable ergon-fprintd-resume.service"
check "light sensor: illuminanced installed" hasx "$T/log/pacman" "-S --needed --noconfirm illuminanced"
check "  driving the raw backlight, not the firmware one" hasx "$D/etc/illuminanced.toml" 'backlight_file = "/sys/class/backlight/amdgpu_bl1/brightness"'
check "  reading the sensor by glob, not a device number" hasx "$D/etc/illuminanced.toml" 'illuminance_file = "/sys/bus/iio/devices/iio:device*/in_illuminance_raw"'
check "  and started" hasx "$T/log/systemctl" "enable --now illuminanced.service"
check "profile matched by DMI: kernel parameter added" hasx "$D/etc/default/grub" 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet amdgpu.dcdebugmask=0x610"'
check "  and grub.cfg regenerated" hasx "$T/log/grub" "-o $D/boot/grub/grub.cfg"
check "power key: ignored by logind (ergon-session owns it)" hasx "$D/etc/systemd/logind.conf.d/10-power-key.conf" "HandlePowerKey=ignore"
reset_logs; apply fw
check "a second apply does not add the parameter twice" hasx "$D/etc/default/grub" 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet amdgpu.dcdebugmask=0x610"'
check "  nor regenerate grub.cfg" test ! -e "$T/log/grub"

echo "== an Intel laptop"
reset_logs; apply tp; D=$T/tp/dest
check "lid: logind default, because the firmware offers S3" test ! -e "$D/etc/systemd/logind.conf.d/10-lid.conf"
check "  and says why" has "$T/out" "firmware offers S3"
check "i915 panel: no ABM drop-in" test ! -e "$D/etc/systemd/system/power-profiles-daemon.service.d/10-no-abm.conf"
check "fprintd: restarted after resume" test -e "$D/etc/systemd/system/ergon-fprintd-resume.service"
check "no light sensor: no illuminanced" not has "$T/log/pacman" "illuminanced"
check "no profile matches: grub untouched" hasx "$D/etc/default/grub" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'
check "power key: ignored by logind (no S3/hibernation dependency)" hasx "$D/etc/systemd/logind.conf.d/10-power-key.conf" "HandlePowerKey=ignore"

echo "== an AMD desktop"
reset_logs; apply desk; D=$T/desk/dest
check "no lid config" test ! -e "$D/etc/systemd/logind.conf.d/10-lid.conf"
check "amdgpu without a built-in panel: no ABM drop-in" test ! -e "$D/etc/systemd/system/power-profiles-daemon.service.d/10-no-abm.conf"
check "no fprintd: no resume unit" test ! -e "$D/etc/systemd/system/ergon-fprintd-resume.service"
check "no sensor or backlight: no illuminanced" not has "$T/log/pacman" "illuminanced"
check "power key: ignored by logind on a desktop with no laptop capabilities at all" hasx "$D/etc/systemd/logind.conf.d/10-power-key.conf" "HandlePowerKey=ignore"

echo "== a pacman failure elsewhere in _capabilities must not skip the power key"
# Regression for an ordering bug: the power-key drop-in used to be the LAST
# thing _capabilities() wrote, after the illuminanced block -- which returns
# early (rc=0, no error surfaced beyond its own warn) when `pacman -S
# illuminanced` fails. On the Framework 13 (sensor + backlight, so it always
# takes that branch) a mirror hiccup, a held pacman lock or no network during
# provisioning silently left the power key at logind's default: poweroff. The
# fix moved the power-key _put to the top of the function, before anything
# that can return early; this fails if that ever regresses.
D=$T/fw/dest
rm -f "$D/etc/systemd/logind.conf.d/10-power-key.conf"
cp "$T/stub/pacman" "$T/stub/pacman.ok"
cat > "$T/stub/pacman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/pacman"
case "$*" in *illuminanced*) exit 1 ;; esac
EOF
chmod +x "$T/stub/pacman"
reset_logs; apply fw
check "illuminanced install failing is still reported" has "$T/out" "illuminanced failed to install"
check "  but the power key is ignored anyway (fw has a sensor + backlight, so it always hits this path)" \
  hasx "$D/etc/systemd/logind.conf.d/10-power-key.conf" "HandlePowerKey=ignore"
mv "$T/stub/pacman.ok" "$T/stub/pacman"

echo "== a capability that goes away"
R=$T/fw/root; D=$T/fw/dest
put "$R/proc/cmdline" "root=/dev/mapper/cryptroot quiet"           # resume= dropped
rm -rf "$R/sys/bus/iio"                                              # sensor gone
put "$D/etc/systemd/system/power-profiles-daemon.service.d/10-no-abm.conf" "# mine, by hand"
rm "$R/sys/class/drm/card1/device/driver"
reset_logs; apply fw
check "s2idle only without hibernation: the lid config is removed" test ! -e "$D/etc/systemd/logind.conf.d/10-lid.conf"
check "  and says what is missing" has "$T/out" "hibernation is not set up"
check "sensor gone: illuminanced disabled" hasx "$T/log/systemctl" "disable --now illuminanced.service"
check "  and its generated config removed" test ! -e "$D/etc/illuminanced.toml"
check "a hand-written file at a managed path is never removed" hasx "$D/etc/systemd/system/power-profiles-daemon.service.d/10-no-abm.conf" "# mine, by hand"

echo "== profiles"
mkdir -p "$E/hardware/bad-model"
printf 'sys_vendor=LENOVO\n' > "$E/hardware/bad-model/match"
printf 'quiet;touch /tmp/x\n' > "$E/hardware/bad-model/cmdline"
reset_logs; apply tp
check "a profile's malformed kernel parameter is refused" has "$T/out" "is not a kernel parameter"
check "  and grub is not touched" hasx "$T/tp/dest/etc/default/grub" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'
rm -rf "$E/hardware/bad-model"
ERGON_SYSROOT=$T/desk/root ERGON_DESTROOT=$T/desk/dest ERGON_HARDWARE=framework-13-amd "$EH" apply > "$T/out" 2>&1
check "ERGON_HARDWARE forces a profile on a machine it does not match" hasx "$T/desk/dest/etc/default/grub" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet amdgpu.dcdebugmask=0x610"'
ERGON_SYSROOT=$T/tp/root "$EH" detect > "$T/out" 2>&1
check "detect reports S3 on the Intel laptop" hasx "$T/out" "  s2idle only:  no"

echo "== ergon-sleep check"
ES="$E/bin/ergon-sleep"
R=$T/fw/root
put "$R/proc/cmdline" "root=/dev/mapper/cryptroot resume=/dev/mapper/cryptroot quiet"
put "$R/sys/power/suspend_stats/success" "3"; put "$R/sys/power/suspend_stats/fail" "0"
put "$R/sys/power/suspend_stats/last_hw_sleep" "0"
ERGON_SYSROOT=$R "$ES" check > "$T/out" 2>&1
check "s2idle-only firmware is reported" has "$T/out" "s2idle only"
check "hibernation ready" has "$T/out" "hibernation: ready"
check "a suspend that never reached hardware sleep is flagged" has "$T/out" "never reached it"
put "$R/sys/power/suspend_stats/last_hw_sleep" "27500000"
ERGON_SYSROOT=$R "$ES" check > "$T/out" 2>&1
check "hardware sleep time is reported in seconds" has "$T/out" "27.5 s in the last suspend"
ERGON_SYSROOT=$T/desk/root "$ES" check > "$T/out" 2>&1
check "no resume= on the desktop: hibernation cannot resume" has "$T/out" "no resume= on the kernel cmdline"
"$ES" cycle 0 > "$T/out" 2>&1
check "cycle rejects a count of 0" has "$T/out" "usage: ergon-sleep cycle N"

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
