"""Fractal flame -- Draves' iterated function system with nonlinear variations.

A classical IFS (Barnsley's fern, the Sierpinski triangle) is a handful of
affine maps chosen at random and applied over and over; the orbit settles onto
the set they leave invariant. Draves and Reckase (2003) made each map

    F_i(x, y) = sum_j  v_ij  V_j(a_i x + b_i y + c_i,  d_i x + e_i y + f_i)

an affine map followed by a weighted blend of NONLINEAR "variations" -- a
swirl, a sphere inversion, a polar unwrap, a Julia square root. The affine part
still does the folding and contracting that makes an IFS converge; the
variations bend the pieces, so the attractor is made of curved sheets that fold
over one another instead of straight-edged copies. That is where the silk and
smoke look comes from.

Every preset below also carries a SYMMETRY group: after each map, the point is
rotated by a random element of the cyclic (or dihedral) group of order n. The
group permutes the pieces of the attractor among themselves, so the set that
survives is exactly n-fold symmetric -- the flower in most well-known flames.

RENDERING:

  * The chaos game is run as a large vector of independent walkers per core,
    each choosing its own map at every step. They cannot share one sequence of
    choices: for contracting maps, orbits driven by the same sequence converge
    onto one another and the whole ensemble collapses to a single point.
  * Points are splatted BILINEARLY (see lib.deposit) into a float32 grid at
    the supersampled resolution, buffered in batches so the grid is touched
    once per few million points and never held as a point list.
  * The density spans five or six decades, from the folded cores to the
    outermost wisps, which is why flames are always shown on a LOG scale; the
    field is scaled so its level does not depend on how many samples were
    taken (see accumulate).
  * There is no colour coordinate. Draves' renderer carries a second channel
    that averages a per-map colour along the orbit; the house pipeline maps one
    scalar through the palette, so the ramp here encodes density: faint sheets
    at the teal end, the folded cores toward pink.
"""

import os

import numpy as np

TITLE = "Fractal flame"
SUBTITLE = "iterated function system with nonlinear variations  (Draves & Reckase 2003)"

# LOG, then gamma 1.3 -- above one, which darkens the faint end.
#
# A flame is not bounded by the frame: its faint sheets run past every edge.
# Log alone (gamma 0.45, first try) lifted them to the ramp's teal across the
# whole panel -- a teal slab with the flame drawn on it. zscale and a percentile
# clip do the same, because the faint sheets ARE the bulk of the lit pixels.
# Gamma 1.3 on top of log sinks them back toward the ground as a dim glow and
# leaves the folded ridges lit, so the image has depth: empty ground, smoke,
# silk, core. 1.6 was more elegant but read as muted; equalize flooded again.
SCALE = "log"
GAMMA = 1.3
# House 2.25 / 1.1 and the full ramp: with the faint sheets pushed down this is
# lines on dark ground again, not a screen-filling field. At gamma 0.45 the
# same numbers were loud.
SATURATION = 2.25
EXPOSURE = 1.1
BLEND = 0.85
# The ridges are one or two pixels wide; see lib.render.
SOFTEN = 0.8
HUE_SMOOTH = 3.0


# The variations: those the presets below use, from the catalogue in Draves &
# Reckase's paper (which has fifty; each is a one-liner to add here). theta is
# measured from +y, atan2(x, y), as in the paper. r2 is kept off zero so an
# exact hit on the origin does not produce an infinity.
def _v(name, x, y):
    r2 = x * x + y * y + 1e-12
    r, th = np.sqrt(r2), np.arctan2(x, y)
    if name == "linear":
        return x, y
    if name == "sinusoidal":
        return np.sin(x), np.sin(y)
    if name == "spherical":
        return x / r2, y / r2
    if name == "bubble":
        k = 4 / (r2 + 4)
        return k * x, k * y
    if name == "bent":
        return np.where(x < 0, 2 * x, x), np.where(y < 0, y / 2, y)
    if name == "swirl":
        s, c = np.sin(r2), np.cos(r2)
        return x * s - y * c, x * c + y * s
    if name == "polar":
        return th / np.pi, r - 1
    if name == "handkerchief":
        return r * np.sin(th + r), r * np.cos(th - r)
    if name == "heart":
        return r * np.sin(th * r), -r * np.cos(th * r)
    if name == "fisheye":
        k = 2 / (r + 1)
        return k * y, k * x
    if name == "eyefish":
        k = 2 / (r + 1)
        return k * x, k * y
    if name == "exponential":
        k = np.exp(np.clip(x - 1, -50, 50))
        return k * np.cos(np.pi * y), k * np.sin(np.pi * y)
    raise KeyError(name)


def _xform(x, y, aff, var, rng=None):
    a, b, c, d, e, f = aff
    tx, ty = a * x + b * y + c, d * x + e * y + f
    ox = np.zeros_like(tx); oy = np.zeros_like(ty)
    for name, wt in var.items():
        vx, vy = _v(name, tx, ty)
        ox += wt * vx; oy += wt * vy
    return ox, oy


