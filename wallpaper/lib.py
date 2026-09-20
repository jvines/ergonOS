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

    # Interpolated in LINEAR LIGHT, not in sRGB.
    #
    # Blending sRGB values directly is the usual cause of a gradient that
    # looks harsh: sRGB is perceptually encoded, so a straight lerp between
    # two stops moves quickly through some of the range and slowly through
    # the rest, and the joins between stops show as creases. Undoing the
    # transfer function, interpolating in the linear space where light
    # actually adds, and re-encoding gives even steps and no visible seams.
    rgb = np.array([
        [int(s.lstrip("#")[i:i + 2], 16) / 255 for i in (0, 2, 4)]
        for s in stops
    ])
    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)

    n = 512
    t = np.linspace(0, 1, n)
    src = np.linspace(0, 1, len(stops))
    out = np.stack([np.interp(t, src, lin[:, c]) for c in range(3)], axis=1)
    out = np.where(out <= 0.0031308, out * 12.92,
                   1.055 * np.maximum(out, 0) ** (1 / 2.4) - 0.055)
    return LinearSegmentedColormap.from_list("ergon", np.clip(out, 0, 1), N=n)


def normalise(field, gamma=0.45, clip=99.5, scale="linear"):
    """Field -> 0..1, with the long tail of a density compressed.

    Attractor densities are extremely peaked: a few cells collect orders of
    magnitude more visits than the rest, so a linear scale shows one bright
    smear on black and loses the structure that makes the thing worth looking
    at. The percentile clip drops the outliers and gamma lifts the floor.

    scale="log" goes further and is the right choice when the density spans
    orders of magnitude rather than a factor of a few. Lorenz is the case that
    forced this: linear-with-clip rendered the butterfly as a solid blob,
    because the two lobes are so much denser than the connecting sheet that
    clipping at the 99.5th percentile still left everything interesting in the
    top few percent of the range. Under log the lobes, the sheet and the
    unstable fixed points at the lobe centres are all visible at once.
    """
    field = np.asarray(field, dtype=float)
    if scale == "log":
        # +1 so empty cells stay exactly 0 and land on the background.
        field = np.log1p(field)
    hi = np.percentile(field[field > 0], clip) if np.any(field > 0) else 1.0
    if hi <= 0:
        hi = 1.0
    return np.clip(field / hi, 0.0, 1.0) ** gamma


def render(field, palette, out, blend=0.55, reverse=False, gamma=0.45,
           scale="linear", title=None, subtitle=None):
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

    v = normalise(field, gamma=gamma, scale=scale)
    cmap = ramp_cmap(palette, reverse=reverse)
    rgb = cmap(v)[..., :3]

    bg = np.array([int(palette["COOL_BG0"][i:i + 2], 16) / 255 for i in (1, 3, 5)])
    rgb = bg + (rgb - bg) * blend

    # Dither, for the same reason ergon-wallpaper dithers: a low-contrast image
    # spans few 8-bit levels and bands visibly on a large panel. One level of
    # noise breaks the steps without measurably costing file size.
    rng = np.random.default_rng(0)
    rgb = np.clip(rgb + (rng.random(rgb.shape) - 0.5) / 255.0 * 2.0, 0, 1)

    if not title:
        plt.imsave(out, rgb)
        return out

    # Caption, bottom left.
    #
    # A wallpaper computed from a named system should say which one. Without
    # it these are abstract patterns; with it the desktop tells you it is
    # showing the Sun-Jupiter co-orbital region, which is the entire point of
    # a science OS generating its own backgrounds.
    #
    # Drawn through a figure rather than imsave because imsave writes an array
    # and cannot draw text. figsize * dpi is set to the exact pixel size and
    # the axes fill the canvas, so the output is pixel-for-pixel what imsave
    # would have written, plus the text.
    dpi = 100.0
    h_px, w_px = rgb.shape[:2]
    fig = plt.figure(figsize=(w_px / dpi, h_px / dpi), dpi=dpi)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.imshow(rgb, interpolation="nearest", aspect="auto")
    ax.set_axis_off()

    # DIM, not FG0: this is a label on a wallpaper, not a heading. It should be
    # legible when looked for and invisible when not.
    col = palette.get("COOL_DIM", "#888888")
    pad = max(18, int(w_px * 0.018))
    size = max(9.0, w_px / 145.0)

    ax.text(pad, h_px - pad, title, color=col, alpha=0.62,
            family="monospace", fontsize=size, va="bottom", ha="left")
    if subtitle:
        ax.text(pad, h_px - pad - size * 1.9, subtitle, color=col, alpha=0.40,
                family="monospace", fontsize=size * 0.78, va="bottom", ha="left")

    fig.savefig(out, dpi=dpi, pad_inches=0)
    plt.close(fig)
    return out


