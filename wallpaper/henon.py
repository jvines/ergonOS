"""Henon map -- two views of one stretch-and-fold.

    x' = 1 - a x^2 + y,   y' = b x          a = 1.4, b = 0.3   (Henon 1976)

Stretched and bent into a horseshoe, squashed by b a step: the attractor is
a smooth curve along its length and a Cantor set across it. It is the closure
of the unstable manifold of the saddle P inside it, so it is DRAWN AS A CURVE
-- a segment through P mapped forward, split wherever neighbours drift apart.

It cannot be made dense: across its strands it has dimension ~0.26, so H
pixels resolve about (H / pen)^0.26 strands at any zoom (a 500x fold showed
14). The density comes from objects that are dense:

  0  BASIN   the points that escape, as contours of how fast; the attractor
             inside. See isochrones().
  1  SHEAF   the fold for ten values of a, one colour each.

A third view, the attractor through P's stable manifold (grown with the
inverse map for 20 steps, frame (-1.4, 1.4, -0.52, 0.43)), was shown and
pruned.

Deterministic: no random sampling.
"""

import os

import numpy as np

A, B = 1.4, 0.3

TITLE = "Henon map"
SUBTITLE = "x' = 1 - a x^2 + y,  y' = b x"

# Lines on the ground colour in all three views, built in 0..1 (a pen profile
# times a hue), so the renderer takes the field as it is; house saturation.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
# No SOFTEN: the strokes are band-limited already, as in koch.py. With it a
# thin line's core sank to ~0.6 and every hue slid a third down the ramp.
SOFTEN = 0.0
HUE_SMOOTH = 3.0

# Frames as (x0, x1, y0, y1), anisotropic as in Henon's own figures. WHOLE is
# the a = 1.4 attractor.
WHOLE = (-1.305, 1.295, -0.4776, 0.389)
# Left edge inside the basin, so the caption sits on its dark floor with no
# band through it (the attractor's left tip is cut); tall, so the escaping
# tongues run long.
BASIN = (-0.92, 3.08, -0.9, 2.3)
ISOCHRONES = 40
SHEAF = (1.10, 1.31, -0.21, 0.21)
# Only a with a strange attractor that contains P (Lyapunov exponent 0.23 to
# 0.42): below 1.155 it is in pieces with P off it; 1.227..1.262 and
# 1.294..1.306 are periodic windows. Spaced so the fold tips are roughly even.
SHEAF_A = (1.155, 1.178, 1.201, 1.2255, 1.2765, 1.299, 1.3265, 1.3505, 1.375, 1.40)

# Pen: Gaussian sigma in pixels of a 3840-wide panel (a fixed fraction of the
# frame, so 4K, 8K and previews match), clipped at CORE x its peak for a flat
# core ~1.6 px wide.
PEN = 0.5
CORE = 3.6


def caption(seed):
    if seed % 2 == 0:
        # Short: it has to end inside the basin, left of the right band.
        return ("Henon map, what escapes and what stays",
                "a = 1.4, b = 0.3:  lines of equal escape time;  the dark never escapes")
    return ("Henon attractors, a = 1.155 to 1.40",
            "x' = 1 - a x^2 + y,  y' = b x,  b = 0.3:"
            "  the right-hand fold of ten attractors, one colour for each a")


def _saddle(a):
    """P, the fixed point inside the attractor, and its eigen-directions:
    unstable (eigenvalue ~ -1.92, flips sides) and stable (~ +0.156)."""
    x = (-(1 - B) + np.sqrt((1 - B) ** 2 + 4 * a)) / (2 * a)
    r = np.sqrt(a * a * x * x + B)
    return x, B * x, [np.array([l, B]) / np.hypot(l, B) for l in (-a * x - r, -a * x + r)]


