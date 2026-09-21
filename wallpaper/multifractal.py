"""A strange attractor with multifractal scaling -- Peter de Jong's map.

    x' = sin(a y) - cos(b x)
    y' = sin(c x) - cos(d y)

    (a, b, c, d) = (-0.007, -2.911, -2.228, -0.865)

WHAT MULTIFRACTAL MEANS HERE. Every strange attractor carries a natural
measure -- how often the orbit visits each part of it -- and for almost all of
them that measure is not merely concentrated on a fractal but UNEVEN on it, in
a way that repeats at every scale: the Renyi dimensions D_q differ with q. For
these parameters, measured by box counting over 4e8 iterates, D0 ~ 1.75 (how
much of the plane the set occupies) against D2 ~ 1.0-1.5 (where the weight
actually sits), and the Lyapunov exponents are +0.49 and -0.83, a
Kaplan-Yorke dimension of 1.59. The picture is that statement: a set of arcs
whose spacing and brightness are uneven, and uneven again inside each bundle.

WHY THESE PARAMETERS. Chosen out of 4000 random (a, b, c, d) by ranking on
D0 - D2, the width of the dimension spectrum, and then by eye. a is nearly
zero, which makes the map almost a skew product: x runs its own chaotic 1-D
map, x' ~ -cos(b x), and y, contracted by |d| < 1 on every step, is carried
along by it. That is the mechanism the textbooks use to build a multifractal
on purpose (Kaplan and Yorke 1979; the generalised baker's map), and here it
falls out of the same two lines of trigonometry that make Clifford's shells.
The look is nothing like Clifford: a stack of thin arcs, not smooth lobes.

TURNED A QUARTER. The attractor is a C, taller than wide, and framed as it is
it sat in a column in the middle of the panel. Drawn with y across and x
increasing downward it is a lens of arcs 1.4 times as wide as tall, which a
16:10 panel crops only at the ends of the arcs.

RENDERING. Bilinear point deposit (a map has no path between iterates) into a
float32 grid with np.add.at -- faster than bincount at 11520 x 7200 and without
its full-panel float64 per batch -- summed over one process per core, then a
Gaussian of 0.7 supersampled pixels. zscale, because the arcs span orders of
magnitude in brightness and zscale is the stretch that gives the faint ones
the display range without letting the brightest few decide it.

GAMMA 1.0, not Clifford's 1.8. Clifford wants its smooth fill sunk so only the
ridges show; here there is no fill, only arcs, and the faint ones ARE the
point -- they are the lower tiers of the hierarchy. At 1.4 they sank into a
grey haze between the bright arcs; at 1.0 every tier reads as a line, and the
brightest still saturate to the top of the ramp.

16e9 iterates (x sqrt(zoom) for a zoomed view). The faintest tier is visited
so rarely that at half that its arcs broke into dashes at 1:1.

The short faint streaks between the bright bands of the x5 view are NOT that:
they are the attractor's own, faint pieces of arc that start and stop inside
the view. Checked by rendering the view from two independent runs (3.6e10
and 4.4e10 iterates): the streaks come out identical, where shot noise would
have moved. More iterates buy nothing there; x zoom (8e10) took twice as long
for the same image.
"""

import os

import numpy as np

TITLE = "Multifractal strange attractor"
SUBTITLE = ("Peter de Jong map, a=-0.007 b=-2.911 c=-2.228 d=-0.865:"
            "  bands within bands, unevenly bright at every scale")

SCALE = "zscale"
GAMMA = 1.0
BLEND = 0.85
# Thin arcs: without these they bead and change colour at their edges.
SOFTEN = 0.8
HUE_SMOOTH = 3.0

PARAMS = (-0.007, -2.911, -2.228, -0.865)

# (turn, zoom, cx, cy): turn 3 draws y across and -x up; (cx, cy) is the
# centre of the view as a fraction of the whole turned frame, from its
# left and TOP edges, so a view can be picked straight off an image of it.
#
# Picked from eight: the other zooms were parallel arcs only (plain), or half
# empty, and x20 was too sparse to render cleanly -- at 1920 wide and 4.5e9
# iterates its median lit pixel held under one visit, and the faint tier
# came out as speckle rather than lines.
#
# Only the view chosen on a real desktop is here, with the random seed its
# orbits were drawn from (the sample is part of the picture: a re-render is
# pixel-identical). The whole lens, (3, 1.0, 0.50, 0.50), was good but
# pruned for the crossing.
VIEWS = [
    (3, 5.0, 0.55, 0.08, 1),  # x5, where the two sides of the lens cross: a
                              # lattice of bands, each band a lattice of
                              # fainter ones
]


