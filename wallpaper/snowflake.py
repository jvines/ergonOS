"""Snow crystal growth -- Gravner and Griffeath's mesoscopic lattice model.

Why a snow crystal has six arms, and why the six are alike though no arm can
see another: the ice lattice is hexagonal, so the crystal grows fastest along
six directions, and every arm grows in the same air at the same temperature
and supersaturation, so each writes the same history. Nakaya (1954) grew them
on a rabbit hair in a cold chamber and read the conditions off the shapes:
plates where vapour is scarce, ferns where it is plentiful.

Gravner and Griffeath (Physica D 237, 385, 2008) turned the physics that
decides between them into a local rule on the triangular lattice. Each site
holds vapour d, a quasi-liquid layer c and ice b; the crystal is the set of
sites that have attached. Every step:

  * diffusion: vapour off the crystal relaxes toward its neighbours' mean,
    reflecting off the ice -- the crystal is a sink, and the arms shadow the
    ground between them, which is what makes this diffusion-limited growth;
  * freezing: at the boundary, vapour is deposited, a fraction kappa of it
    into the quasi-liquid layer and the rest as ice;
  * attachment: a boundary site joins the crystal when its ice passes a
    threshold that depends on how many crystal neighbours it has -- beta at a
    tip (one or two), 1 on a flat facet (three) unless the air around is
    nearly exhausted (below theta) and then already at alpha, and at once in
    a notch (four or more). That anisotropy is where the facets come from;
  * melting: a fraction mu of the unattached ice and gamma of the liquid go
    back to vapour.

Tips reach fresh vapour first, so they outrun the facets between them (the
Mullins-Sekerka instability), and a tip that runs ahead sheds side branches
from its facets: dendrites. In the model what counts is the vapour against
the ice a tip must gather before it may attach: a high beta for the rho
available takes away the tips' head start, as scarce vapour does in a cloud,
the facets keep up, and the arms grow as broad plates. Each preset is one run
of the model from a single frozen site, with no noise and no symmetry
imposed: the six-fold symmetry is the lattice's, and the arms agree because
the rule is the same everywhere.

The vapour far from the crystal is held at rho on a circle a fixed margin
beyond the furthest tip, and only the region inside it is computed. The model
itself has no such circle -- its lattice is simply large -- and a margin of a
quarter of the final radius stands in for the far field.

Drawn as ice, coloured by when it froze. An attached site never changes
again, so the model keeps two records: the step each site froze at, and the
ice b it held when it did. Colour runs with the first, through the ramp
reversed -- the oldest ice at the heart pink, the newest at the tips sky --
and the contours of the same record are drawn as fine dark lines: growth
rings, the crystal's own outline at earlier times, hexagons in the plate and
chevrons down every branch. b adds a faint relief, heavier along the spines
where the arms grew fastest. The edge is the half-way contour of the
attached set, smoothed over a cell or two and drawn from its distance, as
in ising.py.
"""

import numpy as np

TITLE = "Snow crystal"
SUBTITLE = "a stellar dendrite grown on a hexagonal lattice from vapour"

# The field arrives in 0..1 (see _draw). Screen-filling -- about half the
# panel is ice -- so saturation sits below the line-on-ground house value.
# HUE_SMOOTH takes the hue from the neighbourhood, so the crystal's soft edge
# fades in its own colour instead of stepping down the ramp through every
# colour below it, and the rings, which are drawn DARKER than the ice around
# them, read as grooves in one colour. Bright rings were tried and made the
# dark halos lib.render warns about.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
RAMP = "full"
REVERSE = True
SATURATION = 1.8
EXPOSURE = 1.0
HUE_SMOOTH = 3.0
# Drawn from a coarse lattice by interpolation and analytic edges: band-
# limited already. Supersampling would grow the same crystal and only cost.
SUPERSAMPLE = 1