def manifold(a, steps, view, shape, coarse=None, spacing=1.5, cspacing=0.3,
             stable=False, far=(1.6, 0.7)):
    """An invariant curve of P as a polyline (x, y, s); NaN breaks it.

    Unstable: a segment through P mapped forward. Stable: mapped BACKWARD;
    basin orbits stay in |x| < 1.4, |y| < 0.6 after a step, so points past
    `far` are cut. A segment longer than `spacing` subpixels of `view` (or
    `cspacing` cells of `coarse`, outside it) is split by mapping points
    spaced along its PREIMAGE. s: offset from P on the starting segment.
    """
    h, w = shape
    x0, x1, y0, y1 = view
    X0, X1, Y0, Y1 = coarse or view
    cs = cspacing if coarse else spacing
    fx, fy = (x1 - x0) / w, (y1 - y0) / h
    qx, qy = ((X1 - X0) / 3840, (Y1 - Y0) / 2400) if coarse else (fx, fy)
    lo_x, hi_x, lo_y, hi_y = x0 - 2 * qx, x1 + 2 * qx, y0 - 2 * qy, y1 + 2 * qy
    px, py, vv = _saddle(a)
    v = vv[1] if stable else vv[0]
    f = (lambda x, y: (y / B, x - 1 + a * (y / B) ** 2)) if stable else \
        (lambda x, y: (1 - a * x * x + y, B * x))
    s = np.linspace(-1e-7, 1e-7, 64)
    x, y = px + s * v[0], py + s * v[1]
    for _ in range(steps):
        xn, yn = f(x, y)
        mx, my = (xn[1:] + xn[:-1]) / 2, (yn[1:] + yn[:-1]) / 2
        inside = (mx > lo_x) & (mx < hi_x) & (my > lo_y) & (my < hi_y)
        seg = np.nan_to_num(np.hypot(np.diff(xn) / np.where(inside, fx, qx),
                                     np.diff(yn) / np.where(inside, fy, qy)))
        k = np.maximum(np.ceil(seg / np.where(inside, spacing, cs)), 1).astype(np.int64)
        if (k > 1).any():
            i = np.repeat(np.arange(k.size), k)
            t = (np.arange(i.size) - np.repeat(np.cumsum(k) - k, k)) / k[i]
            m = t > 0                       # t = 0 keeps a point beside a break
            x, y, s = (np.append(np.where(m, c[i] + t * (c[i + 1] - c[i]), c[i]), c[-1])
                       for c in (x, y, s))
            xn, yn = f(x, y)
        x, y = xn, yn
        if stable:
            gone = ~((np.abs(x) < far[0]) & (np.abs(y) < far[1]))
            x[gone] = y[gone] = np.nan
            keep = np.append(True, ~(gone[1:] & gone[:-1]))
            x, y, s = x[keep], y[keep], s[keep]
    return x, y, s


def deposit(x, y, val, view, shape, sub=4):
    """Length-weighted bilinear deposit of a polyline: (D, D * val). A line
    holds 1 per subpixel of length wherever it falls -- no staircase."""
    h, w = shape
    x0, x1, y0, y1 = view
    u = (x - x0) * (w / (x1 - x0)) - 0.5
    v = (y1 - y) * (h / (y1 - y0)) - 0.5
    du, dv = np.diff(u), np.diff(v)
    ok = ((np.minimum(u[1:], u[:-1]) < w) & (np.maximum(u[1:], u[:-1]) > -1) &
          (np.minimum(v[1:], v[:-1]) < h) & (np.maximum(v[1:], v[:-1]) > -1))
    u0, v0, du, dv = u[:-1][ok], v[:-1][ok], du[ok], dv[ok]
    c0, dc = val[:-1][ok], np.diff(val)[ok]
    L = np.hypot(du, dv) / sub
    D = np.zeros(h * w)
    V = np.zeros(h * w)
    for j in range(sub):
        t = (j + 0.5) / sub
        pu, pv, c = u0 + t * du, v0 + t * dv, c0 + t * dc
        iu, iv = np.floor(pu), np.floor(pv)
        tu, tv = pu - iu, pv - iv
        iu, iv = iu.astype(np.int64), iv.astype(np.int64)
        for eu, ev, wt in ((0, 0, (1 - tu) * (1 - tv)), (1, 0, tu * (1 - tv)),
                           (0, 1, (1 - tu) * tv), (1, 1, tu * tv)):
            cu, cv = iu + eu, iv + ev
            m = (cu >= 0) & (cu < w) & (cv >= 0) & (cv < h)
            q = cv[m] * w + cu[m]
            D += np.bincount(q, weights=(wt * L)[m], minlength=h * w)
            V += np.bincount(q, weights=(wt * L * c)[m], minlength=h * w)
    return D.reshape(h, w), V.reshape(h, w)


