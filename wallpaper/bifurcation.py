"""Logistic map — the bifurcation diagram.

    x' = r x (1 - x)

The one thing here that is famous as an *image* and not only as a system. May's
1976 review made it the standard example of complexity out of nothing, and the
picture of where its attractor sits as r varies is the picture everyone has
seen.

The horizontal axis is not a coordinate of the system. It is a parameter: every
column is a different map, iterated until it has forgotten where it started,
and what is plotted is the set it settles onto. Nothing else in this set does
that, which is the reason to have it. The attractors are all smoke and
filament; this is hairline curves that split, and split again, and dissolve
into a mist with structure inside it.

r runs from 2.8 -- the fixed point 1 - 1/r, still stable -- through the
period-doubling cascade, which accumulates geometrically at r = 3.5699456 with
the ratio delta = 4.6692016 that Feigenbaum showed in 1978 is the same for
every map with a quadratic maximum, into chaos, and past the period-3 window
opening at the tangent bifurcation r = 1 + sqrt(8) = 3.8284271, which by Li and
Yorke's 1975 theorem is the loudest possible statement that everything to its
left is chaotic.

Vectorised over r, not over time: the recurrence is serial in the iteration
count and embarrassingly parallel in r, so the loop runs `keep` times over an
array of two hundred thousand orbits and never once over a point.
"""

import os

import numpy as np

# Sparse: 22% of cells carry anything at all in the default view, and in the
# period-3 one it is 29% with a third of the panel dead empty -- the cascade is
# a handful of one-pixel curves, and the void under the lower envelope cannot
# be reached by the dynamics at all. That argues for 0.6, but the curves are
# hard, continuous, full-width lines rather than a diffuse density, and a
# bright ruled line across a desktop reads as chrome, as something you could
# click. Pulled back to 0.5 for that reason and no other.
TITLE = "Logistic map"
SUBTITLE = "x' = r x (1-x),  period-doubling cascade"


# The field is handed over ALREADY in 0..1 -- see generate() for why -- so the
# renderer is told to take it as it is.
SCALE = "unit"
GAMMA = 1.0

# How the chaotic half is stretched, inside the generator.
MIST_SCALE = "equalize"
MIST_GAMMA = 2.0

# Line width of the periodic branches: a Gaussian pen, as a fraction of the
# frame height, so the look does not change with resolution. 0.6 px at 4K.
PEN = 0.6 / 2400

# Anti-aliasing at the resolution being coloured; see lib.render.
SOFTEN = 0.8
HUE_SMOOTH = 3.0

BLEND = 0.78

# (r0, r1), or (r0, r1, x0, x1) to override the vertical frame. The cascade is
# the whole diagram; the rest are places worth standing close to.
PRESETS = {
    "cascade":    (2.800, 4.000),   # fixed point -> doubling -> chaos, all of it
    "feigenbaum": (3.540, 3.600),   # r_inf = 3.5699456: doubling from the left,
                                    # the chaotic bands merging from the right
    "period3":    (3.820, 3.860),   # chaos collapsing onto three points at
                                    # 1 + sqrt(8), then doubling again from them
    # Inside the period-3 window, cropped to the middle of its three branches
    # (measured: 0.445 to 0.553 over this range, the other two sit near 0.15
    # and 0.96). What fills the panel is the whole diagram again -- one line,
    # doubling, chaos, windows -- because the third iterate restricted to that
    # subinterval is itself a unimodal map with a quadratic maximum, so it has
    # to repeat the entire story at its own scale. That is the renormalisation
    # argument, and the reason Feigenbaum's ratio is universal rather than a
    # fact about x(1-x).
    "renormalise": (3.8450, 3.8565, 0.435, 0.565),
}


# An orbit counts as periodic when it repeats to within a quarter of a pixel
# after `burn` steps, with any period up to this. Beyond it the orbit is drawn
# as chaos, which at this resolution is what it looks like.
MAX_PERIOD = 128


