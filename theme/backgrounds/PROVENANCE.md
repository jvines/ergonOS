# Shipped backgrounds

Every image in this directory must have a row in the table below. `ergon-lint`
enforces it, and an image without one fails the build.

That rule exists because the alternative is visible upstream. Omarchy ships 92
wallpapers with no attribution and no per-image licence anywhere in its tree; in
v3 the filenames at least named the photographers (`2-pawel-czerwinski.jpg`),
and v4 renamed them to descriptions (`2-swirl-buck.webp`), removing the last
trace of where they came from. A repository-wide MIT licence is a software
licence and does not cover third-party photographs.

A wallpaper is redistributed to every person who installs this OS. If its
licence is not established, it does not ship. "Found it on a wallpaper site" is
not a licence, and neither is "it was in someone else's repo".

## What is acceptable

- **CC0 / public domain**, with the source URL recorded.
- **A licence that explicitly permits redistribution** (e.g. CC BY, with the
  attribution given below; the Unsplash Licence). Record the exact licence name,
  not a paraphrase.
- **Generated**, by a script in this repo. Record the script and its arguments,
  so the image can be rebuilt rather than merely copied.
- **Our own work**, marked as such.

Anything whose terms cannot be pointed at does not go in this directory. Users
can always put their own images in `~/.config/ergon/backgrounds/`, which is
theirs and is never touched by this repo.

## Layout

    theme/backgrounds/<file>              shown for every palette
    theme/backgrounds/<palette>/<file>    shown only for that palette

## In the cycle, but not shipped

`bin/ergon-wallpaper` also offers `/usr/share/hypr/wall*.png` — the mascot art
the **hyprland package** installs, the same images its
`misc:disable_hyprland_logo` option turns off as an automatic background. They
are in the cycle so they can be chosen deliberately.

This is not an exception to the rule above, it is outside it. Nothing here
copies, renames or redistributes them: they are on the machine because hyprland
is installed, hyprpaper is handed the package's own path, and removing the
package removes them. The rule governs what **this repository** hands to someone
who installs it.

`ERGON_HYPR_WALLPAPERS` repoints that directory; on a machine without hyprland
it is absent and is skipped. Only `wall*.png` is taken: the same directory
holds `lockdead.png`, which is what hyprlock shows when it has crashed.

## Table

| file | source | author | licence | notes |
|---|---|---|---|---|

*(empty: nothing ships yet)*
