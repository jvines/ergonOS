"""Galaxy collision -- two disc galaxies torn by one close prograde passage,
in the restricted N-body picture of Toomre & Toomre (1972).

Each galaxy is a massive core, a Plummer-softened point mass, carrying a cold
disc of massless test stars on circular orbits. The two cores fall past each
other on a parabolic orbit; every star feels both cores and nothing else. That
is the whole model, and it is the one the Toomres used to show that the long
"antennae" and "tails" hanging off peculiar galaxies are not magnetic
filaments or ejecta but tides: stars on the far side of each disc are pulled
less than its centre and left behind as a tail, stars on the near side are
pulled more and drawn out into a bridge toward the other galaxy.

The passage has to be PROGRADE -- each disc spinning the same way as the
orbit -- for the tails to be long and thin. Then a star on the outer edge
moves with the passing companion for a while instead of against it, the
perturbation is close to resonant, and the disc's outer third is flung out in
a coherent sheet. A retrograde passage barely ruffles the disc. Each disc may
also be tilted to the orbit plane, and the tilt decides whether the tails lie
flat or curl out of it, which is most of the difference between the famous
systems.

Units: G = 1, the two masses sum to 1, the pericentre distance is 1; at
closest approach the pair swings round each other by a radian and a half per
time unit. The discs reach out to 0.55-0.7 of the pericentre distance, which
is what makes the encounter close. Stars fill each disc with equal numbers
per unit radius -- the surface density falls as 1/r, as in the Toomres'
rings -- so the outer disc, which is what becomes the tails, is sampled as
well as the inner, and the centre is a bright cusp. Random motions fall
from 12 per cent of the circular speed at the centre to half a per cent at
the edge (see SIGMA_V).

Integrated with a fixed-step kick-drift-kick leapfrog. Leapfrog because it is
symplectic: over thousands of steps it does not let a cold disc spiral in or
out numerically, which would be very visible. The cores' orbit does not
depend on the stars, so it is integrated once and the stars follow it in
cache-sized blocks. The cores start about five pericentre distances apart,
where the tidal pull on a disc is a few thousandths of its own gravity, placed
there by running the parabolic orbit backwards from pericentre with the same
integrator (leapfrog is time-reversible).

RENDERING. The picture is the stars' surface density on the sky, at one
instant, from a chosen viewing direction. 32 million stars, split into a
fixed number of chunks with their own seeds so the image does not depend on
how many cores rendered it, deposited with bilinear weights, then smoothed
ADAPTIVELY: a cascade of Gaussians, each twice the width of the last, where a
finer one takes over only where it holds enough stars to be a density rather
than a scatter of points. Every width is a fraction of the panel height. Then
an asinh stretch on the physical surface density (see stretch()).
"""

import os

import numpy as np

TITLE = "Galaxy collision"
SUBTITLE = "two disc galaxies after a prograde parabolic passage   (Toomre & Toomre 1972)"

# The stretch is done in generate(), on a physical surface density, so the
# renderer takes the field as it is.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
# A smoothed point density is already band-limited: supersampling would only
# multiply the deposit and the smoothing.
SUPERSAMPLE = 1

EPS = 0.1                   # core softening, pericentre units
R_OUT = 0.70                # disc radius, pericentre units
# Random motion as a fraction of the circular speed: hot in the middle and
# cold at the edge, as in real discs, where the dispersion falls off
# exponentially with radius. The cold edge is what becomes crisp tails; the
# hot middle is what keeps the inner disc from phase-mixing into a
# record-groove of fine rings, which a fully cold one does.
SIGMA_V = (0.12, 0.005)     # centre, edge
DT = 0.005
T0 = -6.0                   # start, before pericentre
CHUNKS = 16                 # fixed: the picture must not depend on core count
PER_CHUNK = 2_000_000       # stars per chunk: 32 million in all
BLOCK = 8192                # stars integrated together: fits in cache
# Finest smoothing width, fraction of panel height; LEVELS doublings above it.
SIGMA0 = 0.0005
LEVELS = 5
# Stars a kernel must hold before it is trusted as a density: shot noise
# 1/sqrt(300), 6 per cent, and the next level up holds four times more.
N_TRUST = 300.0
# asinh knee and ceiling, in units of one disc's mean surface density.
KNEE = 0.02
TOP = 12.0
FLOOR = 0.002               # fraction of all stars per unit area

