#!/usr/bin/env bash
# Exercise ergon-speedtest against stub fio and speedtest-cli.
#
#   ./bin/test-speedtest.sh
#
# COVERS: JSON parsed into Mbit/s, MB/s and IOPS; fio is told O_DIRECT and a
# scratch dir under $HOME; the scratch dir is gone after success, failure and
# SIGTERM; offline network failure exits nonzero without hiding the disk test.
# DOES NOT COVER: real fio or network; the VM suite runs the disk test.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '   ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '   FAIL %s\n' "$*"; }
mkdir "$T/stub" "$T/home"; export HOME="$T/home"
cat > "$T/stub/fio" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$T/fio.args"
for a in "\$@"; do case "\$a" in --directory=*) echo "\${a#*=}" > "$T/fio.dir"; touch "\${a#*=}/testfile";; esac; done
[ -n "\${STUB_HANG:-}" ] && sleep 30
[ -n "\${STUB_FAIL:-}" ] && exit 1
cat <<'J'
{"jobs":[
{"jobname":"seqwrite","read":{"bw_bytes":0,"iops":0},"write":{"bw_bytes":512000000,"iops":488}},
{"jobname":"seqread","read":{"bw_bytes":2100000000,"iops":2000},"write":{"bw_bytes":0,"iops":0}},
{"jobname":"randwrite","read":{"bw_bytes":0,"iops":0},"write":{"bw_bytes":204800000,"iops":50000.4}},
{"jobname":"randread","read":{"bw_bytes":409600000,"iops":100000.2},"write":{"bw_bytes":0,"iops":0}}]}
J
STUB
cat > "$T/stub/speedtest-cli" <<STUB
#!/usr/bin/env bash
[ -n "\${STUB_OFFLINE:-}" ] && exit 1
echo '{"download":94500000.5,"upload":21300000,"ping":12.34,"server":{"sponsor":"Stub ISP"}}'
STUB
chmod +x "$T/stub"/*; export PATH="$T/stub:$PATH"
S="$REPO/bin/ergon-speedtest"

out=$("$S" disk 2>&1); rc=$?
[ $rc -eq 0 ] && ok "disk exits 0" || bad "disk rc=$rc: $out"
grep -q 'sequential write *512 MB/s' <<<"$out" && ok "seq write" || bad "seq write: $out"
grep -q 'sequential read *2100 MB/s' <<<"$out" && ok "seq read" || bad "seq read"
grep -q '4k random read *100000 IOPS (410 MB/s)' <<<"$out" && ok "rand read" || bad "rand read: $out"
grep -q '4k random write *50000 IOPS' <<<"$out" && ok "rand write" || bad "rand write"
grep -q -- '--direct=1' "$T/fio.args" && ok "O_DIRECT requested" || bad "no --direct=1"
case "$(cat "$T/fio.dir")" in "$HOME"/*) ok "scratch under \$HOME";; *) bad "scratch dir elsewhere";; esac
[ ! -e "$(cat "$T/fio.dir")" ] && ok "scratch removed" || bad "scratch left behind"

STUB_FAIL=1 "$S" disk >/dev/null 2>&1 && bad "fio failure exit 0" || ok "fio failure exits nonzero"
[ ! -e "$(cat "$T/fio.dir")" ] && ok "scratch removed after failure" || bad "scratch left after failure"

STUB_HANG=1 "$S" disk >/dev/null 2>&1 & p=$!
for _ in $(seq 20); do [ -s "$T/fio.dir" ] && [ -e "$(cat "$T/fio.dir")/testfile" ] && break; sleep 0.2; done
d=$(cat "$T/fio.dir"); kill -TERM $p; wait $p 2>/dev/null
[ ! -e "$d" ] && ok "scratch removed after SIGTERM" || bad "scratch left after SIGTERM"

out=$("$S" net 2>&1)
grep -q 'download  *94.5 Mbit/s' <<<"$out" && grep -q 'upload  *21.3 Mbit/s' <<<"$out" && grep -q 'latency  *12.34 ms' <<<"$out" && ok "net numbers" || bad "net: $out"
STUB_OFFLINE=1 "$S" net >/dev/null 2>&1 && bad "offline exit 0" || ok "offline net exits nonzero"
out=$(STUB_OFFLINE=1 "$S" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q 'sequential read' <<<"$out" && ok "both: offline still runs disk" || bad "both offline: rc=$rc"
printf '%s pass, %s fail\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
