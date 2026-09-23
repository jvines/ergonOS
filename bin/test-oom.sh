#!/usr/bin/env bash
# ERGON-19: what stops a run that exhausts memory from taking the session down.
#
#   ./bin/test-oom.sh
#
# Seconds, no root, no network, no Arch, no VM, and it never starts a scope, an
# oomd or a compositor -- systemd-run and systemctl are stubs on PATH that log
# their argv, and the three /etc files are extracted from the heredocs
# provisioning writes them from, so this is the bytes an installed machine gets
# rather than a fixture that passes forever after the real one is edited.
#
# The one that matters: a per-run scope. The drop-in on app.slice alone does NOT
# contain a runaway job, because `wezterm start` asks an ALREADY-RUNNING wezterm
# to open the window -- so every terminal is one process in one cgroup, and oomd
# kills cgroups. Without --always-new-process and without a scope per run, this
# card moves the damage from the session to every terminal and calls it a fix.
#
# COVERS: every terminal path going through uwsm-app (and the escape hatch
# deliberately not); wezterm's single-process default; the slice the drop-in is
# on and why it is not app-graphical.slice; the compositor's OOMPolicy; the
# scope ergon-watch asks for, including the --slice= without which oomd may not
# touch it; the probe, including the machine where a scope is granted and
# nothing is watching it; the run still happening when the scope is refused; how
# a kill is attributed to memory WITHOUT any journal access, and what `ergon
# hist` shows for it; and the three doctor rows in every state, including a
# machine with no user manager to ask.
#
# DOES NOT COVER: whether systemd-oomd actually kills the scope under pressure,
# whether the compositor survives it, or whether a notification is drawn. Those
# need a booted session and are in test/arch-vm/guest-desktop.sh.
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '   ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '   FAIL %s\n' "$*"; }
# Neither pass nor fail: something this machine cannot be asked. Kept visibly
# distinct so it never reads as a silent pass.
note() { printf '   --   %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
# -e, not a bare --. `grep -qE -- "$pat" "$file"` looks right and is not: a
# caller writing `has "$f" -- '--unit=...'` to protect a pattern that starts with
# a dash shifts the real pattern into $3, where this function never looks, and
# greps for "--" instead. That matches every systemd-run line ever logged, so
# the assertion passes whatever the file says. -e takes the pattern by name.
has()  { grep -qE -e "$2" "$1" 2>/dev/null; }
hasf() { grep -qF -e "$2" "$1" 2>/dev/null; }
not()  { ! "$@"; }

# --- the files provisioning writes ------------------------------------------
heredoc() {  # heredoc <delimiter> <out>
  sed -n "/<<'$1'\$/,/^$1\$/p" "$REPO/bin/provision-arch.sh" | sed '1d;$d' > "$2"
  [ -s "$2" ]
}
check "the oomd config is still written by provisioning"        heredoc OOMD   "$T/oomd.conf"
check "the app.slice drop-in is still written by provisioning"  heredoc OOMAPP "$T/app.slice.conf"
check "the compositor drop-in is still written by provisioning" heredoc OOMWM  "$T/wayland-wm.conf"
[ -s "$T/oomd.conf" ] && [ -s "$T/app.slice.conf" ] && [ -s "$T/wayland-wm.conf" ] || {
  echo "   cannot read what provisioning writes; the heredoc delimiters moved" >&2
  printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
}

# Pressure, not the kernel's OOM killer: the kernel only acts once an allocation
# actually fails, which on a machine with swap is minutes after it stopped being
# usable. The defaults (60% for 30s) are half a minute of a desktop nobody can
# type into.
check "oomd is configured under [OOM]"        has "$T/oomd.conf" '^\[OOM\]$'
check "it acts on pressure below the default" has "$T/oomd.conf" '^DefaultMemoryPressureLimit=50%$'
check "and sooner than the default 30s"       has "$T/oomd.conf" '^DefaultMemoryPressureDurationSec=20s$'
# Swap on this machine is where the hibernation image goes. Killing jobs because
# it filled is a different policy, and not this card's.
check "a full swap is not by itself a reason to kill" not has "$T/oomd.conf" '^SwapUsedLimit='

# The slice, which is the decision this card is most likely to get wrong.
# systemd-oomd(8): only DESCENDANTS of a monitored cgroup are candidates, the
# monitored unit never is, and only LEAF cgroups are eligible. uwsm gives each
# uwsm-app launch a scope under app-graphical.slice, a child of app.slice -- so
# monitoring app.slice reaches each app's own scope two levels down, and cannot
# kill app-graphical.slice wholesale because a slice with children is no leaf.
# It also covers the transient scope ergon-watch asks for, which
# app-graphical.slice would not.
check "the drop-in is a [Slice] fragment"     has "$T/app.slice.conf" '^\[Slice\]$'
check "app.slice is monitored"                has "$T/app.slice.conf" '^ManagedOOMMemoryPressure=kill$'
# Over the DIRECTIVES: the file argues at length about which slice this must be
# on, and every slice it names appears in that argument.
grep -vE '^[[:space:]]*(#|$)' "$T/app.slice.conf" > "$T/app.slice.rules"
check "  and it sets that, and nothing else" \
  test "$(grep -c . "$T/app.slice.rules")" = 2
check "provisioning writes it where the user manager reads it" \
  has "$REPO/bin/provision-arch.sh" '/etc/systemd/user/app\.slice\.d/'
check "  and the compositor drop-in against the uwsm template unit" \
  has "$REPO/bin/provision-arch.sh" '/etc/systemd/user/wayland-wm@\.service\.d/'
check "systemd-oomd is enabled by provisioning" \
  has "$REPO/bin/provision-arch.sh" 'systemctl enable --now systemd-oomd'

# uwsm's unit sets no OOMPolicy=, so it takes the default, stop -- and it stops
# FAILED, which its own OnFailure=wayland-session-shutdown.target turns into the
# end of the session. Anything still inside that unit would otherwise cost the
# whole desktop the moment the kernel picked it.
check "the compositor drop-in is a [Service] fragment" has "$T/wayland-wm.conf" '^\[Service\]$'
check "one killed process no longer stops the compositor" \
  has "$T/wayland-wm.conf" '^OOMPolicy=continue$'

# --- the terminal path -------------------------------------------------------
B="$REPO/hypr/common/binds.lua"
# Every bind that opens a terminal, by the dispatcher it passes -- not by a
# count, which passes while a new one is added without the prefix.
while IFS= read -r line; do
  chord=$(printf '%s' "$line" | sed 's/^bind("\([^"]*\)".*/\1/')
  case "$line" in
    *'"foot"'*) continue ;;   # the escape hatch, asserted on its own below
    *'launch .. '*) ok "$chord goes through uwsm-app" ;;
    *) bad "$chord starts a terminal inside the compositor's unit — no launch prefix" ;;
  esac
