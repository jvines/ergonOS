"""Re-colour every cached background into one palette, in ONE process.

    python recolour.py --palette theme/gruvbox.env --cache ~/.local/share/ergon/prepared \
                       --out ~/.local/share/ergon/backgrounds/gruvbox

This exists because of where the time actually goes. render.py is one image per
invocation, which is right when you are generating one -- and wrong when a
palette switch asks for sixty-nine, because importing matplotlib costs about a
second and the colouring itself costs 0.4:

    render.py --from-prepared, per image      1.5 s   (1.1 s of it is `import`)
    this file, per image after the first      0.4 s

Sixty-nine backgrounds is the difference between a hundred seconds and thirty.

What it does NOT do is re-derive anything. The cache holds lib.prepare()'s
output -- the field's downsample, SOFTEN's Gaussian, the normalise and
HUE_SMOOTH's two more -- none of which depends on a palette. This file is
lib.colourise() in a loop: a 512-entry lookup, a two-colour ground, a blend and
the caption.

The caption comes from the generator module, not from the cache, for the reason
ergon-lint already enforces elsewhere: a caption that depended on generate()
having run would silently revert to the module default on every re-colour, and
re-colouring is the ONLY thing that happens after a palette switch.
"""

import argparse
import importlib
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import lib  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--palette", required=True)
    ap.add_argument("--cache", required=True,
                    help="directory of <gen>-<seed>.npz from render.py --save-prepared")
    ap.add_argument("--out", required=True, help="directory to write <gen>-<seed>.png into")
    ap.add_argument("--only", default=None,
                    help="one <gen>-<seed>, for the background actually on screen")
    ap.add_argument("--force", action="store_true",
                    help="rewrite images that are already newer than their cache entry")
    # Interruptible, because this run holds a lock that the NEXT palette switch
    # has to wait for. Measured in the VM: 69 images in 119.4s, against a
    # `flock -w 120` in ergon-wallpaper-gen -- so a switch arriving one image in
    # waits out the whole set and then gives up having done nothing, and its
    # palette gets no backgrounds at all. One stat per image ends that: this
    # process stops within one image of a switch, the waiter gets the lock in
    # seconds, and the palette the user actually chose is the one that is served.
    ap.add_argument("--expect", default=None,
                    help="the palette name this run is for; with --palette-state, stop "
                         "as soon as a different palette is chosen")
    ap.add_argument("--palette-state", default=None,
                    help="file holding the active palette name or path")
    args = ap.parse_args()

    def superseded():
        """The active palette, if it is no longer the one this run is for."""
        if not (args.expect and args.palette_state):
            return None
        try:
            with open(args.palette_state) as fh:
                now = fh.read().strip()
        except OSError:
            return None
        now = os.path.basename(now)
        if now.endswith(".env"):
            now = now[:-4]
        return now if now and now != args.expect else None

    palette = lib.load_palette(args.palette)
    for key in ("COOL_BG0", "COOL_0", "COOL_4"):
        if key not in palette:
            sys.exit(f"palette {args.palette} has no {key}")
    os.makedirs(args.out, exist_ok=True)

    names = sorted(n[:-4] for n in os.listdir(args.cache) if n.endswith(".npz"))
    if args.only:
        names = [n for n in names if n == args.only]
        if not names:
            sys.exit(f"no cache entry {args.only} in {args.cache}")

    t0 = time.time()
    done = skipped = failed = 0
    for name in names:
        other = superseded()
        if other:
            print(f"   {args.expect} superseded by {other} after {done} "
                  f"re-coloured; stopping so it can have the lock")
            break
        src = os.path.join(args.cache, name + ".npz")
        dst = os.path.join(args.out, name + ".png")
        # Newer than its input is up to date. The palette is part of the input
        # in the sense that matters -- a different palette writes into a
        # different --out directory, so there is no way for this to serve a
        # stale colour.
        if not args.force and os.path.exists(dst) \
                and os.path.getmtime(dst) >= os.path.getmtime(src):
            skipped += 1
            continue
        # <gen>-<seed>, the same shape ergon-wallpaper-gen files them under.
        gen, _, seed = name.rpartition("-")
        try:
            mod = importlib.import_module(gen)
        except Exception as exc:
            print(f"   no generator for {name}: {exc}", file=sys.stderr)
            failed += 1
            continue
        try:
            p = np.load(src)
            v = p["v"].astype(np.float32)
            hue = p["hue"].astype(np.float32)
            alpha = p["alpha"].astype(np.float32) if "alpha" in p else None
            if callable(getattr(mod, "caption", None)):
                title, subtitle = mod.caption(int(seed))
            else:
                title = getattr(mod, "TITLE", None)
                subtitle = getattr(mod, "SUBTITLE", None)
            # Written beside the target and moved into place, so a process that
            # dies half way cannot leave a torn PNG that the mtime check above
            # would then treat as current for ever.
            tmp = dst + f".new.{os.getpid()}.png"
            lib.colourise(
                v, hue, alpha, palette, tmp,
                blend=getattr(mod, "BLEND", 0.45),
                reverse=getattr(mod, "REVERSE", False),
                ramp=getattr(mod, "RAMP", "full"),
                saturation=getattr(mod, "SATURATION", lib.DEFAULT_SATURATION),
                exposure=getattr(mod, "EXPOSURE", lib.DEFAULT_EXPOSURE),
                title=title, subtitle=subtitle)
            os.replace(tmp, dst)
            done += 1
        except Exception as exc:
            print(f"   {name} failed: {exc}", file=sys.stderr)
            failed += 1

    print(f"   {done} re-coloured, {skipped} already current, {failed} failed "
          f"in {time.time() - t0:.1f}s")
    return 1 if failed and not done else 0


if __name__ == "__main__":
    sys.exit(main())
