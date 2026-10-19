#!/usr/bin/env bash
# ERGON-97: the PAM edits behind `ergon fido2`, run on fixture files.
#
#   ./bin/test-fido2.sh
#
# Seconds, no root, no key, no /etc. The point is the two properties that keep
# a user able to sudo: the key line is `sufficient` and sits before the password
# line, and remove(add(f)) is byte-identical to f.
set -uo pipefail
ERGON="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)"
. "$ERGON/lib/fido2-pam.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "   ok   $1"; }
bad() { echo "   FAIL $1"; fail=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', want '$3'"; fi; }

AF="$T/fido2"; echo "user:cred" > "$AF"
MOD="$T/lib"; mkdir "$MOD"; : > "$MOD/pam_u2f.so"

# The three shapes real files come in: Arch sudo, Arch polkit-1, Debian sudo.
printf '#%%PAM-1.0\nauth       include      system-auth\naccount    include      system-auth\nsession    include      system-auth\n' > "$T/arch-sudo"
printf 'auth       include      system-auth\naccount    include      system-auth\npassword   include      system-auth\nsession    include      system-auth\n' > "$T/polkit-1"
printf '#%%PAM-1.0\n\nsession    required   pam_limits.so\n\n@include common-auth\n@include common-account\n' > "$T/deb-sudo"
printf '# comment\n-auth optional pam_foo.so\nauth required pam_unix.so nullok\n' > "$T/odd"

for n in arch-sudo polkit-1 deb-sudo odd; do
  f=$T/$n
  fido2_pam_add "$f" "$AF" > "$T/$n.new"
  fido2_pam_validate "$f" "$T/$n.new" "$AF" "$MOD"; eq "$n: edit validates" "$?" 0
  eq "$n: key line is sufficient, not required" \
     "$(grep -c 'sufficient.*pam_u2f.so' "$T/$n.new")/$(grep -c 'required.*pam_u2f' "$T/$n.new")" 1/0
  # Ahead of the first auth line, or it could never short-circuit it.
  eq "$n: key precedes the first password-bearing line" \
     "$(grep -nE 'pam_u2f|^auth[[:space:]]+(include|required)|^@include.*auth' "$T/$n.new" | head -1 | grep -c pam_u2f)" 1
  fido2_pam_add "$T/$n.new" "$AF" > "$T/$n.twice"
  eq "$n: adding twice is a no-op" "$(cksum <"$T/$n.twice")" "$(cksum <"$T/$n.new")"
  fido2_pam_remove "$T/$n.new" > "$T/$n.back"
  cmp -s "$f" "$T/$n.back"; eq "$n: remove restores it byte for byte" "$?" 0
  fido2_pam_remove "$f" > "$T/$n.noop"
  cmp -s "$f" "$T/$n.noop"; eq "$n: remove on an untouched file changes nothing" "$?" 0
done

echo "== things that must be refused"
printf 'session required pam_limits.so\n' > "$T/noauth"
fido2_pam_add "$T/noauth" "$AF" >/dev/null; eq "file with no auth line is not edited" "$?" 1
fido2_pam_add "$T/arch-sudo" "$AF" > "$T/good"
cp "$T/good" "$T/extra"; echo "auth required pam_deny.so" >> "$T/extra"
fido2_pam_validate "$T/arch-sudo" "$T/extra" "$AF" "$MOD"; eq "an extra line is rejected" "$?" 1
printf 'garbage\n' >> "$T/good"
fido2_pam_validate "$T/arch-sudo" "$T/good" "$AF" "$MOD"; eq "a malformed line is rejected" "$?" 1
fido2_pam_add "$T/arch-sudo" "$AF" > "$T/good"
fido2_pam_validate "$T/arch-sudo" "$T/good" "$T/nokey" "$MOD"; eq "missing authfile is rejected" "$?" 1
: > "$T/empty"; fido2_pam_validate "$T/arch-sudo" "$T/good" "$T/empty" "$MOD"; eq "empty authfile is rejected" "$?" 1
fido2_pam_validate "$T/arch-sudo" "$T/good" "$AF" "$T/nomod"; eq "missing pam_u2f.so is rejected" "$?" 1
: > "$T/blank"; fido2_pam_validate "$T/arch-sudo" "$T/blank" "$AF" "$MOD"; eq "empty result is rejected" "$?" 1

echo "== command"
out=$("$ERGON/bin/ergon-fido2" --bogus 2>&1); eq "unknown flag exits 2" "$?" 2
"$ERGON/bin/ergon-fido2" --help | grep -q -- --remove; eq "--help prints the header" "$?" 0
[ "$fail" = 0 ] && echo "PASS" || { echo "FAILED"; exit 1; }
