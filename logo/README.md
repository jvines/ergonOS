# ergonOS logo

The approved mark and wordmark (ERGON-161). Do not change the shapes; a new
look is a new card.

| file | what it is |
|---|---|
| `ergon-mark-{light,dark}.svg` | the symbol. `light` is white (for dark backgrounds), `dark` is #0D0D12 |
| `ergon-wordmark-*.svg` | "ergon" |
| `ergon-lockup-*.svg` | symbol and word side by side |
| `ergon-lockup-stacked-*.svg` | symbol over word (boot splash, lock screen) |
| `png/ergon-mark-{16..512}.png` | the symbol at fixed sizes |
| `term/ergon-{24x10,36x15,60x25}.txt` | half-block terminal art (fastfetch, screensaver) |
| `preview.png` | everything at a glance |

The wordmark is Chakra Petch SemiBold (SIL OFL 1.1, Cadson Demak), converted to
paths, so no font is needed to draw it. The mark is ergonOS's own.

## Where it is used

Surfaces that follow the palette do not carry a copy of a hex colour; they are
templates rendered from the active palette:

- Waybar menu button: `waybar/logo-dim.svg.in` and `logo-active.svg.in`, rendered by
  `ergon theme` (the `*.in` loop) and drawn as a CSS background of `#custom-menu`.
- Lock screen: `hypr/lock-logo.svg.in`, rasterised by `ergon theme` to
  `~/.local/share/ergon/lock-logo.png` for hyprlock.
- Boot splash: `bin/ergon-plymouth` recolours `ergon-lockup-stacked-light.svg` to
  the palette's foreground and writes `logo.png` into the Plymouth theme.
- fastfetch: `fastfetch/logo.txt` links to `term/ergon-24x10.txt`.
- Screensaver: `bin/ergon-screensaver` animates `term/` art with `tte`.

The mark's path data is copied into the `.in` files; `bin/test-logo.sh` fails
if any copy differs from `ergon-mark-light.svg`.
