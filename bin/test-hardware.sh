#!/usr/bin/env bash
# Exercise ergon-hardware, ergon-battery, ergon-sleep and ergon-display against
# fake machines.
#
#   ./bin/test-hardware.sh
#
# Seconds, no root, no VM. Each machine is a directory standing in for / --
# sysfs, /proc and the systemd unit directory -- plus a destination tree that
# /etc and /boot are written into. sudo, pacman, systemctl, grub-mkconfig and
# notify-send are stubs that log, so the assertions are about exactly what
# would have run.
#
# COVERS: every capability on and off (s2idle-only + hibernation, amdgpu
# panel, fprintd, light sensor + backlight, an NVIDIA card -- Turing,
# pre-Turing, hybrid, an iGPU beside a card that drives the display, a kernel
# with no prebuilt module, either kind of module already installed, a failed
# download -- and that UPower's
# CriticalPowerAction is never overridden -- see ergon-hardware for why),
# removal of a config whose capability went away (and never of a
# hand-written one), kernel parameters from a profile, DMI matching,
# ergon-sleep check's readings, battery discovery by
# /sys/class/power_supply/*/type rather than by name (excluding scope=Device
# peripherals), energy-weighted capacity across differently sized packs, and
# ergon-battery's low/critical notification thresholds (once per crossing,
# only while discharging), and what ergon-display lets into hyprctl eval.
#
# DOES NOT COVER: real sysfs, logind, fprintd, illuminanced or upowerd itself,
# an NVIDIA module loading, or an actual suspend. test-hypr-session.sh covers
# the lid on a VM made s2idle-only; test-hypr-config.sh, that Hyprland loads
# the NVIDIA env file; test/arch-vm/guest-desktop.sh mirrors onto a real
# output.
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
cp "$REPO/bin/ergon-hardware" "$REPO/bin/ergon-sleep" "$REPO/bin/ergon-battery" "$E/bin/"
cp -r "$REPO/hardware" "$REPO/lib" "$E/"
cp "$REPO/bin/ergon-gpu" "$E/bin/"
# ergon-aur is stubbed: it builds from the AUR. It records what it was asked for.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$TEST_ROOT/log/aur"\n[ ! -e "$TEST_ROOT/aur-fails" ]\n' > "$E/bin/ergon-aur"; chmod +x "$E/bin/ergon-aur"
for s in sudo pacman systemctl grub-mkconfig notify-send mkinitcpio; do
  printf '#!/usr/bin/env bash\n' > "$T/stub/$s"
done
cat >> "$T/stub/sudo" <<'EOF'
exec "$@"
EOF
# -Q answers from $TEST_ROOT/installed, one package per line and then what it
# provides: pacman -Q answers for a provided name too (measured). With
# $TEST_ROOT/pacman-fails, every -S fails, as it does offline.
cat >> "$T/stub/pacman" <<'EOF'
case $1 in -Q*) awk -v n="${!#}" 'index(" " $0 " ", " " n " ") { print $1; f = 1; exit } END { exit !f }' "$TEST_ROOT/installed" 2>/dev/null; exit ;; esac
printf '%s\n' "$*" >> "$TEST_ROOT/log/pacman"
case $1 in -S*) [ ! -e "$TEST_ROOT/pacman-fails" ] ;; esac
EOF
cat >> "$T/stub/systemctl" <<'EOF'
printf '%s\n' "$*" >> "$TEST_ROOT/log/systemctl"
EOF
cat >> "$T/stub/grub-mkconfig" <<'EOF'
printf '%s\n' "$*" >> "$TEST_ROOT/log/grub"
EOF
cat >> "$T/stub/mkinitcpio" <<'EOF'
printf '%s\n' "$*" >> "$TEST_ROOT/log/mkinitcpio"
EOF
cat >> "$T/stub/notify-send" <<'EOF'
printf '%s\n' "$*" >> "$TEST_ROOT/log/notify"
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
# pci <root> <slot> <class> <vendor> <device> [boot_vga]; kernel <root> <release> <pkgbase>
pci() { put "$1/sys/bus/pci/devices/$2/class" "$3"; put "$1/sys/bus/pci/devices/$2/vendor" "$4"
        put "$1/sys/bus/pci/devices/$2/device" "$5"; [ -z "${6:-}" ] || put "$1/sys/bus/pci/devices/$2/boot_vga" "$6"; }
