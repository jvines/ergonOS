"""Spiral galaxy -- a disc of stars and gas answering a rotating two-armed
density wave: arms that are not made of the same stars for long, but are
where the orbits slow and crowd (Lin & Shu 1964).

The galaxy is a potential with a flat rotation curve,

    Phi_0 = (v0^2 / 2) ln(R^2 + Rc^2)

plus a weak logarithmic spiral turning rigidly at the pattern speed Omega_p,

    Phi_1 = -A(R) cos(2 (phi - Omega_p t) + (2 / tan p) ln R),

p the pitch angle, A a few per cent of the radial force. Inside corotation
the stars go round faster than the pattern and pass through the arms again
and again; they linger in them -- the spiral's pull slows them on the way
in, and their epicycles are phased to bunch them there -- and that crowding
is the arm. Test particles: the pattern is imposed rather than self-
consistent, the standard way to show the mechanism (Contopoulos & Grosbol
1986), and all that numpy can afford.

Three components, integrated in the same potential by leapfrog:

  OLD STARS, an exponential disc with a real disc's velocity dispersion,
  started in epicyclic equilibrium. They answer the wave with broad, smooth
  arms of a few tens of per cent.

  GAS, a colder disc that also COLLIDES: clouds that meet share momentum,
  done by pulling each particle toward the mean velocity of its cell on a
  coarse grid -- a sticky-particle scheme in the spirit of Levinson &
  Roberts (1981) -- plus an isothermal pressure at 9 km/s from the same
  grid. Gas cannot stream through itself as stars do, so where the orbits
  crowd it shocks (Roberts 1969) into a narrow ridge on the inner, concave
  side of each arm. Dust goes with the gas, and that ridge is drawn as the
  DUST LANE, absorbing the starlight behind it.

  YOUNG STARS, born in clusters where the shock has compressed the gas, at
  24 moments over the last 90 Myr, with the observed dN/dM ~ M^-2 cluster
  mass function, then moving ballistically and fading as they age. They
  drift out of the shock before they fade, which puts the bright knotted
  arms just downstream of the dark lanes: the arrangement of every
  grand-design spiral.

Units: kpc, and v0 = 220 km/s, so one time unit is 4.45 Myr. The spiral is
grown over the first 450 Myr, so that the discs meet it adiabatically rather
than being struck by it, and then held for another 450.

RENDERING. Surface brightness: old stars, a round bulge (a Plummer sphere,
drawn analytically: a pressure-supported bulge takes no part in the wave)
and the young stars, dimmed by the dust in front of them, then an asinh
stretch. All of it is a physical surface density, so the picture is the same
at any panel size, and every smoothing length is a fraction of the panel.
"""

import os

import numpy as np

TITLE = "Spiral galaxy"
SUBTITLE = "stars and gas answering a rotating two-armed density wave   (Lin & Shu 1964)"

SCALE = "unit"      # stretched in generate(), on a physical surface brightness
GAMMA = 1.0
BLEND = 0.85
SUPERSAMPLE = 1     # smoothed densities and analytic fields: band-limited

RC = 1.0            # potential core, kpc
HR = 3.0            # old-disc scale length, kpc
HG = 4.5            # gas-disc scale length, kpc
RMAX = 22.0         # discs sampled out to here (past the frame)
RGAS = 17.0         # the gas disc's edge
# The gas thins out inside ~2 kpc (a soft Gaussian hole), as in most early-
# type spirals, where it has gone into stars and the bulge. Given gas there,
# it collected in the middle as a dense dusty knot that hid the nucleus.
GAS_HOLE = 2.0
SIG_R = 0.16        # old-disc radial dispersion at the centre, x v0
SIG_GAS = 0.03      # gas dispersion, x v0
DT = 0.05           # 0.22 Myr
T_GROW, T_END = 100.0, 200.0
TAU = 2.0           # gas collision time, 9 Myr
CS = 0.04           # gas sound speed, x v0: 9 km/s
CELL = 0.12         # gas collision cell, kpc
# Young stars: N_BIRTH star-forming episodes over the last 90 Myr, each
# making CLUSTERS clusters of PER_CLUSTER star particles, only where the gas
# is ARM_SF times its mean at that radius, and not inside SF_HOLE kpc.
N_BIRTH, CLUSTERS, PER_CLUSTER = 24, 2500, 128
ARM_SF = 1.5
SF_HOLE = 3.0
CHUNKS = 16         # old-star chunks: fixed, so the image ignores core count
PER_CHUNK = 3_000_000       # 48 million old stars: the gas is the slow part
HS = 5.0            # old-disc radii drawn from this scale, weighted to HR
N_GAS = 1_000_000
BLOCK = 16384
# Smoothing (see _adaptive): the finest width, as a fraction of the panel
# height, doubled at each level up.
SIGMA0 = 0.0005
# (points to trust, levels) per component. 2000 for the smooth components (2
# per cent): at 300 the grain came through the stretch as sand, worst in the
# dust, where it multiplies the opacity. 40 for young stars, whose clumps are
# real: a young cluster stays a knot and only dispersed ones are smoothed.
# Levels capped (widest 0.4-0.8 per cent of the panel): wider ones blended in
# and out across the faint outer disc and printed as terraced blotches.
N_TRUST = dict(old=(2000.0, 5), gas=(2000.0, 4), young=(40.0, 3))