S3 = np.sqrt(3.0) / 2.0
# The six neighbours of lattice site (r, c) in axial coordinates. Site (r, c)
# sits at c e1 + r e2 with e1 = (1, 0), e2 = (1/2, sqrt 3 / 2).
NBRS = ((0, 1), (0, -1), (1, 0), (-1, 0), (1, -1), (-1, 1))
VEC = np.array([(dc + 0.5 * dr, S3 * dr) for dr, dc in NBRS])

# Drawing, as fractions of the panel height: the edge's anti-aliasing ramp and
# a ring's pen. Then the tone: the level of the newest ice, how far the oldest
# rises above it, the b relief, and how dark a ring cuts.
EDGE = 2.5 / 2400
PEN = 1.2 / 2400
BODY = 0.2
AGE = 0.55
RELIEF = 0.08
RING_DARK = 0.45
# In lattice cells, so every render size draws the same crystal: passes of the
# seven-site mean under the edge, and how far past the crystal its records are
# carried (see _lattice_fields).
EDGE_PASSES = 6
EXTEND = 3

# (rho, beta, alpha, theta, kappa, mu, gamma) -- the seven of G&G's rule, set
# in the dendrite and the plate regimes and chosen by growing a survey of them
# small and looking -- then the crystal radius and the reservoir margin in
# lattice cells, the number of growth rings, and the view: the crystal's radius
# on screen in panel heights, its rotation in degrees, and the offset of its
# centre in panel heights.
#
# Rotated 90 degrees, so two arms run up and down off the panel and the other
# four point almost exactly into its corners -- a 16:10 diagonal is 32 degrees
# off the horizontal, the arms 30. The fern is sized so its arms leave the
# corners; the plate, whose arms end in broad hexagonal plates worth seeing
# whole, so they stop just inside them.
#
# A third regime -- rho 0.38, plates on every branch -- took 28 minutes to grow
# at this radius and filled the panel solid; pruned. So was a sectored plate,
# which is a hexagon, and a hexagon on a 16:10 screen is either boxed in the
# middle or a texture.
#
# Before the view, the radius in cells of the closing that fills the edge's
# narrowest inlets. The plate's notches fill by side plates stacking two or
# three cells apart, which at 3.6 px a cell printed as a saw; the fern's gaps
# between branchlets are real, and closing bridged them into holes.
# Only "plate" was chosen on a real desktop. "fern" -- ((0.5, 1.4, 0.1, 0.005,
# 0.001, 0.04, 0.0001), 540, 140, 20, 0, (1.0, 90.0, 0.0, 0.0)) -- was shown in
# both ramp directions and pruned.
PRESETS = {
    "plate": ((0.8, 2.6, 0.004, 0.001, 0.05, 0.015, 0.0001),
              540, 140, 20, 2, (0.8, 90.0, 0.0, 0.0)),
}


def _preset(seed):
    names = list(PRESETS)
    return names[seed % len(names)], PRESETS[names[seed % len(names)]]


def caption(seed):
    name, ((rho, beta, *_p), *_r) = _preset(seed)
    kind = {"fern": "a stellar dendrite", "plate": "a stellar plate"}[name]
    return TITLE, (f"{kind} grown from vapour on a hexagonal lattice,  rho = {rho:g}, "
                   f"beta = {beta:g}   (Gravner & Griffeath 2008)")


def _nsum(p):
    """Sum over the six neighbours, for the interior of a 1-padded array."""
    return (p[1:-1, 2:] + p[1:-1, :-2] + p[2:, 1:-1] + p[:-2, 1:-1]
            + p[2:, :-2] + p[:-2, 2:])