kernel() { put "$1/usr/lib/modules/$2/pkgbase" "$3"; }

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
put "$R/sys/class/power_supply/BAT1/capacity" "84"
put "$R/sys/class/power_supply/BAT1/status" "Full"
put "$R/sys/class/power_supply/ACAD/type" "Mains"
mkdir -p "$R/sys/class/drm/card1-eDP-1" "$R/sys/class/drm/card1/device"
ln -s ../../../../bus/pci/drivers/amdgpu "$R/sys/class/drm/card1/device/driver"
put "$R/sys/bus/iio/devices/iio:device3/in_illuminance_raw" "142"
put "$R/sys/class/backlight/acpi_video0/brightness" "0"; put "$R/sys/class/backlight/acpi_video0/type" "firmware"
put "$R/sys/class/backlight/amdgpu_bl1/brightness" "120"; put "$R/sys/class/backlight/amdgpu_bl1/type" "raw"
put "$R/sys/class/backlight/amdgpu_bl1/max_brightness" "255"
put "$R/usr/lib/systemd/system/fprintd.service" ""
put "$R/usr/lib/systemd/system/power-profiles-daemon.service" ""
put "$R/usr/lib/systemd/system/upower.service" ""
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
put "$R/sys/class/power_supply/BAT0/capacity" "63"
put "$R/sys/class/power_supply/BAT0/status" "Charging"
mkdir -p "$R/sys/class/drm/card0-eDP-1" "$R/sys/class/drm/card0/device"
pci "$R" 0000:00:02.0 0x030000 0x8086 0x9b41 1
put "$R/usr/lib/systemd/system/power-profiles-daemon.service" ""
put "$R/usr/lib/systemd/system/upower.service" ""
ln -s ../../../../bus/pci/drivers/i915 "$R/sys/class/drm/card0/device/driver"
put "$R/sys/class/backlight/intel_backlight/brightness" "500"; put "$R/sys/class/backlight/intel_backlight/type" "raw"
put "$R/usr/lib/systemd/system/fprintd.service" ""
put "$R/sys/class/dmi/id/sys_vendor" "LENOVO"; put "$R/sys/class/dmi/id/product_name" "21HM"
put "$D/etc/default/grub" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'

# An AMD desktop: S3, amdgpu on an external DP port, no battery, no sensor,
# no backlight, no fprintd, no NVIDIA.
R=$T/desk/root; D=$T/desk/dest
put "$R/sys/power/mem_sleep" "s2idle [deep]"
put "$R/sys/power/state" "freeze mem disk"
put "$R/proc/cmdline" "root=/dev/sda2"
printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$R/proc/swaps"
mkdir -p "$R/sys/class/drm/card0-DP-1" "$R/sys/class/drm/card0/device"
ln -s ../../../../bus/pci/drivers/amdgpu "$R/sys/class/drm/card0/device/driver"
pci "$R" 0000:03:00.0 0x030000 0x1002 0x744c 1
put "$R/sys/class/dmi/id/sys_vendor" "ASUS"; put "$R/sys/class/dmi/id/product_name" "System Product Name"
put "$D/etc/default/grub" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'

echo "== a Framework-like AMD laptop"
reset_logs; apply fw; D=$T/fw/dest
check "apply succeeds" test "$?" -eq 0
check "lid: suspend-then-hibernate" hasx "$D/etc/systemd/logind.conf.d/10-lid.conf" "HandleLidSwitch=suspend-then-hibernate"
check "  with the hibernate delay" hasx "$D/etc/systemd/sleep.conf.d/10-hibernate.conf" "HibernateDelaySec=45min"
check "battery: no UPower CriticalPowerAction override -- Auto already does the right thing (see ergon-hardware)" \
  test ! -e "$D/etc/UPower/UPower.conf.d/90-ergon-hibernate.conf"
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

echo "== the same laptop on systemd-boot (ERGON-123)"
# The cmdline lives in /etc/kernel/cmdline and is baked into the UKIs, so a
# profile parameter means a rebuild, not grub-mkconfig.
mkdir -p "$T/sdb/dest/etc/kernel"; cp -r "$T/fw/root" "$T/sdb/root"
printf 'root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet splash\n' > "$T/sdb/dest/etc/kernel/cmdline"
reset_logs; apply sdb; D=$T/sdb/dest
check "profile parameter added to /etc/kernel/cmdline" hasx "$D/etc/kernel/cmdline" 'root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet splash amdgpu.dcdebugmask=0x610'
check "  and the UKIs rebuilt" hasx "$T/log/mkinitcpio" "-P"
check "  and no grub-mkconfig" test ! -e "$T/log/grub"
reset_logs; apply sdb
check "a second apply adds nothing" hasx "$D/etc/kernel/cmdline" 'root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet splash amdgpu.dcdebugmask=0x610'
check "  and rebuilds nothing" test ! -e "$T/log/mkinitcpio"