def lines(D, V, rank=True, floor=0.3, pen=PEN):
    """Deposits -> 0..1 field: a Gaussian pen, peaking at CORE and clipped to
    1 (the flat core keeps a thin line's colour through the renderer's hue
    smoothing), times the hue, ranked into floor..1 if `rank`. Deposits are
    capped at one strand a subpixel -- a UNION: summed, bundles fattened."""
    import lib
    sig = max(0.7, pen * D.shape[1] / 3840)
    cap = 1.0 / np.maximum(D, 1.0)
    D, V = D * cap, V * cap
    del cap
    Dg = lib.smooth(D.astype(np.float32), sig)
    hue = lib.smooth(V.astype(np.float32), sig) / np.maximum(Dg, 1e-12)
    cov = np.clip(Dg * np.float32(sig * np.sqrt(2 * np.pi) * CORE), 0, 1)
    del Dg
    if rank:
        core = hue[cov > 0.5]
        q = np.quantile(core[::max(1, core.size // 2_000_000)],
                        np.linspace(0, 1, 1025))
        hue = floor + (1 - floor) * np.interp(hue, q, np.linspace(0, 1, 1025))
    return (np.clip(hue, 0, 1) * cov).astype(np.float32)


def _attractor(view, shape, pen=PEN):
    x, y, _ = manifold(A, 36, view, shape)
    return lines(*deposit(x, y, np.ones_like(x), view, shape), rank=False, pen=pen)


def _sheaf_one(job):
    a, view, shape = job
    x, y, _ = manifold(a, 38, view, shape, coarse=WHOLE)
    return deposit(x, y, np.zeros_like(x), view, shape)[0].astype(np.float32)


def _escape_rows(job):
    """Smooth escape count for rows r0..r1; 0 where the orbit stays."""
    r0, r1, w, h, view, maxiter = job
    x0, x1, y0, y1 = view
    gx = x0 + (np.arange(w) + 0.5) / w * (x1 - x0)
    gy = y1 - (np.arange(r0, r1) + 0.5) / h * (y1 - y0)
    out = np.zeros((r1 - r0) * w, np.float32)
    # Henon's own trapping quadrilateral: an orbit that enters never leaves.
    quad = np.array([(-1.33, 0.42), (1.32, 0.133), (1.245, -0.14), (-1.06, -0.5)])
    R = 1e6
    for c in range(0, out.size, 8192):
        idx = np.arange(c, min(c + 8192, out.size))
        x, y = gx[idx % w].copy(), gy[idx // w].copy()
        for n in range(1, maxiter + 1):
            x, y = 1 - A * x * x + y, B * x
            esc = np.abs(x) > R
            if esc.any():
                # Far out, a|x| squares every step, as |z| does for z^2 + c:
                # the fraction says where between two steps the orbit left.
                out[idx[esc]] = n - np.log2(np.log(A * np.abs(x[esc])) / np.log(A * R))
            trap = np.ones(x.size, bool)
            for i in range(4):
                (ax, ay), (bx, by) = quad[i], quad[(i + 1) % 4]
                trap &= (bx - ax) * (y - ay) - (by - ay) * (x - ax) <= 0
            keep = ~esc & ~trap
            if not keep.any():
                break
            x, y, idx = x[keep], y[keep], idx[keep]
    return r0, out.reshape(r1 - r0, w)


def escape(size, view, maxiter=400, jobs=None):
    import multiprocessing as mp
    w, h = size
    work = [(r, min(r + 16, h), w, h, view, maxiter) for r in range(0, h, 16)]
    nu = np.zeros((h, w), np.float32)
    with mp.get_context("fork").Pool(jobs or os.cpu_count()) as pool:
        for r0, part in pool.imap_unordered(_escape_rows, work):
            nu[r0:r0 + part.shape[0]] = part
    return nu


def isochrones(nu, K=ISOCHRONES, hues=(0.3, 0.75), edge_hue=0.8):
    """Escape time as contour lines, K of them at equal-AREA steps.

    A filled escape field failed: the escape time is smooth, so every stretch
    was a teal flood or a faint fade showing the colormap's 512 steps as
    terraces. Where lines crowd closer than a few pen widths they give way to
    a flat fill of their hue at the cover they average to (4.2 sig per line),
    and the LAST band, next to the basin, is filled solid: it holds the
    tongues of escaping points reaching into the basin, which as bare
    outlines read as scratches. The boundary gets a line of its own.
    """
    import lib
    h, w = nu.shape
    sig = max(0.7, PEN * w / 3840)
    ext = nu > 0
    s = nu[ext]
    grid = np.linspace(0, 1, 4097)
    q = np.quantile(s[::max(1, s.size // 4_000_000)], grid)
    # Inside the basin R is held at K, the value it tends to at the boundary,
    # so its gradient has no step there.
    R = np.full(nu.shape, np.float32(K))
    R[ext] = K * np.interp(s, q, grid)
    gy, gx = np.gradient(R)
    g = np.maximum(np.hypot(gx, gy), 1e-6)
    del gx, gy
    body = np.clip(CORE * np.exp(-0.5 * (np.abs(R - np.round(R)) / g / sig) ** 2), 0, 1)
    solid = np.where(R > K - 1, 1, 1 - np.clip((1 / g - 3 * sig) / (4 * sig), 0, 1))
    cover = np.where(R > K - 1, 1, np.minimum(1, 4.2 * sig * g))
    body = (body * (1 - solid) + cover * solid) * ext
    del solid, cover
    field = (hues[0] + (hues[1] - hues[0]) * R / K) * body
    del body, g
    # The boundary: a blurred inside/outside step; 4M(1-M) peaks on it.
    M = lib.smooth((~ext).astype(np.float32), sig)
    edge = np.clip(1.6 * 4 * M * (1 - M), 0, 1)
    return np.maximum(field, np.float32(edge_hue) * edge).astype(np.float32)


def generate(size, seed=0, view=None, jobs=None):
    w, h = size
    if seed % 2 == 0:
        v = view or BASIN
        return np.maximum(isochrones(escape(size, v, jobs=jobs)), _attractor(v, (h, w)))
    import multiprocessing as mp
    v = view or SHEAF
    D = np.zeros((h, w), np.float32)
    V = np.zeros((h, w), np.float32)
    # Hue by a, from the ramp's middle up: the full ramp across a ribbon of
    # threads read as a rainbow.
    hues = np.linspace(0.5, 1.0, len(SHEAF_A))
    with mp.get_context("fork").Pool(jobs or min(5, os.cpu_count() or 4)) as pool:
        for hue, part in zip(hues, pool.imap(_sheaf_one, [(a, v, (h, w)) for a in SHEAF_A])):
            D += part
            V += part * np.float32(hue)
    return lines(D, V, rank=False)
