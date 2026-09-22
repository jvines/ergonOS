# What provisioning reads, and what this machine last recorded for it.
# Sourced by bin/provision-arch.sh (which writes the stamp), bin/ergon-sync and
# bin/ergon-doctor (which read it). Not a command; nothing execs this.
#
# It lives here because the list was written out twice and was wrong both
# times. ergon-sync watched bin/provision-arch.sh, packages/pacman, grub and
# systemd; the stamp recorded hashes for two of those. So "did the inputs move"
# and "do the incoming commits touch the inputs" were different questions over
# different sets, and they contradicted each other -- doctor certified a machine
# as current while sync said it was not.

# Everything provisioning reads from the checkout, directly or through a helper
# it invokes. The helpers are here because they are the only things that write
# /etc/systemd/logind.conf.d, the sleep and PPD drop-ins, the boot-guard units
# and a profile's kernel cmdline: a commit touching bin/ergon-hardware alone
# changes what an installed machine should have, and nothing noticed.
#
# bin/ergon-bundle and bin/ergon-aur are invoked by provisioning too and are
# deliberately NOT here: `ergon sync` runs `ergon-bundle sync` on its own after
# install.sh, and the AUR stage is driven by packages/aur, which is. Listing
# them would mean a full re-provision every time a bundle helper is touched.
#
# systemd/ is deliberately NOT here either. Its only readers are install.sh:127
# and install.sh:144, which copy two USER timers into ~/.config/systemd/user --
# the user layer, which every sync re-runs anyway. Listing it meant a change to
# ergon-battery.timer told the machine to re-provision.
#
# This file is not in its own list. A path added here has no digest in any
# existing stamp, so it reads as changed on the next run, which is the answer
# we want; hashing the list itself would additionally re-provision every
# machine whenever this comment is edited.
ERGON_PROVISION_INPUTS=(
  bin/provision-arch.sh
  bin/ergon-hardware
  bin/ergon-backup
  bin/ergon-boot-guard
  packages/pacman
  packages/aur
  grub
  hardware
  knowledge
  AGENTS.system.md
)

ergon_input_digest() {  # <ergon-root> <path> -> one digest for that input
  local root=$1 p=$2
  if [ -d "$root/$p" ]; then
    # Over the NAMES as well as the contents: sha256sum prints the path beside
    # each hash, so a new hardware profile or a deleted knowledge topic moves
    # the digest too. LC_ALL=C because the sort has to mean the same thing on
    # the machine that wrote the stamp and the one that reads it.
    ( cd "$root" && find "$p" -type f -print0 2>/dev/null \
        | LC_ALL=C sort -z | xargs -0r sha256sum 2>/dev/null ) \
      | sha256sum | cut -d' ' -f1
  elif [ -f "$root/$p" ]; then
    sha256sum "$root/$p" | cut -d' ' -f1
  else
    # A stable marker, not the empty string: an input the repo does not have is
    # a state both sides can agree on, and "" is also what a stamp with no line
    # for this path returns.
    printf 'absent\n'
  fi
}

ergon_input_digests() {  # <ergon-root> -> the stamp's input lines
  local root=$1 p
  for p in "${ERGON_PROVISION_INPUTS[@]}"; do
    printf 'input:%s=%s\n' "$p" "$(ergon_input_digest "$root" "$p")"
  done
}

ergon_stale_inputs() {  # <ergon-root> <stamp> -> the inputs the stamp does not match
  local root=$1 stamp=$2 p recorded
  for p in "${ERGON_PROVISION_INPUTS[@]}"; do
    # The path is a literal in the pattern, so | as the delimiter and no
    # escaping needed for the / in bin/provision-arch.sh.
    recorded=$(sed -n "s|^input:$p=||p" "$stamp" 2>/dev/null | tail -1)
    [ "$recorded" = "$(ergon_input_digest "$root" "$p")" ] || printf '%s\n' "$p"
  done
}