# Light: bulge central brightness and radius (kpc), young-star weight, dust
# opacity per unit of central gas density, fraction of light in front of the
# dust, the sky level, asinh knee and ceiling. Surface brightness is in units
# of the old disc's face-on central value.
LIGHT = dict(bulge=8.0, rb=0.6, young=1.5, dust=2.5, front=0.25,
             sky=0.012, knee=0.5, top=8.0)

# Chosen on a real desktop in the full ramp; the same galaxy in the warm ramp
# (softer, the dust lanes a darkening rather than a change of hue) was shown
# and passed over.
VIEWS = [
    # Corotation at 9.5 kpc puts the pattern just faster than the peak of
    # Omega - kappa/2, so there is no inner Lindblad resonance: the arms run
    # unbroken from the bulge out, as in M51 and M100. With corotation at
    # 11 kpc the gas piled into a nuclear ring at the ILR instead. Radial
    # force of the wave at its peak: about a tenth of the axisymmetric pull.
    dict(name="grand design", pitch=22.0, amp=0.025, r_cr=9.5,
         incl=35.0, pa=20.0, half=11.0, seed=1),
]


def caption(seed):
    v = VIEWS[seed % len(VIEWS)]
    return TITLE, (f"two-armed density wave, pitch {v['pitch']:.0f} deg, corotation"
                   f" {v['r_cr']:g} kpc: shocked gas, dust lanes, young stars"
                   "   (Lin & Shu 1964)")


def _vc(r):
    return r / np.sqrt(r * r + RC * RC)


def _kappa(r):
    """Epicyclic frequency of the cored log potential."""
    q = r * r + RC * RC
    return np.sqrt((4.0 - 2.0 * r * r / q) / q)


def _force(x, y, t, v):
    """Acceleration at (x, y) at time t, in the arrays' own precision.

    The spiral uses e^(2i phi) = ((x + iy)/R)^2 rather than an arctan: one
    log and one sincos per star per step is its whole transcendental cost."""
    f = x.dtype.type
    r2 = x * x + y * y + f(1e-6)
    f0 = f(-1.0) / (r2 + f(RC * RC))
    fx, fy = f0 * x, f0 * y
    s = min(t / T_GROW, 1.0)
    grow = s * s * (3 - 2 * s)
    if grow == 0:
        return fx, fy
    k = 2.0 / np.tan(np.radians(v["pitch"]))
    om_p = _vc(v["r_cr"]) / v["r_cr"]
    rr = np.sqrt(r2)
    th = f(k) * np.log(rr) - f(2 * om_p * t)
    ct, st = np.cos(th), np.sin(th)
    c2, s2 = (x * x - y * y) / r2, f(2) * x * y / r2
    cchi, schi = c2 * ct - s2 * st, s2 * ct + c2 * st
    # Envelope: rises over the inner 3 kpc, cut off just past corotation --
    # driven beyond it, the outer disc rang in concentric ripples.
    u = (rr / f(3.0)) ** 2
    q = (rr / f(1.1 * v["r_cr"])) ** 6
    a = f(v["amp"] * grow) * u / (1 + u) * np.exp(-q)
    da = a * (f(2) / (rr * (1 + u)) - f(6) * q / rr)
    fr = da * cchi - a * schi * f(k) / rr          # -dPhi1/dR
    fp = -f(2) * a * schi / rr                     # -(1/R) dPhi1/dphi
    cx, sy = x / rr, y / rr
    return fx + fr * cx - fp * sy, fy + fr * sy + fp * cx


