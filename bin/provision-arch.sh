#!/usr/bin/env bash
# Take a freshly-bootstrapped Arch box to "one of Jose's machines".
#
#   ./provision-arch.sh                          # run locally on the new box
#   ./provision-arch.sh --remote <ssh-target>    # drive it over ssh from here
#
# The Arch counterpart to provision-debian.sh: everything AFTER the installer.
# arch-bootstrap.sh made it bootable; this makes it usable. Idempotent — every
# step checks first, so a re-run is a no-op.
#
# Structurally parallel to provision-debian.sh and deliberately shares none of
# its code. Three things from that script must NEVER appear here:
#   - the exoautomata worker-recovery stage. It installs a timer that fires
#     every 10 minutes forever; provision-debian.sh's own header says "a laptop
#     wants the first and not the second".
#   - the fdfind/batcat shims. Arch names them fd and bat.
#   - unattended-upgrades. There is no Arch equivalent and there must not be.
# And never run enroll-debian-node.sh against this machine: its net-watchdog
# stage is gated on running infra containers, which a laptop fails, so enrolling
# it installs a daemon whose job is to reboot the machine when it cannot reach
# the LAN.
set -euo pipefail

if [ "${1:-}" = "--remote" ]; then
  T="${2:?usage: provision-arch.sh --remote <ssh-target>}"
  echo "== copying provisioner to $T"
  scp -q "$0" "$T:/tmp/provision-arch.sh"
  exec ssh -t "$T" 'bash /tmp/provision-arch.sh; rm -f /tmp/provision-arch.sh'
fi

ERGON="${ERGON:-$HOME/ergonOS}"
export PATH="$HOME/.local/bin:$PATH"
say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ok  %s\n' "$*"; }
skip() { printf '   ·   %s\n' "$*"; }
warn() { printf '   !!  %s\n' "$*" >&2; }

[ -f /etc/arch-release ] || { echo "not an Arch system" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "run as your user, not root (makepkg refuses root)" >&2; exit 1; }

# Same helper install.sh uses: strip comments, blank lines and trailing space.
_pkglist() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]*$//' "$1"; }

# ---------------------------------------------------------------------------
say "system packages"
# informant, once installed, hooks pacman and ABORTS any transaction while there
# is unread Arch news -- it exits with the number of unread items, and the hook
# propagates that. That is exactly what it is for, and it means this script
# fails on its second run and every run after until the news is read.
#
# It is NOT cleared automatically here. Marking the news read on your behalf
# would silently discard the manual-intervention notices that are the only
# reason informant is in packages/pacman at all. Show them and stop; the
# override is explicit.
if command -v informant >/dev/null && ! informant check >/dev/null 2>&1; then
  warn "unread Arch news is blocking pacman:"
  informant list -r --unread 2>/dev/null | head -10 | sed 's/^/     /'
  if [ "${ERGON_SKIP_NEWS:-0}" = 1 ]; then
    warn "ERGON_SKIP_NEWS=1 — marking the news read"
    # sudo, and VERIFIED.
    #
    # informant's read state lives under /var, so this needs root. It used to
    # run as the user with `|| true`, which silently did nothing: the flag
    # claimed to skip the gate, provisioning continued past it, and then
    # pacman's informant HOOK aborted the first transaction that actually had
    # something to install. It looked like the flag worked for as long as every
    # package happened to be up to date.
    sudo informant read --all >/dev/null 2>&1 || true
    if informant check >/dev/null 2>&1; then
      ok "news marked read; pacman is unblocked"
    else
      warn "could not clear the news — pacman's hook will abort the first transaction"
      warn "run:  sudo informant read"
      exit 1
    fi
  else
    echo
    echo "   Read it, then re-run:   informant read" >&2
    echo "   Or, to skip:            ERGON_SKIP_NEWS=1 $0" >&2
    exit 1
  fi
fi

# --needed makes this a no-op for anything already present. No -y: refreshing
# the db and installing in one transaction is the partial-upgrade footgun.
sudo pacman -Sy --noconfirm >/dev/null
mapfile -t PKGS < <(_pkglist "$ERGON/packages/pacman")
sudo pacman -S --needed --noconfirm "${PKGS[@]}"
ok "${#PKGS[@]} packages"

# ---------------------------------------------------------------------------
say "snapshots"
# arch-bootstrap.sh created the snapper config; this is the part that is safe to
# re-apply and easy to get wrong. The 10/10/10/10 timeline defaults are tuned
# for a fileserver and will fill a laptop that also carries a large swapfile.
if [ -f /etc/snapper/configs/root ]; then
  sudo sed -i \
    -e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' \
    -e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' \
    -e 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' \
    -e 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' \
    -e 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' \
    /etc/snapper/configs/root
  ok "snapper timeline trimmed"