def _group(sym):
    """cos, sin and x-flip of every element of the symmetry group.

    sym = n > 1 is the cyclic group of n rotations; sym = -n adds the n
    mirrors (the dihedral group); -1 is a single mirror; 0 or 1 is none.
    Identity included, so a point is left alone 1/|G| of the time.
    """
    n = max(1, abs(sym))
    ang = 2 * np.pi * np.arange(n) / n
    flip = np.ones(n)
    if sym < 0:
        ang, flip = np.concatenate([ang, ang]), np.concatenate([flip, -flip])
    return np.cos(ang), np.sin(ang), flip


def _step(x, y, g, cum, grp, rng):
    """One chaos-game step for every walker, each with its own choice of map."""
    k = np.searchsorted(cum, rng.random(x.size), side="right")
    nx = np.empty_like(x); ny = np.empty_like(y)
    for i, (_, aff, var) in enumerate(g["xforms"]):
        m = k == i
        if m.any():
            nx[m], ny[m] = _xform(x[m], y[m], aff, var, rng)
    if len(grp[0]) > 1:
        # Rotating AFTER the map rather than as maps of its own: the group
        # permutes the pieces either way, so the invariant set is the same
        # n-fold symmetric one, and this costs no extra masked passes.
        j = rng.integers(0, len(grp[0]), x.size)
        c, s, nx = grp[0][j], grp[1][j], nx * grp[2][j]
        nx, ny = c * nx - s * ny, s * nx + c * ny
    # A walker thrown to infinity by an inversion near the origin is restarted
    # rather than propagated: one NaN otherwise poisons its whole orbit.
    bad = ~(np.isfinite(nx) & np.isfinite(ny)) | (np.abs(nx) + np.abs(ny) > 1e6)
    if bad.any():
        nx[bad] = rng.uniform(-1, 1, bad.sum()); ny[bad] = rng.uniform(-1, 1, bad.sum())
    return nx, ny


def _camera(x, y, g, rng):
    """Final transform (drawn, never fed back into the orbit), then the view."""
    if g.get("final"):
        x, y = _xform(x, y, *g["final"], rng)
    t = np.radians(g.get("rotate", 0.0))
    if t:
        x, y = np.cos(t) * x - np.sin(t) * y, np.sin(t) * x + np.cos(t) * y
    return x, y


def _orbit(g, rng, walkers, burn=40):
    cum = np.cumsum([w for w, _, _ in g["xforms"]], dtype=float)
    cum /= cum[-1]
    grp = _group(g.get("sym", 0))
    x, y = rng.uniform(-1, 1, walkers), rng.uniform(-1, 1, walkers)
    # Inversions divide by r^2 and a few walkers always land near 0; those are
    # restarted in _step, and the warnings are noise. seterr, not errstate:
    # a context manager held open across a generator's yields leaks.
    np.seterr(all="ignore")
    for _ in range(burn):
        x, y = _step(x, y, g, cum, grp, rng)
    while True:
        x, y = _step(x, y, g, cum, grp, rng)
        yield _camera(x, y, g, rng)


def _splat(px, py, shape, ext, acc):
    """Bilinear deposit, all four corners in ONE bincount.

    lib.deposit does four, each allocating a full-frame float64 array; at the
    supersampled 4K frame that is 660 MB apiece, per worker. Rows are flipped
    so that +y is up on screen.
    """
    h, w = shape
    x0, x1, y0, y1 = ext
    fx = (px - x0) / (x1 - x0) * w - 0.5
    fy = (y1 - py) / (y1 - y0) * h - 0.5
    ok = (fx >= 0) & (fx < w - 1) & (fy >= 0) & (fy < h - 1)
    fx, fy = fx[ok], fy[ok]
    ix, iy = fx.astype(np.int64), fy.astype(np.int64)
    tx, ty = fx - ix, fy - iy
    i = iy * w + ix
    acc += np.bincount(np.concatenate([i, i + 1, i + w, i + w + 1]),
                       np.concatenate([(1 - tx) * (1 - ty), tx * (1 - ty),
                                       (1 - tx) * ty, tx * ty]),
                       minlength=h * w)


