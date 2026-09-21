"""Folded-towel map -- Rossler's 1979 hyperchaotic map, seen in 3-D.

    x' = 3.8 x (1 - x) - 0.05 (y + 0.35)(1 - 2z)
    y' = 0.1 [(y + 0.35)(1 - 2z) - 1](1 - 1.9x)
    z' = 3.78 z (1 - z) + 0.2 y

Rossler's "An equation for hyperchaos" (Phys. Lett. A 71, 155, 1979): the
first system shown to have TWO positive Lyapunov exponents -- 0.43 and 0.38,
against -3.30 for the third (computed here, Benettin QR over 500 orbits x 5e4
steps; the spread between orbits is 0.003). Stretching in two directions and
folding makes the attractor a SHEET, not a set of filaments: a towel, draped
and folded over on itself, with a Kaplan-Yorke dimension of 2.24. The 0.24 is
the towel's thickness -- it is not one sheet but a lamination of sheets,
packed like the leaves of a Cantor set.

It is essentially two logistic maps, x and z, coupled weakly through y. y is
itself nearly a function of x -- a parabola -- and that is the fold: every
point of the sheet at a given x sits at nearly the same y, so the towel runs
along z and is bent over along x.

WHY A ROTATED VIEW, not a pair of coordinates. The three axis projections were
all tried and each hides the thing the map is named for: x-z looks straight
down onto the towel and shows a filled square; x-y sees it edge-on as a bent
line; z-y shows a flat band. The fold is a three-dimensional shape and only an
oblique view shows it as one. The state is rotated (azimuth about z, then
elevation) and projected orthographically -- no perspective, so the density on
screen is still the attractor's own density, integrated along the line of
sight.

y spans a quarter of the range of x and z, so it is drawn at 4x before
rotating. Without that the fold is too shallow to read at any angle.

RENDERING. The field is where the orbit spends its time, projected. A sheet
seen obliquely is brightest where it is seen most nearly edge-on -- at the
fold, and along the creases the map's critical lines print across the towel.

HISTOGRAM-EQUALISED, gamma 3. zscale (Clifford's stretch) was tried first and
flooded: the towel's smooth fill is most of the lit panel and sits in one
narrow band of density, so it took one colour -- teal -- across the whole
screen with flat pink slabs at the folds. log was worse. Ranking gives each
level of density an equal share of the ramp, which is what lets the creases
separate from the fill, and gamma 3 hands the fill the dark end so the towel
reads as translucent and the folds as its bright edges.

Points are deposited bilinearly into a float32 grid with np.add.at, which in
numpy 2 is faster than bincount at this size and never allocates a full-panel
float64 per batch (measured: 0.26 s against 0.80 s for four million points
into 11520 x 7200, and no 660 MB temporary per worker).
"""

import os

import numpy as np

TITLE = "Folded-towel map"
SUBTITLE = ("Rossler 1979, hyperchaotic:  Lyapunov exponents 0.43, 0.38,"
            " -3.30,  dimension 2.24")

SCALE = "equalize"
GAMMA = 3.0
BLEND = 0.85
# The creases are one or two pixels wide; see lib.render.
SOFTEN = 0.8
HUE_SMOOTH = 3.0

# (azimuth, elevation, zoom, (dx, dy) shift of the window in units of the
# window). Each one picked by looking at a sheet of many angles; they are the
# ones where the towel reads as a towel.
#
# A third, from behind (210, 30, 1.30, (-0.02, 0)), rendered well at 1920 and
# failed at 4K: the curl is seen edge-on over a quarter of the panel, so the
# top ranks of the equalisation all land there as one mauve-pink slab.
#
# The arch was first framed at 1.45 with dy 0.10, which cut its crown off at
# the top edge and still left an eighth of the panel empty at each side. It is
# now zoomed to 1.9 and lowered until the crown has 4% headroom: the pink rim
# sweeps in from the bottom-left corner, over the crown and down the right,
# and the legs run off the bottom. The upper corners stay dark; an arch
# shows its crown only against empty sky.
# Only the view chosen on a real desktop is here. "Draped over the fold",
# (60, 30, 1.30, (0, 0)), was shown and pruned. The walkers are seeded from
# the view index, which stays 0 for the arch, so the kept picture is unchanged.
VIEWS = [
    (80.0, 45.0, 1.90, (0.01, 0.49)),  # the fold as an arch, crown whole
]

# The unit box the state lives in, measured on 8 million iterates: x and z in
# [0.10, 0.97], y in [-0.105, 0.106]. Centred and scaled so the three axes have
# comparable extents; this is what "y at 4x" means above.
CENTRE = np.array([0.54, 0.0, 0.54])
SPAN = np.array([0.87, 0.21, 0.85])


def _step(x, y, z):
    u = (y + 0.35) * (1.0 - 2.0 * z)
    return (3.8 * x * (1.0 - x) - 0.05 * u,
            0.1 * (u - 1.0) * (1.0 - 1.9 * x),
            3.78 * z * (1.0 - z) + 0.2 * y)


def _rotation(az, el):
    """Rows 0 and 2 of Rx(el) Rz(az): screen right and screen up."""
    a, e = np.radians(az), np.radians(el)
    rz = np.array([[np.cos(a), -np.sin(a), 0], [np.sin(a), np.cos(a), 0],
                   [0, 0, 1]])
    rx = np.array([[1, 0, 0], [0, np.cos(e), -np.sin(e)],
                   [0, np.sin(e), np.cos(e)]])
    r = rx @ rz
    return r[0] / SPAN, r[2] / SPAN


