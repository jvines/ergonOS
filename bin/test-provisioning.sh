#!/usr/bin/env bash
# ERGON-22: a system-level change has to reach a machine that is ALREADY
# installed, and nothing has to say it did when it did not.
#
#   ./bin/test-provisioning.sh
#
# Seconds, no root, no network, no Arch. A throwaway git repository is the
# remote, a stub install.sh records that it ran, a stub provision-arch.sh
# records that it ran AND writes the stamp the real one writes, and a stub
# pacman answers the -T query -- so "sync re-provisioned" is a line in the
# stub's log rather than an inference from the output, and "the machine is
# current again afterwards" is the stamp rather than an assumption.
#
# The claims it pins down, each of which has an obvious wrong answer:
#   * a commit that touches no provisioning input must NOT re-provision. A sync
#     that re-provisions on every push is a sync people stop running. systemd/
#     is the case worth naming: those are USER timers install.sh copies, and
#     watching them meant a battery-timer edit ordered an unattended upgrade.
#   * one that touches any input must -- including bin/ergon-hardware, which
#     writes logind, sleep and cmdline state and which the first version of the
#     watch list did not mention -- and BEFORE install.sh, which assumes the
#     packages and the /usr/local/bin links.
#   * non-interactive and without --yes, nothing may run unasked, the command
#     must be printed instead, and the run must NOT exit 0 claiming the machine
#     matches the remote.
#   * the question must be asked again on the next run. It used to be derived
#     from the incoming commit range, so it was put exactly once -- on the run
#     that fast-forwarded -- and a decline was never revisited.
#   * `ergon doctor` must tell the two apart over the SAME set of inputs sync
#     uses: provisioned at an older commit whose inputs are unchanged is fine;
#     any changed input is not.
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@ergon.invalid \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@ergon.invalid
export HOME="$T/home"
export XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state" \
       XDG_DATA_HOME="$HOME/.local/share" XDG_CONFIG_HOME="$HOME/.config"
unset WAYLAND_DISPLAY
mkdir -p "$HOME/.local/share"

LOG="$T/ran"
: > "$LOG"
# Where the fixture's stamp lives. sync, doctor and the provisioning stub all
# read ERGON_SYSROOT, so none of them touches this machine's /var.
export ERGON_SYSROOT="$T/sysroot"
STAMP="$ERGON_SYSROOT/var/lib/ergon/provisioned"
mkdir -p "$(dirname "$STAMP")"

# --- the machine ------------------------------------------------------------
# Shaped like the repo, not a copy of it: every path below is one the shared
# input list names, plus two that it deliberately does not.
M="$T/machine"
mkdir -p "$M/bin" "$M/lib" "$M/packages" "$M/grub" "$M/hardware/fake" \
         "$M/knowledge" "$M/systemd" "$M/zsh"
cp "$REPO/lib/provision-inputs.sh" "$M/lib/provision-inputs.sh"
cat > "$M/install.sh" <<EOF
#!/usr/bin/env bash
echo install.sh >> "$LOG"
EOF
# Stands in for provisioning, and records what provisioning records. A stub
# that only logged its own name would let a sync which applied nothing look
# exactly like one that applied everything, because the stamp is what both
# sync and doctor read afterwards.
cat > "$M/bin/provision-arch.sh" <<EOF
#!/usr/bin/env bash
echo provision-arch.sh >> "$LOG"
[ "\${STUB_PROVISION_FAIL:-0}" = 1 ] && exit 1
. "$M/lib/provision-inputs.sh"
{ echo "commit=\$(git -C "$M" rev-parse HEAD)"
  echo "at=\$(date +%s)"
  ergon_input_digests "$M"
} > "$STAMP"
EOF
chmod +x "$M/install.sh" "$M/bin/provision-arch.sh"
printf 'zsh\ntmux\n'   > "$M/packages/pacman"
printf 'wezterm-git\n' > "$M/packages/aur"
printf 'x\n' > "$M/bin/ergon-hardware"
printf 'x\n' > "$M/bin/ergon-backup"
printf 'x\n' > "$M/bin/ergon-boot-guard"
printf 'x\n' > "$M/grub/09_x"
printf 'x\n' > "$M/hardware/fake/profile.sh"
printf 'x\n' > "$M/knowledge/desktop-config.md"
printf 'x\n' > "$M/AGENTS.system.md"
printf 'x\n' > "$M/systemd/ergon-x.timer"
printf 'x\n' > "$M/zsh/zshrc"

