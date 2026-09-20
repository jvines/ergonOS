"""Entry point: render one generator into a wallpaper.

    python render.py --generator lorenz --palette theme/cool.env \
                     --size 2880x1920 --seed 0 --out /tmp/lorenz.png

Kept deliberately thin. Everything about how a field becomes an image lives in
lib.py, and everything about the physics lives in the generator, so this file
only has to know how to connect them and what to call the result.
"""

import argparse
import importlib

import numpy as np
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import lib  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--generator", required=True)
    ap.add_argument("--palette", required=True)
    ap.add_argument("--size", default="2880x1920")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", required=True)
    # Default comes from the generator, which knows whether it fills the panel.
    ap.add_argument("--blend", type=float, default=None)
    ap.add_argument("--reverse", action="store_true")
    ap.add_argument("--fit", default=None, help="cover or contain")
    ap.add_argument("--zoom", type=float, default=None)
    ap.add_argument("--no-title", action="store_true")
    # The field costs minutes and the colouring costs a second. Saving it means
    # trying a palette, a stretch or a gamma does not re-run the simulation --
    # which is the difference between iterating on how it looks and iterating
    # on how long it takes.
    ap.add_argument("--save-field", default=None,
                    help="write the raw field as .npy for re-colouring")
    ap.add_argument("--supersample", type=int, default=3,
                    help="render at this multiple of the panel, then average down")
    args = ap.parse_args()

    w, h = (int(v) for v in args.size.lower().split("x"))
    palette = lib.load_palette(args.palette)
    for key in ("COOL_BG0", "COOL_0", "COOL_4"):
        if key not in palette:
            sys.exit(f"palette {args.palette} has no {key}")

    mod = importlib.import_module(args.generator)

    blend = args.blend if args.blend is not None else getattr(mod, "BLEND", 0.45)
    scale = getattr(mod, "SCALE", "linear")
    gamma = getattr(mod, "GAMMA", 0.45)

    t0 = time.time()
    kw = {}
    if args.fit is not None: kw["fit"] = args.fit
    if args.zoom is not None: kw["zoom"] = args.zoom
    # SUPERSAMPLE the whole generator, then area-average down.
    #
    # This is what removes moire and colour fringing, and neither is fixable
    # afterwards. Both come from sampling structure finer than the pixel grid
    # at exactly one sample per pixel: an attractor's filaments and a PDE's
    # stripes both have detail below a pixel, and at 1:1 that detail beats
    # against the grid and reappears as false large-scale patterns. Computing
    # at ss times the panel and averaging each ss x ss block puts several
    # samples inside every output pixel, so sub-pixel detail averages into
    # tone instead of aliasing into a pattern that is not there.
    #
    # Done HERE rather than inside a generator so every generator gets it,
    # including the ones that build a field directly and never bin anything.
    ss = max(1, args.supersample)
    field = mod.generate((w * ss, h * ss), seed=args.seed, **kw)
    if ss > 1:
        field = lib.downsample(field, ss)
    if args.save_field:
        np.save(args.save_field, field)
    lib.render(field, palette, args.out, blend=blend, reverse=args.reverse,
               scale=scale, gamma=gamma,
               title=None if args.no_title else getattr(mod, "TITLE", None),
               subtitle=None if args.no_title else getattr(mod, "SUBTITLE", None))
    print(f"{args.out} ({w}x{h}, {time.time() - t0:.1f}s)")


if __name__ == "__main__":
    main()
