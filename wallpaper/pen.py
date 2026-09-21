"""A vector pen: line segments drawn as anti-aliased strokes into a field.

Not a generator. It is the drawing half of the four line-art generators
(fractaltree, koch, masscentre, lissajous), which differ in what they draw and
not in how, and would otherwise carry four copies of this.

Why not lib.deposit_path, which Lorenz uses: a deposited path is a DENSITY.
Where two strokes cross it adds, and the colour then says how much ink is there.
That is the statement an attractor makes and the wrong one for a drawing, where
a line is a line wherever it runs and its colour should say something chosen --
the depth of a branch, the generation of a bump, which side of a cylinder a
strand is on. So each segment here carries its own value, and strokes combine
by MAXIMUM, not by sum. Two consecutive segments of one line then join with no
bright knot at the joint (the maximum of two capsule profiles is exactly the
profile of their union), and where two lines cross, the higher value is drawn
over the lower, which a generator can use as a painter's algorithm.

The stroke is an analytic distance field, as in chladni.py: every pixel near a
segment gets its true distance d to it, and the ink is

    val * exp(-(max(d - core, 0) / soft)^2)

a flat core of half-width `core` with Gaussian shoulders. core=0 is a pure
Gaussian hairline; a large core is a solid bar with soft edges. One formula
covers a tree's trunk and its last twig, and the width may taper along the
segment. The shoulders are what anti-alias it: d is exact, so the edge is
smooth at any angle with no supersampling of its own.

One thing a caller has to know. Under HUE_SMOOTH (lib.render) a line's colour
is the value-weighted mean over its profile, not its peak, so a hairline is
shown at about 0.7 of the value it was drawn with and a stroke with a flat
core of a pixel or two at 0.8-0.9; only broad strokes, and bundles of lines
packed closer than a few pixels, reach the value itself. So the top of the
ramp is where lines crowd, whatever value they were drawn with -- which the
generators use rather than fight.
"""

import os

import numpy as np

# Segments handed to the workers. A global rather than an argument so that
# forked workers inherit it copy-on-write instead of each being sent a pickled
# copy of a few hundred thousand segments.
_JOB = None


def _band(rows):
    """Draw every segment that reaches rows j0..j1 into that band alone."""
    j0, j1 = rows
    x0, y0, dx, dy, il2, c0, dc, val, lo, hi, reach, w, soft = _JOB
    sel = np.nonzero((hi >= j0) & (lo <= j1))[0]
    out = np.zeros((j1 - j0, w), np.float32)
    colc = np.arange(w, dtype=np.float32) + 0.5       # pixel centres
    rowc = np.arange(j0, j1, dtype=np.float32)[:, None] + 0.5
    inv = 1.0 / soft
    for i in sel:
        r = reach[i]
        xa = max(0, int(min(x0[i], x0[i] + dx[i]) - r))
        xb = min(w, int(max(x0[i], x0[i] + dx[i]) + r) + 2)
        ya = max(j0, int(lo[i]))
        yb = min(j1, int(hi[i]) + 2)
        if xa >= xb or ya >= yb:
            continue
        ax = colc[xa:xb] - x0[i]
        ay = rowc[ya - j0:yb - j0] - y0[i]
        # Parameter of the nearest point on the segment, clamped to its ends,
        # which is what gives the stroke round caps.
        t = np.clip((ax * dx[i] + ay * dy[i]) * il2[i], 0.0, 1.0)
        e = np.hypot(ax - t * dx[i], ay - t * dy[i])
        e -= c0[i] + dc[i] * t
        np.maximum(e, 0.0, out=e)
        e *= inv
        v = val[i] * np.exp(-e * e)
        sl = out[ya - j0:yb - j0, xa:xb]
        np.maximum(sl, v, out=sl)
    return j0, out