git -C "$M" init -q -b main
git -C "$M" add -A
git -C "$M" commit -qm base
git clone -q --bare "$M" "$T/origin.git"
git -C "$M" remote add origin "$T/origin.git"
git clone -q "$T/origin.git" "$T/upstream"

# Stubs. ergon-bundle so a sync never touches the real one if this host has it
# on PATH; pacman for the doctor check, answering with whatever $MISSING says.
mkdir -p "$T/stub"
cat > "$T/stub/ergon-bundle" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$T/stub/pacman" <<'EOF'
#!/usr/bin/env bash
# `pacman -T` prints the targets that are NOT satisfied, and exits 127 when
# there are any.
[ "${1:-}" = "-T" ] || exit 1
[ -n "${MISSING:-}" ] || exit 0
printf '%s\n' $MISSING
exit 127
EOF
# hostname, so doctor's hosts/<host>/host.env lookup lands on a fixture path
# rather than whatever machine happens to run this test. groups, controlled by
# $STUB_IN_DOCKER, for the docker-group check below -- the real `groups` can't
# be made to say "docker" on demand.
cat > "$T/stub/hostname" <<'EOF'
#!/usr/bin/env bash
echo testhost
EOF
cat > "$T/stub/groups" <<'EOF'
#!/usr/bin/env bash
# Bare `groups` (no argument) answers for the CALLING PROCESS's cached
# supplementary groups, not a live /etc/group lookup -- see ergon-doctor's
# docker-group check. Requiring an argument here is what would catch a
# regression back to the bare form: doctor only sees $STUB_IN_DOCKER when it
# names a user, exactly as a real stale session only sees a live answer that
# way too.
[ $# -ge 1 ] || { echo "t wheel"; exit 0; }
# $STUB_DOCKER_USER puts the membership on ONE name, which is how the sudo
# case below can tell whose groups doctor actually asked for.
if [ -n "${STUB_DOCKER_USER:-}" ]; then
  [ "$1" = "$STUB_DOCKER_USER" ] && echo "t docker wheel" || echo "t wheel"
  exit 0
fi
[ "${STUB_IN_DOCKER:-0}" = 1 ] && echo "t docker wheel" || echo "t wheel"
EOF
chmod +x "$T/stub/ergon-bundle" "$T/stub/pacman" "$T/stub/hostname" "$T/stub/groups"
export PATH="$T/stub:$PATH"

# The same digests provisioning writes, so the fixture can be stamped as
# current without running the stub.
# shellcheck source=../lib/provision-inputs.sh
. "$REPO/lib/provision-inputs.sh"
stamp() {  # stamp <commit> [input-to-corrupt]
  { printf 'commit=%s\nat=%s\n' "$1" "$(date +%s)"
    ergon_input_digests "$M"
  } > "$STAMP"
  [ -z "${2:-}" ] || sed -i "s|^input:$2=.*|input:$2=0000|" "$STAMP"
}

push() {  # push <path-in-repo>
  printf 'line added for %s\n' "$1" >> "$T/upstream/$1"
  git -C "$T/upstream" add -A
  git -C "$T/upstream" commit -qm "change $1"
  git -C "$T/upstream" push -q origin main
}

RC=0
sync() {  # sync [args...] -> status in $RC, output in $T/out, stubs in $LOG
  : > "$LOG"
  ERGON="$M" "$REPO/bin/ergon-sync" "$@" > "$T/out" 2>&1
  RC=$?
}

# --- a commit that provisioning does not read -------------------------------
# systemd/ is here because ergon-sync used to watch it. Its only readers are
# install.sh's two `cp`s into ~/.config/systemd/user, so watching it meant an
# edit to ergon-battery.timer told every machine to re-provision -- and with
# --yes, to upgrade itself unattended.
stamp "$(git -C "$M" rev-parse HEAD)"
push zsh/zshrc
push systemd/ergon-x.timer
sync --yes
if grep -qx install.sh "$LOG" && ! grep -qx provision-arch.sh "$LOG" && [ "$RC" = 0 ]; then
  ok "a config-only commit, systemd/ included, re-runs install.sh and does not re-provision"
else
  bad "a config-only commit ran: $(tr '\n' ' ' < "$LOG") (exit $RC)"
fi

# --- a helper that provisioning invokes -------------------------------------
# bin/ergon-hardware is the only thing that writes /etc/systemd/logind.conf.d,
# the sleep and power-profile drop-ins and a profile's kernel cmdline. The
# first watch list named neither it nor packages/aur, hardware/ or knowledge/,
# so a commit touching only one of those was silently a fresh-installs-only
# change -- which is the drift this card exists to end.
for input in bin/ergon-hardware packages/aur hardware/fake/profile.sh \
             knowledge/desktop-config.md AGENTS.system.md grub/09_x; do
  push "$input"
  sync --yes
  if [ "$(head -1 "$LOG")" = provision-arch.sh ] && [ "$RC" = 0 ]; then
    ok "a commit to $input re-provisions"
  else
    bad "a commit to $input ran: $(tr '\n' ' ' < "$LOG") (exit $RC)"
  fi
done

# --- --check ----------------------------------------------------------------
push packages/pacman
sync --check
if grep -q 'packages/pacman' "$T/out" && [ ! -s "$LOG" ] && [ "$RC" = 0 ]; then
  ok "--check names the provisioning input and applies nothing"
else
  bad "--check said $(tr '\n' ' ' < "$T/out") and ran $(tr '\n' ' ' < "$LOG")"
fi

# --- no --yes, no tty -------------------------------------------------------
# < /dev/null is the point: this is the shape a timer or a script has, and the
# failure worth catching is a sync that decides silence means yes -- or one
# that decides silence means everything is fine.
sync < /dev/null
if ! grep -qx provision-arch.sh "$LOG"; then
  ok "a packages/pacman commit does not re-provision unasked"
else
  bad "provisioning ran without --yes on a non-interactive sync"
fi
if grep -q 'bin/provision-arch.sh' "$T/out" && [ "$RC" != 0 ] \
   && ! grep -q 'matches the remote' "$T/out"; then
  ok "it prints the command, does not claim the machine matches, and exits non-zero"
else
  bad "an unapplied sync exited $RC saying: $(tr '\n' ' ' < "$T/out")"
fi

# --- and asks again on the next run -----------------------------------------
# The run above already fast-forwarded, so there is nothing incoming now. When
# the decision came from the commit RANGE this printed "ok up to date" and
# exited 0, over a machine that had taken none of it, and never mentioned
# provisioning again.
sync < /dev/null
if grep -q 'bin/provision-arch.sh' "$T/out" && [ "$RC" != 0 ]; then
  ok "with nothing incoming it still says the system layer is unapplied"
else
  bad "the second run exited $RC saying: $(tr '\n' ' ' < "$T/out")"
fi

# --- provisioning that fails ------------------------------------------------
export STUB_PROVISION_FAIL=1
sync --yes
if grep -qx provision-arch.sh "$LOG" && [ "$RC" != 0 ] \
   && ! grep -q 'matches the remote' "$T/out"; then
  ok "a failed provisioning run exits non-zero and says so"
else
  bad "a failed provisioning run exited $RC saying: $(tr '\n' ' ' < "$T/out")"
fi
unset STUB_PROVISION_FAIL

# --- and then applies -------------------------------------------------------
sync --yes
if grep -qx provision-arch.sh "$LOG" && [ "$RC" = 0 ] \
   && grep -q 'matches the remote' "$T/out"; then
  ok "provisioning that succeeds ends the run clean"
else
  bad "a successful re-provision exited $RC saying: $(tr '\n' ' ' < "$T/out")"
fi
sync < /dev/null
if [ "$RC" = 0 ] && ! grep -q 'provision-arch.sh' "$T/out"; then
  ok "and the run after it is quiet"
else
  bad "a provisioned machine still exited $RC saying: $(tr '\n' ' ' < "$T/out")"
fi

# --- what doctor says about the stamp ---------------------------------------
doctor() {  # doctor <check> -> that check's JSON object
  # `|| true`, because doctor exits 1 when ANY check on the fixture machine
  # fails and this helper is only ever asked about one row. Under `set -o
  # pipefail` that status propagated out of `doctor base-packages | grep -q`,
  # so an assertion about packages/pacman was silently a verdict on every other
  # check too -- and ERGON-20's firewall row, which a fixture with no nftables
  # rightly fails, broke two assertions that have nothing to do with it.
  ERGON="$M" "$REPO/bin/ergon-doctor" --json 2>/dev/null \
    | grep -o "{\"name\":\"$1\"[^}]*}" || true
}
HEAD_SHA=$(git -C "$M" rev-parse HEAD)
OLD_SHA=$(git -C "$M" rev-parse HEAD~2)

rm -f "$STAMP"
case "$(doctor provisioned)" in
  *'"state":"warn"'*never*recorded*) ok "no stamp reads as never recorded, not as current" ;;
  *) bad "with no stamp, doctor said: $(doctor provisioned)" ;;
