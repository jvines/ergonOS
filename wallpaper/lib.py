"""Shared machinery for wallpaper generators.

A generator's job is to produce a 2-D float array of "how much is here" — a
density, a field, an occupancy count. This module turns that into an image in
the active palette. Splitting it that way means a generator contains only the
physics, and every generator gets identical colour handling for free.

Dependencies are numpy and matplotlib ONLY, both already in the base pyfleet
venv (see packages/python). Nothing here needs scipy, Pillow or a system
python, because a wallpaper generator that pulls a dependency tree is a
wallpaper generator that stops working.

Why generated at all: a photograph has a licence, a fixed resolution and a
fixed palette. A simulation has none of those. It renders at the panel's exact
size, it is coloured from whichever palette is active, it is reproducible from
a seed, and it is ours because we computed it.
"""

import numpy as np
from matplotlib.colors import LinearSegmentedColormap


def load_palette(path):
    """Read a theme/*.env into {COOL_BG0: '#1A1A2E', ...}.

    The same flat format ergon-theme reads. Values may carry a trailing
    comment, which is why this takes the first whitespace-delimited token and
    not the rest of the line.
    """
    out = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            val = val.split()[0].strip()
            if val.startswith("#") and len(val) == 7:
                out[key.strip()] = val
    return out


def ramp_cmap(palette, reverse=False):
    """A colormap from the palette's five-step ramp, grounded in BG0.

    BG0 is the first stop rather than the ramp's own dark end, so that empty
    regions of the field land exactly on the desktop background and the image
    has no edge. A wallpaper whose corners are a slightly different dark from
    the compositor's is worse than one with no structure at all.
    """
    stops = [palette["COOL_BG0"]] + [palette[f"COOL_{i}"] for i in range(5)]
    if reverse:
        stops = [stops[0]] + stops[1:][::-1]
    return LinearSegmentedColormap.from_list("ergon", stops)


def normalise(field, gamma=0.45, clip=99.5):
    """Field -> 0..1, with the long tail of a density compressed.

    Attractor densities are extremely peaked: a few cells collect orders of
    magnitude more visits than the rest, so a linear scale shows one bright
    smear on black and loses the structure that makes the thing worth looking
    at. The percentile clip drops the outliers and gamma lifts the floor.
    """
    field = np.asarray(field, dtype=float)
    hi = np.percentile(field[field > 0], clip) if np.any(field > 0) else 1.0
    if hi <= 0:
        hi = 1.0
    return np.clip(field / hi, 0.0, 1.0) ** gamma


def render(field, palette, out, blend=0.55, reverse=False, gamma=0.45):
    """Write `field` as a wallpaper PNG in the palette's colours.

    `blend` is how far toward full colour the structure is taken. It is well
    below 1 on purpose: this is a surface that windows sit on top of all day,
    and it has to stay quiet. The existing gradient uses 18%; structure carries
    more visual weight than a gradient, so it gets less headroom than the
    number alone suggests.
    """
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    v = normalise(field, gamma=gamma)
    cmap = ramp_cmap(palette, reverse=reverse)
    rgb = cmap(v)[..., :3]

    bg = np.array([int(palette["COOL_BG0"][i:i + 2], 16) / 255 for i in (1, 3, 5)])
    rgb = bg + (rgb - bg) * blend

    # Dither, for the same reason ergon-wallpaper dithers: a low-contrast image
    # spans few 8-bit levels and bands visibly on a large panel. One level of
    # noise breaks the steps without measurably costing file size.
    rng = np.random.default_rng(0)
    rgb = np.clip(rgb + (rng.random(rgb.shape) - 0.5) / 255.0 * 2.0, 0, 1)

    plt.imsave(out, rgb)
    return out


def histogram2d(xs, ys, size, extent=None, pad=0.04):
    """Bin a trajectory into a (h, w) density, preserving aspect.

    A trajectory is a list of points; the wallpaper is a raster. Binning rather
    than drawing lines is what makes the density -- where the system spends its
    time -- the thing you see, which is the interesting statement an attractor
    makes.
    """
    w, h = size
    if extent is None:
        xr = xs.max() - xs.min()
        yr = ys.max() - ys.min()
        extent = (
            xs.min() - xr * pad, xs.max() + xr * pad,
            ys.min() - yr * pad, ys.max() + yr * pad,
        )
    x0, x1, y0, y1 = extent

    # Match the panel's aspect so the attractor is not stretched. The shorter
    # axis is widened rather than the longer one cropped: cropping an attractor
    # cuts off the lobes that make it recognisable.
    agot = (x1 - x0) / (y1 - y0)
    awant = w / h
    if agot < awant:
        cx, half = (x0 + x1) / 2, (y1 - y0) * awant / 2
        x0, x1 = cx - half, cx + half
    else:
        cy, half = (y0 + y1) / 2, (x1 - x0) / awant / 2
        y0, y1 = cy - half, cy + half

    field, _, _ = np.histogram2d(
        ys, xs, bins=(h, w), range=[[y0, y1], [x0, x1]]
    )
    return field
