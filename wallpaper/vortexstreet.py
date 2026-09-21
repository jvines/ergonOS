"""Von Karman vortex street -- the wake of a cylinder in a steady stream,
shed alternately from either side, drawn as smoke.

Above a Reynolds number Re = U D / nu of about 47 the twin eddies behind a
cylinder stop being steady (a Hopf bifurcation of the wake), and the shear
layers leaving its two sides roll up in turn: a clockwise vortex from the top,
then an anticlockwise one from the bottom, half a period later. They drift
downstream in two staggered rows. Von Karman (1911) showed that of all the
arrangements of two rows of point vortices, only the staggered one with the
rows about 0.28 of a spacing apart is even neutrally stable -- which is why it
is the one seen behind chimneys, telegraph wires and islands (the cloud
streets downwind of Guadalupe, or of Alejandro Selkirk in the Juan Fernandez
archipelago, are the same flow at a Reynolds number millions of times
higher). The street drawn here is a young one, and narrower: its vortices are
4.7 D apart and its rows about 0.13 of that apart behind the cylinder,
widening to 0.23 twenty diameters on as the cores spread -- usual for a near
wake at this Reynolds number; von Karman's figure is for point vortices.
The shedding frequency obeys a Strouhal number f D / U ~ 0.18 over this range
(here about 0.19: cores drifting at 0.9 U, 4.7 D apart), the note an Aeolian
harp sings at.

The flow is computed with the lattice Boltzmann method (D2Q9, BGK collision):
populations of fictitious particles hop between the nodes of a square lattice
and relax toward a local Maxwellian, which recovers the incompressible
Navier-Stokes equations at low Mach number. It is the natural numpy solver for
this problem, because the cylinder is just a set of nodes where populations
bounce back, and everything else is a shift and a local update. Inflow is a
Zou-He velocity boundary, outflow a zero-gradient copy, top and bottom are
periodic six diameters from the axis. Re = 150: still two-dimensional and
periodic in reality (the wake goes three-dimensional near 190).

WHAT IS DRAWN is smoke, as in the photographs in Van Dyke's Album of Fluid
Motion: streaklines, the curves traced by marker released continuously from a
rake of fixed points upstream. Each is a chain of particles advected by the
computed velocity; points are inserted wherever the chain stretches, so the
curve stays resolved as it is wound into a vortex. Lines released near the
axis creep round the cylinder in its boundary layer and are rolled up into
the vortices; those further out are only rocked by the passing street. Colour
is the local vorticity: one sense of rotation to one end of the ramp, the other
to the other, irrotational stream in between. The cylinder is drawn as its
outline, and smoke in the nearly dead water at its base fades out (see
generate).
"""

import os

import numpy as np

TITLE = "Von Karman vortex street"
# The fallback; the per-view caption comes from caption(seed).
SUBTITLE = "smoke in the wake of a cylinder, vortices shed from alternate sides   Re = 150"

# Line opacity times line colour, already in 0..1: the renderer takes it as is.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
SOFTEN = 0.0         # the pen is already a band-limited Gaussian
HUE_SMOOTH = 3.0     # one colour across a line's width

# Pen sigma as a fraction of the panel height: 0.8 px at 2400. And how hard
# the pen saturates: opacity is 1 - exp(-INK ink), ink 1 at a line's centre.
# Flat-topped on purpose. HUE_SMOOTH colours a pixel by the value-weighted
# mean of its neighbourhood, so a line's soft shoulders pull its colour down
# the ramp: with the gentler 3 a line meant to be pink came out 0.77 of the
# way up (violet). At 8 it is 0.88 there, for the same 3.3 px apparent width.
PEN = 0.8 / 2400
INK = 8.0

# The lattice. D cells to a diameter: the boundary layer at Re 150 is about
# D / sqrt(Re) = 2.4 cells thick. U in lattice units (Mach 0.13).
D = 30
U = 0.075
# Domain in diameters, cylinder at the origin: inlet, outlet, half-height.
BOX = (-6.0, 26.0, 6.0)
# Lattice steps between particle moves, and between releases at the rake. The
# flow changes over hundreds of steps and a core turns 0.1 rad in twelve.
MOVE = 12
EMIT = 12
# Insert a point where neighbours on a streakline are this far apart (cells).
EPS = 0.7
# Smoke fades out where the fluid is slower than these fractions of U, within
# BASE diameters of the cylinder's centre (see generate).
SLOW = (0.15, 0.5)
BASE = (1.0, 1.3)

