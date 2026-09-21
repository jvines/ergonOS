"""Wing-tip vortex -- the trailing vortex sheet of a wing rolling up into the
two tip vortices, seen in the plane across the wake.

A lifting wing sheds a sheet of streamwise vorticity from its trailing edge,
of strength -dGamma/dx where Gamma(x) is the circulation bound to the wing at
span station x. For the elliptic loading of lifting-line theory,
Gamma = sqrt(1 - x^2), that strength is infinite at the tips. The sheet is
Kelvin-Helmholtz unstable everywhere and cannot stay flat: its edges wind up
into two spirals, each of which becomes a tip vortex, and the pair sinks under
its own induced velocity (the downwash). Looked at in a plane fixed in the air
as the wing passes (the Trefftz plane), the 3-D steady wake is a 2-D unsteady
problem, and time is distance behind the wing.

It is the picture behind the Landau-Hopf versus Ruelle-Takens argument over
how a flow becomes turbulent: a free shear layer is the textbook case of a
flow that never stays laminar, and the rolled-up tip vortex, laid out in
smoke, is the classic photograph of it.

Krasny's vortex-blob method (J. Fluid Mech. 184, 123, 1987). The sheet is a
chain of point vortices, each carrying the circulation of its stretch of
sheet; the singular Biot-Savart kernel 1/r is softened to r/(r^2 + delta^2),
which is what makes the problem well posed at all -- the point-vortex sheet
develops a curvature singularity in finite time (Moore 1979) and then
chaotic, grid-scale noise. delta sets how tightly the spiral may wind. As
the sheet stretches round the spiral, points are inserted to keep it
resolved, by four-point interpolation along the sheet.

What is DRAWN is dye, not vorticity: material lines laid across the wake at
the start, like the smoke in the photographs, carried passively by the
velocity of the sheet and wound into the spirals with it. The sheet itself is
one of them. Colour is the local speed of the air, so each core glows where it
whirls fastest and the far field is cool. Lines are drawn at uniform
brightness per unit length (resampled along their own arc, by Catmull-Rom
interpolation so the tight inner turns stay round), through a Gaussian pen at
the supersampled resolution.

Each core is left as a dark EYE. Inside about delta the kernel turns solid-
body and the innermost turns are unresolved, so the dye scribbled a hook at
every focus. Ink fades out between 1.2 and 0.7 delta from each centre, as in
the photographs, where the core flings the smoke out.

A symmetric pair, centred, read as a face (two ringed eyes over a band), so
no view has both vortices whole and level.
"""

import os

import numpy as np

TITLE = "Wing-tip vortex"
# The fallback; the per-view caption comes from caption(seed).
SUBTITLE = "the wake of a wing rolling up into its tip vortex   (Krasny 1987)"

# Line opacity times line colour, already in 0..1: the renderer takes it as is.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
SOFTEN = 0.0         # the pen is already a band-limited Gaussian
HUE_SMOOTH = 3.0     # one colour across a line's width

# Pen sigma as a fraction of the panel width: 0.8 px at 4K.
PEN = 0.8 / 3840
# Radii, in units of delta, over which ink fades in around each vortex centre.
EYE = (0.7, 1.2)

# loading: 'elliptic' = sqrt(1-x^2); 'flap' adds a nested ellipse of half-span
#   xf carrying a fraction A of the root circulation (a deployed inboard flap),
#   whose edge sheds a second, co-rotating vortex on each side.
# view: (anchor, dx, dy, width), lengths in semi-spans. anchor 'vortex' is the
#   right vortex (circulation-weighted centroid of the right half of the
#   sheet); 'pair' is the point midway between the two.
# dye: (lowest, highest, count) starting heights of the lines of dye, spaced
#   so that none starts exactly on the sheet.
PRESETS = {
    "wake": dict(loading="elliptic", delta=0.05, t=4.0,
                 view=("vortex", -0.35, 0.2, 1.6), dye=(-1.575, 1.275, 58),
                 about="the wake of a wing rolling up into its tip vortex"),
    "flap": dict(loading="flap", xf=0.45, A=0.4, delta=0.05, t=5.0,
                 view=("vortex", -0.05, -0.05, 1.6), dye=(-1.575, 1.275, 58),
                 about="tip and flap vortices rolling up behind a wing"),
}
# Only views chosen on a real desktop are offered. A close-up of one tip
# vortex ("tip": elliptic loading, view (vortex, 0, 0, 0.9), dye -0.30..0.30 x
# 26) read as a bullseye and was pruned.
ORDER = ["flap", "wake"]