# Each view: mass ratio M2/M1, the two discs' tilts to the orbit plane
# (i, w in degrees: tipped by i about an axis in the orbit plane at w from
# the pericentre direction), the time after pericentre, the viewing direction
# (theta from the orbit's pole, phi around it; the picture is then turned so
# the two nuclei lie level, plus `tilt`), the frame (centre and half-height
# on the sky, pericentre units) and the random seed of the stars -- part of
# the picture, so pinned here.
VIEWS = [
    # Both discs tipped 60 degrees, seen almost in the orbit plane: each
    # galaxy's bridge has swung round behind the other and the two join in
    # one loop of stars, with the tails leaving the frame left and right.
    dict(name="loop", q=1.0, discs=((60, -30), (60, -30)), t=7.0,
         view=(80, 0), tilt=0.0, frame=(0.0, 0.0, 3.06), seed=1),
    # Only "loop" was chosen on a real desktop. "pair" -- smaller discs
    # (r_out 0.55) tipped 20 and 70 degrees, t 5.0, seen from 30 degrees off
    # the orbit's pole and turned 14 degrees, seed 1 -- was shown and pruned.
]


def caption(seed):
    v = VIEWS[seed % len(VIEWS)]
    # Time in turns of the outer disc, which is what the tails are made of:
    # more telling than code units, and it is what sets how far they have run.
    r = v.get("r_out", R_OUT)
    turns = v["t"] / (2 * np.pi * np.sqrt(r ** 3 * (1 + v["q"])))
    tilt = " and ".join(str(d[0]) for d in v["discs"])
    pair = "two equal discs" if v["q"] == 1 else f"discs of mass ratio {v['q']:.2g}"
    return TITLE, (f"{pair} tilted {tilt} deg, {turns:.1f} turns after a prograde"
                   " parabolic passage   (Toomre & Toomre 1972)")


def _core_acc(pos, m):
    d = pos[1] - pos[0]
    r2 = d @ d + EPS * EPS
    f = d / (r2 * np.sqrt(r2))
    return np.array([m[1] * f, -m[0] * f])


def _track(q, t_end):
    """The cores' positions at every step from T0 to t_end.

    At pericentre (t = 0) the separation is 1 along x and the relative
    velocity is the zero-energy one for the SOFTENED potential, along +y, so
    the orbit's pole is +z. Stepped back to T0, then forward to t_end."""
    m = np.array([1.0 / (1 + q), q / (1 + q)])
    vp = np.sqrt(2.0 / np.sqrt(1 + EPS * EPS))
    pos = np.array([[-m[1], 0, 0], [m[0], 0, 0]], dtype=float)
    vel = np.array([[0, -m[1] * vp, 0], [0, m[0] * vp, 0]], dtype=float)
    a = _core_acc(pos, m)
    for _ in range(int(round(-T0 / DT))):
        vel -= 0.5 * DT * a
        pos -= DT * vel
        a = _core_acc(pos, m)
        vel -= 0.5 * DT * a
    p0, v0 = pos.copy(), vel.copy()
    n = int(round((t_end - T0) / DT))
    tr = np.empty((n + 1, 2, 3))
    tr[0] = pos
    a = _core_acc(pos, m)
    for s in range(n):
        vel += 0.5 * DT * a
        pos += DT * vel
        a = _core_acc(pos, m)
        vel += 0.5 * DT * a
        tr[s + 1] = pos
    return tr, p0, v0, m


