"""Kirkwood gaps -- the lanes Jupiter's resonances cut through the asteroid belt.

Kirkwood (1867) noticed that asteroids avoid the semi-major axes where their
period is a simple fraction of Jupiter's: 3:1 at 2.50 AU, 5:2 at 2.82, 7:3 at
2.96, 2:1 at 3.28. There the conjunctions with Jupiter recur at the same few
points of the orbit, the kicks add instead of averaging away, and in the
elliptic problem the motion near each commensurability is chaotic (Wisdom
1982, 1983): the eccentricity wanders up until the perihelion crosses Mars's
orbit, and Mars scatters the asteroid out. That is a gap.

WHAT IS DRAWN. The plane of semi-major axis (across) and eccentricity (up), as
a stability map. Every point is an asteroid in the planar elliptic Sun-Jupiter
problem, followed for 50,000 years, and it is drawn only if it survives:

  * it never crosses Mars's orbit -- perihelion stays outside 1.666 AU, Mars's
    aphelion. This is the belt's curved upper-left edge, and it is also how
    the resonances kill: they pump e until the orbit reaches Mars;
  * it never enters Jupiter's Hill sphere;
  * it stays regular. Chaos is measured by MEGNO (Cincotta & Simo 2000): a
    shadow orbit 1e-8 away is renormalised every Jupiter period and the time-
    weighted log growth averaged, <Y> -> 2 for a quasi-periodic orbit and
    growing linearly for a chaotic one. <Y> > 4 is chaotic here.

So the 3:1, 5:2 and 7:3 come out as dark lanes widening with e, high-order
resonances as hairlines at high e, and the outer belt's overlapping
resonances as a chaotic fringe. The 2:1 comes out as its chaotic separatrix,
a dark V with a lit core: with Jupiter alone that core librates stably (the
Zhongguo and Griqua asteroids live there); emptying it needs Saturn's secular
resonances, which are not in this model. Nor is the nu6 resonance that makes
the real belt's inner edge at 2.1 AU.

COLOUR is the lowest perihelion distance the orbit reached: how close it came
to Mars, teal at the Mars edge to pink at the view's largest perihelion. The
colour bands follow curves of equal perihelion, parallel to the Mars edge,
and bend down beside each resonance where Jupiter has pumped the
eccentricity. Not ranked (equalize): that put the lowest ranks, the orbits
just inside the Mars edge, on the ground colour, and the edge dissolved into
a vignette. Here the edge is drawn at the first colour of the ramp.

Initial angles: perihelion aligned with Jupiter's, Jupiter at perihelion, the
asteroid a quarter turn ahead of it. One starting phase, as stability maps are
usually made: averaging phases gave half-survivors that drew in another
colour. Nothing is random.

INTEGRATOR. Wisdom-Holman in heliocentric coordinates: exact Kepler drift
(Danby's f and g functions, vectorised), kicks from Jupiter with the indirect
term, Jupiter on its fixed ellipse (a = 5.2026 AU, e = 0.0484, mass
1/1047.35), 64 steps per Jupiter period. Orbits that met Jupiter or are
certainly chaotic (<Y> > 50) stop being integrated.

RENDERING. The grid is fixed (1920 across, 96 up) so a 4K and an 8K render
are the same picture. Perihelion and log<Y> are interpolated to each pixel
and the survival thresholds are applied THERE, as signed distances to the
contour divided by the local gradient, so every edge is ~1 px sharp at any
panel size instead of an upscaled blur (as in ising.py). SUPERSAMPLE = 1.
A lost orbit whose eight grid neighbours all survive is drawn as they are
(see _unspeckle): a lone cell is below what the grid resolves.
"""

import os

import numpy as np

TITLE = "Kirkwood gaps"
SUBTITLE = "stability of the asteroid belt under Jupiter"

# 0..1 by construction: the ground is lost orbits, LIT_LO..1 is perihelion.
SCALE = "unit"
GAMMA = 0.75                         # more of the belt past sky-blue
BLEND = 0.85
RAMP = "full"
SATURATION = 1.8
EXPOSURE = 1.0
HUE_SMOOTH = 3.0
SUPERSAMPLE = 1