echo "== an Intel laptop"
reset_logs; apply tp; D=$T/tp/dest
check "lid: logind default, because the firmware offers S3" test ! -e "$D/etc/systemd/logind.conf.d/10-lid.conf"
check "  and says why" has "$T/out" "firmware offers S3"
check "battery: still no UPower override, independently of the lid decision or upower.service being present" \
  test ! -e "$D/etc/UPower/UPower.conf.d/90-ergon-hibernate.conf"
check "i915 panel: no ABM drop-in" test ! -e "$D/etc/systemd/system/power-profiles-daemon.service.d/10-no-abm.conf"
check "fprintd: restarted after resume" test -e "$D/etc/systemd/system/ergon-fprintd-resume.service"
check "no light sensor: no illuminanced" not has "$T/log/pacman" "illuminanced"
check "Intel GPU: vulkan-intel and the media driver installed" hasx "$T/log/pacman" "-S --needed --noconfirm vulkan-intel intel-media-driver"
check "  an Intel-only machine gets no AMD package (ERGON-71: 'ati' is a substring of 'Corporation')" not has "$T/log/pacman" "vulkan-radeon"
check "no profile matches: grub untouched" hasx "$D/etc/default/grub" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'
check "power key: ignored by logind (no S3/hibernation dependency)" hasx "$D/etc/systemd/logind.conf.d/10-power-key.conf" "HandlePowerKey=ignore"

echo "== an AMD desktop"
reset_logs; apply desk; D=$T/desk/dest
check "no lid config" test ! -e "$D/etc/systemd/logind.conf.d/10-lid.conf"
check "no resume=, no swap: no UPower hibernate drop-in" test ! -e "$D/etc/UPower/UPower.conf.d/90-ergon-hibernate.conf"
check "amdgpu without a built-in panel: no ABM drop-in" test ! -e "$D/etc/systemd/system/power-profiles-daemon.service.d/10-no-abm.conf"
check "no fprintd: no resume unit" test ! -e "$D/etc/systemd/system/ergon-fprintd-resume.service"
check "no sensor or backlight: no illuminanced" not has "$T/log/pacman" "illuminanced"
check "an AMD GPU and no NVIDIA: no NVIDIA package" not has "$T/log/pacman" "nvidia"
check "an AMD GPU: vulkan-radeon installed" hasx "$T/log/pacman" "-S --needed --noconfirm vulkan-radeon"
check "  and no Intel package" not has "$T/log/pacman" "vulkan-intel"
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
put "$D/etc/UPower/UPower.conf.d/90-ergon-hibernate.conf" "# mine, by hand"
rm "$R/sys/class/drm/card1/device/driver"
reset_logs; apply fw
check "s2idle only without hibernation: the lid config is removed" test ! -e "$D/etc/systemd/logind.conf.d/10-lid.conf"
check "  and says what is missing" has "$T/out" "hibernation is not set up"
check "sensor gone: illuminanced disabled" hasx "$T/log/systemctl" "disable --now illuminanced.service"
check "  and its generated config removed" test ! -e "$D/etc/illuminanced.toml"
check "a hand-written file at a managed path is never removed" hasx "$D/etc/systemd/system/power-profiles-daemon.service.d/10-no-abm.conf" "# mine, by hand"
check "  same for a hand-written UPower drop-in at our managed path" hasx "$D/etc/UPower/UPower.conf.d/90-ergon-hibernate.conf" "# mine, by hand"

echo "== NVIDIA"
# A Turing desktop. The card's HDMI audio is vendor 0x10de too and the chipset's
# USB controller is another vendor: neither is a GPU, so this is not hybrid.
R=$T/nv/root; NV=$T/nv/dest/etc/ergon/hypr/nvidia.lua
pci "$R" 0000:01:00.0 0x030000 0x10de 0x1f08 1
pci "$R" 0000:01:00.1 0x040300 0x10de 0x10f9
pci "$R" 0000:02:00.0 0x0c0330 0x1022 0x43ee
kernel "$R" 7.2.7-arch1-1 linux; kernel "$R" 6.18.54-1-lts linux-lts
mkdir -p "$R/usr/lib/modules/7.1.9-arch1-1"   # left by an upgrade, no pkgbase
echo "nvidia-open-dkms nvidia-open" > "$T/installed"   # what provisioning used to install, and what it provides
reset_logs; apply nv
check "Turing: a prebuilt module for each installed kernel, and the VA-API driver" \
  hasx "$T/log/pacman" "-S --needed --noconfirm -- nvidia-open nvidia-open-lts libva-nvidia-driver"
check "  after removing the dkms package, which conflicts and built nothing -- once its replacement is downloaded" \
  test "$(head -2 "$T/log/pacman" | tr '\n' '|')" = "-Sw --needed --noconfirm -- nvidia-open nvidia-open-lts|-Rdd --noconfirm -- nvidia-open-dkms|"
