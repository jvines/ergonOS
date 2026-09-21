"""Lichtenberg figure -- a discharge grown by the dielectric breakdown model.

A spark crossing the surface of an insulator does not take one path. It
branches, each branch branching again, into the fern-like figure Lichtenberg
dusted with powder in 1777 and which a high-voltage discharge still burns
into acrylic and wood. Niemeyer, Pietronero and Wiesmann (Phys. Rev. Lett.
52, 1033, 1984) showed that the whole figure follows from one rule:

    the discharge is a conductor, held at one potential;
    the electric potential around it satisfies Laplace's equation;
    it grows at its edge, into a neighbouring site with probability ~ |E|^eta.

Tips stick out into the field, so the field there is strongest and they grow
fastest; the fjords between branches are screened and starve. That is the
instability that makes branches, and screening is what keeps them apart.
eta = 1 is the value NPW matched to real surface discharges (fractal dimension
~1.7); larger eta makes fewer, straighter, more lightning-like leaders.

The model, as they wrote it, on a square lattice: the discharge at phi = 0,
a distant electrode at phi = 1, Laplace relaxed by red-black over-relaxation
between growth steps -- warm-started, since each step changes the field only
near the cells that were added. Candidate sites are the eight neighbours of
the discharge, and the field across a diagonal bond is phi / sqrt 2. A few
sites are added per solve, sampled exactly in proportion to E^eta by the
Gumbel top-k trick; the batch is kept a small fraction of the discharge, so
the tips barely advance before the field catches up. The lattice resolution
is fixed in cells per panel height, so the same figure is drawn at any size.

DRAWN as the tree it is. Every cell was added next to one that was already
part of the discharge, so each has a parent, and the current through any
channel is fed by everything that grew beyond it -- its subtree. Stroke width
goes as (subtree size)^ALPHA (Leonardo's rule again, as in the fractal tree:
the trunk carries the whole figure, a tip carries one cell) and colour
follows the same current, so the main channels burn hot and the fringe of
fine twigs is cool. The lattice's right angles are hidden, not removed: each
cell is jittered a third of a cell and the tree smoothed along its own
channels, which rounds the 45-degree staircase into the wandering channels of
a real figure; which cell grew from which -- the figure -- is the model's.
The smoothing length grows with the stroke: a twig is smoothed over a couple
of cells, a trunk over several times its own width, since a one-cell step
that is invisible in a hairline shows as a bend in a fat channel.
"""

import numpy as np

TITLE = "Lichtenberg figure"
SUBTITLE = "a spark grown where the field is strongest  (Niemeyer et al. 1984)"

# The field arrives already toned, 0..1: strokes carry their own colour.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
SOFTEN = 0.0          # strokes are analytic Gaussians, already band-limited
HUE_SMOOTH = 3.0      # one colour across a stroke's width
SUPERSAMPLE = 1

# Stroke geometry as fractions of the panel height (4K: x 2400 = pixels).
SOFT = 1.0 / 2400     # Gaussian edge of every stroke
CORE0 = 0.25 / 2400   # flat half-width of a one-cell tip
CORE_MAX = 9.0 / 2400 # the trunk's, at most
ALPHA = 0.42          # width ~ subtree^ALPHA
V0, VPOW = 0.30, 1.4  # colour: V0 at a tip, 1 at the root; power on log size
# Smoothing along a channel, in cells: SIG0, which rounds the lattice's one-cell
# steps, and then SIGK times the channel's half-width, so that a trunk bends at
# the scale of its branches and not of the lattice. Two Gaussian smoothings in
# a row are one, of the two lengths added in quadrature.
SIG0 = 2.45
SIGK = 7.0