else
  warn "no snapper root config — did arch-bootstrap.sh run?"
fi
# paccache keeps the last 3 versions. That cache lives on its own subvolume
# precisely so a rollback can still reach the packages needed to fix itself.
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer \
                            paccache.timer grub-btrfsd >/dev/null 2>&1 || true
sudo install -Dm644 /dev/stdin /etc/conf.d/pacman-contrib <<'EOF'
PACCACHE_ARGS='-rk3'
EOF
ok "snapshot + cache timers"

# Snapshots being bootable is worth little if recovering from a broken update
# needs someone who knows to pick one at the GRUB menu, on a machine that just
# failed to boot. The guard makes the machine do it: two boots that never reach
# the default target and the third boots the last one that did. It needs the
# EFI partition (its counter lives there, because GRUB must write it before the
# kernel runs) and snapper's layout, and says so and skips when either is
# missing -- a desktop installed some other way is unaffected.
"$ERGON/bin/ergon-boot-guard" install || warn "boot guard not installed (see the message above)"

# ---------------------------------------------------------------------------
say "services"
for u in NetworkManager docker tailscaled bluetooth fwupd; do
  if systemctl list-unit-files "$u.service" >/dev/null 2>&1; then
    sudo systemctl enable --now "$u" >/dev/null 2>&1 && ok "$u" || skip "$u (not installed)"
  fi
done
groups | grep -qw docker || { sudo usermod -aG docker "$USER"; ok "added $USER to docker (re-login required)"; }

# ---------------------------------------------------------------------------
say "graphics"
# The Vulkan ICD is chosen from what is on the PCI bus, not assumed.
#
# packages/pacman carries mesa and the loader, which every machine needs; the
# per-vendor driver is decided here so an AMD laptop does not drag in Intel and
# Nouveau for nothing. Hyprland without an ICD still starts and renders through
# llvmpipe, which feels broken in a way that reads as a compositor bug rather
# than a missing package -- so this is not optional polish.
GPUS=$(/sbin/lspci -nn 2>/dev/null | grep -iE 'vga|3d controller|display controller' || true)
GFX=""
printf '%s' "$GPUS" | grep -qiE 'amd|ati|radeon' && GFX="$GFX vulkan-radeon"
printf '%s' "$GPUS" | grep -qi 'intel'            && GFX="$GFX vulkan-intel intel-media-driver"
printf '%s' "$GPUS" | grep -qiE 'nvidia'          && {
  # Deliberately the open kernel modules and NOT the proprietary blob: nouveau
  # cannot drive modern cards, and nvidia-open is what upstream now recommends
  # for Turing and later. Anything older needs a human decision, so say so
  # rather than installing something that will not work.
  GFX="$GFX nvidia-open-dkms nvidia-utils"
  warn "nvidia detected — nvidia-open-dkms covers Turing and later."
  warn "  Older cards need the legacy driver chosen by hand; Wayland support varies."
}
if [ -n "$GFX" ]; then
  # shellcheck disable=SC2086
  sudo pacman -S --needed --noconfirm $GFX >/dev/null && ok "graphics:$GFX" \
    || warn "some graphics packages failed:$GFX"
else
  skip "no GPU recognised on the PCI bus — mesa software rendering only"
fi

# ---------------------------------------------------------------------------
say "hardware"
# Quirks that belong to ONE machine, selected by matching DMI rather than by
# assuming. This used to be inline here, behind conditionals reading "or not
# FW13" -- fine for one laptop, and exactly the "works on my laptop" shape for
# a distro: the first person to install this on a ThinkPad with Nvidia would
# inherit decisions made about a panel they do not have.
#
# See hardware/README.md. A profile that matches nothing is inert.
#
# ERGON_HARDWARE=<name> forces one, which is how the VM test exercises the
# Framework profile on a machine whose DMI says QEMU.
"$ERGON/bin/ergon-hardware" apply || warn "hardware profile failed to apply"