def _disc(n, h, sig, rng, rmax=RMAX, hole=0.0, hs=None):
    """n particles of an exponential disc of scale h, in epicyclic equilibrium,
    and the weight of each.

    Guiding radii from the exponential (a gamma(2) in R); radial epicycles of
    Gaussian velocity, dispersion sig exp(-R/2h) as observed; the angular
    momentum set by the guiding radius. Equilibrium to first order, so the
    disc does not ring when released. `hole` empties the middle softly.

    With hs, the radii are DRAWN from a longer exponential of scale hs and
    weighted back to h (importance sampling): the faint outer disc, where the
    picture fades into the desktop, gets several times the particles it
    would, and the crowded middle, which has plenty, gets fewer."""
    hs = hs or h
    rg = rng.gamma(2.0, hs, 2 * n)
    keep = (rg < rmax) & (rng.random(2 * n) > np.exp(-(rg / max(hole, 1e-9)) ** 2))
    rg = rg[keep][:n]
    wgt = (hs / h) ** 2 * np.exp(-rg * (1 / h - 1 / hs))
    sr = sig * np.exp(-rg / (2 * h))
    vr = rng.normal(0, 1, n) * sr
    r = np.abs(rg + rng.normal(0, 1, n) * sr / _kappa(rg))
    phi = rng.uniform(0, 2 * np.pi, n)
    vphi = rg * _vc(rg) / r
    c, s = np.cos(phi), np.sin(phi)
    return np.stack([r * c, r * s, vr * c - vphi * s, vr * s + vphi * c]), wgt


def _kdk(p, t0, t1, v):
    """Leapfrog p = (x, y, vx, vy) in place from t0 to t1."""
    dt = p.dtype.type(DT)
    x, y, vx, vy = p
    ax, ay = _force(x, y, t0, v)
    for i in range(1, int(round((t1 - t0) / DT)) + 1):
        vx += dt / 2 * ax; vy += dt / 2 * ay
        x += dt * vx; y += dt * vy
        ax, ay = _force(x, y, t0 + i * DT, v)
        vx += dt / 2 * ax; vy += dt / 2 * ay


def _stars(args):
    """One chunk of old stars, in cache-sized blocks, single precision."""
    v, j, n = args
    p, wgt = _disc(n, HR, SIG_R, np.random.default_rng(v["seed"] * 1000 + j),
                   hs=HS)
    p = p.astype(np.float32)
    for b in range(0, n, BLOCK):
        _kdk(p[:, b:b + BLOCK], 0.0, T_END, v)
    return p[0], p[1], wgt.astype(np.float32)


def _cic(x, y, n):
    """Cloud-in-cell (index, weight) pairs on an n x n grid of CELL kpc."""
    fx = x / CELL + n / 2 - 0.5
    fy = y / CELL + n / 2 - 0.5
    ix = np.clip(np.floor(fx).astype(np.int64), 0, n - 2)
    iy = np.clip(np.floor(fy).astype(np.int64), 0, n - 2)
    tx, ty = np.clip(fx - ix, 0, 1), np.clip(fy - iy, 0, 1)
    i = iy * n + ix
    return ((i, (1 - tx) * (1 - ty)), (i + 1, tx * (1 - ty)),
            (i + n, (1 - tx) * ty), (i + n + 1, tx * ty))


def _births():
    """Ages at the end (time units) of the star-forming episodes: log-spaced
    from 2 to 90 Myr, finely where the clusters are youngest and brightest."""
    return tuple(np.round(np.geomspace(0.5, 20.0, N_BIRTH) / DT) * DT)


def _clusters(x, y, vx, vy, rho, age, rng):
    """Star clusters born from the gas: CLUSTERS sites per episode, drawn with
    probability ~ rho^0.5 per unit gas (the Schmidt law) where the arm shock
    has compressed it, masses from the
    dN/dM ~ M^-2 cluster mass function, each a little ball of PER_CLUSTER
    stars with a few km/s of internal motion. Returned as (state, light per
    star, age): the light fades as age^-0.7 over this range."""
    # Only in the arms: where the gas is compressed to at least ARM_SF times
    # the mean at its radius. Without the threshold the clusters sprinkled
    # the whole disc evenly and buried the spiral in dots.
    rb = np.minimum((np.hypot(x, y) / 0.25).astype(np.int64), 200)
    mean = np.bincount(rb, rho, 201) / np.maximum(np.bincount(rb, None, 201), 1)
    p = np.where(rho > ARM_SF * mean[rb], np.sqrt(rho), 0.0)
    # None in the bulge's shear either (morphological quenching, Martig et
    # al. 2009): there the gas shows only as dust.
    p *= 1 - np.exp(-(np.hypot(x, y) / SF_HOLE) ** 4)
    site = rng.choice(len(x), CLUSTERS, p=p / p.sum())
    mass = 1.0 / (1.0 - rng.uniform(0, 0.99, CLUSTERS))      # 1..100, M^-2
    k = np.repeat(site, PER_CLUSTER)
    n = len(k)
    q = np.stack([x[k] + rng.normal(0, 0.05, n), y[k] + rng.normal(0, 0.05, n),
                  vx[k] + rng.normal(0, 0.03, n), vy[k] + rng.normal(0, 0.03, n)])
    wgt = np.repeat(mass, PER_CLUSTER) / PER_CLUSTER * age ** -0.7
    return q, wgt, age