done < <(grep -E '^bind\(.*(ergon-term|term \.\.|\.\. term)' "$B")
# The awkward chord is reached only when something is already broken, so it must
# not depend on uwsm-app being installed and working either.
check "the fallback terminal deliberately has no prefix" \
  has "$B" '^bind\("SUPER \+ SHIFT \+ ALT \+ RETURN", "Terminal \(fallback\)", "foot"\)$'
check "the prefix is uwsm-app, which is what puts a window in app-graphical.slice" \
  has "$B" '^local launch += "uwsm-app -- "'

# The half the prefix cannot do. `wezterm start` with the default class asks the
# running GUI to open the window, so every terminal shares one process and one
# cgroup: oomd would kill all of them at once, which is not what the card
# promises. The flag has to reach wezterm BEFORE the -- that ends its options.
W=$(grep -n 'exec wezterm' -B3 "$REPO/bin/ergon-term" | grep 'set -- start')
check "ergon-term forces a process per window" \
  test -n "$(printf '%s' "$W" | grep -F -- '--always-new-process')"
check "  as an option of wezterm start, before the -- that ends them" \
  test -n "$(printf '%s' "$W" | grep -E 'start --always-new-process .*\{1:\+--\}')"

F="$REPO/fuzzel/fuzzel.ini"
check "the launcher starts apps in their own scope" has "$F" '^launch-prefix=uwsm-app --$'
check "  and its terminal apps through ergon-term, not a shared wezterm" \
  has "$F" '^terminal=ergon-term$'