# ---------------------------------------------------------------------------
say "login policy"
# Login lockout: Arch ships deny=3, unlock_time=600.
#
# Three typos locks you out of your own laptop for ten minutes. On a machine
# that already demands a LUKS passphrase at boot, that is punishment rather than
# security -- the attacker who has the powered-off disk is not the one being
# slowed down, you are, at an observatory at 3am with cold hands.
#
# 10 attempts, 2 minutes, and the counter forgets after 15. Still bounded
# against someone sitting at an unlocked-but-logged-out machine, which is the
# only threat this control actually addresses.
sudo install -Dm644 /dev/stdin /etc/security/faillock.conf <<'EOF'
deny = 10
unlock_time = 120
fail_interval = 900
EOF
ok "login lockout relaxed (10 tries, 2 min)"
# ---------------------------------------------------------------------------
say "wifi regulatory domain"
# ArchWiki rates the RZ717/MT7925 "poor support" and notes throughput is very
# limited until the regdomain is set -- without it you can end up pinned to
# 2.4 GHz. Set it in provisioning, not by hand at an observatory.
#
# Derived from the system timezone rather than hardcoded. This said CL, which
# is right for exactly one person: transmit power and which channels exist are
# legally determined by where the machine is, and shipping a distro that
# silently tells a German laptop it is in Chile is both wrong and unlawful
# there. zoneinfo already carries the timezone-to-country mapping.
TZ_NOW=$(timedatectl show -p Timezone --value 2>/dev/null || readlink -f /etc/localtime | sed 's|.*/zoneinfo/||')
REGDOM=$(awk -v t="$TZ_NOW" '$1 !~ /^#/ && $3 == t { print $1; exit }' \
           /usr/share/zoneinfo/zone.tab 2>/dev/null | cut -c1-2)
[ -n "$REGDOM" ] || REGDOM=00     # 00 is the world-safe fallback domain
sudo install -Dm644 /dev/stdin /etc/modprobe.d/cfg80211.conf <<EOF
options cfg80211 ieee80211_regdom=$REGDOM
EOF
ok "regdom=$REGDOM (from $TZ_NOW)"

# ---------------------------------------------------------------------------
say "desktop session"
# greetd + tuigreet, launching Hyprland through uwsm.
#
# uwsm matters more than the greeter does: without it every app you open is a
# child process of the compositor, so a Hyprland crash or reload takes the whole
# session's apps with it. Under uwsm the session is a systemd slice and apps get
# their own scopes. hyprland-uwsm.desktop is shipped by the hyprland package
# itself, not by uwsm.
# The --cmd is what tuigreet runs AFTER authenticating, and getting it wrong
# gives a greeter that accepts your password and then returns to the greeter --
# which is what this did. Two mistakes were in the original:
#
#   * it pointed uwsm at hyprland-uwsm.desktop, whose own Exec is
#     "uwsm start -e -D Hyprland hyprland.desktop" -- so uwsm was being asked
#     to start uwsm. Point it at the PLAIN hyprland.desktop.
#   * -S is not a uwsm flag. uwsm start takes -D -a -e -N -C -U -t -T -F -g -G
#     -o -n, and errors on anything else.
#
# This line now matches, exactly, what the packaged hyprland-uwsm.desktop runs.
sudo install -Dm644 /dev/stdin /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-user-session --asterisks --cmd 'uwsm start -e -D Hyprland hyprland.desktop'"
user = "greeter"
EOF
sudo systemctl enable greetd >/dev/null 2>&1 || true
ok "greetd + tuigreet on vt1"

# Group membership, both of which are silent failures rather than errors:
#   video  -- brightnessctl writes /sys/class/backlight; without it the
#             brightness keys do nothing and report no error at all.
#   input  -- swayosd's libinput backend reads /dev/input for caps-lock state.
for g in video input; do
  groups | grep -qw "$g" || { sudo usermod -aG "$g" "$USER"; ok "added $USER to $g (re-login required)"; }
done

# Caps-lock / num-lock OSD. A SYSTEM service (it reads /dev/input), unlike
# swayosd-server which autostart.lua runs in the session.
sudo systemctl enable --now swayosd-libinput-backend.service >/dev/null 2>&1 \
  && ok "swayosd libinput backend" || skip "swayosd backend (not installed yet)"

# ~/Pictures, ~/Downloads and friends. The GTK file chooser falls back to $HOME
# for everything without them, so every save dialog opens in the wrong place.
command -v xdg-user-dirs-update >/dev/null && xdg-user-dirs-update && ok "xdg user dirs"

# GTK4 reads the theme from gsettings rather than settings.ini. gtk/settings.ini
# is linked by install.sh and covers GTK3 plus a fresh machine; this covers GTK4
# on a machine that has a session bus. Over ssh there is none, hence the guard.
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v gsettings >/dev/null; then
  gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
  gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
  gsettings set org.gnome.desktop.interface icon-theme 'Papirus-Dark'
  gsettings set org.gnome.desktop.interface cursor-theme 'Adwaita'
  gsettings set org.gnome.desktop.interface font-name 'Noto Sans 11'
  ok "GTK4 dark theme"
