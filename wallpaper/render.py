"""Entry point: render one generator into a wallpaper.

    python render.py --generator lorenz --palette theme/cool.env \
                     --size 2880x1920 --seed 0 --out /tmp/lorenz.png

Kept deliberately thin. Everything about how a field becomes an image lives in
lib.py, and everything about the physics lives in the generator, so this file
only has to know how to connect them and what to call the result.
"""

import argparse
import importlib
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
    args = ap.parse_args()

    w, h = (int(v) for v in args.size.lower().split("x"))
    palette = lib.load_palette(args.palette)
    for key in ("COOL_BG0", "COOL_0", "COOL_4"):
        if key not in palette:
            sys.exit(f"palette {args.palette} has no {key}")

    mod = importlib.import_module(args.generator)

    blend = args.blend if args.blend is not None else getattr(mod, "BLEND", 0.45)

    t0 = time.time()
    field = mod.generate((w, h), seed=args.seed)
    lib.render(field, palette, args.out, blend=blend, reverse=args.reverse)
    print(f"{args.out} ({w}x{h}, {time.time() - t0:.1f}s)")


if __name__ == "__main__":
    main()
