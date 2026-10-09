# shellcheck shell=bash
# The fleet-qemu image every VM script runs qemu in. Sourced by
# bin/test-arch-vm.sh, bin/test-hypr-session.sh, bin/hypr-vm,
# bin/test-hibernate.sh and bin/test-boot-guard.sh; not a command.
#
# Built by each of them, not only by test-arch-vm.sh. Since ERGON-49 a
# session-only run is the usual diagnosis cycle, and on 2026-10-09 it died in
# its first second because the image had been pruned from checo to free disk:
# test-arch-vm.sh was the one script that built it, and nothing had run it
# since. With the layer cache warm this is a no-op; cold, about a minute.
#
# Everything runs in a container; qemu is never installed on the host.
# Needs DOCKER from lib/docker-cmd.sh.
fleet_qemu_image() {
  "${DOCKER[@]}" build -q -t "${1:-fleet-qemu}" - >/dev/null <<'DOCKERFILE'
FROM debian:13
ENV DEBIAN_FRONTEND=noninteractive
# ovmf is the point: the laptop boots UEFI and GRUB is installed in UEFI mode,
# so a SeaBIOS test would exercise a path that never runs on real hardware.
# libarchive-tools gives bsdtar, which reads the ISO without needing a loop
# mount (and therefore without needing root or a privileged container).
# qemu-system-gui is a RECOMMENDS of qemu-system-x86, and --no-install-recommends
# drops it. Without it this qemu has only the `none` and `curses` displays and no
# virtio-*-gl device at all, so the guest gets no GL and no dmabuf -- which is
# why hyprpaper could not composite a wallpaper and grim could not capture. Those
# were written off as "the VM cannot do graphics"; they were one missing package.
# libegl1/libgbm1/libgl1-mesa-dri are the EGL runtime qemu dlopens for
# -display egl-headless. qemu-system-gui provides the GL-capable binary but not
# these, and without them qemu exits with "Couldn't open libEGL.so.1" -- which
# reads like a qemu problem and is a missing dependency.
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      qemu-system-x86 qemu-system-gui qemu-utils ovmf expect libarchive-tools \
      libegl1 libgbm1 libgl1-mesa-dri \
      curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
DOCKERFILE
}