# fuzzel.ini is GENERATED (see its first line). Asserting only the output would
# pass on a hand-edit that the next `ergon theme` silently reverts, so the
# template has to carry both lines as well.
check "  and both lines come from the template, not a hand-edit of the output" \
  test "$(grep -cE '^(launch-prefix=uwsm-app --|terminal=ergon-term)$' "$REPO/fuzzel/fuzzel.ini.in")" = 2

# --- what `ergon watch` runs -------------------------------------------------
mkdir -p "$T/stub" "$T/log" "$T/home" "$T/data"
cat > "$T/stub/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/systemd-run"
# The PROBE and the real call are told apart by the unit name, so refusing one
# and allowing the other is what tests the probe at all.
case " $* " in
  *" --unit="*)
    [ -z "${STUB_NO_SCOPE:-}" ] || { echo "Failed to start transient scope" >&2; exit 1; }
    # oomd SIGKILLs the whole scope, so the command never returns: 137 without
    # running it is what ergon-watch sees. Only the real call, never the probe.
    [ -z "${STUB_KILLED:-}" ] || exit 137 ;;
  *) [ -z "${STUB_NO_SCOPE:-}${STUB_PROBE_ONLY:-}" ] || { echo "Failed to start transient scope" >&2; exit 1; } ;;
esac
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
EOF
cat > "$T/stub/systemd-inhibit" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/systemd-inhibit"
[ -z "${STUB_NO_INHIBIT:-}" ] || { echo "Failed to inhibit: Access denied" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in --) shift; break ;; --*) shift ;; *) break ;; esac
done
exec "$@"
EOF
cat > "$T/stub/journalctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/journalctl"
# What the REAL journalctl does for the owner of a machine this repo builds:
# prints nothing and exits 0. systemd's tmpfiles grants the journal ACL to
# `adm`, arch-bootstrap.sh creates the user with -G wheel, and provisioning adds
# only video and input -- so an attribution that greps the system journal
# succeeds, matches nothing, and records every real kill as an ordinary
# failure. Kept as a stub, and asserted unused, so that going back to the
# journal fails this suite rather than a laptop two hours into a fit.
exit 0
EOF
cat > "$T/stub/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/systemctl"
case " $* " in
  *" reset-failed "*) ;;
  *"-p Result"*)
    # The user manager's own verdict on the scope, which is what replaced the
    # journal grep. It answers about the unit it was ASKED about, so the stub
    # reads the name this run gave systemd-run rather than being handed one.
    unit=$(sed -n 's/.*--unit=\([^ ]*\).*/\1/p' "$TEST_ROOT/log/systemd-run" 2>/dev/null | tail -1)
    case " $* " in
      *" ${unit:-__none__}.scope "*) printf '%s\n' "${STUB_SCOPE_RESULT:-success}" ;;
      *) echo success ;;
    esac ;;
  # A scope is over by the time ergon-watch asks; the poll exists for the
  # moment before that, and a stub that never says "active" still exercises it.
  *"-p ActiveState"*) echo failed ;;
  *"ManagedOOMMemoryPressure"*)
    # An empty answer is not "auto": it is a machine with no user manager to ask.
    [ -n "${STUB_OOM_APP:-}" ] || exit 1
    printf '%s\n' "$STUB_OOM_APP" ;;
  *"systemd-oomd"*) [ "${STUB_OOMD:-active}" = active ] ;;
  *) exit 0 ;;