else
  skip "gsettings (no session bus — re-run from a graphical login)"
fi

# The wallpaper is derived from the palette at the panel's resolution and lives
# outside the repo. Generating it here is what makes a fresh install come up
# with a desktop rather than a black screen.
if command -v magick >/dev/null; then
  "$ERGON/bin/ergon-wallpaper" >/dev/null 2>&1 && ok "wallpaper" || skip "wallpaper (run ergon wallpaper from a session)"
else
  skip "wallpaper (imagemagick not installed)"
fi

# The themed configs are generated from theme/cool.env and committed. Rendering
# here would dirty the tree on every provision; checking costs nothing.
if ! "$ERGON/bin/ergon-theme" --check >/dev/null 2>&1; then
  warn "themed configs are stale in the repo — run 'ergon theme' and commit"
fi

# ---------------------------------------------------------------------------
say "AUR packages"
# Three packages does not justify a helper. Clone, review once, makepkg.
#
# ERGON_SKIP_AUR=1 skips only the packages whose line in packages/aur is marked
# "(slow build)". It exists because these build from SOURCE: wezterm-git alone is
# a long Rust build, intolerable in a VM test and unwelcome the first time you
# provision a machine you want to start using. binds.lua carries a foot escape
# hatch precisely so a machine without wezterm still has a terminal.
#
# It used to skip the stage ENTIRELY, which was fine while the only AUR package
# that mattered was a nicer terminal. It stopped being fine when waybar moved
# here: a desktop without waybar-git has a bar whose workspace buttons do
# nothing, so "skip the slow builds" and "skip the desktop working" became the
# same flag. Hence the marker -- the distinction is per package, not per stage.
_aurlist() {
  awk -v skipslow="${ERGON_SKIP_AUR:-0}" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { if (skipslow == "1" && $0 ~ /\(slow build\)/) next
      print $1 }' "$1"
}
if [ "${ERGON_SKIP_AUR:-0}" = 1 ]; then
  skip "slow AUR builds (ERGON_SKIP_AUR=1) -- run again without it for wezterm"
fi
AURDIR="$HOME/.cache/aur"; mkdir -p "$AURDIR"
while read -r pkg; do
  if AURDIR="$AURDIR" "$ERGON/bin/ergon-aur" "$pkg"; then
    ok "$pkg"
  else
    warn "$pkg FAILED to build — see $AURDIR/$pkg"
  fi
done < <(_aurlist "$ERGON/packages/aur")

# A git package can fail to build on any given day, and waybar is the one whose
# absence is not survivable: no bar at all, on a desktop with no other status
# surface. Fall back to the repo build, which works in every respect except the
# one that put waybar in packages/aur -- clicking a workspace.
if ! command -v waybar >/dev/null 2>&1; then
  warn "waybar-git is not installed; falling back to extra/waybar"
  warn "  the bar will work EXCEPT that clicking a workspace does nothing"
  warn "  (Alexays/Waybar#5013 — see packages/aur)"
  sudo pacman -S --needed --noconfirm waybar || warn "extra/waybar failed too"
fi

# ---------------------------------------------------------------------------
say "per-host directory"
# The hostname is chosen at install time (arch-bootstrap.sh prompts for it and
# writes /etc/hostname), so hosts/<name>/ cannot be pre-committed. Scaffold it
# here from the template; it stays untracked until you commit it.
HOST=$(hostname -s 2>/dev/null || cat /etc/hostname)
if [ -d "$ERGON/hosts/$HOST" ]; then
  skip "hosts/$HOST already exists"
else
  mkdir -p "$ERGON/hosts/$HOST"
  sed -e 's/^GRAPHICAL=0/GRAPHICAL=1/' -e 's/^PROFILE=server/PROFILE=laptop/' \
      "$ERGON/hosts/_template/host.env" > "$ERGON/hosts/$HOST/host.env"
  # The keyboard layout the installer was told about. hypr/common/looknfeel.lua
  # used to hardcode kb_layout = "us", which silently gave every non-US user a
  # US graphical layout no matter what they answered at install -- and unlike a
  # wrong locale, you find out by typing your password wrong.
  #
  # /etc/vconsole.conf is written by arch-bootstrap.sh from the chosen KEYMAP,
  # so this reads the answer rather than asking again.
  KB=$(awk -F= '/^KEYMAP=/ { gsub(/"/, "", $2); print $2 }' /etc/vconsole.conf 2>/dev/null)
  KB=${KB:-us}
  cat > "$ERGON/hosts/$HOST/hyprland.lua" <<HYPRHOST
