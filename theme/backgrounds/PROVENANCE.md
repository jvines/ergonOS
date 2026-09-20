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

## Table

| file | source | author | licence | notes |
|---|---|---|---|---|

*(empty: nothing ships yet)*