# The flow, shared by every view. re; spin: steps before the smoke is turned
# on (the wake needs a few periods to settle into the street); run: steps of
# smoke after that; rake: heights of the release points in diameters, all at
# x = RAKE_X -- close together where they will pass through the boundary
# layer and be rolled into the vortices, 0.3 apart outside it. There is no
# random number anywhere: the lattice run is deterministic.
RAKE_X = -2.5
FLOW = dict(re=150, spin=12000, run=13200,
            rake=np.concatenate([np.linspace(-0.62, 0.62, 16) + 0.013,
                                 np.linspace(0.9, 5.7, 17), -np.linspace(0.9, 5.7, 17)]))
# The views: (x-centre, y-centre, width) in diameters, and what they show. The
# small vertical offsets are for the caption: the far-field smoke lines are
# nearly horizontal, and on a 16:10 panel these put one in the gap between
# title and subtitle instead of through the words. No offset fits
# "downstream", whose lines there still ripple too much.
PRESETS = {
    "street": dict(view=(7.0, -0.10, 17.0),
                   about="smoke in the wake of a cylinder, vortices shed from alternate sides"),
    "near": dict(view=(4.6, -0.06, 12.0),
                 about="smoke rolling up behind a cylinder, one vortex from each side in turn"),
    "downstream": dict(view=(9.0, 0.0, 12.0),
                       about="two staggered rows of vortices drifting downstream of a cylinder"),
}
# Offered on the desktop: the view chosen there. "street" and "downstream"
# were shown and pruned (their presets stay above).
ORDER = ["near"]

C = np.array([[0, 0], [1, 0], [0, 1], [-1, 0], [0, -1],
              [1, 1], [-1, 1], [-1, -1], [1, -1]])
W = np.array([4 / 9] + [1 / 9] * 4 + [1 / 36] * 4, dtype=np.float32)
OPP = np.array([0, 3, 4, 1, 2, 7, 8, 5, 6])


def _feq(rho, ux, uy, out):
    usq = 1.5 * (ux * ux + uy * uy)
    for i in range(9):
        cu = 3.0 * (C[i, 0] * ux + C[i, 1] * uy)
        out[i] = W[i] * rho * (1.0 + cu + 0.5 * cu * cu - usq)
    return out


def _interp(a, x, y):
    """Bilinear sample of lattice field a at (x, y), in cell units."""
    ny, nx = a.shape
    x = np.clip(x, 0.0, nx - 1.001)
    y = np.clip(y, 0.0, ny - 1.001)
    i, j = x.astype(np.int64), y.astype(np.int64)
    fx, fy = x - i, y - j
    return ((a[j, i] * (1 - fx) + a[j, i + 1] * fx) * (1 - fy)
            + (a[j + 1, i] * (1 - fx) + a[j + 1, i + 1] * fx) * fy)


def _interp_grid(a, x, y):
    """Bilinear sample of lattice field a on the grid x (columns) by y (rows),
    in cell units. Separable, so a supersampled panel costs one row of the
    lattice per output row instead of four gathers per pixel."""
    ny, nx = a.shape
    x = np.clip(x, 0.0, nx - 1.001)
    y = np.clip(y, 0.0, ny - 1.001)
    i, j = x.astype(np.int64), y.astype(np.int64)
    fx, fy = (x - i).astype(np.float32), (y - j).astype(np.float32)[:, None]
    rows = a[:, i] * (1 - fx) + a[:, i + 1] * fx
    return rows[j] * (1 - fy) + rows[j + 1] * fy