DT = 0.01            # RK4 step, as Krasny's
N0 = 400             # sheet points at the start
# Insert a point wherever neighbours are further apart than this. The sheet
# only needs to resolve delta (its velocity is smooth below it); the dye is
# drawn through a spline, so it needs only to resolve its own curvature.
EPS_SHEET = 0.02
EPS_DYE = 0.01


def _loading(p):
    """Initial position x0 and circulation G as functions of a label s in 0..1.

    Labels are spaced uniformly along the curve (x, Gamma(x)), so points
    crowd where Gamma is steep -- the tips, and the flap edge -- which is
    where the sheet's strength is concentrated and where it will wind up.
    """
    xf = -np.cos(np.linspace(0.0, np.pi, 400001))
    g = np.sqrt(np.clip(1 - xf * xf, 0, None))
    if p["loading"] == "flap":
        g = (1 - p["A"]) * g + p["A"] * np.sqrt(np.clip(1 - (xf / p["xf"]) ** 2, 0, None))
    arc = np.concatenate([[0.0], np.cumsum(np.hypot(np.diff(xf), np.diff(g)))])
    arc /= arc[-1]
    return (lambda s: np.interp(s, arc, xf)), (lambda s: np.interp(s, arc, g))


def _kappa(s, G):
    """Circulation of each point: the drop in Gamma across its share of sheet,
    so the total is exactly zero and an inserted point adds none."""
    e = np.concatenate([[s[0]], 0.5 * (s[1:] + s[:-1]), [s[-1]]])
    return G(e[:-1]) - G(e[1:])