esac
EOF
cat > "$T/stub/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/log/notify-send"
EOF
chmod +x "$T/stub"/*
export TEST_ROOT="$T" PATH="$T/stub:$PATH" HOME="$T/home" XDG_DATA_HOME="$T/data"
L="$T/log"
J="$T/data/ergon/runs.jsonl"

watch() {  # watch <args>... -- fresh logs, one run
  rm -f "$L"/* "$J"
  "$REPO/bin/ergon-watch" --quiet "$@" >/dev/null 2>&1
}

watch --name fit -- true
check "a run is wrapped in a scope of its own"  hasf "$L/systemd-run" '--scope'
# The line without which oomd may not touch the scope at all: systemd-run --user
# defaults to the user manager's ROOT slice, and the drop-in is on app.slice.
check "  in app.slice, where the oomd drop-in is" hasf "$L/systemd-run" '--slice=app.slice'
check "  with a memory limit, so it throttles before the machine does" \
  hasf "$L/systemd-run" '-p MemoryHigh=80%'
check "  under a name the manager can be asked about afterwards" \
  has "$L/systemd-run" '--unit=ergon-watch-fit-[0-9]+'
check "  and it is a USER scope, not a system one" hasf "$L/systemd-run" '--user'
# --collect unloads a unit the moment it dies, verdict and all, so the real call
# must not carry it -- only the probe, whose unit nobody asks about.
check "  and it is not collected, or its verdict would be gone before it is read" \
  not has "$L/systemd-run" '--unit=[^ ]+.*--collect|--collect.*--unit='
check "the inhibitor is still held around the run"  hasf "$L/systemd-inhibit" '--what=sleep:idle'
# Outermost, so it lasts as long as the run rather than as long as the scope.
check "  and it wraps the scope rather than the other way round" \
  hasf "$L/systemd-inhibit" 'systemd-run'

watch --name fit --mem 3G -- true
check "--mem sets the limit"                   hasf "$L/systemd-run" '-p MemoryHigh=3G'
check "  and nothing else about the scope moves" hasf "$L/systemd-run" '--slice=app.slice'

# GNU time is not installed everywhere and its path cannot be stubbed -- it is
# looked for by absolute path, deliberately, so that a stub cannot make this
# pass on a machine where the real thing is missing.
if [ -x /usr/bin/time ] || [ -x /bin/time ]; then
  check "peak memory is measured OUTSIDE the scope, so a killed run still reports it" \
    has "$L/systemd-inhibit" '/(usr/)?bin/time .* systemd-run'
else
  note "no GNU time here, so the timer's position around the scope is not checked that way"
fi
# The order itself, off the one line that sets it. A string assertion, which
# this repo rightly distrusts -- it is here because the behavioural check above
# cannot run on a machine without GNU time, and that is the machine CI runs on.
# The order is the difference between knowing what a killed run died holding and
# having no number at all.
check "  and the order is what the script actually runs" \
  has "$REPO/bin/ergon-watch" '^\$INHIBIT \$TIMER \$SCOPE "\$@"$'

# The lesson this file inherits from the inhibitor: containment is a nicety,
# RUNNING THE COMMAND is the point.
rm -f "$L"/* "$J"
STUB_NO_SCOPE=1 "$REPO/bin/ergon-watch" --quiet --name fit -- true >/dev/null 2>&1
check "a refused scope does not stop the run happening" test -s "$J"
check "  and the run is still journalled, with its exit status" \
  hasf "$J" '"exit":0'
rm -f "$L"/* "$J"
STUB_PROBE_ONLY=1 "$REPO/bin/ergon-watch" --quiet --name fit -- true >/dev/null 2>&1
check "a scope that only the probe refuses still leaves the run unscoped" \
  not hasf "$L/systemd-run" '--unit='
check "  rather than failing the run" hasf "$J" '"exit":0'

# --- a scope with nothing watching it ----------------------------------------
# app.slice is a stock systemd user unit, so the scope is granted on a machine
# that has never seen this card's provisioning -- and MemoryHigh there throttles
# a job at 80% of RAM with nothing that will ever end it. Slower than no limit
# at all, uncontained, and silent about both until this warning existed.
# Captured, not piped into `grep -q`: grep leaves as soon as it matches, the
# writer takes SIGPIPE, and `set -o pipefail` at the top of this file then hands
# back 141 for a run that said exactly what it was supposed to -- so the check
# fails when the warning is there and passes when it is not.
warned() {  # warned <env assignments...> -- does the run say nothing is watching?
  rm -f "$L"/* "$J"
  local out
  out=$(env "$@" "$REPO/bin/ergon-watch" --name fit -- true 2>&1)
  case "$out" in *"nothing watches its pressure"*) return 0 ;; *) return 1 ;; esac
}
check "a scope with oomd running and app.slice monitored says nothing" \
  not warned STUB_OOMD=active STUB_OOM_APP=kill
check "a scope with no oomd running warns that the limit only throttles" \
  warned STUB_OOMD=dead STUB_OOM_APP=kill
check "  and so does one where app.slice is left unmonitored" \
  warned STUB_OOMD=active STUB_OOM_APP=auto
check "  and the run still happens either way" hasf "$J" '"exit":0'

# --- a run the machine killed ------------------------------------------------
# NOT out of the system journal. `journalctl -u systemd-oomd` and `journalctl -k`
# print nothing and exit 0 for a user outside `adm`, which is every user this
# repo builds, so the stub journalctl is the silent one a real owner gets and
# the attribution has to work without it.
killed() {  # killed <env assignments...> -- one killed run, fresh logs
  rm -f "$L"/* "$J"
  env STUB_KILLED=1 "$@" "$REPO/bin/ergon-watch" --quiet --name fit -- true >/dev/null 2>&1
}
killed STUB_SCOPE_RESULT=oom-kill
check "a killed run is journalled, not lost"          hasf "$J" '"exit":137'
check "  and recorded as out of memory, not as exit 137" hasf "$J" '"oom":1'
check "  by asking the manager that owns the scope, not the journal" \
  has "$L/systemctl" '--user show --value -p Result ergon-watch-fit-[0-9]+\.scope'
check "  which needs no journal access at all"        not test -s "$L/journalctl"
# A failed scope is kept loaded so that it can be asked; keeping it forever is a
# corpse in `systemctl --user` for every job that ever ran out of memory.
check "  and the scope it kept is cleared once it has been read" \
  hasf "$L/systemctl" 'reset-failed'
# The window it ran in may have gone with it, so this is the only place the
# machine says what it killed.
check "  and says so in a notification naming the run" hasf "$L/notify-send" 'fit'
check "  at critical urgency"                          hasf "$L/notify-send" '-u critical'

killed STUB_SCOPE_RESULT=exit-code
# The manager distinguishes the two; the exit status cannot. A run that was
# Ctrl-C'd and recorded as an OOM kill sends the next person tuning memory
# limits for hours.
check "a kill the manager did not call an OOM kill is not recorded as one" \
  hasf "$J" '"oom":0'
killed STUB_NO_SCOPE=1 STUB_SCOPE_RESULT=oom-kill
check "with no scope there is no unit to ask about, so oom stays unclaimed" \
  hasf "$J" '"oom":0'

# --- what `ergon hist` shows -------------------------------------------------
mkdir -p "$T/data/ergon"
cat > "$J" <<'RUNS'
{"name":"old","cmd":"a","cwd":"/","git":"","started":"2026-01-01T00:00:00","seconds":10,"exit":0,"peak_mb":1,"host":"h"}
{"name":"broke","cmd":"b","cwd":"/","git":"","started":"2026-01-01T00:00:00","seconds":10,"exit":2,"peak_mb":1,"oom":0,"host":"h"}
{"name":"toobig","cmd":"c","cwd":"/","git":"","started":"2026-01-01T00:00:00","seconds":10,"exit":137,"peak_mb":9999,"oom":1,"host":"h"}
RUNS
"$REPO/bin/ergon-hist" > "$T/hist.out" 2>&1
check "hist says out of memory rather than exit 137"   has "$T/hist.out" 'toobig.*OUT OF MEMORY'
check "  and an ordinary failure still reads as one"   has "$T/hist.out" 'broke.*FAILED \(2\)'
# The field did not exist before this card; every line already in the journal
# lacks it, and a KeyError here would take the whole history with it.
check "  and a line written before the field existed still prints" \
  has "$T/hist.out" 'old.*ok'
check "a killed run is in --failed"                    has <("$REPO/bin/ergon-hist" --failed) 'toobig'

# --- what ergon-doctor says --------------------------------------------------
mkdir -p "$T/ergon/lib" "$T/sysroot/proc/self"
cp "$REPO/lib/provision-inputs.sh" "$T/ergon/lib/"
cat > "$T/stub/sudo" <<'EOF'
#!/usr/bin/env bash
# doctor asks with -n; this machine's user cannot become root without a
# password, which is how doctor is normally run.
exit 1
EOF
chmod +x "$T/stub/sudo"
export ERGON="$T/ergon" ERGON_SYSROOT="$T/sysroot"
CG="$T/sysroot/proc/self/cgroup"

doctor() {  # doctor <check> -> that check's JSON object
  "$REPO/bin/ergon-doctor" --json 2>/dev/null | grep -o "{\"name\":\"$1\"[^}]*}"
}

export STUB_OOM_APP=kill
check "a running systemd-oomd is ok"        has <(doctor oomd) '"state":"ok"'
check "one that is not running is a failure" \
  has <(STUB_OOMD=dead doctor oomd) '"state":"fail"'
check "  and it says what that costs, and how to fix it" \
  has <(STUB_OOMD=dead doctor oomd) 'takes the session with it'
check "app.slice set to kill is ok"         has <(doctor oom-policy) '"state":"ok"'
# The state a check that only asked "is oomd running" would call healthy: the
# daemon is up and allowed to act on nothing.
check "oomd running with app.slice unmonitored is a failure" \
  has <(STUB_OOM_APP=auto doctor oom-policy) '"state":"fail"'
check "  and it says to reload the user manager, not just to re-provision" \
  has <(STUB_OOM_APP=auto doctor oom-policy) 'daemon-reload'
check "no user manager to ask is said, not guessed at" \
  has <(STUB_OOM_APP= doctor oom-policy) '"state":"ok".*no user manager'

# The row that answers "what would a runaway job in THIS window cost".
export WAYLAND_DISPLAY=wayland-1
printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-graphical-ergon\\x2dterm-1234.scope\n' > "$CG"
check "a terminal in its own scope under app.slice is ok" \
  has <(doctor shell-slice) '"state":"ok"'
printf '0::/user.slice/user-1000.slice/user@1000.service/session.slice/wayland-wm@hyprland.service\n' > "$CG"
check "a shell inside the compositor's unit is a failure" \
  has <(doctor shell-slice) '"state":"fail"'
check "  and it names the cause a person can act on" \
  has <(doctor shell-slice) 'uwsm-app'
printf '0::/user.slice/user-1000.slice/session-3.scope\n' > "$CG"
check "a shell outside app.slice altogether is a warning, not a pass" \
  has <(doctor shell-slice) '"state":"warn"'

# --- the answer a ROOT shell can honestly give -------------------------------
# doctor tells you to run itself under sudo for the rows that need root, and
# under sudo these two are about a user manager and a shell that are not the
# ones being asked about. Both used to answer anyway, one of them ok.
printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-graphical-ergon\\x2dterm-1234.scope\n' > "$CG"
check "under sudo, oom-policy says it cannot answer rather than reporting ok" \
  has <(SUDO_USER=someone STUB_OOM_APP= doctor oom-policy) '"state":"warn"'
check "  and it names the user to ask as" \
  has <(SUDO_USER=someone STUB_OOM_APP= doctor oom-policy) 'as someone'
check "under sudo, shell-slice does not answer for the root shell" \
  has <(SUDO_USER=someone doctor shell-slice) '"state":"warn"'

# --- the JSON is JSON --------------------------------------------------------
# systemd escapes a dash in a unit name as \x2d, so the scope name of every
# uwsm-app terminal -- which this round creates -- carries a backslash. doctor
# escaped the quote and not the backslash, so `ergon doctor --json` on a
# working machine emitted a string no parser accepts. Asserted by PARSING, not
# by grepping: a grep cannot tell valid JSON from a near miss.
command -v jq >/dev/null \
  || { echo "jq is missing; it is in packages/pacman and this asserts with it"; exit 1; }
check "--json parses when a scope name carries a backslash" \
  sh -c '"$0"/bin/ergon-doctor --json 2>/dev/null | jq -e . >/dev/null' "$REPO"
check "  and the note survives the escaping intact" \
  sh -c '"$0"/bin/ergon-doctor --json 2>/dev/null | jq -er ".checks[]|select(.name==\"shell-slice\").note" | grep -q "ergon.x2dterm-1234.scope"' "$REPO"
unset WAYLAND_DISPLAY
check "outside a graphical session the row is not asked at all" \
  test -z "$(doctor shell-slice)"

printf '\n   %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