def _insert(x, y, eps):
    """Add a point mid-way along every segment longer than eps: four-point
    (cubic) interpolation, so it lands on the curve as it turns."""
    i = np.nonzero(np.hypot(np.diff(x), np.diff(y)) > eps)[0]
    if i.size == 0:
        return x, y
    a, d = np.maximum(i - 1, 0), np.minimum(i + 2, x.size - 1)
    end = (a == i) | (d == i + 1)
    out = []
    for c in (x, y):
        m = (-c[a] + 9 * c[i] + 9 * c[i + 1] - c[d]) / 16
        m[end] = 0.5 * (c[i] + c[i + 1])[end]
        out.append(np.insert(c, i + 1, m))
    return out[0], out[1]


def _simulate(p, log=None):
    """Run the lattice to a developed street, then release smoke. Returns the
    streaklines (in diameters, cylinder at the origin), the final vorticity
    and speed on the lattice, and the lattice position of the centre."""
    nx, ny = int((BOX[1] - BOX[0]) * D), int(2 * BOX[2] * D)
    nu = U * D / p["re"]
    om = np.float32(1.0 / (3.0 * nu + 0.5))
    # Centre a third of a cell off the lattice's mid-line, so the discrete
    # cylinder is not mirror-symmetric and the wake has a side to fall to.
    cx, cy = -BOX[0] * D, ny / 2 + 0.3
    yy, xx = np.mgrid[0:ny, 0:nx]
    solid = (xx - cx) ** 2 + (yy - cy) ** 2 < (D / 2) ** 2
    sidx = np.flatnonzero(solid)

    # Start from uniform flow with a transverse nudge in the near wake, so the
    # shedding starts in a couple of periods rather than waiting on rounding.
    ux = np.full((ny, nx), U, np.float32)
    uy = (0.3 * U * np.exp(-((xx - cx - D) ** 2 + (yy - cy) ** 2) / D ** 2)
          ).astype(np.float32)
    ux[solid] = uy[solid] = 0
    f = _feq(np.ones((ny, nx), np.float32), ux, uy, np.empty((9, ny, nx), np.float32))
    fo = np.empty_like(f)
    ff, ffo = f.reshape(9, -1), fo.reshape(9, -1)
    del xx, yy

    src_y = cy + np.asarray(p["rake"]) * D
    src_x = cx + RAKE_X * D
    lines = [(np.array([src_x]), np.array([sy])) for sy in src_y]
    # Smoke is kept only as far as the view needs it, and short of the outlet.
    vx, _, vw = p["view"]
    xcut = min(nx - 2.5 * D, cx + (vx + vw / 2 + 1.5) * D)
    total = p["spin"] + p["run"]
    for t in range(total):
        f[[3, 6, 7], :, -1] = f[[3, 6, 7], :, -2]
        rho = f.sum(0)
        ux = (f[1] + f[5] + f[8] - f[3] - f[6] - f[7]) / rho
        uy = (f[2] + f[5] + f[6] - f[4] - f[7] - f[8]) / rho
        ux[:, 0], uy[:, 0] = U, 0.0
        rho[:, 0] = (f[0, :, 0] + f[2, :, 0] + f[4, :, 0]
                     + 2 * (f[3, :, 0] + f[6, :, 0] + f[7, :, 0])) / (1 - U)
        _feq(rho, ux, uy, fo)
        f[[1, 5, 8], :, 0] = fo[[1, 5, 8], :, 0] + f[[3, 7, 6], :, 0] - fo[[3, 7, 6], :, 0]
        fo -= f
        fo *= om
        fo += f
        ffo[:, sidx] = ff[OPP[:, None], sidx[None, :]]
        for i in range(9):
            f[i] = np.roll(fo[i], (C[i, 1], C[i, 0]), axis=(0, 1))
        if t % 2000 == 0:
            if not np.isfinite(rho).all():
                raise FloatingPointError(f"lattice went unstable at step {t}")
            if log:
                log(f"step {t}/{total}  points {sum(l[0].size for l in lines)}")

        if t < p["spin"] or t % MOVE:
            continue
        # Smoke: move every chain by midpoint RK2 through this instant's
        # velocity, which changes over hundreds of steps, not MOVE.
        ux.flat[sidx] = 0.0
        uy.flat[sidx] = 0.0
        n = [lx.size for lx, _ in lines]
        x = np.concatenate([lx for lx, _ in lines])
        y = np.concatenate([ly for _, ly in lines])
        xm = x + 0.5 * MOVE * _interp(ux, x, y)
        ym = y + 0.5 * MOVE * _interp(uy, x, y)
        x = x + MOVE * _interp(ux, xm, ym)
        y = y + MOVE * _interp(uy, xm, ym)
        # Anything the step carried into the cylinder goes back to its skin.
        r = np.hypot(x - cx, y - cy)
        inside = r < D / 2 + 0.3
        k = (D / 2 + 0.3) / np.maximum(r[inside], 1e-6)
        x[inside] = cx + (x[inside] - cx) * k
        y[inside] = cy + (y[inside] - cy) * k
        emit = (t - p["spin"]) % EMIT == 0
        cut = np.cumsum(n)[:-1]
        lines = []
        for lx, ly, sy in zip(np.split(x, cut), np.split(y, cut), src_y):
            # Newest first: drop the oldest end once it nears the outlet.
            gone = np.nonzero(lx > xcut)[0]
            if gone.size:
                lx, ly = lx[:gone[0]], ly[:gone[0]]
            if emit:
                lx, ly = np.concatenate([[src_x], lx]), np.concatenate([[sy], ly])
            lines.append(_insert(lx, ly, EPS))
    ux.flat[sidx] = 0.0
    uy.flat[sidx] = 0.0
    wz = (np.gradient(uy, axis=1) - np.gradient(ux, axis=0)) * (D / U)
    # Vorticity (units of U / D) and speed (units of U), stacked.
    wz = np.stack([wz, np.hypot(ux, uy) / U])
    lines = [((lx - cx) / D, (ly - cy) / D) for lx, ly in lines]
    return lines, wz.astype(np.float32), (cx, cy)