def _grow(params, radius, margin):
    rho, beta, alpha, theta, kappa, mu, gamma = params
    n = 2 * (int(np.ceil((radius + margin) / S3)) + 4) + 1
    o = n // 2
    r, c = np.mgrid[0:n, 0:n]
    dist = np.hypot((c - o) + 0.5 * (r - o), S3 * (r - o)).astype(np.float32)
    del r, c

    a = np.zeros((n, n), bool)
    nA = np.zeros((n, n), np.float32)       # attached neighbours
    b = np.zeros((n, n), np.float32)
    q = np.zeros((n, n), np.float32)        # quasi-liquid, G&G's c
    d = np.full((n, n), rho, np.float32)
    t = np.zeros((n, n), np.float32)
    a[o, o], b[o, o], d[o, o] = True, 1.0, 0.0
    for dr, dc in NBRS:
        nA[o + dr, o + dc] += 1

    tip, step, far_r = 0.0, 0, -1
    while tip < radius:
        step += 1
        # The window: the axial box around the circle of the reservoir, which
        # sits `margin` cells beyond the furthest tip. Rebuilt only when the
        # crystal has grown by a cell.
        if int(tip) + margin > far_r:
            far_r = int(tip) + margin
            k = int(np.ceil(far_r / S3)) + 2
            win = (slice(o - k, o + k + 1), slice(o - k, o + k + 1))
            pad = (slice(o - k - 1, o + k + 2), slice(o - k - 1, o + k + 2))
            far = dist[win] > far_r
            A, N, B, Q, D, T = a[win], nA[win], b[win], q[win], d[win], t[win]
            R = dist[win]

        # 1. Diffusion, reflecting off the crystal: an attached neighbour
        #    contributes the site's own vapour (it holds none of its own).
        dn = (D * (1.0 + N) + _nsum(d[pad])) / 7.0
        dn[A] = 0.0
        dn[far] = rho
        D[...] = dn
        # Views into the window, indexed by (row, col) pairs, so that every
        # assignment below writes through to the lattice.
        br, bc = np.nonzero((N > 0) & ~A)

        # 2. Freezing at the boundary.
        v = D[br, bc]
        B[br, bc] += (1.0 - kappa) * v
        Q[br, bc] += kappa * v
        D[br, bc] = 0.0

        # 3. Attachment, by attached-neighbour count (see the docstring). The
        #    vapour test sums the neighbourhood after freezing.
        nb, bb = N[br, bc], B[br, bc]
        P = d[pad]
        near = sum(P[br + 1 + dr, bc + 1 + dc] for dr, dc in NBRS)
        join = (((nb <= 2) & (bb >= beta))
                | ((nb == 3) & ((bb >= 1.0) | ((near < theta) & (bb >= alpha))))
                | (nb >= 4))
        jr, jc = br[join], bc[join]
        if jr.size:
            A[jr, jc] = True
            B[jr, jc] += Q[jr, jc]
            Q[jr, jc] = 0.0
            T[jr, jc] = step
            for dr, dc in NBRS:
                np.add.at(N, (jr + dr, jc + dc), 1.0)
            tip = max(tip, float(R[jr, jc].max()))

        # 4. Melting, on the boundary that did not attach.
        kr, kc = br[~join], bc[~join]
        D[kr, kc] += mu * B[kr, kc] + gamma * Q[kr, kc]
        B[kr, kc] *= 1.0 - mu
        Q[kr, kc] *= 1.0 - gamma
    return a, b, t, step


def _roll(f, dr, dc):
    """f at the neighbour (dr, dc) of every site."""
    return np.roll(f, (-dr, -dc), (0, 1))


def _grad(f):
    """Cartesian gradient on the triangular lattice: the six unit vectors
    satisfy sum e e^T = 3 I, so (1/3) sum_k f(x + e_k) e_k is exact for a
    linear f and needs no preferred axis."""
    gx = np.zeros_like(f)
    gy = np.zeros_like(f)
    for (dr, dc), (ex, ey) in zip(NBRS, VEC):
        fk = _roll(f, dr, dc)
        gx += fk * ex
        gy += fk * ey
    return gx / 3.0, gy / 3.0