def _orbit(seed, walkers, iters):
    """`walkers` orbits, each `iters` steps, yielded one step at a time.

    Started in a small cloud about Rossler's own initial point (0.085, -0.121,
    0.075), which is in the basin; a random start in the unit cube is not
    always, and an escaped orbit goes to minus infinity in a few steps. Any
    walker that does escape is restarted on the position of a live one, which
    after the burn-in is a point on the attractor.
    """
    rng = np.random.default_rng(seed)
    x = 0.085 + rng.normal(0, 1e-3, walkers)
    y = -0.121 + rng.normal(0, 1e-3, walkers)
    z = 0.075 + rng.normal(0, 1e-3, walkers)
    for i in range(200 + iters):
        x, y, z = _step(x, y, z)
        bad = ~(np.abs(x) < 4) | ~(np.abs(z) < 4)
        if bad.any():
            j = rng.choice(np.flatnonzero(~bad), int(bad.sum()))
            x[bad], y[bad], z[bad] = x[j], y[j], z[j]
        if i >= 200:
            yield x, y, z


def _project(view, x, y, z):
    right, up = _rotation(*view[:2])
    p = (x - CENTRE[0], y - CENTRE[1], z - CENTRE[2])
    return (right[0] * p[0] + right[1] * p[1] + right[2] * p[2],
            up[0] * p[0] + up[1] * p[1] + up[2] * p[2])


def _worker(args):
    view, seed, walkers, iters, ext, shape = args
    x0, x1, y0, y1 = ext
    hh, ww = shape
    acc = np.zeros(hh * ww, dtype=np.float32)
    for x, y, z in _orbit(seed, walkers, iters):
        sx, sy = _project(view, x, y, z)
        # Bilinear deposit (lib.deposit's arithmetic), with y measured from
        # the TOP so the raster's first row is physical up.
        fx = (sx - x0) / (x1 - x0) * ww - 0.5
        fy = (y1 - sy) / (y1 - y0) * hh - 0.5
        ix = np.floor(fx).astype(np.int64)
        iy = np.floor(fy).astype(np.int64)
        tx = (fx - ix).astype(np.float32)
        ty = (fy - iy).astype(np.float32)
        ok = (ix >= 0) & (ix < ww - 1) & (iy >= 0) & (iy < hh - 1)
        base, tx, ty = iy[ok] * ww + ix[ok], tx[ok], ty[ok]
        np.add.at(acc, base, (1 - tx) * (1 - ty))
        np.add.at(acc, base + 1, tx * (1 - ty))
        np.add.at(acc, base + ww, (1 - tx) * ty)
        np.add.at(acc, base + ww + 1, tx * ty)
    return acc.reshape(hh, ww)


def generate(size, seed=0, n=40_000_000_000, zoom=None, view=None, jobs=None,
             sigma=0.7, fit="contain"):
    """Density of the projected attractor on a (h, w) grid.

    n=4e10 iterates, four times what first looked like enough. Equalisation
    ranks the towel's smooth fill, where density varies by only a few
    percent, so shot noise that a value stretch would never show gets ranked
    into speckle: at 1e10 (~1600 per lit 4K pixel) the fill was visibly
    freckled at 1:1. Four times the points halves it. ~20 min on 8 cores.
    That was measured at zoom 1.45; a pixel's share of the sheet falls as
    1/zoom^2, so a closer view gets (zoom / 1.45)^2 times the iterates: the
    arch at 1.9 takes 6.9e10, ~26 min.
    """
    from lib import frame, smooth

    v = VIEWS[seed % len(VIEWS)] if view is None else view
    w, h = size

    # The window from a short run of the same orbits: fixed before the long
    # accumulation, so every worker bins into the same grid.
    sx, sy = [], []
    for x, y, z in _orbit(12345, 20000, 50):
        a, b = _project(v, x, y, z)
        sx.append(a); sy.append(b)
    sx, sy = np.concatenate(sx), np.concatenate(sy)
    lo = np.percentile(sx, [0.01, 99.99]), np.percentile(sy, [0.01, 99.99])
    # CONTAIN, then zoomed past it. cover was tried first and cropped the
    # towel to a slab of sheet with no silhouette -- the fold, the one thing
    # worth seeing, went off the screen. Contain alone left it in the middle.
    # Zooming 1.3-1.9 past contain crops the towel's ends, not its fold.
    zoom = v[2] if zoom is None else zoom
    x0, x1, y0, y1 = frame(np.array(lo[0]), np.array(lo[1]), size, fit=fit,
                           zoom=zoom)
    n = int(n * max(1.0, (zoom / 1.45) ** 2))
    dx, dy = v[3]
    x0, x1 = x0 + dx * (x1 - x0), x1 + dx * (x1 - x0)
    y0, y1 = y0 + dy * (y1 - y0), y1 + dy * (y1 - y0)

    jobs = jobs or min(os.cpu_count() or 4, 8)
    walkers = 200_000
    iters = max(1, n // (jobs * walkers))
    work = [(v, seed * 1000 + j + 1, walkers, iters, (x0, x1, y0, y1), (h, w))
            for j in range(jobs)]
    if jobs > 1:
        import multiprocessing as mp
        field = None
        with mp.Pool(jobs) as pool:
            for part in pool.imap_unordered(_worker, work):
                field = part if field is None else field + part
    else:
        field = _worker(work[0])
    # A touch of blur at the supersampled scale, so the shot noise of the
    # deposit averages out before render.py area-averages down.
    return smooth(field, sigma) if sigma > 0 else field