GM = 4 * np.pi ** 2                  # Sun, AU^3 / yr^2
MU = 1 / 1047.3486                   # Jupiter / Sun
A_J, E_J = 5.2026, 0.0484
N_J = np.sqrt(GM * (1 + MU) / A_J ** 3)
P_J = 2 * np.pi / N_J
R_HILL = A_J * (MU / 3) ** (1 / 3)
Q_MARS = 1.666                       # Mars's aphelion, AU
LAM0 = np.pi / 2                     # start a quarter turn ahead of Jupiter
STEPS = 64                           # per Jupiter period
DELTA = 1e-8                         # shadow-orbit offset, scaled units
Y_CHAOS = 4.0                        # MEGNO above this is chaotic
Y_DROP = 50.0                        # certainly chaotic: stop integrating
CRISP = 1.2 / 2400                   # edge width, panel heights
LIT_LO = 0.2                         # the first ramp colour: an orbit just grazing Mars

# (a0, a1, e0, e1, grid across, grid up, years, what it shows).
VIEWS = [
    (2.1, 3.5, 0.0, 0.32, 1920, 96, 50000.0,
     "2.1-3.5 AU across, eccentricity up: the 3:1, 5:2, 7:3 gaps, the 2:1's chaotic rim"),
    (2.42, 3.08, 0.0, 0.36, 1920, 96, 50000.0,
     "2.42-3.08 AU, eccentricity up: the 3:1, 5:2, 7:3 gaps; hairlines at 11:4, 8:3, 9:4"),
]


def caption(seed):
    return TITLE, ("orbits that last 50,000 yr beside Jupiter, coloured by perihelion; "
                   + VIEWS[seed % len(VIEWS)][7])


def _jupiter(t):
    """Jupiter's heliocentric position on its fixed ellipse, perihelion on +x."""
    m = N_J * t
    e = m
    for _ in range(8):
        e = e - (e - E_J * np.sin(e) - m) / (1 - E_J * np.cos(e))
    return A_J * (np.cos(e) - E_J), A_J * np.sqrt(1 - E_J ** 2) * np.sin(e)


def _kick(x, y, vx, vy, t, h):
    """Jupiter's pull, direct and indirect, in place. Returns distance^2."""
    jx, jy = _jupiter(t)
    dx, dy = x - jx, y - jy
    d2 = dx * dx + dy * dy
    inv3 = 1.0 / (d2 * np.sqrt(d2))
    rj3 = (jx * jx + jy * jy) ** -1.5
    g = GM * MU * h
    vx -= g * (dx * inv3 + jx * rj3)
    vy -= g * (dy * inv3 + jy * rj3)
    return d2


def _drift(x, y, vx, vy, h):
    """Exact Kepler motion about the Sun for a time h, in place. Returns a, e."""
    r0 = np.sqrt(x * x + y * y)
    a = 1 / (2 / r0 - (vx * vx + vy * vy) / GM)
    sa = np.sqrt(GM * a)
    n = sa / (a * a)
    ec = 1 - r0 / a                                   # e cos E0
    es = (x * vx + y * vy) / sa                       # e sin E0
    m = n * h
    de = m / (1 - ec)
    for _ in range(5):                                # Newton, dE
        s, c = np.sin(de), np.cos(de)
        de -= (de - ec * s + es * (1 - c) - m) / (1 - ec * c + es * s)
    s, c = np.sin(de), np.cos(de)
    f = 1 - a / r0 * (1 - c)
    g = h + (s - de) / n
    r = a * (1 - ec * c + es * s)
    fd = -sa * s / (r * r0)
    gd = 1 - a / r * (1 - c)
    nx, ny = f * x + g * vx, f * y + g * vy
    vx[:], vy[:] = fd * x + gd * vx, fd * y + gd * vy
    x[:], y[:] = nx, ny
    return a, np.hypot(ec, es)