def _curve(c, q, xs, ys, tone, size, extent, spacing=0.5):
    """Deposit a curve resampled every `spacing` pixels along its own arc, so
    brightness does not record where insertion was busy; Catmull-Rom through
    the points, so a spiral's inner turns are round, not polygons."""
    w, h = size
    x0, x1, y0, y1 = extent
    s = h / (y1 - y0)
    px = (xs - x0) * s - 0.5
    py = (y1 - ys) * s - 0.5                        # up is up: row 0 at the top
    seg = np.hypot(np.diff(px), np.diff(py))
    arc = np.concatenate([[0.0], np.cumsum(seg)])
    if arc[-1] <= spacing:
        return
    t = np.arange(0.0, arc[-1], spacing)
    j = np.clip(np.searchsorted(arc, t, side="right") - 1, 0, px.size - 2)
    u = ((t - arc[j]) / np.maximum(seg[j], 1e-12))[:, None]
    a, d = np.maximum(j - 1, 0), np.minimum(j + 2, px.size - 1)
    P = np.stack([px, py], axis=1)
    p0, p1, p2, p3 = P[a], P[j], P[j + 1], P[d]
    pt = 0.5 * (2 * p1 + (p2 - p0) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u ** 2
                + (3 * p1 - p0 - 3 * p2 + p3) * u ** 3)
    px, py = pt[:, 0], pt[:, 1]
    tn = tone[j] + (tone[j + 1] - tone[j]) * u[:, 0]
    keep = (px > -8) & (px < w + 8) & (py > -8) & (py < h + 8)
    px, py, tn = px[keep], py[keep], tn[keep]
    ix, iy = np.floor(px).astype(np.int64), np.floor(py).astype(np.int64)
    fx, fy = px - ix, py - iy
    for dx, dy, wt in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)),
                       (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
        cx, cy = ix + dx, iy + dy
        m = (cx >= 0) & (cx < w) & (cy >= 0) & (cy < h)
        if m.any():
            idx = cy[m] * w + cx[m]
            c += np.bincount(idx, weights=wt[m], minlength=w * h)
            q += np.bincount(idx, weights=wt[m] * tn[m], minlength=w * h)


def caption(seed):
    """(title, subtitle) from the preset alone, so a re-colour from a saved
    field -- which never calls generate() -- gets the same caption."""
    return TITLE, PRESETS[ORDER[seed % len(ORDER)]]["about"] + f"   Re = {FLOW['re']}"


def generate(size, seed=0, cache=None, view=None, log=None):
    import lib

    w, h = size
    p = dict(FLOW, **PRESETS[ORDER[seed % len(ORDER)]])
    # The flow is independent of the panel; `cache` keeps it between renders
    # so that framing and colour can be iterated without re-running it.
    if cache and os.path.exists(cache):
        z = np.load(cache)
        cut = np.cumsum(z["n"])[:-1]
        lines = list(zip(np.split(z["lx"], cut), np.split(z["ly"], cut)))
        wz, (cx, cy) = z["wz"], z["cen"]
    else:
        lines, wz, (cx, cy) = _simulate(p, log)
        if cache:
            np.savez(cache, n=[l[0].size for l in lines], wz=wz, cen=[cx, cy],
                     lx=np.concatenate([l[0] for l in lines]),
                     ly=np.concatenate([l[1] for l in lines]))

    vx, vy, width = view or p["view"]
    height = width * h / w
    extent = (vx - width / 2, vx + width / 2, vy - height / 2, vy + height / 2)

    sigma = PEN * h

    def pen(c, q):
        """Opacity and tone of what was deposited: 1 - exp(-INK ink), with ink
        1 at the centre of a lone line; tone the ink-weighted mean."""
        c = lib.smooth(c.reshape(h, w).astype(np.float32), sigma)
        q = lib.smooth(q.reshape(h, w).astype(np.float32), sigma)
        with np.errstate(divide="ignore", invalid="ignore"):
            tone = np.where(c > 1e-9, q / c, 0.0).astype(np.float32)
        return 1.0 - np.exp(-INK * c * (sigma * np.sqrt(2 * np.pi) / 2.0)), tone

    c, q = np.zeros(w * h), np.zeros(w * h)
    for lx, ly in lines:
        # COLOUR IS THE VORTICITY where the smoke is, in units of U / D: the
        # clockwise row warm, the anticlockwise row cool, the irrotational
        # stream between them in the middle of the ramp.
        om = _interp(wz[0], lx * D + cx, ly * D + cy)
        _curve(c, q, lx, ly, 0.6 - 0.4 * np.tanh(om / 2.0), size, extent)
    alpha, tone = pen(c, q)
    del c, q

    # Smoke in the nearly dead water at the base fades out. The reversed flow
    # there presses marker that never diffuses into a stack of twenty-odd
    # folds; in the photographs that dye has long since spread into a haze.
    # The fade multiplies the COMPOSITED opacity, by a smooth function of the
    # speed at each pixel: fading each line's ink instead left the stack
    # opaque until every fold was nearly gone, a knife-cut edge. Only inside
    # BASE, where the dead water is: further out, slow water is a saddle or a
    # slowly drifting core that smoke merely passes, and fading it cut notches
    # out of the shear layers. (Fading slides down the ramp, so the haze is
    # tinted toward the ramp's cool end.)
    xs = extent[0] + (np.arange(w) + 0.5) * (width / w)
    ys = extent[3] - (np.arange(h) + 0.5) * (height / h)
    e = np.clip((_interp_grid(wz[1], xs * D + cx, ys * D + cy) - SLOW[0])
                / (SLOW[1] - SLOW[0]), 0.0, 1.0)
    k = np.clip((np.hypot(xs[None, :], ys[:, None]) - BASE[0]) / (BASE[1] - BASE[0]), 0.0, 1.0)
    alpha *= 1.0 - (1.0 - e * e * (3 - 2 * e)) * (1.0 - k * k * (3 - 2 * k))
    del e, k

    # The cylinder, as its outline, laid over the smoke: the smoke alone
    # leaves it a hole, and its skin is the slowest water of all.
    th = np.linspace(0.0, 2 * np.pi, 1441)
    c, q = np.zeros(w * h), np.zeros(w * h)
    _curve(c, q, 0.5 * np.cos(th), 0.5 * np.sin(th), np.full(th.size, 0.6), size, extent)
    ring, _ = pen(c, q)
    return (alpha * tone + ring * (1.0 - alpha) * 0.6).astype(np.float32)