def _discs(v, n, rng, pos, vel, m):
    """n disc stars (x, y, z, vx, vy, vz), split between the galaxies by mass.

    The companion's disc is scaled by sqrt(mass ratio): the size a disc of the
    same central surface density would have."""
    out = []
    counts = [int(round(n * m[0])), n - int(round(n * m[0]))]
    for k, ((inc, w), nk) in enumerate(zip(v["discs"], counts)):
        i, w = np.radians(inc), np.radians(w)
        # Spin axis: the orbit's pole tipped by i about an in-plane axis at w.
        nrm = np.array([np.sin(i) * np.sin(w), -np.sin(i) * np.cos(w), np.cos(i)])
        # Any in-plane basis will do: the stars' phases are uniform.
        u = np.cross([0.0, 0.0, 1.0], nrm)
        u = u / np.linalg.norm(u) if u @ u > 1e-12 else np.array([1.0, 0, 0])
        e2 = np.cross(nrm, u)
        rd = np.sqrt(m[k] / m[0]) * v.get("r_out", R_OUT)
        r = rng.uniform(0, rd, nk)
        ph = rng.uniform(0, 2 * np.pi, nk)
        # Two per cent of its radius thick, so an edge-on disc is a blade.
        z = rng.normal(0, 0.02, nk) * r
        vc = np.sqrt(m[k] * r * r / (r * r + EPS * EPS) ** 1.5)
        sv = SIGMA_V[0] * np.exp(-4 * r / rd) + SIGMA_V[1]
        dv = rng.normal(0, 1, (3, nk)) * sv * vc
        x = (pos[k][:, None] + np.outer(u, r * np.cos(ph))
             + np.outer(e2, r * np.sin(ph)) + np.outer(nrm, z))
        vv = (vel[k][:, None] + np.outer(u, -vc * np.sin(ph) + dv[0])
              + np.outer(e2, vc * np.cos(ph) + dv[1]) + np.outer(nrm, dv[2]))
        out.append(np.concatenate([x, vv]))
    return np.concatenate(out, 1)


def _pull(x, y, z, c, m):
    """Softened pull of both cores on the stars. float32 throughout: the
    arithmetic is memory-bound and single precision is 1e-5 of a pixel here."""
    ax = ay = az = 0
    for k in (0, 1):
        dx, dy, dz = c[k, 0] - x, c[k, 1] - y, c[k, 2] - z
        r2 = dx * dx + dy * dy + dz * dz + np.float32(EPS * EPS)
        f = m[k] / (r2 * np.sqrt(r2))
        ax, ay, az = ax + f * dx, ay + f * dy, az + f * dz
    return ax, ay, az


def simulate(v, n, seed):
    """Star positions (3, n) at v['t'] after pericentre, and the cores'."""
    tr, p0, v0, m = _track(v["q"], v["t"])
    s = _discs(v, n, np.random.default_rng(seed), p0, v0, m).astype(np.float32)
    trf, mf = tr.astype(np.float32), m.astype(np.float32)
    h, dt = np.float32(0.5 * DT), np.float32(DT)
    for b in range(0, n, BLOCK):
        x, y, z, vx, vy, vz = s[:, b:b + BLOCK]   # views: updated in place
        ax, ay, az = _pull(x, y, z, trf[0], mf)
        vx += h * ax; vy += h * ay; vz += h * az
        for k in range(1, len(tr)):
            x += dt * vx; y += dt * vy; z += dt * vz
            ax, ay, az = _pull(x, y, z, trf[k], mf)
            # The two half-kicks either side of a step, merged. Velocities
            # end half a kick ahead; only positions are drawn.
            vx += dt * ax; vy += dt * ay; vz += dt * az
    return s[:3].astype(np.float64), tr[-1]


def sky(x, v, cores):
    """Project (3, n) onto the sky for an observer at (theta, phi), turned so
    the two nuclei lie level, then by the view's tilt."""
    th, ph = np.radians(v["view"])
    ex = np.array([-np.sin(ph), np.cos(ph), 0.0])
    ey = np.array([-np.cos(th) * np.cos(ph), -np.cos(th) * np.sin(ph), np.sin(th)])
    d = cores[1] - cores[0]
    ps = np.radians(v.get("tilt", 0.0)) - np.arctan2(ey @ d, ex @ d)
    sx, sy = ex @ x, ey @ x
    return (np.cos(ps) * sx - np.sin(ps) * sy, np.sin(ps) * sx + np.cos(ps) * sy)


def _worker(args):
    v, j, n = args
    x, cores = simulate(v, n, v["seed"] * 1000 + j)
    sx, sy = sky(x, v, cores)
    return sx.astype(np.float32), sy.astype(np.float32)


