# PAM edits for `ergon fido2`, kept apart from the command so the tests can run
# them on fixture files. Sourced, not executed. Every function takes plain file
# paths and prints the result to stdout; none of them writes to its input, so
# the caller decides when (and as whom) anything lands in /etc/pam.d.
#
# The pair of lines we add is
#       # ergon-fido2
#       auth    sufficient    pam_u2f.so cue authfile=...
# `sufficient` is the whole safety story: a present, touched key lets you in,
# and anything else (no key, key not touched, bad authfile) falls through to
# the password line already below it. `required` would lock you out of sudo.
# Removal deletes exactly those two lines, so remove(add(f)) == f byte for byte.

FIDO2_MARK='# ergon-fido2'

# fido2_pam_add FILE AUTHFILE -- FILE with the key line inserted ahead of its
# first auth line (that is where `sufficient` has to sit to short-circuit it),
# or unchanged if it is already there. A file with no auth line is refused:
# prepending to it would make the key the only way in.
fido2_pam_add() {
  local f=$1 authfile=$2
  grep -qxF "$FIDO2_MARK" "$f" && { cat "$f"; return 0; }
  grep -Eq '^(auth[[:space:]]|@include[[:space:]]+[^#]*auth)' "$f" || return 1
  awk -v mark="$FIDO2_MARK" -v af="$authfile" '
    !done && /^(auth[ \t]|@include[ \t]+[^#]*auth)/ {
      print mark
      print "auth       sufficient   pam_u2f.so cue authfile=" af
      done = 1
    }
    { print }' "$f"
}

# fido2_pam_remove FILE -- FILE without our marker and the line after it.
fido2_pam_remove() {
  awk -v mark="$FIDO2_MARK" '
    skip { skip = 0; next }
    $0 == mark { skip = 1; next }
    { print }' "$1"
}

# fido2_pam_validate OLD NEW AUTHFILE MODDIR -- 0 only if NEW is OLD plus our two
# lines and nothing else, every line of NEW has a shape PAM will parse, the
# module exists and the authfile is a non-empty regular file. A bad edit never
# reaches /etc/pam.d.
fido2_pam_validate() {
  local old=$1 new=$2 authfile=$3 moddir=$4
  [ -s "$new" ] || return 1
  [ "$(fido2_pam_remove "$new" | cksum)" = "$(cksum <"$old")" ] || return 1
  [ "$(( $(wc -l <"$new") - $(wc -l <"$old") ))" -eq 2 ] || return 1
  [ -f "$moddir/pam_u2f.so" ] || [ -f "$moddir/security/pam_u2f.so" ] || return 1
  [ -f "$authfile" ] && [ ! -L "$authfile" ] && [ -s "$authfile" ] || return 1
  awk '
    /^[ \t]*(#|$)/ { next }
    /^@include[ \t]+[A-Za-z0-9._-]+[ \t]*$/ { next }
    $1 !~ /^-?(auth|account|password|session)$/ { bad = 1 }
    NF < 3 { bad = 1 }
    END { exit bad }' "$new"
}