check "  Hyprland env: LIBVA_DRIVER_NAME" hasx "$NV" 'hl.env("LIBVA_DRIVER_NAME", "nvidia")'
check "  __GLX_VENDOR_LIBRARY_NAME" hasx "$NV" 'hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")'
check "  NVD_BACKEND" hasx "$NV" 'hl.env("NVD_BACKEND", "direct")'
check "  the marker on line 1, the only line Lua skips" has <(head -1 "$NV") "# Written by ergon-hardware"
check "  at the path hypr/common/env.lua loads" has "$REPO/hypr/common/env.lua" 'pcall(require, "/etc/ergon/hypr/nvidia")'
check "  open modules: modeset+fbdev in modprobe.d, modules early, no sleep services (kernel notifiers do it)" \
  test "$(cat "$T/nv/dest/etc/modprobe.d/ergon-nvidia.conf" | tail -1)" = "options nvidia_drm modeset=1 fbdev=1" -a ! -e "$T/log/systemctl"
check "  Turing: the AUR is not touched" test ! -e "$T/log/aur"
check "  NVIDIA-only: the kms-dropping initramfs drop-in, and one rebuild" \
  test -e "$T/nv/dest/etc/mkinitcpio.conf.d/ergon-nvidia.conf" -a "$(wc -l < "$T/log/mkinitcpio")" = 1
touch "$T/pacman-fails"; reset_logs; apply nv
check "downloads failing: the dkms package stays" not has "$T/log/pacman" "-Rdd"
check "  the env goes, with no module for it to point at" test ! -e "$NV"
check "  and it says so rather than ok" has "$T/out" "NVIDIA packages failed"
rm "$T/pacman-fails"
kernel "$R" 7.2.7-zen1-1-zen linux-zen
reset_logs; apply nv
check "a kernel with no prebuilt module: dkms for every kernel, with their headers" \
  hasx "$T/log/pacman" "-S --needed --noconfirm -- nvidia-open-dkms linux-headers linux-lts-headers linux-zen-headers libva-nvidia-driver"
check "  and the dkms package is kept" not has "$T/log/pacman" "-Rdd"
printf 'nvidia-open\nnvidia-open-lts\n' > "$T/installed"
reset_logs; apply nv
check "  over prebuilt ones, they go once dkms is downloaded" \
  test "$(head -2 "$T/log/pacman" | tr '\n' '|')" = "-Sw --needed --noconfirm -- nvidia-open-dkms linux-headers linux-lts-headers linux-zen-headers|-Rdd --noconfirm -- nvidia-open nvidia-open-lts|"
rm -rf "$R/usr/lib/modules"
reset_logs; apply nv
check "no kernel with a pkgbase: nothing installed or removed" test ! -e "$T/log/pacman"
check "  and no env" test ! -e "$NV"
rm -f "$T/installed"; rm -rf "$R/sys/bus/pci/devices/0000:01:00.0"
put "$NV" "# Written by ergon-hardware from what this machine has; removed when that stops being true."
reset_logs; apply nv
check "card gone: the env file goes too" test ! -e "$NV"

R=$T/pascal/root; PD=$T/pascal/dest
pci "$R" 0000:01:00.0 0x030000 0x10de 0x1b80 1
kernel "$R" 7.2.7-arch1-1 linux; kernel "$R" 6.18.54-1-lts linux-lts
echo "nvidia-open-dkms nvidia-open" > "$T/installed"
reset_logs; apply pascal
check "Pascal: headers for every kernel, then the pinned 580xx build from the AUR" \
  test "$(cat "$T/log/pacman" "$T/log/aur" 2>/dev/null | tr '\n' '|')" = "-S --needed --noconfirm -- linux-headers linux-lts-headers|-Rdd --noconfirm -- nvidia-open-dkms|nvidia-580xx-utils|"
check "  no GSP-only package (nvidia-open), and no AMD or Intel one" not has "$T/log/pacman" "vulkan-"
check "  Hyprland env: GLX only, no libva-nvidia-driver to point LIBVA at" hasx "$PD/etc/ergon/hypr/nvidia.lua" 'hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")'
check "  and not LIBVA_DRIVER_NAME" not has "$PD/etc/ergon/hypr/nvidia.lua" LIBVA
check "  the 580xx sleep services enabled (it preserves video memory through them)" \
  hasx "$T/log/systemctl" "enable nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service"