def _smooth_inside(f, a, passes):
    """Mean over each site of `a` and its neighbours in `a`, `passes` times.

    Rounds the one-cell steps the lattice prints into anything recorded per
    site, without averaging in the empty ground beside the crystal."""
    af = a.astype(np.float32)
    den = af + sum(_roll(af, dr, dc) for dr, dc in NBRS)
    for _ in range(passes):
        g = f * af
        f = np.where(a, (g + sum(_roll(g, dr, dc) for dr, dc in NBRS))
                     / np.maximum(den, 1.0), 0.0)
    return f


def _dilate(a, k):
    for _ in range(k):
        a = a | np.any([_roll(a, dr, dc) for dr, dc in NBRS], axis=0)
    return a


def _extend(f, have, want):
    """f carried from the sites in `have` out over `want`, a ring of sites at
    a time, each taking the mean of its neighbours that already hold one."""
    f = np.where(have, f, 0.0).astype(np.float32)
    have = have.copy()
    while True:
        hf = have.astype(np.float32)
        den = sum(_roll(hf, dr, dc) for dr, dc in NBRS)
        new = want & ~have & (den > 0)
        if not new.any():
            return f
        num = sum(_roll(f * hf, dr, dc) for dr, dc in NBRS)
        f[new] = num[new] / den[new]
        have |= new


def _lattice_fields(a, b, t, n_rings, close):
    """Everything the drawing needs, per lattice site."""
    # Inlets narrower than about 2 * close cells are filled by a closing with
    # a hexagon, which leaves the facets alone; the sites it adds take their
    # records from the crystal around them.
    if close:
        c = _dilate(a, close)
        for _ in range(close):
            c &= np.all([_roll(c, dr, dc) for dr, dc in NBRS], axis=0)
        c |= a
        t, b, a = _extend(t, a, c), _extend(b, a, c), c
    # The edge: the half-way contour under EDGE_PASSES of the seven-site mean,
    # a Gaussian of about 1.6 cells. It rounds the lattice's zigzag and the
    # teeth left where a notch filled in steps -- at 4 px a cell both printed
    # as a saw -- and leaves facets, which run along lattice directions,
    # straight. It would erase a branch under ~4 cells wide; the presets have
    # none.
    s = a.astype(np.float32)
    for _ in range(EDGE_PASSES):
        s = (s + sum(_roll(s, dr, dc) for dr, dc in NBRS)) / 7.0
    gx, gy = _grad(s)
    sd = np.clip((s - 0.5) / (np.hypot(gx, gy) + 1e-6), -3.0, 3.0)
    lo, hi = np.percentile(b[a], [2, 98])

    # Records carried EXTEND cells past the crystal: the smoothed edge fills
    # concave corners, and pixels there met the ground's zeros -- a ring for
    # every interval down to none, crammed into a cell: a dark speck.
    m = _dilate(a, EXTEND)
    t, b = _extend(t, a, m), _extend(b, a, m)

    # Ice mass at attachment, as a fraction of its spread in the crystal,
    # mixed once with its neighbours: the ridges are several cells wide and
    # survive it, the cell-to-cell scatter of the threshold crossing does not.
    tone = _smooth_inside(np.clip((b - lo) / (hi - lo), 0.0, 1.0), m, 1)

    # The step each site froze at, smoothed so that its contours -- the rings
    # -- are the crystal's past outlines and not the lattice's steps; as a
    # fraction of the whole growth, and in ring intervals.
    ts = _smooth_inside(t, m, 2)
    age = ts / ts.max()
    tau = age * n_rings
    # Its gradient, with the margin's edge reflecting: beyond it each site's
    # own value stands in, so the rings do not see the empty ground as a cliff
    # in time and crowd into the rim.
    gx = np.zeros_like(tau)
    gy = np.zeros_like(tau)
    for (dr, dc), (ex, ey) in zip(NBRS, VEC):
        tk = np.where(_roll(m, dr, dc), _roll(tau, dr, dc), tau)
        gx += (tk - tau) * ex
        gy += (tk - tau) * ey
    slope = np.where(m, np.hypot(gx, gy) / 3.0, 0.0)
    return sd, tone, tau, slope, age