esac

stamp "$HEAD_SHA"
case "$(doctor provisioned)" in
  *'"state":"ok"'*) ok "a stamp at HEAD with matching inputs is ok" ;;
  *) bad "at HEAD, doctor said: $(doctor provisioned)" ;;
esac

# An older commit is NOT by itself a problem: most commits change nothing
# provisioning reads, and warning on every one of them is a warning people
# learn to scroll past.
stamp "$OLD_SHA"
out=$(doctor provisioned)
case "$out" in
  *'"state":"ok"'*"${OLD_SHA:0:7}"*"${HEAD_SHA:0:7}"*)
    ok "an older commit with unchanged inputs is ok, and both commits are named" ;;
  *) bad "at an older commit, doctor said: $out" ;;
esac

# Every input, not the two the stamp used to carry. doctor hashed
# provision-arch.sh and packages/pacman only, so it certified a machine as
# current while sync, watching a wider set, was saying it was not.
for input in "${ERGON_PROVISION_INPUTS[@]}"; do
  stamp "$OLD_SHA" "$input"
  case "$(doctor provisioned)" in
    *'"state":"warn"'*"$input"*) ok "a changed $input is reported as stale" ;;
    *) bad "with $input changed, doctor said: $(doctor provisioned)" ;;
  esac
done

