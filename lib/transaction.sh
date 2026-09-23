# What a pacman transaction needs wrapped around it. Sourced by
# bin/ergon-update and by bin/provision-arch.sh; not a command, nothing execs
# this.
#
# It lives here because the two scripts that open a transaction had different
# answers, and ERGON-22 turned that into a real difference rather than an
# untidy one: `ergon sync` now re-runs provisioning on a machine that is in
# use, so the copy with no scope and no inhibitor is the one that runs on a
# laptop with a session open and a lid to close.

# PROBED, never assumed -- the lesson bin/ergon-watch's inhibitor already
# carries. systemd-run and systemd-inhibit need a system manager and, for the
# inhibitor, logind's blessing; in a container, a chroot or over ssh they fail
# WITHOUT running the command. A transaction that did not happen because its
# wrapper refused is worse than one that ran unwrapped, so a refused probe
# degrades to running the thing and says what was lost.
#
# Sets ERGON_TXN to the argv prefix. Empty is a valid answer.
ergon_txn_wrap() {  # <description> <inhibit-why> <noun>
  local desc=$1 why=$2 noun=$3
  ERGON_TXN=()
  if command -v systemd-run >/dev/null 2>&1 \
     && sudo systemd-run --scope --quiet --collect -- true >/dev/null 2>&1; then
    ERGON_TXN+=(systemd-run --scope --quiet --collect --description="$desc" --)
  else
    printf '   !!   no transient scope here — a compositor or systemd restart could kill this %s\n' "$noun" >&2
  fi
  if command -v systemd-inhibit >/dev/null 2>&1 \
     && sudo systemd-inhibit --what=sleep --who=ergon --why=probe true >/dev/null 2>&1; then
    ERGON_TXN+=(systemd-inhibit --what=sleep:shutdown:handle-lid-switch
                --who=ergon --why="$why" --)
  else
    printf '   !!   cannot inhibit sleep here — do not close the lid until this finishes\n' >&2
  fi
}

# Refuse a transaction the disk cannot finish. Dying part way through a glibc
# or kernel upgrade is the genuinely bad outcome, and the pre-transaction
# snapshot is no answer: snap-pac takes it on the same filesystem that is
# about to fill.
ergon_txn_space() {  # <min-gib> <what-to-run-instead> -> 1, and says so, if short
  local min=$1 advice=$2 free
  free=$(df --output=avail -BG / 2>/dev/null | tail -1 | tr -dc '0-9')
  # No answer from df is not evidence of a full disk, and refusing on it would
  # block provisioning on any filesystem df cannot describe.
  [ -n "$free" ] || return 0
  [ "$free" -ge "$min" ] && return 0
  printf '   !!   only %s GiB free on / — need %s GiB. %s\n' "$free" "$min" "$advice" >&2
  return 1
}