def _state(a, e, mean_anom):
    """Elements (perihelion on +x) -> heliocentric position and velocity."""
    E = mean_anom.copy()
    for _ in range(30):
        E = E - (E - e * np.sin(E) - mean_anom) / (1 - e * np.cos(E))
    b = a * np.sqrt(1 - e * e)
    edot = np.sqrt(GM / a ** 3) / (1 - e * np.cos(E))
    return (a * (np.cos(E) - e), b * np.sin(E),
            -a * np.sin(E) * edot, b * np.cos(E) * edot)


def _worker(args):
    """Lowest perihelion and log10 MEGNO for a chunk of starting orbits.

    An orbit that met Jupiter or blew up comes back as q = 0, log<Y> = 4."""
    a0, e0, years = args
    q_out = a0 * (1 - e0)
    y_out = np.full(a0.size, np.log10(2.0))
    # Every orbit is integrated, even one that starts inside Mars's aphelion.
    # Skipping those and storing their starting perihelion put a step the
    # size of the short-period dip between them and their integrated
    # neighbours, and the Mars edge came out with one sawtooth per grid row.
    live = np.arange(a0.size)
    x, y, vx, vy = _state(a0[live], e0[live], np.full(live.size, LAM0))
    sx, sv = a0[live], np.sqrt(GM / a0[live])         # position, velocity scales
    X = np.concatenate([x, x + 0.5 * DELTA * sx]); Y = np.concatenate([y, y + 0.5 * DELTA * sx])
    VX = np.concatenate([vx, vx + 0.5 * DELTA * sv]); VY = np.concatenate([vy, vy - 0.5 * DELTA * sv])
    qmin = q_out[live].copy()
    I = np.zeros(live.size); ysum = np.zeros(live.size)
    h = P_J / STEPS
    t = 0.0
    _kick(X, Y, VX, VY, t, h / 2)
    with np.errstate(all="ignore"):
        for p in range(1, int(round(years / P_J)) + 1):
            m = live.size
            ok = np.ones(m, bool)
            for i in range(STEPS):
                aa, ee = _drift(X, Y, VX, VY, h)
                t += h
                d2 = _kick(X, Y, VX, VY, t, h)
                if i % 4 == 0:
                    qmin = np.minimum(qmin, aa[:m] * (1 - ee[:m]))
                    ok &= (d2[:m] >= R_HILL ** 2) & (aa[:m] > 0) & (ee[:m] < 0.95)
            # MEGNO: log growth of the shadow over this period, time-weighted
            dx = (X[m:] - X[:m]) / sx; dy = (Y[m:] - Y[:m]) / sx
            dvx = (VX[m:] - VX[:m]) / sv; dvy = (VY[m:] - VY[:m]) / sv
            d = np.sqrt(dx * dx + dy * dy + dvx * dvx + dvy * dvy)
            ok &= np.isfinite(d) & (d > 0) & np.isfinite(qmin)
            d = np.where(ok, d, DELTA)
            I += np.log(d / DELTA) * (p - 0.5) * P_J
            ysum += 2 * I / (p * P_J)
            k = DELTA / d
            X[m:] = X[:m] + dx * sx * k; Y[m:] = Y[:m] + dy * sx * k
            VX[m:] = VX[:m] + dvx * sv * k; VY[m:] = VY[:m] + dvy * sv * k
            # A Mars-crosser is lost, but is followed to the end anyway: its
            # lowest perihelion then varies smoothly across the Mars edge and
            # the edge interpolates cleanly between grid rows. Stopping it at
            # the crossing left every one at q = 1.666 and drew the edge as a
            # staircase, one step per row.
            lost = ~ok | (ysum / p > Y_DROP)
            if lost.any():
                q_out[live[lost]] = np.where(ok[lost], qmin[lost], 0.0)
                y_out[live[lost]] = np.where(
                    ok[lost], np.log10(np.maximum(ysum[lost] / p, 1e-3)), 4.0)
                keep = ~lost
                both = np.concatenate([keep, keep])
                X, Y, VX, VY = X[both], Y[both], VX[both], VY[both]
                live, sx, sv = live[keep], sx[keep], sv[keep]
                qmin, I, ysum = qmin[keep], I[keep], ysum[keep]
                if live.size == 0:
                    break
    q_out[live] = qmin
    y_out[live] = np.log10(np.maximum(ysum / p, 1e-3))
    return q_out, y_out