# --- and about the packages themselves --------------------------------------
stamp "$HEAD_SHA"
MISSING="tmux" doctor base-packages | grep -q '"state":"warn"' \
  && ok "a package from packages/pacman that pacman does not have is reported" \
  || bad "a missing base package was not reported: $(MISSING=tmux doctor base-packages)"
doctor base-packages | grep -q '"state":"ok"' \
  && ok "nothing missing reads as ok" \
  || bad "with nothing missing, doctor said: $(doctor base-packages)"

# --- ERGON-21: the docker group is opt-in, and doctor reports what is real --
# `groups` decides the state, not host.env's opinion of it -- see ergon-doctor.
mkdir -p "$M/hosts/testhost"
printf 'DOCKER_GROUP=0\n' > "$M/hosts/testhost/host.env"
case "$(doctor docker-group)" in
  *'"state":"ok"'*) ok "DOCKER_GROUP=0 and out of the group reads as ok" ;;
  *) bad "DOCKER_GROUP=0, out of the group: doctor said $(doctor docker-group)" ;;
esac

printf 'DOCKER_GROUP=1\n' > "$M/hosts/testhost/host.env"
case "$(STUB_IN_DOCKER=1 doctor docker-group)" in
  *'"state":"warn"'*root*DOCKER_GROUP=1*) ok "DOCKER_GROUP=1 and in the group warns, naming the knob that chose it" ;;
  *) bad "DOCKER_GROUP=1, in the group: doctor said $(STUB_IN_DOCKER=1 doctor docker-group)" ;;
esac

# Drift: host.env says 0 but the machine disagrees (provisioned before this
# knob existed, or usermod run by hand). Still root, so still a warning --
# provisioning's job is to never remove it, doctor's is to say so.
printf 'DOCKER_GROUP=0\n' > "$M/hosts/testhost/host.env"
case "$(STUB_IN_DOCKER=1 doctor docker-group)" in
  *'"state":"warn"'*"DOCKER_GROUP=0"*) ok "in the group despite DOCKER_GROUP=0 is reported as drift, not silently accepted" ;;
  *) bad "DOCKER_GROUP=0, in the group anyway: doctor said $(STUB_IN_DOCKER=1 doctor docker-group)" ;;
esac

# Under sudo -- which doctor's own firewall row tells you to use, because the
# nftables chain cannot be read without root -- $(id -un) is root, root is in
# no docker group, and this row reported ok about a machine whose real user
# can become root without a password. The row that exists to catch exactly
# that, saying the opposite, under the invocation doctor itself suggests.
case "$(SUDO_USER=jose STUB_DOCKER_USER=jose doctor docker-group)" in
  *'"state":"warn"'*) ok "under sudo the row is about the invoking user, not root" ;;
  *) bad "under sudo, in the group: doctor said $(SUDO_USER=jose STUB_DOCKER_USER=jose doctor docker-group)" ;;