def _gas(args):
    """The colliding gas, and the young stars it forms. One process: the
    collisions couple every particle to its neighbours."""
    v, n = args
    rng = np.random.default_rng(v["seed"] * 1000 + 999)
    p, _ = _disc(n, HG, SIG_GAS, rng, RGAS, GAS_HOLE)
    x, y, vx, vy = p
    ng = int(2 * (RGAS + 3) / CELL)
    born = {int(round((T_END - b) / DT)): b for b in _births()}
    young = []
    ax, ay = _force(x, y, 0.0, v)
    for i in range(1, int(round(T_END / DT)) + 1):
        vx += DT / 2 * ax; vy += DT / 2 * ay
        x += DT * vx; y += DT * vy
        ax, ay = _force(x, y, i * DT, v)
        vx += DT / 2 * ax; vy += DT / 2 * ay
        # Collisions, every third step: each particle relaxes toward the
        # mean velocity of the gas around it, on the collision time TAU.
        if i % 3 == 0 or i in born:
            w = _cic(x, y, ng)
            m = sum(np.bincount(k, c, ng * ng) for k, c in w) + 1e-12
            mx = sum(np.bincount(k, c * vx, ng * ng) for k, c in w) / m
            my = sum(np.bincount(k, c * vy, ng * ng) for k, c in w) / m
            g = min(1.0, 3 * DT / TAU)
            vx += g * (sum(c * mx[k] for k, c in w) - vx)
            vy += g * (sum(c * my[k] for k, c in w) - vy)
            # Pressure: isothermal, a = -cs^2 grad ln rho, on the same grid.
            # Without it colliding gas has nothing to stop it collapsing, and
            # it curdled into cell-sized lumps all over the outer disc.
            lr = np.log(m + 0.05 * m[m > 1e-6].mean()).reshape(ng, ng)
            gy, gx = (q.ravel() for q in np.gradient(lr, CELL))
            vx -= 3 * DT * CS * CS * sum(c * gx[k] for k, c in w)
            vy -= 3 * DT * CS * CS * sum(c * gy[k] for k, c in w)
            if i in born:
                young.append(_clusters(x, y, vx, vy, sum(c * m[k] for k, c in w),
                                       born[i], rng))
    out = []
    for q, wgt, age in young:
        for b in range(0, q.shape[1], BLOCK):
            _kdk(q[:, b:b + BLOCK], T_END - age, T_END, v)
        out.append((q[0], q[1], wgt))
    yx, yy, yw = (np.concatenate(c).astype(np.float32) for c in zip(*out))
    return x.astype(np.float32), y.astype(np.float32), yx, yy, yw


def _sky(x, y, v):
    """Tilt the disc by incl about the x axis, then turn by pa on the sky."""
    x, y = np.asarray(x, float), np.asarray(y, float) * np.cos(np.radians(v["incl"]))
    c, s = np.cos(np.radians(v["pa"])), np.sin(np.radians(v["pa"]))
    return c * x - s * y, s * x + c * y


def _deposit(x, y, wt, size, ext, out):
    """lib.deposit with a weight per point: bilinear, into a flat array."""
    w, h = size
    fx = (x - ext[0]) / (ext[1] - ext[0]) * w - 0.5
    fy = (y - ext[2]) / (ext[3] - ext[2]) * h - 0.5
    ix, iy = np.floor(fx).astype(np.int64), np.floor(fy).astype(np.int64)
    tx, ty = fx - ix, fy - iy
    for dx, dy, c in ((0, 0, (1 - tx) * (1 - ty)), (1, 0, tx * (1 - ty)),
                      (0, 1, (1 - tx) * ty), (1, 1, tx * ty)):
        cx, cy = ix + dx, iy + dy
        ok = (cx >= 0) & (cx < w) & (cy >= 0) & (cy < h)
        out += np.bincount(cy[ok] * w + cx[ok], (c * wt)[ok], h * w)