check "  early KMS: modeset and fbdev in modprobe.d" hasx "$PD/etc/modprobe.d/ergon-nvidia.conf" "options nvidia_drm modeset=1 fbdev=1"
check "  nvidia modules in the initramfs" has "$PD/etc/mkinitcpio.conf.d/ergon-nvidia.conf" "MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)"
check "  and the initramfs rebuilt, once" test "$(wc -l < "$T/log/mkinitcpio")" = 1
reset_logs; apply pascal
check "  a second run changes nothing: no rebuild" test ! -e "$T/log/mkinitcpio"
touch "$T/aur-fails"; reset_logs; rm -rf "$PD/etc"; apply pascal; rm "$T/aur-fails"
check "  the build failing: warned, no env, no early modules (the card has no driver)" \
  test ! -e "$PD/etc/ergon/hypr/nvidia.lua" -a ! -e "$PD/etc/mkinitcpio.conf.d/ergon-nvidia.conf"
check "  and it says so" has "$T/out" "failed to build"
rm -f "$T/installed"
# the drop-in is real shell: run it as mkinitcpio would, against fake PCI trees
reset_logs; apply pascal
hooks() { ( HOOKS=(base systemd autodetect microcode modconf kms keyboard block filesystems); MODULES=()
            ERGON_PCI_DEVICES=$1; . "$2"; echo "${HOOKS[*]} // ${MODULES[*]}" ); }
check "  kms dropped when NVIDIA owns every display controller" \
  test "$(hooks "$R/sys/bus/pci/devices" "$PD/etc/mkinitcpio.conf.d/ergon-nvidia.conf")" = "base systemd autodetect microcode modconf keyboard block filesystems // nvidia nvidia_modeset nvidia_uvm nvidia_drm"
pci "$R" 0000:00:02.0 0x030000 0x8086 0x9b41 0
check "  kept when anything else is a display controller" \
  has <(hooks "$R/sys/bus/pci/devices" "$PD/etc/mkinitcpio.conf.d/ergon-nvidia.conf") " kms "
mkdir -p "$T/unreadable/0000:00:02.0"
check "  kept when a device cannot be read (it could be another GPU)" has <(hooks "$T/unreadable" "$PD/etc/mkinitcpio.conf.d/ergon-nvidia.conf") " kms "
rm -rf "$R/sys/bus/pci/devices/0000:00:02.0"

# Kepler: no driver exists for it here
R=$T/kepler/root
pci "$R" 0000:01:00.0 0x030000 0x10de 0x1180 1
kernel "$R" 7.2.7-arch1-1 linux
echo nvidia-utils > "$T/installed"; reset_logs; apply kepler; rm "$T/installed"
check "Kepler: refused, nothing installed, nothing built" test ! -e "$T/log/pacman" -a ! -e "$T/log/aur"
check "  naming why" has "$T/out" "older than Maxwell"
check "  and that nvidia-utils is left over, blacklisting nouveau" has "$T/out" "blacklists nouveau, so the card has no driver"
check "  no env, no early modules, no rebuild" test ! -e "$T/kepler/dest/etc/ergon/hypr/nvidia.lua" -a ! -e "$T/kepler/dest/etc/modprobe.d/ergon-nvidia.conf" -a ! -e "$T/log/mkinitcpio"
ERGON_SYSROOT=$R "$EH" detect > "$T/out" 2>&1
check "  detect says none" hasx "$T/out" "  nvidia driver: none"

# A desktop whose monitors are on the NVIDIA card (boot_vga), with the CPU's
# iGPU left on and a BMC's VGA beside it: more display controllers, not hybrid.
R=$T/am5/root
pci "$R" 0000:01:00.0 0x030000 0x10de 0x2684 1
pci "$R" 0000:10:00.0 0x030000 0x1002 0x164e 0
pci "$R" 0000:05:00.0 0x030000 0x1a03 0x2000 0
kernel "$R" 7.2.7-arch1-1 linux
reset_logs; apply am5
check "NVIDIA drives the display beside an iGPU and a BMC: the global env, no prime-run" \
  hasx "$T/log/pacman" "-S --needed --noconfirm -- nvidia-open libva-nvidia-driver"
check "  and the env file" test -e "$T/am5/dest/etc/ergon/hypr/nvidia.lua"
check "  the idle AMD iGPU still gets its ICD (ERGON-71: a second _gpus | grep -q used to SIGPIPE the first)" \
  hasx "$T/log/pacman" "-S --needed --noconfirm vulkan-radeon"