-- Machine-specific Hyprland config. Loaded by hypr/hyprland.lua via
--   pcall(require, "hosts." .. hostname)
-- so this file is optional and a syntax error in it cannot take down the base.

-- Keyboard, from the keymap chosen at install (/etc/vconsole.conf).
-- The console keymap and the Wayland layout are different settings with
-- different vocabularies; if yours needs a variant, set it here.
hl.config({ input = { kb_layout = "$KB" } })

HYPRHOST
  cat >> "$ERGON/hosts/$HOST/hyprland.lua" <<'HYPRHOST'
-- Machine-specific Hyprland config. Loaded by hypr/hyprland.lua via
--   pcall(require, "hosts." .. hostname)
-- so this file is optional and a syntax error in it cannot take down the base.
--
-- Fill in once you can see the panel. `hyprctl monitors` gives the real names
-- and modes. The Framework 13 2.8K panel is 2880x1920; scale 2 gives 1440x960
-- logical and integer scaling, which keeps GTK3 apps (including emacs-wayland,
-- which is pgtk-on-GTK3 and has no wp-fractional-scale-v1) sharp.
-- hl.monitor("eDP-1", { mode = "2880x1920@120", position = "0x0", scale = 2 })
HYPRHOST
  ok "scaffolded hosts/$HOST (untracked — commit it)"
fi

# ---------------------------------------------------------------------------
say "bundles"
# Optional package groups: inference, astronomy, ml, gpu, julia, latex,
# notebooks. See packages/bundles/README.md.
#
# The choice is ASKED once and RECORDED in hosts/<host>/host.env, so
# reprovisioning reproduces the machine and `ergon-bundle add` works the same way
# afterwards. Nobody knows at partition time whether they will want the ML stack
# in March, so the installer prompt is a convenience wrapper around a command
# that keeps working, not a one-shot gate.
#
# ERGON_BUNDLES=... answers non-interactively; ERGON_BUNDLES=none takes none.
# It takes sources too (github:me/overlay//fleet@v1), with --yes: naming one in
# the environment IS the answer, since there is nobody at a terminal to ask.
if [ -n "${ERGON_BUNDLES:-}" ]; then
  if [ "$ERGON_BUNDLES" = none ]; then
    skip "bundles (ERGON_BUNDLES=none)"
  else
    # A bundle that fails to install must not take the whole provision with it,
    # any more than a failed AUR build does. The machine is still usable; the
    # bundle is a choice, and the user needs to be told which one did not land
    # rather than handed "provision-arch.sh failed" twenty minutes in.
    # shellcheck disable=SC2086
    "$ERGON/bin/ergon-bundle" add --yes $ERGON_BUNDLES || warn "some bundles failed to install"
  fi
elif [ -t 0 ]; then
  echo
  "$ERGON/bin/ergon-bundle" list
  echo
  echo "   Which bundles? (space separated, empty for none — ergon-bundle add <name> later)"
  printf '   > '
  read -r _bundles
  if [ -n "$_bundles" ]; then
    # shellcheck disable=SC2086
    "$ERGON/bin/ergon-bundle" add $_bundles || warn "some bundles failed to install"
  else
    skip "no bundles chosen"
  fi
else
  # Non-interactive and unanswered: apply whatever host.env already declares
  # rather than silently installing nothing on a reprovision.
  "$ERGON/bin/ergon-bundle" sync || warn "some bundles failed to install"
fi

# ---------------------------------------------------------------------------
say "editor tooling"
# Isolated per-tool venvs, matching the Macs. NOT the AUR basedpyright, which
# has depends=('nodejs') and would tie an LSP server to the system node.
for t in basedpyright ruff; do
  if command -v "$t" >/dev/null 2>&1 || [ -x "$HOME/.local/bin/$t" ]; then
    skip "$t"
  else
    uv tool install "$t" >/dev/null && ok "$t"
  fi
done

# Tree-sitter grammars are per-machine (they live outside the repo in
# ~/.emacs.d/tree-sitter), so they have to be built here, not synced.
if command -v emacs >/dev/null && [ -f "$HOME/.emacs.d/init.el" ]; then
  emacs --batch -l "$HOME/.emacs.d/init.el" --eval '(my/treesit-install-missing)' \
    >/dev/null 2>&1 && ok "tree-sitter grammars" || warn "grammar build failed — run M-x my/treesit-install-missing"
fi

say "done"
cat <<'EOF'

  Next:
    tailscale up --accept-routes       # *.jvines.cl resolves to a LAN literal;
                                       # chiki advertises 192.168.0.0/24
    ~/ergonOS/install.sh
    re-login for the docker group

  NOT to run here: enroll-debian-node.sh. See the header.
EOF