def _vel(tx, ty, sx, sy, k, d2, dtype=np.float64):
    """Velocity at targets from blobs at sources, by direct summation."""
    tx, ty = tx.astype(dtype), ty.astype(dtype)
    sx, sy, k = sx.astype(dtype), sy.astype(dtype), k.astype(dtype)
    u, v = np.empty_like(tx), np.empty_like(ty)
    step = max(1, 3_000_000 // max(1, sx.size))
    for i in range(0, tx.size, step):
        dx = tx[i:i + step, None] - sx[None, :]
        dy = ty[i:i + step, None] - sy[None, :]
        f = k / (dx * dx + dy * dy + dtype(d2))
        u[i:i + step] = -np.einsum("ij,ij->i", dy, f)
        v[i:i + step] = np.einsum("ij,ij->i", dx, f)
    return u / (2 * np.pi), v / (2 * np.pi)


def _insert(x, y, eps, s=None):
    """Add a point mid-way along every segment longer than eps: four-point
    (cubic) interpolation, so it lands on the curve as it turns."""
    i = np.nonzero(np.hypot(np.diff(x), np.diff(y)) > eps)[0]
    if i.size == 0:
        return x, y, s
    a, d = np.maximum(i - 1, 0), np.minimum(i + 2, x.size - 1)
    end = (a == i) | (d == i + 1)
    out = []
    for c in (x, y):
        m = (-c[a] + 9 * c[i] + 9 * c[i + 1] - c[d]) / 16
        m[end] = 0.5 * (c[i] + c[i + 1])[end]
        out.append(np.insert(c, i + 1, m))
    if s is not None:
        s = np.insert(s, i + 1, 0.5 * (s[i] + s[i + 1]))
    return out[0], out[1], s


def _sheet(p):
    """Evolve the sheet by RK4; keep the state at every stage for the dye."""
    X0, G = _loading(p)
    s = np.linspace(0.0, 1.0, N0)
    x, y = X0(s), np.zeros(N0)
    d2 = p["delta"] ** 2
    hist = []
    for _ in range(int(round(p["t"] / DT))):
        k = _kappa(s, G)
        u1, v1 = _vel(x, y, x, y, k, d2)
        x2, y2 = x + 0.5 * DT * u1, y + 0.5 * DT * v1
        u2, v2 = _vel(x2, y2, x2, y2, k, d2)
        x3, y3 = x + 0.5 * DT * u2, y + 0.5 * DT * v2
        u3, v3 = _vel(x3, y3, x3, y3, k, d2)
        x4, y4 = x + DT * u3, y + DT * v3
        u4, v4 = _vel(x4, y4, x4, y4, k, d2)
        hist.append((k, (x, y), (x2, y2), (x3, y3), (x4, y4)))
        x = x + DT / 6 * (u1 + 2 * u2 + 2 * u3 + u4)
        y = y + DT / 6 * (v1 + 2 * v2 + 2 * v3 + v4)
        x, y, s = _insert(x, y, EPS_SHEET, s)
    return hist, x, y, _kappa(s, G)


_HIST = None         # the sheet's history, inherited by forked workers


def _advect(args):
    """Carry one line of dye through the sheet's recorded history: the
    sources at each stage are the sheet's own RK4 stages, so the dye moves in
    exactly its velocity field. Single precision: the time goes here."""
    x, y, d2 = args
    f32 = np.float32
    for k, (ax, ay), (bx, by), (ex, ey), (cx, cy) in _HIST:
        u1, v1 = _vel(x, y, ax, ay, k, d2, f32)
        u2, v2 = _vel(x + 0.5 * DT * u1, y + 0.5 * DT * v1, bx, by, k, d2, f32)
        u3, v3 = _vel(x + 0.5 * DT * u2, y + 0.5 * DT * v2, ex, ey, k, d2, f32)
        u4, v4 = _vel(x + DT * u3, y + DT * v3, cx, cy, k, d2, f32)
        x = x + DT / 6 * (u1 + 2 * u2 + 2 * u3 + u4)
        y = y + DT / 6 * (v1 + 2 * v2 + 2 * v3 + v4)
        x, y, _ = _insert(x, y, EPS_DYE)
    return x, y


def _simulate(p, jobs):
    """The sheet, serially, then one line of dye per task across `jobs`."""
    global _HIST
    _HIST, sx, sy, k = _sheet(p)
    # Dye reaches well past the tips, so no line ends inside the frame.
    xs = np.linspace(-2.2, 2.2, 441)
    work = [(xs.copy(), np.full_like(xs, h0), p["delta"] ** 2)
            for h0 in np.linspace(*p["dye"])]
    import multiprocessing as mp
    # Forked AFTER the history exists, so every worker inherits it.
    with mp.get_context("fork").Pool(jobs) as pool:
        lines = pool.map(_advect, work, chunksize=1)
    _HIST = None
    return (sx, sy, k), lines


def _eyes(sx, sy, k, p):
    """Vortex centres: the sheet's ends, and with the flap the points that
    left the wing at -+xf: where -cumsum(kappa), the circulation bound at a
    point, which rises monotonically to the root, crosses Gamma(xf)."""
    i = [0, sx.size - 1]
    if p["loading"] == "flap":
        g = -(np.cumsum(k) - 0.5 * k)
        gf, m = (1 - p["A"]) * np.sqrt(1 - p["xf"] ** 2), np.argmax(g)
        i += [np.searchsorted(g[:m], gf), m + np.searchsorted(-g[m:], -gf)]
    return sx[i], sy[i]


def _deposit(c, q, colour, xs, ys, size, extent, eyes, r, spacing=0.5):
    """Deposit a curve resampled every `spacing` pixels along its own arc, so
    brightness does not record where insertion was busy; Catmull-Rom through
    the points, so a spiral's inner turns are round, not polygons. `colour`
    is a ramp position per point, interpolated along the curve. Ink fades to
    nothing between r[0] and r[1] from each of the `eyes`."""
    w, h = size
    x0, x1, y0, y1 = extent
    s = w / (x1 - x0)                              # pixels per semi-span
    px = (xs - x0) * s - 0.5
    py = (y1 - ys) * s - 0.5                       # up is up: row 0 at the top
    seg = np.hypot(np.diff(px), np.diff(py))
    arc = np.concatenate([[0.0], np.cumsum(seg)])
    t = np.arange(0.0, arc[-1], spacing)
    j = np.clip(np.searchsorted(arc, t, side="right") - 1, 0, px.size - 2)
    u = ((t - arc[j]) / np.maximum(seg[j], 1e-12))[:, None]
    a, d = np.maximum(j - 1, 0), np.minimum(j + 2, px.size - 1)
    P = np.stack([px, py], axis=1)
    p0, p1, p2, p3 = P[a], P[j], P[j + 1], P[d]
    pt = 0.5 * (2 * p1 + (p2 - p0) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u ** 2
                + (3 * p1 - p0 - 3 * p2 + p3) * u ** 3)
    px, py = pt[:, 0], pt[:, 1]
    colour = colour[j] + (colour[j + 1] - colour[j]) * u[:, 0]   # per point
    ink = np.ones_like(px)
    for ex, ey in zip((eyes[0] - x0) * s - 0.5, (y1 - eyes[1]) * s - 0.5):
        e = np.clip((np.hypot(px - ex, py - ey) / s - r[0]) / (r[1] - r[0]), 0, 1)
        ink *= e * e * (3 - 2 * e)
    ix, iy = np.floor(px).astype(np.int64), np.floor(py).astype(np.int64)
    fx, fy = px - ix, py - iy
    for dx, dy, wt in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)),
                       (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
        cx, cy = ix + dx, iy + dy
        m = (cx >= 0) & (cx < w) & (cy >= 0) & (cy < h)
        if m.any():
            idx = cy[m] * w + cx[m]
            c += np.bincount(idx, weights=wt[m] * ink[m], minlength=w * h)
            q += np.bincount(idx, weights=wt[m] * ink[m] * colour[m], minlength=w * h)


def caption(seed):
    """(title, subtitle) from the preset alone, so a re-colour from a saved
    field -- which never calls generate() -- gets the same caption."""
    return TITLE, PRESETS[ORDER[seed % len(ORDER)]]["about"] + "   (Krasny 1987)"


def generate(size, seed=0, jobs=None, cache=None, view=None):
    import lib

    w, h = size
    p = PRESETS[ORDER[seed % len(ORDER)]]

    # The simulation is independent of the panel; `cache` keeps it between
    # renders so that framing and colour can be iterated without re-running.
    if cache and os.path.exists(cache):
        z = np.load(cache)
        sx, sy, k = z["sx"], z["sy"], z["k"]
        cut = np.cumsum(z["n"])[:-1]
        lines = list(zip(np.split(z["lx"], cut), np.split(z["ly"], cut)))
    else:
        (sx, sy, k), lines = _simulate(p, jobs or min(14, os.cpu_count() or 4))
        if cache:
            np.savez(cache, sx=sx, sy=sy, k=k, n=[l[0].size for l in lines],
                     lx=np.concatenate([l[0] for l in lines]),
                     ly=np.concatenate([l[1] for l in lines]))

    right = k > 0
    vx = np.sum(k[right] * sx[right]) / np.sum(k[right])
    vy = np.sum(k[right] * sy[right]) / np.sum(k[right])
    anchor, dx, dy, width = view or p["view"]
    cx, cy = (vx if anchor == "vortex" else 0.0) + dx, vy + dy
    height = width * h / w
    extent = (cx - width / 2, cx + width / 2, cy - height / 2, cy + height / 2)

    # COLOUR IS THE SPEED of the air, by rank over the ramp: the cores at the
    # top, the far field at the bottom. Colour by starting height was tried
    # first: the spiral interleaves every height a pixel or two apart, and
    # the defringing (hue from the neighbourhood) averaged it all to one
    # blue. Speed is smooth, so neighbouring turns share a colour.
    curves = list(lines) + [(sx, sy)]
    px = np.concatenate([cv[0] for cv in curves])
    py = np.concatenate([cv[1] for cv in curves])
    u, v = _vel(px, py, sx, sy, k, p["delta"] ** 2, np.float32)
    speed = np.hypot(u, v)
    rank = np.argsort(np.argsort(speed, kind="stable"), kind="stable") / (speed.size - 1)
    tone = np.split(0.30 + 0.70 * rank, np.cumsum([cv[0].size for cv in curves])[:-1])
    c, q = np.zeros(w * h), np.zeros(w * h)
    eyes, r = _eyes(sx, sy, k, p), (EYE[0] * p["delta"], EYE[1] * p["delta"])
    for (lx, ly), tn in zip(curves, tone):
        _deposit(c, q, tn, lx, ly, size, extent, eyes, r)

    # Pen: a Gaussian; `ink` is 1 at the centre of a single line wherever it
    # falls. Opacity saturates, so a core is flat (HUE_SMOOTH's local mean is
    # the line's own colour) and a pile of lines is solid, not over full.
    sigma = PEN * w
    c = lib.smooth(c.reshape(h, w).astype(np.float32), sigma)
    q = lib.smooth(q.reshape(h, w).astype(np.float32), sigma)
    ink = c * (sigma * np.sqrt(2 * np.pi) / 2.0)
    with np.errstate(divide="ignore", invalid="ignore"):
        hue = np.where(c > 1e-9, q / c, 0.0)
    return ((1.0 - np.exp(-3.0 * ink)) * hue).astype(np.float32)