# A laptop: Intel drives the panel, the NVIDIA card is a 3D controller.
R=$T/hyb/root
pci "$R" 0000:00:02.0 0x030000 0x8086 0x7d55 1
pci "$R" 0000:01:00.0 0x030200 0x10de 0x2820
kernel "$R" 7.2.7-arch1-1 linux
put "$T/hyb/dest/etc/ergon/hypr/nvidia.lua" "# Written by ergon-hardware from what this machine has; removed when that stops being true."
reset_logs; apply hyb
check "hybrid: the module, and prime-run for offload" hasx "$T/log/pacman" "-S --needed --noconfirm -- nvidia-open nvidia-prime"
check "  no global env, which would put every GL client on the dGPU" test ! -e "$T/hyb/dest/etc/ergon/hypr/nvidia.lua"
check "  hybrid: the iGPU keeps the kms hook (no NVIDIA initramfs drop-in), modeset still set" \
  test ! -e "$T/hyb/dest/etc/mkinitcpio.conf.d/ergon-nvidia.conf" -a -e "$T/hyb/dest/etc/modprobe.d/ergon-nvidia.conf"
check "  the panel's Intel iGPU gets its ICD too (ERGON-71: grep -q's early exit used to SIGPIPE _gpus)" \
  hasx "$T/log/pacman" "-S --needed --noconfirm vulkan-intel intel-media-driver"
ERGON_SYSROOT=$R "$EH" detect > "$T/out" 2>&1
check "detect names the card" hasx "$T/out" "  nvidia:       0x2820"
check "  and the hybrid" hasx "$T/out" "  hybrid gpu:   yes"
ERGON_SYSROOT=$T/desk/root "$EH" detect > "$T/out" 2>&1
check "an AMD GPU alone is not hybrid" hasx "$T/out" "  hybrid gpu:   no"

echo "== ergon gpu"
GPU="$E/bin/ergon-gpu"
R=$T/hyb/root
mkdir -p "$R/sys/class/drm/card0-eDP-1" "$R/sys/class/drm/card0" "$R/sys/class/drm/card1-DP-1" "$R/sys/class/drm/card1"
put "$R/sys/class/drm/card0-eDP-1/status" connected; put "$R/sys/class/drm/card1-DP-1/status" disconnected
ln -s ../../../bus/pci/devices/0000:00:02.0 "$R/sys/class/drm/card0/device"
ln -s ../../../bus/pci/devices/0000:01:00.0 "$R/sys/class/drm/card1/device"
ERGON_SYSROOT=$R "$GPU" > "$T/out" 2>&1
check "hybrid: the iGPU is primary and owns the panel" has "$T/out" "Intel  0x7d55 0000:00:02.0"
check "  with its connected output named" has "$T/out" "primary: the compositor renders here; outputs: eDP-1"
check "  the NVIDIA card secondary, with no outputs" has "$T/out" "secondary"
check "  prime-run is the offload" has "$T/out" "prime-run <program>"
ERGON_SYSROOT=$R PATH="$T/stub:/usr/bin:/bin" "$GPU" --doctor > "$T/out" 2>&1
check "doctor: module not loaded is a warning" hasx "$T/out" "warn|nvidia-driver|NVIDIA 0x2820 is present but the nvidia module is not loaded (open branch): dkms status; sudo ergon hardware apply"
check "  modeset off is a warning" has "$T/out" "warn|nvidia-modeset|"
mkdir -p "$R/sys/module/nvidia/"; put "$R/sys/module/nvidia_drm/parameters/modeset" Y
ERGON_SYSROOT=$R PATH="$T/stub:/usr/bin:/bin" "$GPU" --doctor > "$T/out" 2>&1
check "  loaded with modeset: ok rows" has "$T/out" "ok|nvidia-modeset|nvidia_drm.modeset=1"
check "  open modules: sleep needs no services" has "$T/out" "ok|nvidia-sleep|open modules"
check "  hybrid without prime-run warns" has "$T/out" "warn|gpu-offload|"
ERGON_SYSROOT=$T/desk/root "$GPU" --doctor > "$T/out" 2>&1
check "an AMD-only machine gets no NVIDIA rows" test ! -s "$T/out"
ERGON_SYSROOT=$T/desk/root "$GPU" > "$T/out" 2>&1
check "  and a status with the amdgpu GPU listed" has "$T/out" "AMD"
ERGON_SYSROOT=$T/pascal/root "$GPU" --doctor > "$T/out" 2>&1
check "580xx: sleep services are checked (stubbed systemctl says enabled)" has "$T/out" "ok|nvidia-sleep|nvidia-suspend, -hibernate, -resume enabled"
ERGON_SYSROOT=$T/kepler/root "$GPU" --doctor > "$T/out" 2>&1
check "Kepler: one warning, no driver rows" test "$(wc -l < "$T/out")" = 1 -a "$(cut -d'|' -f1 "$T/out")" = warn

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

echo "== ergon-battery: discovery"
EB="$E/bin/ergon-battery"
check "found via type=Battery on BAT1, not a BAT1 hardcode" \
  test "$(ERGON_SYSROOT=$T/fw/root "$EB" --short)" = "84%"
check "  and equally via BAT0 on another machine" \
  test "$(ERGON_SYSROOT=$T/tp/root "$EB" --short)" = "63%"
