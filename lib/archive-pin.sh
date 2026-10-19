# Which Arch pacman installs from: the day the VM suite last passed (ERGON-35).
# Sourced by bin/ergon-update, bin/ergon-channel, bin/provision-arch.sh,
# bin/arch-bootstrap.sh, bin/ergon-doctor and bin/test-arch-vm.sh; not a command.
# Callers set $ERGON.
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
#
# Two channels (ERGON-99), recorded as CHANNEL= in hosts/<host>/host.env, the
# file that says what a machine IS and that reprovisioning reproduces it from.
# `ergon channel` writes it; unset, or anything else, is tested. tested is all
# of the above. rolling is the same list reading live mirrors (ergon_pin_list
# with no date): updates the day they land, nothing between them and the
# machine. ERGON_ARCHIVE_DATE (the VM harness) is always tested. The switch
# itself only edits host.env; the next `ergon update`, or provisioning that
# installs, moves the list, and the move forces -Syy like any other.
#
# rolling -> tested is the hard direction: the tested day is normally OLDER
# than what live mirrors installed. Three answers, and why two are wrong.
# Moving the list and running -Su is today's --latest-and-back: nothing
# downgrades ("local is newer"), so the machine is a mix -- the next bundle or
# `pacman -S` resolves the tested day's builds against newer libraries. A
# soname bump fails loudly, but a python-* built for the older python installs
# cleanly and does not import. -Suu to the tested set is coherent for pacman
# and wrong for the person: a Firefox profile refuses to open in an older
# Firefox, and any config or data format that migrated forward stays migrated.
# The machine already has a coherent way back to a tested state, which is
# `ergon rollback` to a snapshot from before rolling. So: WAIT. While the
# day this machine last synced live mirrors (ergon_live_day) is not before
# the tested day, `ergon update` holds it exactly where it is -- list on live
# mirrors, no sync, no upgrade -- and says so; the first tested day AFTER it
# moves the list, and -Syy/-Su from there is an ordinary forward upgrade. The
# day must be strictly later: a snapshot is taken mid-day, so the live state of
# the afternoon is only in the next day's. The cost is no updates for the gap,
# normally under a week. Provisioning that must install during it installs
# from live mirrors, as the machine already is, and the gap moves to that day.
# The same rule covers `ergon update --latest` and back.
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

# The UTC day the last sync against live mirrors went through, written by
# ergon_pin_synced_cmd in the same root command, and removed by the first
# sync against a tested day after it. What ergon_live_day reads first.
ERGON_LIVE_SYNCED=/var/lib/ergon/live-synced

# tested or rolling, from hosts/<host>/host.env (default: this machine). 1, and
# tested, for a value that is neither: a typo must not take a machine off the
# tested day.
ergon_channel() {  # [host]
  local f v
  [ -z "${ERGON_ARCHIVE_DATE:-}" ] || { echo tested; return 0; }
  f="$ERGON/hosts/${1:-$(hostname -s)}/host.env"
  # Read, not sourced: under a caller's set -u, one unset variable anywhere in
  # host.env ends the sourcing before CHANNEL, and that would read as a typo.
  # The last CHANNEL= line, quotes and a trailing comment stripped.
  v=$(awk '/^CHANNEL=/ { v = substr($0, 9); sub(/[[:space:]]*#.*$/, "", v); gsub(/["'\''[:space:]]/, "", v); f = 1 }
           END { print f ? v : "tested" }' "$f" 2>/dev/null) || v=tested
  v=${v:-tested}
  case "$v" in
    tested|rolling) echo "$v" ;;
    *) echo tested; return 1 ;;
  esac
}

# The day this machine's packages may be as new as, when that came from live
# mirrors: the record a live sync leaves, or, on a list reading live mirrors
# whose databases are known to be its own and that has no record (an
# --latest from before ERGON-99), the newest database's mtime -- pacman sets it
# from the server's Last-Modified (measured, archlinux:latest, 2026-10-19).
# The later of the two when both exist: a hand `pacman -Syu` moves the
# databases and not the record. Nothing (1) when the databases are a tested
# day's, or not known to be anything.
ergon_live_day() {
  local r=${ERGON_SYSROOT:-} rec="" db="" t
  [ ! -s "$r$ERGON_LIVE_SYNCED" ] || rec=$(head -1 "$r$ERGON_LIVE_SYNCED")
  if [ "$(ergon_pin_held)" = live ] && ! ergon_pin_owed; then
    t=$(find "$r/var/lib/pacman/sync" -maxdepth 1 -name '*.db' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
    [ -z "$t" ] || db=$(date -u -d "@${t%.*}" +%F)
  fi
  [[ $db > $rec ]] && rec=$db
  [[ $rec =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  echo "$rec"
}

# What the next sync holds this machine at, in globals every caller reads the
# same way: ERGON_CHANNEL; ERGON_TESTED, the tested day or empty; ERGON_PIN,
# the day to write into the list, empty for live mirrors; ERGON_LIVE, the live
# day when that is what holds it; and ERGON_PIN_WHY, one of
#   tested      ERGON_PIN is the tested day
#   rolling     the channel is rolling: live mirrors
#   untestable  tested channel, no usable tested day: live mirrors, as ERGON-35
#   ahead       tested channel, but this machine took live Arch on ERGON_LIVE,
#               not before the tested day: hold, see the header
# ERGON_CHANNEL_BAD is 1 when host.env names neither channel.
# shellcheck disable=SC2034  # read by every caller, never here
ergon_pin_decide() {
  ERGON_CHANNEL_BAD=0; ERGON_PIN=""; ERGON_LIVE=""
  ERGON_CHANNEL=$(ergon_channel) || ERGON_CHANNEL_BAD=1
  ERGON_TESTED=$(ergon_tested_date) || ERGON_TESTED=""
  if [ "$ERGON_CHANNEL" = rolling ]; then ERGON_PIN_WHY=rolling
  elif [ -z "$ERGON_TESTED" ]; then ERGON_PIN_WHY=untestable
  elif ERGON_LIVE=$(ergon_live_day) && [[ ! $ERGON_TESTED > $ERGON_LIVE ]]; then ERGON_PIN_WHY=ahead
  else ERGON_LIVE=""; ERGON_PIN=$ERGON_TESTED; ERGON_PIN_WHY=tested
  fi
}

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
# otherwise. Against live mirrors it also records the day (ERGON_LIVE_SYNCED),
# so callers run it after EVERY live sync, owed or not; against a day it
# removes that record, since the machine is now at a tested day after it.
ergon_pin_synced_cmd() {
  local r=${ERGON_SYSROOT:-}
  printf 'install -Dm644 %q %q' "$r$ERGON_PIN_LIST" "$r$ERGON_PIN_SYNCED"
  if grep -q '^Include = /etc/pacman.d/mirrorlist' "$r$ERGON_PIN_LIST" 2>/dev/null; then
    printf ' && date -u +%%F > %q' "$r$ERGON_LIVE_SYNCED"
  else
    printf ' && rm -f %q' "$r$ERGON_LIVE_SYNCED"
  fi
}