def _worker(args):
    g, seed, walkers, steps, ext, shape = args
    rng = np.random.default_rng(seed)
    acc = np.zeros(shape[0] * shape[1], dtype=np.float32)
    per = max(1, 4_000_000 // walkers)          # steps per ~4M-point batch
    bx, by = [], []
    for i, (x, y) in enumerate(_orbit(g, rng, walkers)):
        if i == steps:
            break
        bx.append(x); by.append(y)
        if len(bx) == per:
            _splat(np.concatenate(bx), np.concatenate(by), shape, ext, acc)
            bx, by = [], []
    if bx:
        _splat(np.concatenate(bx), np.concatenate(by), shape, ext, acc)
    return acc


def window(g, size, rng, fit="cover", zoom=1.0, q=0.5):
    """The frame, from a cheap sample: robust extent, then cover the panel.

    Percentiles rather than the bounding box, because a flame's outermost
    points are a sparse spray thrown far out by the inversions; the box would
    frame the spray and leave the flame a speck in the middle.
    """
    from lib import frame
    o = _orbit(g, rng, 20_000)
    pts = [next(o) for _ in range(40)]
    xs = np.concatenate([p[0] for p in pts]); ys = np.concatenate([p[1] for p in pts])
    ext = (*np.percentile(xs, [q, 100 - q]), *np.percentile(ys, [q, 100 - q]))
    x0, x1, y0, y1 = frame(xs, ys, size, extent=ext, fit=fit, zoom=zoom)
    dx, dy = g.get("shift", (0.0, 0.0))
    return x0 + dx * (x1 - x0), x1 + dx * (x1 - x0), y0 + dy * (y1 - y0), y1 + dy * (y1 - y0)


def accumulate(g, size, seed=0, spp=40.0, jobs=None, fit="cover", zoom=None,
               walkers=200_000):
    """Density of genome g on a (w, h) grid, relative to uniform coverage."""
    w, h = size
    ext = window(g, size, np.random.default_rng(seed), fit=fit,
                 zoom=g.get("zoom", 1.0) if zoom is None else zoom)
    jobs = jobs or min(os.cpu_count() or 4, 14)
    n = spp * w * h
    steps = max(1, int(n // (jobs * walkers)))
    work = [(g, seed * 1000 + j, walkers, steps, ext, (h, w)) for j in range(jobs)]
    import multiprocessing as mp
    with mp.Pool(jobs) as pool:
        acc = None
        for part in pool.imap_unordered(_worker, work):
            acc = part if acc is None else acc + part
    # Divided by the samples per cell, so 1.0 means "as dense as if the orbit
    # had spread evenly over the frame" whatever the sample count: the log
    # stretch below then has the same knee at any resolution or quality.
    return acc.reshape(h, w) / (jobs * walkers * steps / (w * h))


# Genomes: (weight, (a, b, c, d, e, f), {variation: blend}) per map. Found by
# rendering a few hundred random genomes as a contact sheet and keeping the
# ones that looked like something, not designed -- nobody designs a flame, the
# parameter space is too strange -- then framed by hand.
#
# Only the flame chosen on a real desktop is here, with the random seed its
# sample was drawn from -- the orbits are part of the picture, and a
# re-render is pixel-identical. Two others were built and pruned; their
# genomes, should they be wanted again:
#   lens (sym -2): 0.752 (0.024,-0.278,0.152,0.196,-0.524,0.646) bent .115 bubble .885;
#     0.417 (-0.577,0.241,-0.545,0.004,0.566,-0.52) sinusoidal .785 spherical .215;
#     0.803 (-0.31,0.182,0.483,-0.671,0.799,0.881) swirl .946 sinusoidal .054
#   feather (sym 2): 0.287 (0.387,0.884,-0.881,0.381,0.845,-0.049) sinusoidal .937
#     handkerchief .063; 0.624 (0.275,-0.915,-0.905,-0.361,-0.578,0.552) eyefish .354
#     swirl .646; 0.61 (0.085,-0.24,-0.137,-0.279,-0.451,0.241) handkerchief 1
PRESETS = [
    # No symmetry; polar + heart, a linear map, eyefish + exponential, all
    # drawn through a final swirl. One silk sheet folding over itself.
    # shift: centred, the folded knot where every strand crosses sat on the
    # top edge with its arches cut off; this brings it down and a little left.
    ("silk", 1, dict(sym=0, zoom=1.0, shift=(0.04, 0.09), final=((1, 0, 0, 0, 1, 0), {"swirl": 1.0}), xforms=[
        (0.914, (-0.912, -0.96, 0.678, 0.174, -0.551, 0.504), {"polar": 0.339, "heart": 0.661}),
        (0.588, (-0.443, -0.443, -0.156, -0.992, -0.382, 0.904), {"linear": 1.0}),
        (0.641, (0.89, 0.186, 0.886, 0.996, -0.932, -0.763), {"eyefish": 0.633, "exponential": 0.367}),
    ])),
]


def generate(size, seed=0, spp=60.0, jobs=None, fit="cover", zoom=None):
    # (name, sample seed, genome): the sample seed, not the preset's index,
    # seeds the orbits, so pruning or reordering presets never changes one.
    name, sample, g = PRESETS[seed % len(PRESETS)]
    return accumulate(g, size, seed=sample, spp=spp, jobs=jobs, fit=fit, zoom=zoom)