def _turn(k, x, y):
    """State -> screen (right, up), turned k quarter-turns anticlockwise."""
    for _ in range(k % 4):
        x, y = -y, x
    return x, y


def _orbit(p, seed, walkers, iters, burn=300):
    a, b, c, d = p
    rng = np.random.default_rng(seed)
    x = rng.uniform(-2, 2, walkers)
    y = rng.uniform(-2, 2, walkers)
    for i in range(burn + iters):
        x, y = np.sin(a * y) - np.cos(b * x), np.sin(c * x) - np.cos(d * y)
        if i >= burn:
            yield x, y


def _worker(args):
    p, turn, seed, walkers, iters, ext, shape = args
    x0, x1, y0, y1 = ext
    hh, ww = shape
    acc = np.zeros(hh * ww, dtype=np.float32)
    for x, y in _orbit(p, seed, walkers, iters):
        sx, sy = _turn(turn, x, y)
        # lib.deposit's bilinear weights, with rows counted from the TOP so
        # the first row of the raster is physical up.
        fx = (sx - x0) / (x1 - x0) * ww - 0.5
        fy = (y1 - sy) / (y1 - y0) * hh - 0.5
        ok = (fx >= 0) & (fx < ww - 1) & (fy >= 0) & (fy < hh - 1)
        fx, fy = fx[ok], fy[ok]
        ix = fx.astype(np.int64)
        iy = fy.astype(np.int64)
        tx = (fx - ix).astype(np.float32)
        ty = (fy - iy).astype(np.float32)
        base = iy * ww + ix
        np.add.at(acc, base, (1 - tx) * (1 - ty))
        np.add.at(acc, base + 1, tx * (1 - ty))
        np.add.at(acc, base + ww, (1 - tx) * ty)
        np.add.at(acc, base + ww + 1, tx * ty)
    return acc.reshape(hh, ww)


def generate(size, seed=0, n=16_000_000_000, view=None, params=None,
             jobs=None, sigma=0.7):
    """Density of the attractor in view `seed` on a (h, w) grid."""
    from lib import frame, smooth

    turn, zoom, cx, cy, sample = (VIEWS[seed % len(VIEWS)] if view is None
                                  else (*view, seed))
    p = PARAMS if params is None else params
    w, h = size

    # The whole attractor's frame from a short run, filled edge to edge
    # (cover), then the view's window inside it.
    sx, sy = [], []
    for x, y in _orbit(p, 12345, 20000, 50):
        a, b = _turn(turn, x, y)
        sx.append(a); sy.append(b)
    sx, sy = np.concatenate(sx), np.concatenate(sy)
    lo = np.percentile(sx, [0.01, 99.99]), np.percentile(sy, [0.01, 99.99])
    x0, x1, y0, y1 = frame(np.array(lo[0]), np.array(lo[1]), size,
                           fit="cover", zoom=1.0)
    mx, my = x0 + cx * (x1 - x0), y1 - cy * (y1 - y0)
    hx, hy = (x1 - x0) / 2 / zoom, (y1 - y0) / 2 / zoom
    ext = (mx - hx, mx + hx, my - hy, my + hy)

    # A zoomed view catches only the iterates that land in its window, so it
    # is given sqrt(zoom) times more of them. Not zoom times: the arcs cross
    # the window, so it holds far more than 1/zoom^2 of the attractor, and
    # iterates that miss it cost only the map, never a deposit.
    n = int(n * max(1.0, zoom ** 0.5))
    jobs = jobs or min(os.cpu_count() or 4, 8)
    walkers = 200_000
    iters = max(1, n // (jobs * walkers))
    work = [(p, turn, sample * 1000 + j + 1, walkers, iters, ext, (h, w))
            for j in range(jobs)]
    if jobs > 1:
        import multiprocessing as mp
        field = None
        with mp.Pool(jobs) as pool:
            for part in pool.imap_unordered(_worker, work):
                field = part if field is None else field + part
    else:
        field = _worker(work[0])
    return smooth(field, sigma) if sigma > 0 else field