def draw(x0, y0, x1, y1, core0, core1, val, size, soft, piece=40.0,
         jobs=None):
    """Stroke segments (x0,y0)-(x1,y1) into an (h, w) float32 field.

    Coordinates are in pixels of the field, x right and y DOWN (row order);
    the caller flips its maths frame. core0/core1 are the flat half-widths at
    each end, val the ink value, soft the Gaussian edge in pixels. All but
    size, soft and piece may be scalars or per-segment arrays.
    """
    w, h = size
    n = np.broadcast(x0, y0, x1, y1, core0, core1, val).shape
    x0, y0, x1, y1, core0, core1, val = (
        np.broadcast_to(np.asarray(a, dtype=np.float64), n).ravel()
        for a in (x0, y0, x1, y1, core0, core1, val))

    # CUT LONG SEGMENTS INTO PIECES of at most `piece` pixels. A segment is
    # drawn over its bounding box, and a long diagonal's box is almost all
    # empty: one corner-to-corner line at 4K supersampled would evaluate
    # eighty million pixels to ink a few tens of thousands. Pieces keep the
    # box close to the ink. The join is exact, because strokes combine by
    # maximum and the core width is interpolated continuously across the cut.
    L = np.hypot(x1 - x0, y1 - y0)
    k = np.maximum(1, np.ceil(L / piece)).astype(np.int64)
    idx = np.repeat(np.arange(L.size), k)
    first = np.repeat(np.cumsum(k) - k, k)
    ta = (np.arange(idx.size) - first) / k[idx]
    tb = ta + 1.0 / k[idx]
    ddx, ddy, dcc = x1 - x0, y1 - y0, core1 - core0
    X0 = x0[idx] + ddx[idx] * ta
    Y0 = y0[idx] + ddy[idx] * ta
    DX = ddx[idx] * (tb - ta)
    DY = ddy[idx] * (tb - ta)
    C0 = core0[idx] + dcc[idx] * ta
    DC = dcc[idx] * (tb - ta)
    V = val[idx]
    del idx, first, ta, tb

    L2 = DX * DX + DY * DY
    IL2 = np.where(L2 > 0, 1.0 / np.maximum(L2, 1e-300), 0.0)
    # Past three soft-widths the Gaussian shoulder is under 1e-4: not drawn.
    reach = np.maximum(C0, C0 + DC) + 3.0 * soft + 1.0
    lo = np.minimum(Y0, Y0 + DY) - reach
    hi = np.maximum(Y0, Y0 + DY) + reach
    # Anything wholly off the field costs nothing further.
    keep = (hi >= 0) & (lo <= h) & \
        (np.maximum(X0, X0 + DX) + reach >= 0) & (np.minimum(X0, X0 + DX) - reach <= w)

    global _JOB
    _JOB = tuple(a[keep] for a in (X0, Y0, DX, DY, IL2, C0, DC, V, lo, hi, reach)) \
        + (w, float(soft))

    # Row bands, several per core so a band full of dense detail does not
    # leave the rest idle. Bands are independent: each draws only its own
    # rows of every segment that reaches it, so there is no seam to join.
    jobs = jobs or os.cpu_count() or 4
    nb = max(1, min(h, jobs * 6))
    edges = np.linspace(0, h, nb + 1).astype(int)
    tasks = [(edges[j], edges[j + 1]) for j in range(nb) if edges[j + 1] > edges[j]]
    field = np.zeros((h, w), np.float32)
    try:
        if jobs > 1 and len(tasks) > 1:
            import multiprocessing as mp
            with mp.get_context("fork").Pool(jobs) as pool:
                for j0, band in pool.imap_unordered(_band, tasks):
                    field[j0:j0 + band.shape[0]] = band
        else:
            for t in tasks:
                j0, band = _band(t)
                field[j0:j0 + band.shape[0]] = band
    finally:
        _JOB = None
    return field


def to_pixels(extent, size):
    """World -> pixel mapping: returns (px(x), py(y), pixels per world unit).

    Equal scale on both axes, so nothing is stretched. `extent` is the
    (x0, x1, y0, y1) window to show, already at the panel's aspect (see
    lib.frame); y is flipped so that up in the maths is up on the screen.
    """
    w, _ = size
    x0, x1, y0, y1 = extent
    s = w / (x1 - x0)
    return (lambda x: (np.asarray(x) - x0) * s,
            lambda y: (y1 - np.asarray(y)) * s,
            s)
