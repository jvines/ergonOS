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
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)                # already reaches the socket -- every
    return 0                       # existing machine, which still sets 1
  fi
  # sudo -n proves a NOPASSWD rule or a cached ticket without ever blocking a
  # non-interactive run (CI, or this function called from set -e). Falling
  # back to "is this a tty" is what lets a person sitting at a fresh install
  # answer a real password prompt instead of the harness refusing one keystroke
  # from working.
  if command -v sudo >/dev/null 2>&1 && { sudo -n true 2>/dev/null || [ -t 0 ]; }; then
    DOCKER=(sudo docker)
    return 0
  fi
  echo "docker: $(id -un) can't reach the socket and sudo isn't available here -- set DOCKER_GROUP=1 in hosts/<host>/host.env, or read knowledge/security.md" >&2
  return 1
}