# geometry: "point" (a point electrode, radial), "fan" (a point on the bottom
# edge, the edge insulating), "edge" (the whole bottom edge is the electrode,
# periodic sideways).  cells: lattice cells per panel height.  eta: the NPW
# exponent.  reach: stop when the discharge gets this far from the electrode,
# in panel heights.  seed: the random seed that grew it -- part of the picture.
# at: where along the bottom edge the fan's electrode sits, as a fraction of the
# width -- right of centre, so the caption does not run into the trunk.
PRESETS = {
    "blossom": dict(geometry="point", cells=300, eta=1.0, reach=0.80, seed=1),
    "fan":     dict(geometry="fan", cells=300, eta=1.0, reach=0.98, seed=1, at=0.55),
    "forest":  dict(geometry="edge", cells=300, eta=1.0, reach=0.96, seed=1),
}
# The growth is CHAOTIC in the arithmetic: each step picks a site by comparing
# field values that differ in the last bits, so the same seed grows a different
# discharge on another CPU architecture -- measured, 2026-09-22: pixel-identical
# on x86 (tiare, yuki), a different tree on arm64 (bronco). Masters and shipped
# fields come from x86; re-rendering elsewhere gives a sibling, not a copy.
#
# Offered on the desktop: the views chosen there. "blossom" was shown and pruned
# (its preset stays above).
VIEWS = ["fan", "forest"]

OMEGA = 1.85          # over-relaxation
SWEEPS = 10           # per growth step
BATCH = 0.005         # sites added per step, as a fraction of the discharge


def _relax(P, M, sweeps, ghost):
    """Red-black over-relaxation of Laplace's equation, in place.

    P is the potential with a one-cell ghost frame, M the relaxation weight
    of each interior cell (0 where the potential is held). The lattice is
    split into its four checkerboard sub-lattices -- (even, even) and
    (odd, odd) are red, the other two black -- and each is updated as a
    strided view of P, so no work is spent on the half that is not moving."""
    gh, gw = M.shape
    subs = []
    for r0, c0 in ((1, 1), (2, 2), (1, 2), (2, 1)):
        subs.append((P[r0:gh + 1:2, c0:gw + 1:2],
                     P[r0 - 1:gh:2, c0:gw + 1:2], P[r0 + 1:gh + 2:2, c0:gw + 1:2],
                     P[r0:gh + 1:2, c0 - 1:gw:2], P[r0:gh + 1:2, c0 + 1:gw + 2:2],
                     M[r0 - 1::2, c0 - 1::2]))
    for _ in range(sweeps):
        for q, (I, u, d, l, r, m) in enumerate(subs):
            t = u + d
            t += l; t += r
            t *= 0.25; t -= I; t *= m
            I += t
            if q % 2:
                ghost()