check "no battery at all (a desktop): --short says AC, not empty" \
  test "$(ERGON_SYSROOT=$T/desk/root "$EB" --short)" = "AC"

# A Logitech-style peripheral (hidpp_battery_N) is type=Battery too, but
# scope=Device -- it must never be blended into the system reading, nor let
# its own Discharging flip the machine's status.
put "$T/fw/root/sys/class/power_supply/hidpp_battery_0/type" "Battery"
put "$T/fw/root/sys/class/power_supply/hidpp_battery_0/scope" "Device"
put "$T/fw/root/sys/class/power_supply/hidpp_battery_0/capacity" "12"
put "$T/fw/root/sys/class/power_supply/hidpp_battery_0/status" "Discharging"
check "a scope=Device peripheral (mouse) at 12% Discharging is ignored -- still 84%, not blended" \
  test "$(ERGON_SYSROOT=$T/fw/root "$EB" --short)" = "84%"
check "  and status stays Full, not the mouse's Discharging" \
  test "$(ERGON_SYSROOT=$T/fw/root "$EB" status)" = "84% (Full)"

put "$T/desk/root/sys/class/power_supply/hidpp_battery_0/type" "Battery"
put "$T/desk/root/sys/class/power_supply/hidpp_battery_0/scope" "Device"
put "$T/desk/root/sys/class/power_supply/hidpp_battery_0/capacity" "12"
put "$T/desk/root/sys/class/power_supply/hidpp_battery_0/status" "Discharging"
check "a desktop with only a peripheral battery is still AC, not the mouse's 12%" \
  test "$(ERGON_SYSROOT=$T/desk/root "$EB" --short)" = "AC"

# Two real packs of different size (a 24 Wh internal cell at 30%, a 72 Wh
# external one empty): capacity must be energy-weighted (7.5%, rounding to
# 8%), not a plain per-battery average (which would read 15%).
PR=$T/pack/root
put "$PR/sys/class/power_supply/BAT0/type" "Battery"
put "$PR/sys/class/power_supply/BAT0/capacity" "30"
put "$PR/sys/class/power_supply/BAT0/status" "Discharging"
put "$PR/sys/class/power_supply/BAT0/energy_full" "24000000"
put "$PR/sys/class/power_supply/BAT0/energy_now" "7200000"
put "$PR/sys/class/power_supply/BAT1/type" "Battery"
put "$PR/sys/class/power_supply/BAT1/capacity" "0"
put "$PR/sys/class/power_supply/BAT1/status" "Discharging"
put "$PR/sys/class/power_supply/BAT1/energy_full" "72000000"
put "$PR/sys/class/power_supply/BAT1/energy_now" "0"
check "differently sized packs: energy-weighted (8%), not a plain 15% average" \
  test "$(ERGON_SYSROOT=$PR "$EB" --short)" = "8%"

echo "== ergon-battery: notification thresholds"
BR=$T/batt/root
mkbatt() { put "$BR/sys/class/power_supply/BAT0/type" "Battery"
           put "$BR/sys/class/power_supply/BAT0/capacity" "$1"
           put "$BR/sys/class/power_supply/BAT0/status" "$2"; }
XS=$T/xdg   # a state dir private to this block, so crossings here don't
            # interact with the discovery calls above
runcheck() { rm -f "$T/log/notify"
             ERGON_SYSROOT="$BR" XDG_STATE_HOME="$XS" "$EB" check > "$T/out" 2>&1; }

mkbatt 84 Discharging; runcheck
check "well above 15%: no notification" test ! -e "$T/log/notify"

mkbatt 14 Discharging; runcheck
check "crossing 15%: low notification" has "$T/log/notify" "Battery low: 14%"
check "  without -u critical" not has "$T/log/notify" "critical"

runcheck   # same 14%, second tick
check "same level a tick later: not renotified (once per crossing, not per minute)" \
  test ! -e "$T/log/notify"

mkbatt 9 Discharging; runcheck
check "still under 15%, above 7%: still no repeat" test ! -e "$T/log/notify"

mkbatt 6 Discharging; runcheck
check "crossing 7%: critical notification" has "$T/log/notify" "Battery critical: 6%"
check "  with -u critical, matching mako/config.in's urgency=critical section" \
  has "$T/log/notify" "-u critical"

runcheck
check "same critical level a tick later: not renotified" test ! -e "$T/log/notify"

mkbatt 6 Charging; runcheck
check "plugged in at 6%: no notification -- only while discharging" test ! -e "$T/log/notify"

mkbatt 50 Discharging; runcheck   # back above the low threshold: crossing resets
mkbatt 6 Discharging; runcheck
check "discharging again after recovering above 15%: crosses and warns again" \
  has "$T/log/notify" "Battery critical: 6%"