def frame(xs, ys, size, extent=None, pad=0.0, fit="cover", zoom=1.18):
    """The (x0, x1, y0, y1) window this trajectory should be drawn in.

    Split out from histogram2d so a generator can compute the window ONCE from
    a small sample and then accumulate billions of points into it in bounded
    memory. Holding the points first does not scale: 220 million points is
    3.5 GB of float64 before anything is binned.
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

    agot = (x1 - x0) / (y1 - y0)
    awant = w / h
    contain = fit == "contain"
    if (agot < awant) == contain:
        cx, half = (x0 + x1) / 2, (y1 - y0) * awant / 2
        x0, x1 = cx - half, cx + half
    else:
        cy, half = (y0 + y1) / 2, (x1 - x0) / awant / 2
        y0, y1 = cy - half, cy + half

    if zoom != 1.0:
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        hx, hy = (x1 - x0) / 2 / zoom, (y1 - y0) / 2 / zoom
        x0, x1, y0, y1 = cx - hx, cx + hx, cy - hy, cy + hy

    return x0, x1, y0, y1


def _gauss1d(sigma):
    r = max(1, int(round(3 * sigma)))
    x = np.arange(-r, r + 1, dtype=np.float32)
    k = np.exp(-0.5 * (x / sigma) ** 2)
    return k / k.sum()


def smooth(field, sigma):
    """Separable Gaussian blur, numpy only.

    This is what actually removes the dots, and no amount of extra sampling
    would. A hard-binned histogram is Poisson in every cell: where the orbit
    visits a pixel once or twice, the result is a speck, and the gamma applied
    later amplifies exactly those cells. Convolving before the downsample
    turns each sample into a small smooth contribution instead of a hit in one
    cell -- the cheap equivalent of splatting a kernel per point, which is how
    the smooth renders of these systems are actually made.

    Done at the SUPERSAMPLED resolution, so sigma is in subpixels and the
    structure is not softened at the scale anyone looks at it.
    """
    if sigma <= 0:
        return field
    k = _gauss1d(sigma)
    pad = len(k) // 2
    a = np.pad(field.astype(np.float32), pad, mode="edge")
    # Two 1-D passes rather than a 2-D kernel: separable, so it is O(2r) per
    # pixel instead of O(r^2), which at these resolutions is the difference
    # between seconds and minutes.
    out = np.empty_like(a)
    np.copyto(out, 0)
    for i, kv in enumerate(k):
        out[pad:-pad or None, :] += kv * a[i:i + field.shape[0], :]
    a2 = out
    out = np.zeros_like(a2)
    for i, kv in enumerate(k):
        out[:, pad:-pad or None] += kv * a2[:, i:i + field.shape[1]]
    return out[pad:-pad or None, pad:-pad or None]


def downsample(field, ss):
    h, w = field.shape[0] // ss, field.shape[1] // ss
    return field[:h * ss, :w * ss].reshape(h, ss, w, ss).mean(axis=(1, 3))


def histogram2d(xs, ys, size, extent=None, pad=0.0, fit="cover", zoom=1.18,
                ss=2, sigma=1.5):
    """Bin a trajectory into a (h, w) density, filling the panel.

    A trajectory is a list of points; the wallpaper is a raster. Binning rather
    than drawing lines is what makes the density -- where the system spends its
    time -- the thing you see, which is the interesting statement an attractor
    makes.

    fit="cover" CROPS to fill the frame. The first version fitted the whole
    attractor inside it instead, which is correct for a figure and wrong for a
    wallpaper: an attractor is rarely 16:10, so containing it left wide empty
    bands down both sides and the structure sat in a box in the middle of the
    screen. A wallpaper should reach the edges. Losing the outermost wisps of a
    lobe costs nothing -- they are the least-visited cells and the faintest
    pixels -- while the middle of the structure gets the whole panel.

    zoom > 1 pushes further in, past the bounding box, so the densest part of
    the structure is what fills the screen rather than its full extent.
    fit="contain" keeps the old behaviour for anything that genuinely needs its
    whole extent visible.
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

    agot = (x1 - x0) / (y1 - y0)
    awant = w / h
    contain = fit == "contain"
    # cover shrinks the axis with room to spare; contain widens the other one.
    if (agot < awant) == contain:
        cx, half = (x0 + x1) / 2, (y1 - y0) * awant / 2
        x0, x1 = cx - half, cx + half
    else:
        cy, half = (y0 + y1) / 2, (x1 - x0) / awant / 2
        y0, y1 = cy - half, cy + half

    if zoom != 1.0:
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        hx, hy = (x1 - x0) / 2 / zoom, (y1 - y0) / 2 / zoom
        x0, x1, y0, y1 = cx - hx, cx + hx, cy - hy, cy + hy

    # SUPERSAMPLE, then box-average down.
    #
    # A histogram binned straight to the panel is shot-noise limited: each
    # pixel holds a Poisson count, so even a well-sampled attractor renders
    # visibly grainy and the faint outer filaments break into speckle. Binning
    # at ss times the resolution and averaging blocks of ss*ss gives each
    # output pixel ss^2 times the counts and anti-aliases the filament edges in
    # the same pass, which is the difference between this and the smooth
    # renders these systems are usually shown in.
    #
    # ss=2 costs four times the histogram memory and almost no time -- the
    # expense here is generating the points, not binning them.
    # ss=3 where the panel is small enough to afford it. The supersampled
    # histogram is (h*ss)*(w*ss) float64, so 3 costs 2.25x the memory of 2 and
    # buys noticeably smoother filaments; above about 2.5 megapixels that is
    # hundreds of MB for a wallpaper and 2 is the sensible ceiling.
    if ss == 2 and w * h <= 2_500_000:
        ss = 3
    hh, ww = h * ss, w * ss
    field, _, _ = np.histogram2d(
        ys, xs, bins=(hh, ww), range=[[y0, y1], [x0, x1]]
    )

    # ANTIALIAS before downsampling. This is the whole difference between a
    # continuous-looking curve and a trail of dots.
    #
    # A box-average of a hard-binned histogram is not antialiasing: every
    # sample still lands wholly in one subpixel, so a sparse trajectory is a
    # string of isolated hits and the gamma applied at render time makes each
    # one a visible speck. Convolving at the supersampled resolution spreads
    # each sample over a small neighbourhood -- the cheap equivalent of
    # splatting a kernel per point -- and the curve closes up.
    #
    # This lives HERE, not in a generator, because every generator that bins a
    # trajectory needs it. It was first written inside clifford.py, which left
    # the other eight aliased and is exactly the bug this comment exists to
    # stop recurring.
    if sigma > 0:
        field = smooth(field, sigma)
    if ss > 1:
        field = downsample(field, ss)
    return field