esac
case "$(SUDO_USER=jose STUB_DOCKER_USER=jose doctor docker-group)" in
  *'gpasswd -d jose docker'*) ok "  and the command it prints names that user" ;;
  *) bad "  the fix it printed did not name jose" ;;
esac

# Regression: this warn message used to interpolate bare $USER under
# `set -uo pipefail`. $USER is unset in plenty of contexts doctor actually
# runs in -- ssh non-interactive command exec, a cron/timer wrapper, `sudo -u
# user ergon-doctor` -- and an unbound var there killed the WHOLE script
# before it reached the report section: no JSON at all, not just a blank
# docker-group line. This is exactly the drift case above, which is the one
# that reaches the interpolation, with $USER and $LOGNAME both gone.
out=$(env -u USER -u LOGNAME STUB_IN_DOCKER=1 ERGON="$M" "$REPO/bin/ergon-doctor" --json 2>&1)
case "$out" in
  *'"name":"docker-group"'*'"state":"warn"'*) ok "doctor survives \$USER and \$LOGNAME being unset" ;;
  *) bad "with \$USER/\$LOGNAME unset, doctor said: $out" ;;
esac

# --- ERGON-64: the login keyring, and the file that points apps at it -------
# The PAM lines are provisioning's (an input, so sync re-provisions for them);
# the env file is install.sh's, which every sync runs. The awk program is pulled
# out of provision-arch.sh, not copied; its input is greetd 0.10.3's own file.
sed -n "/<<'PAMKR'\$/,/^PAMKR\$/p" "$REPO/bin/provision-arch.sh" | sed '1d;$d' > "$T/pam.awk"
printf '%s\n' '#%PAM-1.0' '' 'auth       required     pam_securetty.so' \
  'auth       requisite    pam_nologin.so' 'auth       include      system-local-login' \
  'account    include      system-local-login' 'session    include      system-local-login' > "$T/greetd"
pam_ok() {  # each keyring line exactly once, straight after the include it extends
  awk 'p ~ /^auth +include +system-local-login$/ && /^auth +optional +pam_gnome_keyring\.so$/ { a++ }
       p ~ /^session +include +system-local-login$/ && /^session +optional +pam_gnome_keyring\.so +auto_start$/ { s++ }
       /pam_gnome_keyring/ { n++ }  { p = $0 }
       END { exit !(a == 1 && s == 1 && n == 2) }' "$1"
}
if [ ! -s "$T/pam.awk" ]; then
  bad "provisioning's greetd PAM edit is gone, or its PAMKR heredoc moved"
else
  awk -f "$T/pam.awk" "$T/greetd" > "$T/pam1"; awk -f "$T/pam.awk" "$T/pam1" > "$T/pam2"
  # auth after the include, where pam_unix has checked the password; session
  # after it, where pam_systemd has made the runtime dir the daemon listens in.
  pam_ok "$T/pam1" && ok "greetd's PAM gets pam_gnome_keyring once, right after each include" \
    || bad "the keyring lines are missing, doubled or misplaced: $(tr '\n' '|' < "$T/pam1")"
  cmp -s "$T/pam1" "$T/pam2" && ok "  and a second provisioning run changes nothing" \
    || bad "  a second run changed it again: $(diff "$T/pam1" "$T/pam2" | tr '\n' ' ')"
  [ "$(grep -v pam_gnome_keyring "$T/pam1")" = "$(cat "$T/greetd")" ] \
    && ok "  and leaves the package's own lines as they were" || bad "  it changed the package's lines"
fi

# install.sh's half, through its own --check: a graphical host whose HOME has
# nothing in it must be told the link is coming.
mkdir -p "$T/inst/uwsm" "$T/inst/hosts/testhost"
cp "$REPO/install.sh" "$T/inst/" && cp "$REPO/uwsm/env-hyprland" "$T/inst/uwsm/"
printf 'GRAPHICAL=1\n' > "$T/inst/hosts/testhost/host.env"
# Captured, not piped into grep -q: under pipefail, grep leaving early kills
# install.sh with SIGPIPE and a match reads as a miss.
out=$("$T/inst/install.sh" --check 2>/dev/null)
grep -qxF '   would link  .config/uwsm/env-hyprland -> uwsm/env-hyprland' <<<"$out" \
  && ok "install.sh links uwsm/env-hyprland into ~/.config/uwsm" \
  || bad "install.sh --check on a graphical host does not plan the uwsm/env-hyprland link"

printf '\n   %d ok, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
