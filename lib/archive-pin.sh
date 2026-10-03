# Which Arch pacman installs from: the day the VM suite last passed (ERGON-35).
# Sourced by bin/ergon-update, bin/provision-arch.sh, bin/arch-bootstrap.sh,
# bin/ergon-doctor and bin/test-arch-vm.sh; not a command. Callers set $ERGON.
#
# A Hyprland that renames a Lua field leaves a desktop with zero binds and a
# config that still parses, and a rolling mirror hands that to every machine
# the day it lands. archive.archlinux.org keeps each day's repos whole, so the
# date bin/test-arch-vm.sh installed from, once vm.yml has passed on it, is a
# package set that is known to work: packages/tested-date. The WHOLE system is
# held there. `--ignore hyprland` would be the partial upgrade ergon-update
# exists to prevent.
#
# The list and the sync databases move TOGETHER, only ever right before a sync,
# and every sync is -Syy until one against the list has gone through: pacman
# keeps a database newer than its server's (measured, see ergon-update). A list
# pointed at another day than the databases asks for files that day never had:
# synced at 2026-09-25, core/linux was 7.2.6, and a live mirror 404'd on it the
# next morning.
#
# archive.archlinux.org is the only server; the *.archive.pkgbuild.com names do
# not resolve (2026-09-26). It served 3-5 MB/s here, as fast as the geo mirror.
# Down, the sync fails, and ergon update says nothing was upgraded.
ERGON_ARCHIVE_URL=https://archive.archlinux.org/repos
ERGON_PIN_LIST=/etc/pacman.d/ergon-mirrorlist
# A copy of the list, made only once a sync against it went through. The list
# alone cannot say that: it is written BEFORE the sync, and one that fails or is
# interrupted leaves it moved and the databases where they were. On a first pin
# those are newer, a later -Sy keeps them, and -Su installed from them under a
# list reading 2026-09-10 (bash 5.3.15 -> 5.3.20, systemd 261.3 -> 262,
# measured): the archive serves a newer file under an older day's path, so not
# even a download fails. Apply removes it before it moves anything.
ERGON_PIN_SYNCED=/var/lib/ergon/pin-synced

# YYYY-MM-DD from ERGON_ARCHIVE_DATE (the VM harness, which picks its own
# date), else packages/tested-date. Fails on anything that is not a real day up
# to today: a snapshot is published at about 12:40 UTC (measured), so today's
# may not exist, and nothing later ever does.
ergon_tested_date() {
  local d=${ERGON_ARCHIVE_DATE:-}
  [ -n "$d" ] || d=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$ERGON/packages/tested-date" 2>/dev/null \
                     | head -1 | tr -d '[:space:]')
  [[ $d =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  [ "$(date -u -d "$d" +%F 2>/dev/null)" = "$d" ] && [[ ! $d > $(date -u +%F) ]] || return 1
  printf '%s\n' "$d"
}

ergon_archive_url() { printf '%s/%s\n' "$ERGON_ARCHIVE_URL" "${1//-//}"; }

# The list for a date, or for live mirrors when there is none. Live is an
# Include of the ordinary mirrorlist, so whatever keeps that current still does;
# pacman follows an Include inside an included file (pacman-conf, measured).
ergon_pin_list() {  # [date]
  echo "# Written by ergon update or provisioning (lib/archive-pin.sh), just before"
  echo "# the pacman -Sy that syncs against it. Edits here are overwritten."
  if [ -n "${1:-}" ]; then
    echo "# Arch as of $1: packages/tested-date, what the VM suite last passed."
    echo "Server = $(ergon_archive_url "$1")/\$repo/os/\$arch"
  else
    echo "# Live mirrors: ergon update --latest, or no usable packages/tested-date."
    echo "Include = /etc/pacman.d/mirrorlist"
  fi
}

# pacman.conf with core, extra and multilib reading the list. Only sections
# that are switched on; the -testing ones, and any repo someone added, are left
# as they are. Idempotent: its own output passes through unchanged.
ergon_pin_conf() {
  awk -v list="$ERGON_PIN_LIST" '
    /^[[:space:]]*\[/ { s = $0; sub(/^[[:space:]]*\[/, "", s); sub(/\].*/, "", s)
                        pin = (s == "core" || s == "extra" || s == "multilib") }
    pin && /^[[:space:]]*(Include|Server)[[:space:]]*=/ {
      if (!done[s]++) print "Include = " list
      next }
    { print }'
}

# What this machine holds: a date, "live", or nothing when pacman.conf does not
# read the list at all. Offline: two files.
ergon_pin_held() {
  local r=${ERGON_SYSROOT:-}
  grep -q "^Include = $ERGON_PIN_LIST" "$r/etc/pacman.conf" 2>/dev/null \
    && ergon_pin_conf < "$r/etc/pacman.conf" | cmp -s - "$r/etc/pacman.conf" || return 1
  if grep -q '^Include = /etc/pacman.d/mirrorlist' "$r$ERGON_PIN_LIST" 2>/dev/null; then
    echo live
  else
    sed -n 's|^Server = .*/repos/\([0-9]\{4\}\)/\([0-9]\{2\}\)/\([0-9]\{2\}\)/.*|\1-\2-\3|p' \
      "$r$ERGON_PIN_LIST" 2>/dev/null | head -1 | grep . || return 1
  fi
}

# Write the list, then point pacman.conf at it, so pacman.conf never names a
# list that is not there. 0 when either changed; 1 when both already said so;
# 2 when a write failed. A pacman.conf that could not be read writes nothing at
# all. Whether a sync is owed is ergon_pin_owed's, not this: a run that moved
# nothing can still owe the one an earlier run failed to finish.
ergon_pin_apply() {  # [date]
  local r=${ERGON_SYSROOT:-} t rc=1
  t=$(mktemp -d) || return 2
  ergon_pin_list "${1:-}" > "$t/list"
  ergon_pin_conf < "$r/etc/pacman.conf" > "$t/conf" 2>/dev/null
  [ -s "$t/conf" ] || rc=2
  [ "$rc" = 2 ] || { cmp -s "$t/list" "$r$ERGON_PIN_LIST" && cmp -s "$t/conf" "$r/etc/pacman.conf"; } \
    || sudo rm -f "$r$ERGON_PIN_SYNCED" || rc=2
  [ "$rc" = 2 ] || cmp -s "$t/list" "$r$ERGON_PIN_LIST" \
    || { sudo install -Dm644 "$t/list" "$r$ERGON_PIN_LIST" && rc=0 || rc=2; }
  [ "$rc" = 2 ] || cmp -s "$t/conf" "$r/etc/pacman.conf" \
    || { sudo install -Dm644 "$t/conf" "$r/etc/pacman.conf" && rc=0 || rc=2; }
  rm -rf "$t"
  return "$rc"
}

# 0 while the databases are not known to be the list's: the next sync is -Syy,
# and it is owed even with nothing to upgrade.
ergon_pin_owed() {
  ! cmp -s "${ERGON_SYSROOT:-}$ERGON_PIN_LIST" "${ERGON_SYSROOT:-}$ERGON_PIN_SYNCED"
}

# What root runs straight after a sync against the list went through, and never
# otherwise.
ergon_pin_synced_cmd() {
  printf 'install -Dm644 %q %q' "${ERGON_SYSROOT:-}$ERGON_PIN_LIST" "${ERGON_SYSROOT:-}$ERGON_PIN_SYNCED"
}
