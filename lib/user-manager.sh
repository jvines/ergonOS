# Reaching the user's OWN systemd manager from a shell that has no session.
# Sourced by bin/provision-arch.sh; not a command, nothing execs this.
#
# `systemctl --user` finds that manager through the user bus and nothing else:
# sd-bus takes $DBUS_SESSION_BUS_ADDRESS, or failing that $XDG_RUNTIME_DIR/bus,
# and gives up with -ENOENT when neither is set -- the familiar "Failed to
# connect to bus". Arch installs its su.pam as BOTH /etc/pam.d/su and
# /etc/pam.d/su-l and that file has no pam_systemd, so `su - <user> -c` (what
# the VM harness runs provisioning with) opens no logind session and sets
# neither variable; `sudo -u` and anything a system service starts are the same.
# Every `systemctl --user` in such a shell fails for a reason that has nothing
# to do with the machine, and provisioning read that failure as "there is no
# user manager here". An interactive ssh login is NOT one of these -- sshd does
# run pam_systemd -- which is part of why this stayed invisible.
#
# There is exactly ONE user manager per user and it outlives every session, so
# it was running the whole time -- which is also the good news: a reload asked
# for from an ssh shell reaches the graphical session's app.slice, because it
# is the same manager.

# The directory the bus lives in. The caller's own is preferred when it has
# one: pam_systemd is the authority on where a real session's runtime directory
# is, not this file.
_ergon_user_runtime_dir() { printf '%s\n' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"; }

# What the RUNNING manager holds, which for anything under /etc/systemd/user is
# the only form that has any effect. Empty output and status 1 mean there was no
# manager to ask -- a different answer from every value it could have given, and
# one that must never be reported as a policy being in place.
ergon_user_prop() {  # <unit> <property>
  local v
  v=$(XDG_RUNTIME_DIR="$(_ergon_user_runtime_dir)" \
      systemctl --user show --value -p "$2" "$1" 2>/dev/null) || return 1
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# Make the drop-ins under /etc/systemd/user live in the manager that is already
# running. 1 when there is no manager to reach.
ergon_user_reload() {
  XDG_RUNTIME_DIR="$(_ergon_user_runtime_dir)" \
    systemctl --user daemon-reload 2>/dev/null
}

# Ask, reload if the answer is wrong, ask again, and hand back what the manager
# says the second time. 0 when it holds <wanted>; 1 when it does not, and stdout
# is then what it holds instead; 2 when there is no user manager running at all,
# which is a first boot or a machine nobody has logged into yet and is the one
# case the caller cannot fix from here.
#
# A RELOAD, and never a restart. `systemctl --user restart app.slice` would
# apply the property too, and would take every app in the slice with it: every
# terminal, every editor, every unsaved buffer -- the exact loss this whole
# stage exists to prevent.
#
# A reload is enough, and that is systemd's behaviour rather than a hope:
# daemon-reload re-reads the drop-ins, then coldplugs each unit back from its
# serialized state, and it is that dead->active transition which makes the
# manager re-report the unit to systemd-oomd (unit_notify() ->
# manager_varlink_send_managed_oom_update(), src/core/unit.c). Nothing in the
# slice is stopped and nothing in it notices.
#
# systemd-oomd has to be running BEFORE this: in user mode the manager is
# oomd's client, it connects to /run/systemd/oom/io.systemd.ManagedOOM only when
# it has something to report, and a report with no socket to send it to is
# dropped. It reconnects on the next unit that changes state -- the next app
# launch in a live session, but possibly never on a machine sitting at a login
# prompt.
ergon_user_ensure_prop() {  # <unit> <property> <wanted>
  local unit=$1 prop=$2 want=$3 live
  live=$(ergon_user_prop "$unit" "$prop") || return 2
  if [ "$live" != "$want" ]; then
    ergon_user_reload || return 2
    live=$(ergon_user_prop "$unit" "$prop") || return 2
  fi
  printf '%s\n' "$live"
  [ "$live" = "$want" ]
}