def survey(view, jobs=None):
    """(perihelion, log MEGNO) on the view's grid, row 0 = lowest e."""
    a0, a1, e0, e1, na, ne, years = view[:7]
    ag = a0 + (np.arange(na) + 0.5) / na * (a1 - a0)
    eg = e0 + (np.arange(ne) + 0.5) / ne * (e1 - e0)
    aa, ee = np.meshgrid(ag, eg)
    rows = np.array_split(np.arange(ne), 48)          # fixed split
    work = [(aa[r].ravel(), ee[r].ravel(), years) for r in rows]
    jobs = jobs or min(os.cpu_count() or 4, 12)
    if jobs > 1:
        import multiprocessing as mp
        with mp.Pool(jobs) as pool:
            parts = pool.map(_worker, work, chunksize=1)
    else:
        parts = [_worker(w) for w in work]
    q = np.concatenate([p[0] for p in parts]).reshape(ne, na)
    ly = np.concatenate([p[1] for p in parts]).reshape(ne, na)
    return q, ly


def _sample(g, fy, fx):
    """Bilinear, at fractional grid indices (rows fy, columns fx), clamped."""
    y0 = np.clip(np.floor(fy).astype(int), 0, g.shape[0] - 2)
    x0 = np.clip(np.floor(fx).astype(int), 0, g.shape[1] - 2)
    ty = np.clip(fy - y0, 0, 1)[:, None].astype(np.float32)
    tx = np.clip(fx - x0, 0, 1)[None, :].astype(np.float32)
    g = g.astype(np.float32)
    top = g[y0][:, x0] * (1 - tx) + g[y0][:, x0 + 1] * tx
    bot = g[y0 + 1][:, x0] * (1 - tx) + g[y0 + 1][:, x0 + 1] * tx
    return top * (1 - ty) + bot * ty


def _inside(f, level, width):
    """0..1 step across the contour f = level, `width` pixels wide."""
    gy, gx = np.gradient(f)
    dist = (f - level) / np.maximum(np.hypot(gx, gy), 1e-9)   # signed, in pixels
    return np.clip(0.5 + dist / width, 0.0, 1.0)


def _unspeckle(q, ly):
    """A lone lost orbit whose eight neighbours all survive is drawn as they are.

    At this grid spacing it is a resonance too thin to resolve, or MEGNO
    tipping just over the line; drawn, every one was an isolated scratch
    across the lit belt. Chains of two or more cells -- the hairline
    resonances at high e -- are kept."""
    lost = (q < Q_MARS) | (ly > np.log10(Y_CHAOS))
    pad = np.pad(lost, 1)
    nbr = sum(pad[1 + dy:pad.shape[0] - 1 + dy, 1 + dx:pad.shape[1] - 1 + dx]
              for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dy or dx)
    lone = lost & (nbr == 0)

    def mean8(g):
        p = np.pad(g, 1, mode="edge")
        return sum(p[1 + dy:p.shape[0] - 1 + dy, 1 + dx:p.shape[1] - 1 + dx]
                   for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dy or dx) / 8.0

    return np.where(lone, mean8(q), q), np.where(lone, mean8(ly), ly)


def generate(size, seed=0, jobs=None, grid=None):
    view = VIEWS[seed % len(VIEWS)]
    a0, a1, e0, e1, na, ne = view[:6]
    q, ly = grid if grid is not None else survey(view, jobs=jobs)
    q, ly = _unspeckle(q, ly)
    w, h = size
    fx = (np.arange(w) + 0.5) / w * na - 0.5
    fy = (1 - (np.arange(h) + 0.5) / h) * ne - 0.5    # top row = highest e
    qi = _sample(q, fy, fx)
    alive = _inside(qi, Q_MARS, CRISP * h)
    alive *= _inside(-_sample(ly, fy, fx), -np.log10(Y_CHAOS), CRISP * h)
    tone = np.clip((qi - Q_MARS) / (a1 - Q_MARS), 0.0, 1.0)
    return alive * (LIT_LO + (1 - LIT_LO) * tone)
