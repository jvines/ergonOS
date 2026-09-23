# The user's own configuration, and the only code allowed to create it.
#
# Sourced by bin/ergon-theme. Not a command; nothing execs this.
#
# Every themed surface is GENERATED from a .in template, so anything a person
# types into the rendered file is gone the next time the palette is rendered --
# which is now every install.sh run, not only an explicit `ergon theme`. So each
# surface that can include another file includes one from here, and this
# directory is the half of the desktop the repository does not own.
#
# The rule is create-if-absent, never write. That is not a stylistic preference:
# for four of these surfaces the file MUST exist or the program does not start
# (see the table below), and for all of them the contents are the user's. A
# shipped script that appended to one of these would be doing exactly what this
# whole mechanism exists to stop the renderer from doing. bin/ergon-lint
# enforces that nothing outside lib/ writes under this directory; this file and
# lib/ergon_arxiv.py (which has created arxiv.toml the same way since long
# before the rule) are the two it allows. Keep the writes here.
#
# What happens when one of these is MISSING, measured against the real parsers
# rather than assumed (Arch containers, 2026-09-23):
#
#   waybar.css      FATAL, and worse than it sounds. waybar loads style.css
#                   with a non-NULL GError, and GTK3 discards the ENTIRE
#                   stylesheet on a failed @import -- including rules written
#                   before the @import line. The bar loses all of its theming,
#                   not just the override.
#   mako            FATAL. mako exits EXIT_FAILURE on a missing include, before
#                   it touches Wayland or the bus. No notification daemon.
#   fuzzel.ini      Non-fatal at runtime, FATAL under --check-config, which is
#                   what bin/test-hypr-config.sh runs.
#   foot.ini        The same asymmetry as fuzzel: logged at runtime, exit 230
#                   under --check-config.
#   newsboat.conf   FATAL on every start. newsboat has no check mode, so there
#                   is no gentler path than this one.
#   gtk.css         Warning only. GTK loads the user stylesheet with a NULL
#                   GError, which switches its parser from discard-the-file to
#                   warn-and-continue.
#   hyprlock.conf   Soft. hyprlang records the error and parses the rest, and
#                   the file is wrapped in `hyprlang noerror` besides.
#   user.lua        Soft. `pcall(require, ...)` is exactly the guard for it.
#
# The four FATAL ones are why creation lives with the renderer instead of only
# in install.sh: the same run that writes the include line into a rendered file
# guarantees the file that line points at. Splitting those apart is how you get
# a machine whose bar disappeared because a step was skipped.

# XDG_CONFIG_HOME, not a hardcoded ~/.config: CI renders on a host runner whose
# $HOME belongs to a real person, and a test that created files in it would be
# reaching outside its own checkout. Everything here is redirectable.
ergon_user_config_dir() {
  printf '%s/ergon\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# The surfaces that include a user file, and the comment each empty stub opens
# with. The name mirrors the surface's own filename so it is guessable without
# reading documentation -- ~/.config/ergon/mako is what mako/config includes,
# ~/.config/ergon/waybar.css is what waybar/style.css imports.
#
# Kept as one list because the knowledge topic documents the same set; a second
# copy somewhere would drift from this one.
# The separator is the FIRST "|" and only the first: everything after it is the
# stub's content, newlines and all, written as a real multi-line string. An
# earlier version joined the lines with "|" too and decoded them afterwards,
# which meant a "|" typed inside a sentence silently became a line break and
# turned the rest of the comment into an uncommented directive. Nothing here
# contained one, which is the only reason it never fired.
ERGON_USER_FILES=(
"waybar.css|/* Your waybar CSS. Imported at the END of the generated stylesheet,
   so a rule here beats the same rule there. */"

"gtk.css|/* Your GTK CSS. Imported at the end of the generated gtk.css,
   for GTK3 and GTK4 both. */"

"mako|# Your mako settings. Included at the end of the generated global
# section, so a key here wins.
#
# Criteria sections ([urgency=critical] and friends) are the exception: mako
# accepts an include only before the first one, so the generated criteria are
# parsed after yours and win on any key both set."

"fuzzel.ini|# Your fuzzel settings. Included at the end of the generated
# config, under [main]."

"foot.ini|# Your foot settings. Included at the end of the generated config,
# under [main]."

"newsboat.conf|# Your newsboat settings. Included at the end of the generated
# config."

"hyprlock.conf|# Your hyprlock settings. Sourced at the end of the generated
# config. This is where an enrolled fingerprint block belongs -- run:
# ergon fingerprint"

"user.lua|-- Your Hyprland config, in Lua. Loaded last, after the per-host
-- file, so an hl.config() here wins.
--
-- The API is not the one most Hyprland documentation describes:
--     ergon explain desktop-config"
)

# Create every user file that does not exist yet. Never touches one that does.
#
# Returns non-zero only if a file that must exist could not be created, because
# for four of these surfaces that is the difference between a desktop and a
# black bar -- and a renderer that reported success there would be lying.
ergon_ensure_user_files() {
  local dir entry name rest created=0 rc=0
  dir="$(ergon_user_config_dir)"
  mkdir -p "$dir" || { printf 'could not create %s\n' "$dir" >&2; return 1; }

  for entry in "${ERGON_USER_FILES[@]}"; do
    # An entry with no separator at all would otherwise leave name and rest
    # both equal to the whole string, and write a file whose content is its own
    # filename -- quietly, and only for the surface someone just added.
    case "$entry" in
      *'|'*) ;;
      *) printf 'malformed ERGON_USER_FILES entry (no "|"): %s\n' "$entry" >&2
         rc=1; continue ;;
    esac
    name="${entry%%|*}"
    rest="${entry#*|}"
    # -e, not -f: a user who made one of these a symlink to somewhere in their
    # own dotfiles has answered the question, and replacing it would be the
    # clobber this whole file exists to prevent.
    [ -e "$dir/$name" ] && continue
    # The ONLY write in the repo under this directory, and it happens exactly
    # once per file per machine. See the header, and ergon-lint's rule.
    if printf '%s\n' "$rest" > "$dir/$name"; then
      created=$((created + 1))
    else
      printf 'could not create %s\n' "$dir/$name" >&2
      rc=1
    fi
  done

  [ "$created" = 0 ] || printf '   %s user override file(s) created in %s\n' "$created" "$dir"
  return $rc
}