def _extent(v, size, sx, sy):
    """The view's window; with no frame pinned, the stars' box, contained."""
    if v.get("frame") is None:
        from lib import frame
        lo = np.percentile(sx, [0.5, 99.5]), np.percentile(sy, [0.5, 99.5])
        x0, x1, y0, y1 = frame(np.array(lo[0]), np.array(lo[1]), size,
                               fit="contain", zoom=v.get("zoom", 1.0))
        print("frame", [round((x0 + x1) / 2, 3), round((y0 + y1) / 2, 3),
                        round((y1 - y0) / 2, 3)])
        return x0, x1, y0, y1
    cx, cy, hh = v["frame"]
    hw = hh * size[0] / size[1]
    return cx - hw, cx + hw, cy - hh, cy + hh


def generate(size, seed=0, **kw):
    return dither(density(size, seed, **kw))


def density(size, seed=0, jobs=None, view=None, per_chunk=PER_CHUNK, raw=False):
    from lib import deposit, smooth
    v = VIEWS[seed % len(VIEWS)] if view is None else view
    w, h = size
    work = [(v, j, per_chunk) for j in range(CHUNKS)]
    import multiprocessing as mp
    with mp.get_context("fork").Pool(jobs or min(CHUNKS, os.cpu_count() or 4)) as pool:
        parts = pool.map(_worker, work, chunksize=1)
    ext = _extent(v, size, np.concatenate([p[0][::64] for p in parts]),
                  np.concatenate([p[1][::64] for p in parts]))
    # Deposited chunk by chunk, in chunk order, so the sum is the same on any
    # machine and 32 million stars never need float64 copies all at once.
    acc = np.zeros(w * h)
    for p in parts:
        deposit(p[0].astype(np.float64), p[1].astype(np.float64), size, ext, out=acc)
    del parts
    # Rows are deposited bottom-up (sky y increasing); images go top-down.
    d = acc.reshape(h, w)[::-1].astype(np.float32)
    del acc

    # ADAPTIVE smoothing, coarse to fine. A level is blended in where the
    # level above it says the finer kernel holds enough stars (its density
    # estimate from the coarser, quieter level, times the kernel's effective
    # area 4 pi sigma^2), so dense discs keep their fine structure and the
    # sparse tails and fans are a smooth haze rather than a spray of dots.
    sig = [SIGMA0 * h * 2 ** k for k in range(LEVELS)]
    out = smooth(d, sig[-1])
    for s in sig[-2::-1]:
        held = out * np.float32(4 * np.pi * s * s)
        wgt = held / (held + np.float32(N_TRUST))
        out = wgt * smooth(d, s) + (1 - wgt) * out
    d = np.clip(out, 0, None)
    del out

    # To SURFACE DENSITY: the fraction of all stars per unit sky area, in
    # pericentre units. A physical quantity, the same at any panel size, so
    # the stretch draws the same picture at 4K and at 8K.
    pix = (ext[1] - ext[0]) / w * (ext[3] - ext[2]) / h
    d = d / np.float32(CHUNKS * per_chunk * pix)
    return d if raw else stretch(d)


def stretch(d):
    """asinh, the stretch astronomers use for exactly this: linear below the
    knee, logarithmic above it. The discs are a hundred times denser than the
    tails, and a zscale clip turned every disc into one flat blob; asinh keeps
    the gradient down each disc and still lifts the tails. The knee and the
    ceiling are in units of one disc's own mean surface density."""
    # Below FLOOR the density is rolled off smoothly to nothing: the limiting
    # surface brightness of the picture. Without it the sparsest spray, a few
    # stars per coarsest kernel, printed as a mottled haze of blotches.
    x = d / FLOOR
    x = x ** 4
    d = d * (x / (1 + x))
    ref = 1.0 / (np.pi * R_OUT ** 2)
    f = np.arcsinh(d / (KNEE * ref)) / np.arcsinh(TOP / KNEE)
    return np.clip(f, 0, 1).astype(np.float64)


def dither(f):
    """Dither the field by one step of the renderer's colour table.

    lib.render looks colours up in a 512-entry table, and across a broad,
    faint gradient -- the fans, the fading ends of the tails -- one entry is
    two or three 8-bit levels once blended and saturated: the dither lib
    applies after that (one level) cannot hide it, and the gradient printed
    as terraced contours. Noise of one table step, before the lookup, spreads
    each step into its neighbours. Pinned, and zero stays zero (the ground).
    """
    d = (np.random.default_rng(0).random(f.shape) - 0.5) * (2.0 / 512)
    return np.where(f > 0, np.clip(f + d, 1e-6, 1.0), 0.0)
