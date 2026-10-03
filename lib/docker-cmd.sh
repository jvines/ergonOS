# How the test harness reaches the docker socket. Sourced by every
# bin/test-*.sh and bin/hypr-vm that runs a container; not a command, nothing
# execs this.
#
# ERGON-21 made DOCKER_GROUP default to 0 -- a fresh install grants no group
# membership, and knowledge/security.md names sudo as the documented path
# instead ("The docker group is passwordless root"). About ten call sites
# across the harness were written when every machine set 1 and just assumed
# socket access, so on a machine that took the new default `docker run`
# failed with a permission error pointing at nothing this repo tells you to
# fix. One resolver instead of ten different patches, per the ERGON-51 card.
#
# ergon_resolve_docker sets DOCKER, an array a caller splices in front of the
# subcommand: `"${DOCKER[@]}" run --rm ...`. An array, not a string, because
# `sudo docker` is two words and a caller building `$DOCKER run ...` would
# either word-split a plain string (fragile the moment either word needs
# quoting) or never split a quoted one.
ergon_resolve_docker() {
  command -v docker >/dev/null 2>&1 || {
    echo "docker: not found on PATH -- install it before running this suite" >&2
    return 1
  }
  local err
  if err=$(docker info 2>&1 >/dev/null); then
    DOCKER=(docker)                # already reaches the socket -- every
    return 0                       # existing machine, which still sets 1
  fi
  # A dead daemon or a broken/remote DOCKER_HOST also makes `docker info`
  # fail, and sudo does not fix either -- it would just as happily reach
  # root's own default daemon, so the container silently comes up somewhere
  # other than the one that was meant. Take the sudo branch only when
  # docker's own error names the thing sudo actually fixes: no group
  # membership on the local socket.
  case "$err" in
    *"permission denied"*) ;;
    *)
      echo "$err" >&2
      return 1
      ;;
  esac
  if ! command -v sudo >/dev/null 2>&1; then
    echo "docker: $(id -un) can't reach the socket and sudo isn't installed -- set DOCKER_GROUP=1 in hosts/<host>/host.env, or read knowledge/security.md" >&2
    return 1
  fi
  # sudo -n proves a NOPASSWD rule or a cached ticket without ever blocking a
  # non-interactive run (CI, or this function called from set -e). Falling
  # back to a real controlling terminal -- /dev/tty, not fd 0 -- is what lets
  # a person sitting at a fresh install answer a real password prompt even
  # when stdin itself is redirected, which every VM-suite call site here does
  # (`docker run ... | tee ... | grep ...` closes fd 0 to a pipe).
  if sudo -n true 2>/dev/null || { : </dev/tty; } 2>/dev/null; then
    DOCKER=(sudo docker)
    return 0
  fi
  echo "docker: $(id -un) can't reach the socket and sudo has no cached ticket or terminal to prompt on -- run 'sudo -v' first, or from an interactive terminal" >&2
  return 1
}
