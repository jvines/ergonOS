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
    ap.add_argument("--saturation", type=float, default=None)
    ap.add_argument("--exposure", type=float, default=None)
    ap.add_argument("--fit", default=None, help="cover or contain")
    ap.add_argument("--zoom", type=float, default=None)
    ap.add_argument("--no-title", action="store_true")
    # The field costs minutes and the colouring costs a second. Saving it means
    # trying a palette, a stretch or a gamma does not re-run the simulation --
    # which is the difference between iterating on how it looks and iterating
    # on how long it takes.
    ap.add_argument("--save-field", default=None,
                    help="write the raw field as .npy for re-colouring")
    # The counterpart: colour a field that was computed earlier. The field is
    # PALETTE-INDEPENDENT -- a generator produces a scalar density and the
    # palette only decides how that maps to colour -- so every palette can be
    # served from one simulation.
    ap.add_argument("--from-field", default=None,
                    help="colour this saved .npy instead of simulating")
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
    sat = args.saturation if args.saturation is not None else \
        getattr(mod, "SATURATION", lib.DEFAULT_SATURATION)
    expo = args.exposure if args.exposure is not None else \
        getattr(mod, "EXPOSURE", lib.DEFAULT_EXPOSURE)
    ramp = getattr(mod, "RAMP", "full")
    reverse = args.reverse or getattr(mod, "REVERSE", False)
    # In pixels of the image being coloured, because both are anti-aliasing
    # filters: they act at the scale of the pixel grid whatever its size.
    soften = getattr(mod, "SOFTEN", 0.0)
    hue_smooth = getattr(mod, "HUE_SMOOTH", 0.0)

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
    if args.from_field:
        field = np.load(args.from_field)
        # Downsample the FIELD to the requested size before colouring.
        #
        # Fields are stored at 4K because that is the master, but re-colouring
        # for a palette switch only has to produce what will be shown. Colouring
        # 9.2M pixels and then having the compositor scale them down costs about
        # fifteen seconds an image; colouring 1M costs about one. Measured in
        # the test VM, eight of the former saturated four vCPUs and made the
        # session's own shells crawl, which is not an acceptable price for
        # changing a colour.
        #
        # Area-averaged, and only by a whole number of pixels -- the common case
        # by construction, since the field was rendered at the panel's aspect.
        fh, fw = field.shape
        if (fw, fh) != (w, h) and fw % w == 0 and fh % h == 0 and fw // w == fh // h:
            field = lib.downsample(field, fw // w)
    else:
        ss = max(1, args.supersample)
        field = mod.generate((w * ss, h * ss), seed=args.seed, **kw)
        if ss > 1:
            field = lib.downsample(field, ss)
    if args.save_field:
        np.save(args.save_field, field)
    # The caption. A module whose caption depends on the seed -- which view,
    # which parameters -- defines caption(seed) -> (title, subtitle).
    #
    # Assigning a module global from inside generate() looks equivalent and is
    # not: re-colouring from a saved field, which every palette switch does,
    # never calls generate(), so the caption silently reverted to the module's
    # default. ergon-lint rejects that pattern for exactly this reason.
    if callable(getattr(mod, "caption", None)):
        title, subtitle = mod.caption(args.seed)
    else:
        title, subtitle = getattr(mod, "TITLE", None), getattr(mod, "SUBTITLE", None)
    lib.render(field, palette, args.out, blend=blend, reverse=reverse, ramp=ramp,
               scale=scale, gamma=gamma, saturation=sat, exposure=expo,
               soften=soften, hue_smooth=hue_smooth,
               title=None if args.no_title else title,
               subtitle=None if args.no_title else subtitle)
    print(f"{args.out} ({w}x{h}, {time.time() - t0:.1f}s)")


if __name__ == "__main__":
    main()