def _adaptive(total, count, h, trust, levels):
    """Smooth `total` with the finest Gaussian that holds `trust` points.

    A cascade, coarse to fine: each finer level is blended in where the level
    above says it would hold enough points to be a density, so dense arms keep
    their detail and the sparse outer disc is smooth rather than grainy."""
    from lib import smooth
    sig = [SIGMA0 * h * 2 ** k for k in range(levels)]
    out, n = smooth(total, sig[-1]), smooth(count, sig[-1])
    for s in sig[-2::-1]:
        held = n * np.float32(4 * np.pi * s * s)
        wgt = held / (held + np.float32(trust))
        out = wgt * smooth(total, s) + (1 - wgt) * out
        n = wgt * smooth(count, s) + (1 - wgt) * n
    return np.clip(out, 0, None)


def fields(size, v, per_chunk=PER_CHUNK, n_gas=N_GAS, jobs=None):
    """Old stars, gas and young light on the panel, per kpc^2, each as a
    fraction of its component's total; and the sky radius of every pixel."""
    import multiprocessing as mp
    w, h = size
    hh = v["half"]
    ext = (-hh * w / h, hh * w / h, -hh, hh)
    pix = (2 * hh / h) ** 2
    with mp.get_context("fork").Pool(jobs or min(CHUNKS + 1, os.cpu_count() or 4)) as pool:
        gas = pool.apply_async(_gas, ((v, n_gas),))
        parts = pool.map(_stars, [(v, j, per_chunk) for j in range(CHUNKS)], chunksize=1)
        gx, gy, yx, yy, yw = gas.get()
    out = {}
    for name, sets in (("old", parts),
                       ("gas", [(gx, gy, None)]), ("young", [(yx, yy, yw)])):
        tot, cnt = np.zeros(w * h), np.zeros(w * h)
        for px, py, wt in sets:
            sx, sy = _sky(px, py, v)
            _deposit(sx, sy, np.ones(len(sx)), size, ext, cnt)
            if wt is not None:
                _deposit(sx, sy, wt.astype(float), size, ext, tot)
        tot = cnt if name == "gas" else tot
        norm = pix * (n_gas if name == "gas" else sum(float(s[2].sum()) for s in sets))
        tot = tot.reshape(h, w)[::-1].astype(np.float32)
        cnt = cnt.reshape(h, w)[::-1].astype(np.float32)
        out[name] = _adaptive(tot, cnt, h, *N_TRUST[name]) / np.float32(norm)
    yy_, xx_ = np.mgrid[0:h, 0:w]
    out["r"] = np.hypot(ext[0] + (xx_ + 0.5) * (2 * hh * w / h) / w,
                        ext[3] - (yy_ + 0.5) * (2 * hh) / h).astype(np.float32)
    return out


def light(fl, L=LIGHT):
    """Surface brightness, in units of the old disc's central value, stretched."""
    s0 = 1.0 / (2 * np.pi * HR * HR)
    g0 = 1.0 / (2 * np.pi * HG * HG)
    stars = (fl["old"] / s0 + L["bulge"] / (1 + (fl["r"] / L["rb"]) ** 2) ** 2
             + L["young"] * fl["young"] / s0)
    tau = L["dust"] * fl["gas"] / g0
    sb = stars * (L["front"] + (1 - L["front"]) * np.exp(-tau))
    # The sky level: what is much fainter than this is not shown, so the
    # disc fades into the desktop inside the frame instead of flooding it.
    # Rolled off smoothly: a hard cut drew the noise at that level as a
    # ragged, blotchy rim.
    x = (sb / L["sky"]) ** 2
    sb = sb * (x / (1 + x))
    f = np.arcsinh(sb / L["knee"]) / np.arcsinh(L["top"] / L["knee"])
    return np.clip(f, 0, 1).astype(np.float64)


def generate(size, seed=0, **kw):
    return dither(light(fields(size, VIEWS[seed % len(VIEWS)], **kw)))


def dither(f):
    """Dither the field by one step of the renderer's colour table.

    lib.render looks colours up in a 512-entry table, and across the broad,
    faint outer disc one entry is two or three 8-bit levels once blended and
    saturated: the dither lib applies after that (one level) cannot hide it,
    and the disc printed as terraced contours. Noise of one table step,
    before the lookup, spreads each step into its neighbours. Pinned, and
    zero stays zero (the ground)."""
    d = (np.random.default_rng(0).random(f.shape) - 0.5) * (2.0 / 512)
    return np.where(f > 0, np.clip(f + d, 1e-6, 1.0), 0.0)