def _strip(args):
    """One vertical strip of the diagram: columns c0..c1, every row.

    Columns never interact -- each is a different map -- so the diagram splits
    into strips with no communication at all, one per core. Returns two
    fields for the strip: the periodic branches, as line coverage, and the
    chaotic density, as counts.
    """
    c0, c1, w, h, r0, r1, xlo, xhi, seed, sub, ninit, burn, keep = args
    rng = np.random.default_rng([seed, c0])
    cw = c1 - c0

    # `sub` values of r inside each pixel column, placed at random within the
    # column rather than on a lattice. A regular grid of r beats against the
    # period of the orbit and prints moire through the cascade; jitter turns
    # that into the anti-aliasing of a curve, which is what it actually is.
    col = np.repeat(np.arange(cw), sub)
    r = r0 + (r1 - r0) * (c0 + col + rng.random(col.size)) / w

    # `ninit` starts per r. For almost every r the map has a single attractor,
    # so these are not different outcomes -- they are the same invariant
    # measure sampled in parallel, which is how the column gets enough points
    # without making the serial loop longer.
    r = np.tile(r, ninit)
    col = np.tile(col, ninit)
    # Never exactly 0 or 1: 0 is a fixed point and 1 maps onto it, so either
    # would sit there for the whole run and print a false line along the axis.
    x = rng.uniform(0.05, 0.95, r.size)

    for _ in range(burn):
        x = r * x * (1.0 - x)

    scale = h / (xhi - xlo)

    # PERIODIC OR CHAOTIC, decided per orbit at the resolution being drawn.
    #
    # The two halves of this diagram are different kinds of object and cannot
    # share one brightness scale. A periodic branch puts all of a column's
    # samples into one or two pixels; the chaotic mist spreads the same count
    # over thousands. Any stretch that makes the mist visible clips the
    # branches ~200x over, and a clipped line cannot be anti-aliased: a pixel
    # the curve half-covers saturates exactly like one it fully covers, so the
    # line alternates between one and two pixels wide -- a staircase, however
    # carefully each point was deposited. Measured on the 4K cascade.
    #
    # So the branches are drawn as LINES, brightness proportional to how much
    # of the pixel the line covers, and only the chaotic orbits make density.
    hist = np.empty((MAX_PERIOD, x.size))
    for k in range(MAX_PERIOD):
        x = r * x * (1.0 - x)
        hist[k] = x
    close = np.abs(hist[-1] - hist[-2::-1]) < 0.25 / scale
    period = np.where(close.any(0), close.argmax(0) + 1, 0)
    del hist, close
    # A period-k orbit visits each of its k branches keep/k times. This weight
    # makes every branch total exactly 1 per column when all the column's
    # orbits are periodic, whatever k is -- so a period-8 branch is as bright
    # as the fixed point, as in every drawing of this diagram.
    wline = period / float(keep * sub * ninit)
    wchaos = (period == 0).astype(float)

    # Deposited BILINEARLY in x: each point is split between the two rows it
    # falls between, by how close it is to each. The columns need no such
    # treatment; r is already jittered within each one.
    #
    # One guard row above and below, so a point just outside the frame can
    # still give its share to the edge row. Anything further out is dropped,
    # not clamped: a cropped preset leaves two thirds of the attractor outside
    # the frame, and clamping would stack all of it onto the edge rows as two
    # bright rules that are not in the dynamics.
    H = h + 2
    dump = H * cw                      # one extra bin for everything outside
    line = np.zeros(dump + 1)
    mist = np.zeros(dump + 1)

    # Buffered and binned through bincount in batches. Per step it would
    # allocate the whole strip for a scatter of a few tens of thousands of
    # points; np.add.at avoids that and is an order of magnitude slower.
    per_call = max(1, min(keep, 4_000_000 // x.size))
    idx = np.empty((per_call, x.size), dtype=np.intp)
    frac = np.empty((per_call, x.size))

    def flush(k):
        i = idx[:k].ravel()
        up = np.minimum(i + cw, dump)
        f = frac[:k].ravel()
        for acc, wt in ((line, wline), (mist, wchaos)):
            wt = np.broadcast_to(wt, (k, wt.size)).ravel()
            acc += np.bincount(i, weights=(1.0 - f) * wt, minlength=dump + 1)
            acc += np.bincount(up, weights=f * wt, minlength=dump + 1)

    k = 0
    for _ in range(keep):
        x = r * x * (1.0 - x)
        # xhi - x, not x - xlo: x increases upward, because everyone has seen
        # this diagram that way up and a flipped one reads as a mistake.
        # +1 for the guard row, -0.5 so a point on a pixel centre lands wholly
        # in that pixel.
        t = (xhi - x) * scale + 0.5
        row = np.floor(t).astype(np.intp)
        ok = (row >= 0) & (row < H - 1)
        idx[k] = np.where(ok, row * cw + col, dump)
        frac[k] = np.where(ok, t - row, 0.0)
        k += 1
        if k == per_call:
            flush(k)
            k = 0
    if k:
        flush(k)
    return (c0, line[:dump].reshape(H, cw)[1:-1],
            mist[:dump].reshape(H, cw)[1:-1])


def generate(size, seed=0, sub=3, ninit=24, burn=1000, keep=4000, jobs=None,
             mist_scale=None, mist_gamma=None, pen=None):
    import lib

    w, h = size
    names = sorted(PRESETS)
    window = PRESETS[names[seed % len(PRESETS)]]
    r0, r1 = window[:2]

    # The frame is the map's own, not a guess. For r in [2, 4] the interval
    # [f(f(1/2)), f(1/2)] -- the first two images of the critical point --
    # traps the dynamics, so it contains the attractor for every r in range,
    # and in the chaotic regions the attractor reaches both ends of it. A
    # preset that names its own x window means it instead, exactly.
    if len(window) == 4:
        xlo, xhi = window[2], window[3]
    else:
        rr = np.linspace(r0, r1, 4096)
        xhi = (rr / 4.0).max()
        xlo = (rr * (rr / 4.0) * (1.0 - rr / 4.0)).min()
        pad = 0.03 * (xhi - xlo)
        xlo, xhi = xlo - pad, xhi + pad

    # Binned directly instead of through lib.histogram2d, which is the only
    # departure from the other generators and is deliberate: that helper makes
    # the bins square so an attractor is not stretched, and here the two axes
    # are a parameter and a state variable. They have no common unit, there is
    # no aspect to preserve, and forcing one would frame empty r beyond 4 where
    # the map escapes to minus infinity. r fills the width, x fills the height.
    #
    # keep=4000 rather than the 1400 this started with: the chaotic mist
    # spreads a column's samples over thousands of rows, and at 1400 it was
    # visibly grainy once the curves were anti-aliased and the grain was the
    # only roughness left.
    jobs = jobs or os.cpu_count() or 4
    edges = np.linspace(0, w, jobs + 1).astype(int)
    work = [(edges[j], edges[j + 1], w, h, r0, r1, xlo, xhi, seed, sub, ninit,
             burn, keep) for j in range(jobs) if edges[j + 1] > edges[j]]
    line = np.zeros((h, w), dtype=np.float32)
    mist = np.zeros((h, w), dtype=np.float32)
    if len(work) > 1:
        import multiprocessing as mp
        with mp.Pool(len(work)) as pool:
            for c0, lp, mp_ in pool.imap_unordered(_strip, work):
                line[:, c0:c0 + lp.shape[1]] = lp
                mist[:, c0:c0 + mp_.shape[1]] = mp_
    else:
        _, line[:], mist[:] = _strip(work[0])

    # The branches, through a Gaussian pen. Each column of a branch holds a
    # total of 1 spread over one or two rows; blurring by sigma spreads it
    # over a profile whose peak is 1 / (sigma sqrt(2 pi)), so rescaling by
    # that makes a branch exactly 1 at its centre wherever it sits between
    # pixel rows -- the whole point. Blurred after the strips are joined, so
    # no seam appears at a strip edge.
    sigma = (PEN if pen is None else pen) * h
    line = np.clip(lib.smooth(line, sigma) * sigma * np.sqrt(2 * np.pi),
                   0.0, 1.0)

    # The mist stretched on its own, now that nothing 200x brighter shares its
    # range. Done here rather than in the renderer because the renderer has
    # one stretch per image and this image needs two.
    mist = lib.normalise(mist,
                         gamma=MIST_GAMMA if mist_gamma is None else mist_gamma,
                         scale=MIST_SCALE if mist_scale is None else mist_scale)

    # Where a column holds both -- a window edge falling inside one pixel --
    # the brighter wins rather than the two adding to more than full.
    return np.maximum(line, mist)