def _sample(fields, rr, cc):
    """Linear interpolation on the triangular lattice, at fractional axial
    coordinates: the three sites of the triangle the point falls in, weighted
    barycentrically. Isotropic -- no square grid is ever involved."""
    r0, c0 = np.floor(rr).astype(np.int64), np.floor(cc).astype(np.int64)
    fr, fc = (rr - r0).astype(np.float32), (cc - c0).astype(np.float32)
    up = fr + fc > 1.0
    # Lower triangle (r0,c0), (r0,c0+1), (r0+1,c0); upper (r0+1,c0+1), (r0,c0+1),
    # (r0+1,c0). The corner that differs is the first one.
    ra = np.where(up, r0 + 1, r0)
    ca = np.where(up, c0 + 1, c0)
    wa = np.where(up, fr + fc - 1.0, 1.0 - fr - fc)
    wb = np.where(up, 1.0 - fr, fc)          # (r0, c0 + 1)
    wc = np.where(up, 1.0 - fc, fr)          # (r0 + 1, c0)
    return [f[ra, ca] * wa + f[r0, c0 + 1] * wb + f[r0 + 1, c0] * wc for f in fields]


def _draw(a, b, t, w, h, radius, n_rings, close, view):
    size, rot, ox, oy = view
    s = size * h / radius                           # pixels per lattice cell
    fields = _lattice_fields(a, b, t, n_rings, close)
    n = a.shape[0]
    o = n // 2
    cr, sr = np.cos(np.radians(rot)), np.sin(np.radians(rot))
    edge_px, pen_px = EDGE * h, PEN * h

    # Pixel by pixel, in bands of rows so an 8K panel stays in bounded memory:
    # pixel -> crystal-centred coordinates in cells -> rotated -> axial.
    out = np.empty((h, w), np.float32)
    x = ((np.arange(w) + 0.5 - (0.5 * w + ox * h)) / s).astype(np.float32)
    rows = max(1, 1_000_000 // w)
    for y0 in range(0, h, rows):
        y = (np.arange(y0, min(h, y0 + rows)) + 0.5 - (0.5 * h + oy * h)) / s
        X, Y = np.meshgrid(x, y.astype(np.float32))
        Xr, Yr = X * cr + Y * sr, Y * cr - X * sr
        rr = np.clip(Yr / S3 + o, 0, n - 2.001)
        cc = np.clip(Xr - 0.5 * Yr / S3 + o, 0, n - 2.001)
        SD, TONE, TAU, SLOPE, AGE_ = _sample(fields, rr, cc)

        edge = np.clip(0.5 + SD * s / edge_px, 0.0, 1.0)
        # A ring is where the freezing step crosses a multiple of the interval:
        # the distance to it is the fractional part over the slope, drawn with
        # a Gaussian pen. Where rings crowd closer than a few pens -- the slow
        # facets of the plates -- they fade out rather than merge into a band.
        spacing = s / np.maximum(SLOPE, 1e-6)
        dist = np.abs(TAU - np.round(TAU)) * spacing
        ring = np.exp(-(dist / pen_px) ** 2)
        ring *= np.clip((spacing / pen_px - 4.0) / 4.0, 0.0, 1.0)
        tone = BODY + AGE * np.clip(AGE_, 0.0, 1.0) + RELIEF * TONE
        out[y0:y0 + len(y)] = edge * tone * (1.0 - RING_DARK * ring)
    return out


def generate(size, seed=0):
    w, h = size
    _, (params, radius, margin, n_rings, close, view) = _preset(seed)
    a, b, t, _steps = _grow(params, radius, margin)
    return _draw(a, b, t, w, h, radius, n_rings, close, view)