def _grow(p, aspect, log=None):
    """Run the model. Returns cell rows, cols, parent index (-1: electrode),
    and the (row, col) of the panel's origin (bottom-left) and its size in
    cells."""
    rng = np.random.default_rng(p["seed"])
    n = p["cells"]
    geo = p["geometry"]
    if geo == "edge":
        gh, gw = int(round(1.2 * n)), int(round(aspect * n))
        src = [(gh - 1, j) for j in range(gw)]
        panel = (gh - 1, 0)                       # bottom-left of the panel
    else:
        R = p["reach"] * n * 1.3                  # the far electrode
        half = int(R) + 2
        gw = 2 * half + 1
        gh = gw if geo == "point" else half + 1
        c = (half, half) if geo == "point" else (gh - 1, half)
        src = [c]
        panel = (c[0] + n // 2, c[1] - int(aspect * n / 2)) if geo == "point" \
            else (gh - 1, c[1] - int(p.get("at", 0.5) * aspect * n))
    yy, xx = np.mgrid[0:gh, 0:gw].astype(np.float32)
    if geo == "edge":
        phi = (gh - 1 - yy) / (gh - 1)
        free = (yy > 0)
    else:
        r = np.hypot(yy - src[0][0], xx - src[0][1])
        phi = np.clip(np.log(np.maximum(r, 0.5) / 0.5) / np.log(R / 0.5), 0, 1)
        free = r < R
        phi[~free] = 1.0
    phi = phi.astype(np.float32)

    # The potential lives in a frame of ghost cells, refreshed after every
    # half-sweep: periodic sideways for "edge", a mirror (no current through
    # the insulating edge) below "fan", fixed at 1 otherwise.
    P = np.ones((gh + 2, gw + 2), np.float32)
    P[1:-1, 1:-1] = phi
    occ = np.zeros((gh, gw), bool)
    order = np.full((gh, gw), np.iinfo(np.int64).max, np.int64)
    near = np.zeros((gh, gw), np.int8)            # 2: edge-adjacent, 1: diagonal
    # Relaxation weight per cell: OMEGA where the potential is free, 0 on the
    # discharge and the far electrode. Kept up to date as cells are added.
    M = (OMEGA * free).astype(np.float32)
    rows, cols, parent = [], [], []

    def ghost():
        if geo == "edge":
            P[:, 0] = P[:, -2]; P[:, -1] = P[:, 1]
            P[-1, :] = 0.0
        elif geo == "fan":
            P[-1, :] = P[-2, :]

    OFF = [(-1, 0, 2), (1, 0, 2), (0, -1, 2), (0, 1, 2),
           (-1, -1, 1), (-1, 1, 1), (1, -1, 1), (1, 1, 1)]

    def nbr(i, j, di, dj):
        ii, jj = i + di, j + dj
        if geo == "edge":
            jj = jj % gw
        ok = (ii >= 0) & (ii < gh) & (jj >= 0) & (jj < gw)
        return ii, jj, ok

    def add(ci, cj, par):
        k0 = len(rows)
        rows.extend(ci.tolist()); cols.extend(cj.tolist()); parent.extend(par)
        occ[ci, cj] = True
        M[ci, cj] = 0.0
        order[ci, cj] = np.arange(k0, k0 + ci.size)
        P[ci + 1, cj + 1] = 0.0
        for di, dj, wgt in OFF:
            ii, jj, ok = nbr(ci, cj, di, dj)
            np.maximum.at(near, (ii[ok], jj[ok]), wgt)

    s = np.array(src)
    add(s[:, 0], s[:, 1], [-1] * len(src))
    ghost()
    target = p["reach"] * n
    first = True
    step = 0
    while True:
        _relax(P, M, 300 if first else SWEEPS, ghost)
        first = False
        cand = np.flatnonzero((near > 0) & free & ~occ)
        ci, cj = np.divmod(cand, gw)
        E = np.maximum(P[ci + 1, cj + 1], 1e-9) * \
            np.where(near[ci, cj] == 2, 1.0, 0.70710678)
        key = p["eta"] * np.log(E) + rng.gumbel(size=cand.size)
        k = min(cand.size, max(1, int(BATCH * len(rows))))
        pick = np.argpartition(-key, k - 1)[:k] if k < cand.size else np.arange(k)
        ci, cj = ci[pick], cj[pick]
        # Parent: the oldest discharge cell across an edge, else a diagonal.
        best = np.full(ci.size, np.iinfo(np.int64).max, np.int64)
        for di, dj, wgt in OFF:
            ii, jj, ok = nbr(ci, cj, di, dj)
            o = np.full(ci.size, np.iinfo(np.int64).max, np.int64)
            o[ok] = order[ii[ok], jj[ok]]
            o = np.where(o == np.iinfo(np.int64).max, o, o + (0 if wgt == 2 else 1 << 40))
            best = np.minimum(best, o)
        best = np.where(best >= 1 << 40, best - (1 << 40), best)
        add(ci, cj, best.tolist())
        step += 1
        if geo != "point":
            # height above the edge: a fan that has run off the sides of the
            # panel has not yet filled it
            far = (gh - 1) - ci.min()
        else:
            far = np.hypot(ci - src[0][0], cj - src[0][1]).max()
        if log and step % 200 == 0:
            log(f"step {step}: {len(rows)} cells, reach {far / n:.2f}")
        if far >= target:
            break
    return (np.array(rows), np.array(cols), np.array(parent), panel, gw)


def caption(seed):
    p = PRESETS[VIEWS[seed % len(VIEWS)]]
    # Short: the fan's trunk stands at the bottom edge, and a longer line ran
    # into it. The exponent is written out only when it is not 1.
    where = {"point": "from a point", "fan": "from a point on the edge",
             "edge": "from an edge electrode"}[p["geometry"]]
    rate = "|E|" if p["eta"] == 1 else f"|E|^{p['eta']:g}"
    return TITLE, f"{where}: growth rate ~ {rate}  (Niemeyer et al. 1984)"


def generate(size, seed=0, jobs=None, view=None, **over):
    import pen

    p = dict(PRESETS[view or VIEWS[seed % len(VIEWS)]], **over)
    w, h = size
    aspect = w / h
    rows, cols, parent, panel, gw = _grow(p, aspect, log=over.get("log"))
    N = rows.size

    # Current through each channel: everything that grew beyond it.
    sub = np.ones(N, np.int64)
    for i in range(N - 1, -1, -1):
        if parent[i] >= 0:
            sub[parent[i]] += sub[i]

    # Positions in cells, jittered off the lattice and smoothed along the
    # channels. A channel runs from each node on through its MAIN child, the
    # one carrying the most current; a side branch starts one of its own.
    # Smoothing is diffusion along each channel, at a rate per node that makes
    # it a Gaussian of sigma `sig` after npass passes. One fixed length for
    # all left the fat channels bending like noodles at the lattice's scale.
    rng = np.random.default_rng([p["seed"], 1])
    x0 = cols.astype(float) + rng.uniform(-0.33, 0.33, N)
    y0 = rows.astype(float) + rng.uniform(-0.33, 0.33, N)
    has = parent >= 0
    a, b = np.flatnonzero(has), parent[has]
    srt = np.lexsort((sub[a], b))                  # by parent, then current
    last = np.r_[b[srt][1:] != b[srt][:-1], True]  # heaviest child of each
    main = np.full(N, -1)
    main[b[srt][last]] = a[srt][last]
    side = has & (main[parent] != np.arange(N))    # first node of a side branch
    core = np.minimum(CORE0 * sub ** ALPHA, CORE_MAX)   # panel heights
    sig = np.hypot(SIG0, SIGK * core * p["cells"])
    npass = int(np.ceil(2 * sig.max() ** 2))
    move = has & (main >= 0)
    q, c = parent[move], main[move]
    rate = sig[move] ** 2 / (2 * npass)            # at most 1/4: stable
    # A side branch is smoothed against where its parent WAS; it is moved
    # with its parent afterwards, below.
    anchor = side[move]
    # Offsets, not positions, so that on the periodic "edge" lattice a
    # channel crossing the seam is averaged across it and not across the
    # whole panel.
    wrap = (lambda d: (d + gw / 2) % gw - gw / 2) if p["geometry"] == "edge" \
        else (lambda d: d)
    x, y = x0.copy(), y0.copy()
    for _ in range(npass):
        xm, ym = x[move], y[move]
        xq = np.where(anchor, x0[q], x[q])
        yq = np.where(anchor, y0[q], y[q])
        x[move] = xm + rate * (wrap(xq - xm) + wrap(x[c] - xm))
        y[move] = ym + rate * ((yq - ym) + (y[c] - ym))
    # A trunk straightened by a few cells carries its side branches with it:
    # each takes its parent's whole displacement at the joint, so twigs keep
    # their shape, and lets it die away along its own channel over its own
    # smoothing length, so distant subtrees stay where they grew.
    dx, dy = (x - x0).tolist(), (y - y0).tolist()
    ex, ey = [0.0] * N, [0.0] * N
    decay = np.exp(-1.0 / sig).tolist()
    for j, (pj, sj) in enumerate(zip(parent.tolist(), side.tolist())):  # parents first
        if pj < 0:
            continue
        if sj:
            ex[j], ey[j] = dx[pj] + ex[pj], dy[pj] + ey[pj]
        else:
            ex[j], ey[j] = decay[j] * ex[pj], decay[j] * ey[pj]
    x += np.array(ex)
    y += np.array(ey)

    # Cells -> panel pixels, y down. The panel's bottom-left is `panel`.
    s = h / p["cells"]
    X = (x - panel[1]) * s
    Y = h - (panel[0] - y) * s
    # The parent end of each segment, unwrapped next to its child.
    X_b = X[a] - wrap(x[a] - x[b]) * s
    half = core[a] * h
    v = V0 + (1 - V0) * (np.log(sub[a]) / np.log(sub[a].max())) ** VPOW
    return pen.draw(X[a], Y[a], X_b, Y[b], half, half, v, size,
                    soft=SOFT * h, jobs=jobs).astype(np.float64)