echo "== ergon-battery: help and unknown commands"
"$EB" -h > "$T/out" 2>&1; rc=$?
check "-h exits 0" test "$rc" -eq 0
check "  and prints its own usage" has "$T/out" "ergon:group=power"
"$EB" bogus > "$T/out" 2>&1; rc=$?
check "an unknown subcommand is refused, not silently ignored" test "$rc" -ne 0

echo "== ergon-display: what reaches hyprctl eval, which runs it as Lua"
# hyprctl answers from $T/mons (enabled outputs) and $T/all (mirrors too). With
# $T/refuse, eval answers the way Hyprland answers bad Lua: "error: ...", exit 7.
cp "$REPO/bin/ergon-display" "$E/bin/"
cat > "$T/stub/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/hyprctl"
case "$1 $2" in
  "monitors -j")  cat "$TEST_ROOT/mons" ;;
  "monitors all") cat "$TEST_ROOT/all" ;;
  eval*) [ ! -e "$TEST_ROOT/refuse" ] || { echo "error: refused"; exit 7; }; echo ok ;;
esac
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$TEST_ROOT/log/makoctl"\n' > "$T/stub/makoctl"
chmod +x "$T/stub/hyprctl" "$T/stub/makoctl"
SAVED=$T/run/ergon/display.lua
disp() { reset_logs; HYPRLAND_INSTANCE_SIGNATURE=t XDG_RUNTIME_DIR="$T/run" "$E/bin/ergon-display" "$@" > "$T/out" 2>&1; }
mons() { printf '%s\n' "$1" > "$T/mons"; printf '%s\n' "${2:-$1}" > "$T/all"; }

# A name is Lua source once it is inside the eval, so one that closes the
# string must never get there -- as the source or as the output mirroring it.
for m in '[{"name":"eDP-1\"})os.execute(\"id","focused":true},{"name":"HDMI-A-1"}]' \
         '[{"name":"eDP-1","focused":true},{"name":"HDMI-A-1\"})os.execute(\"id"}]'; do
  mons "$m"; disp mirror; rc=$?
  check "an output name that closes the Lua string fails the mirror (rc $rc)" test "$rc" -ne 0
  check "  and never reaches eval" not has "$T/log/hyprctl" "os.execute"
done

mons '[{"name":"DP-2","focused":true},{"name":"eDP-1"},{"name":"HDMI-A-1"}]'
disp mirror
check "mirror: the laptop panel is the source even unfocused" \
  hasx "$SAVED" 'hl.monitor({ output = "HDMI-A-1", mirror = "eDP-1" })'
check "  and every other output mirrors it, saved for the next reload" \
  hasx "$SAVED" 'hl.monitor({ output = "DP-2", mirror = "eDP-1" })'

mons '[{"name":"eDP-1","focused":true}]' '[{"name":"eDP-1","mirrorOf":"none"},{"name":"HDMI-A-1","mirrorOf":"0"}]'
touch "$T/refuse"; disp extend; rc=$?; rm -f "$T/refuse"
check "extend: a refused unmirror fails (rc $rc)" test "$rc" -ne 0
check "  and keeps the saved mirror, which is still live" has "$SAVED" '"HDMI-A-1", mirror'
check "  and do-not-disturb" not has "$T/log/makoctl" "do-not-disturb"
disp extend
check "extend: every saved mirror goes, unplugged outputs' too" not has "$SAVED" "mirror ="
check "  and do-not-disturb ends" hasx "$T/log/makoctl" "mode -r do-not-disturb"

mons '[{"name":"eDP-1","focused":true},{"name":"HDMI-A-1"}]'
touch "$T/refuse"; disp present; rc=$?; rm -f "$T/refuse"
check "present: a refused mirror fails (rc $rc)" test "$rc" -ne 0
check "  saves no rule and leaves notifications on" \
  bash -c '! [ -s "$1" ] && ! [ -e "$2" ]' _ "$SAVED" "$T/log/makoctl"

# The steps a mode does not divide by are skipped: Hyprland would round them.
mons '[{"name":"DP-1","focused":true,"width":2560,"height":1440,"scale":2}]'
disp scale +
check "scale + on 2560x1440 goes 2 -> 4: 3 leaves a fractional pixel" \
  hasx "$SAVED" 'hl.monitor({ output = "DP-1", scale = "4" })'
mons '[{"name":"LVDS-1","focused":true,"width":1366,"height":768,"scale":1}]'
disp scale +
check "  and 1366x768 goes 1 -> 2, past 1.25 and 1.6" \
  hasx "$SAVED" 'hl.monitor({ output = "LVDS-1", scale = "2" })'

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
