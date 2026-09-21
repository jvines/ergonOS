"""Kuramoto-Sivashinsky -- one-dimensional spatiotemporal chaos, drawn as
space against time.

    u_t + u_xx + u_xxxx + u u_x = 0,    x in [0, L), periodic

Kuramoto's equation for phase turbulence in reaction-diffusion (1976) and
Sivashinsky's for the wrinkling of a laminar flame front (1977), which turned
out to be the same equation. The u_xx term has the wrong sign, so long
wavelengths are pumped rather than damped; u_xxxx kills the short ones; u u_x
moves energy between the two and stops the balance from ever settling. It is
the cheapest system that is genuinely turbulent, and the standard proving
ground for spectral methods.

x runs across the panel and t runs DOWN it, so a row is the front at one
instant and a column is the history of one point on it.

WHAT IS DRAWN: the cell boundaries, not u.

The u u_x term is Burgers' nonlinearity, so u is a row of cells, each rising
slowly and then dropping through a steep front -- a smoothed shock, where u_x
is strongly negative. Those fronts are the skeleton of the dynamics. Traced
through time they drift, they MERGE when a cell is squeezed out (a Y opening
upward, since time runs down), and a new one is BORN in the middle of a cell
that has grown too wide (a line fading in from nothing). The picture is a
forest of those trees.

The first version drew u itself, rectified and squared: fat soft tubes, each
banded teal-blue-mauve from rim to core because the colour ramp read the tube's
own profile as hue, at blend 0.37 -- a muddy smear that hid the one thing the
system does. Drawing -u_x directly gives the network, but at its physical width
(about a unit of x) every front is a hose. So each front is drawn as a RIDGE
LINE, found at every pixel from the local Hessian of -u_x: the distance to the
crest is one Newton step along the direction of strongest curvature, and a
Gaussian pen of that distance gives a line of fixed width in any direction,
with no linking of points and no gaps where a front runs fast. (A faint glow
at the front's real width was tried underneath; the renderer can only colour
a dim glow by its dimness, so every line got a teal halo -- the fringe again.)

Colour is the front's steepness, by rank among all fronts: newborn fronts and
the two about to merge are weak and teal; the front a merger leaves behind is
the steepest and runs violet.

Births that fail (a crest that swells and sinks back, or a branch that fades
out well short of its junction) and the ridge detector's flecks beside a
junction drew short detached strokes that read as dust on the glass. A real
front runs on until it merges or leaves the panel, so any piece of ink not
joined to something spanning a good fraction of the panel in t is removed.

Pseudo-spectral in x, ETDRK4 in time (Kassam & Trefethen, SIAM J. Sci. Comput.
26, 1214, 2005 -- this is their kursiv.m in numpy). The fourth derivative makes
the linear part violently stiff: mode k decays as exp(-k^4 t), so an explicit
stepper would need a timestep some five orders of magnitude below anything the
picture needs. ETDRK4 integrates that part exactly, leaving the step to be set
by the advection, which is slow.
"""

import numpy as np

TITLE = "Kuramoto-Sivashinsky"

# The field comes out already in 0..1 -- line opacity times the line's colour
# -- so the renderer takes it as it is.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
# No SOFTEN: the pen is already a band-limited Gaussian, so there is no beading
# to cure, and blurring it only dims the core and pulls its colour down the
# ramp. HUE_SMOOTH keeps a line one colour across its width.
SOFTEN = 0.0
HUE_SMOOTH = 3.0

# (L, rate). L is the only parameter the equation has: rescaling x and t
# removes every coefficient and leaves the domain length, so L alone fixes how
# many cells fit across the panel (floor(L/2pi) modes are linearly unstable;
# the cells settle near the fastest-growing wavelength 2pi sqrt 2 = 8.9).
# Below about L = 22 the flow stops being chaotic (Cvitanovic, Davidchack &
# Siminos 2010). `rate` is time units per unit length across the panel: how
# much the picture is stretched along t. The third number seeds the initial
# condition, and is part of the picture: pinned so pruning never changes it.
#
# Only the view chosen on a real desktop is here. "forest" (L = 64 pi, rate
# 1.0, seed 0) was good but pruned; "grove" (40 pi, 1.2, seed 1) was the
# weakest and never shown.
PRESETS = {
    "thicket": (100 * np.pi, 0.70, 2),
}
_EQ = "u_t + u_xx + u_xxxx + u u_x = 0"
SUBTITLE = _EQ + ",  L = 100 pi,  the cell boundaries: x across, t down"

# Pen: the Gaussian sigma of a line, as a fraction of panel width, so the look
# does not change with resolution. 1.3 px at 4K, flat-topped (see below).
PEN = 1.3 / 3840
# Fronts fade in between these fractions of full strength.
FADE = (0.18, 0.50)
# Colour: the weakest crest sits at 0.35 of the ramp, rising by TOP x rank.
TOP = 0.9
# Crest sharpness (1/width^2, units of x) over which a crest fades in. Real
# crests measure 0.8-1.6 (5th-95th percentile); the shards measure ~0.
KAPPA = (0.3, 0.7)
# Debris. Opacity below LIT comes off everything (a soft floor): it only drew
# dust, which the defringe shows at full opacity. A piece of ink spanning
# under MIN_T of the panel in t and touching neither edge is a failed birth;
# pieces within GAP (panel widths) of each other count as joined. Any lone
# piece under FLECK in t is a fleck.
LIT = 0.05
MIN_T = 0.08
GAP = 6 / 3840
FLECK = 0.015

MAX_STEP = 0.25     # ETDRK4 is stable far past this; it only binds on previews
BURN = 150.0        # the initial condition's collapse onto the attractor


def _coeffs(lin, dt, m=32):
    """ETDRK4's weights, by contour integral.

    The weights are combinations like (e^z - 1)/z: exact in algebra and
    catastrophic in floating point as z -> 0, which is precisely where the
    long-wavelength modes that carry the whole solution live. Kassam &
    Trefethen evaluate them instead as a mean over a circle of radius 1 about
    each z -- the functions are analytic there, so the mean is the value at the
    centre, obtained only from arguments far from the singularity. Half a
    circle suffices because `lin` is real and conjugate points pair up.
    """
    r = np.exp(1j * np.pi * (np.arange(1, m + 1) - 0.5) / m)
    z = dt * lin[:, None] + r[None, :]
    ez = np.exp(z)
    z3 = z ** 3
    q = dt * np.real(np.mean((np.exp(z / 2) - 1) / z, axis=1))
    f1 = dt * np.real(np.mean((-4 - z + ez * (4 - 3 * z + z * z)) / z3, axis=1))
    f2 = dt * np.real(np.mean((2 + z + ez * (z - 2)) / z3, axis=1))
    f3 = dt * np.real(np.mean((-4 - 3 * z - z * z + ez * (4 - z)) / z3, axis=1))
    return np.exp(dt * lin), np.exp(dt * lin / 2), q, f1, f2, f3


def _solve(length, rows, per_row, seed, burn):
    """Spectra of u at `rows` instants per_row apart, after a burn-in."""
    # Resolution is set by the physics, not by the panel: the growth rate
    # k^2 - k^4 is negative for every k > 1 and the spectrum falls off a cliff
    # above it -- mode k = 8 sits eleven orders of magnitude below the peak. At
    # 2.6 points per unit length the Nyquist wavenumber is past that. The panel
    # gets an exact interpolation of this at the end, not a finer simulation.
    n = 1 << int(np.ceil(np.log2(2.6 * length)))
    x = length * np.arange(n) / n
    k = 2 * np.pi * np.fft.rfftfreq(n, d=length / n)
    lin = k ** 2 - k ** 4
    deriv = -0.5j * k
    deriv[-1] = 0.0                      # the Nyquist mode carries no phase
    keep = k <= (2.0 / 3.0) * k[-1]      # two-thirds dealiasing; costs nothing

    def nonlinear(v):
        u = np.fft.irfft(v, n=n)
        return deriv * np.fft.rfft(u * u) * keep

    sub = max(1, int(np.ceil(per_row / MAX_STEP)))
    dt = per_row / sub
    e, e2, q, f1, f2, f3 = _coeffs(lin, dt)

    def step(v):
        nv = nonlinear(v)
        a = e2 * v + q * nv
        na = nonlinear(a)
        b = e2 * v + q * na
        nb = nonlinear(b)
        c = e2 * a + q * (2 * nb - nv)
        nc = nonlinear(c)
        return e * v + nv * f1 + 2 * (na + nb) * f2 + nc * f3

    # Unstable-band cosines with random phase and NO j = 0 term: the mean of u
    # is conserved exactly, so a nonzero one would ride on a drift for ever.
    rng = np.random.default_rng(seed)
    j = np.arange(1, 9)[:, None]
    u = (rng.normal(0.0, 1.0, (8, 1))
         * np.cos(2 * np.pi * j * x[None, :] / length
                  + rng.uniform(0.0, 2 * np.pi, (8, 1)))).sum(0)
    v = np.fft.rfft(u)
    for _ in range(int(burn / dt)):
        v = step(v)
    spec = np.empty((rows, k.size), dtype=complex)
    for row in range(rows):
        for _ in range(sub):
            v = step(v)
        spec[row] = v
    return spec, n


def _debris(lit, min_rows):
    """Mask of the 8-connected pieces of `lit` (periodic in x, as the domain
    is) spanning under min_rows rows and touching neither top nor bottom.
    Labelled in numpy (no scipy here): hook each edge's two roots to the
    smaller, point every node at its root, repeat until no edge joins two."""
    h, w = lit.shape
    idx = np.flatnonzero(lit)
    node = np.full(lit.size, -1, dtype=np.int64)
    node[idx] = np.arange(idx.size)
    r, c = idx // w, idx % w
    ea, eb = [], []
    for dr, dc in ((0, 1), (1, -1), (1, 0), (1, 1)):
        ok = r + dr < h
        j = node[(r[ok] + dr) * w + (c[ok] + dc) % w]
        ea.append(np.flatnonzero(ok)[j >= 0])
        eb.append(j[j >= 0])
    ea, eb = np.concatenate(ea), np.concatenate(eb)
    lab = np.arange(idx.size)
    la, lb = lab[ea], lab[eb]
    while not np.array_equal(la, lb):
        m = np.minimum(la, lb)
        np.minimum.at(lab, la, m)
        np.minimum.at(lab, lb, m)
        while not np.array_equal(lab[lab], lab):
            lab = lab[lab]
        la, lb = lab[ea], lab[eb]
    top, bot = np.full(idx.size, h), np.full(idx.size, -1)
    np.minimum.at(top, lab, r)
    np.maximum.at(bot, lab, r)
    top, bot = top[lab], bot[lab]
    out = np.zeros(lit.shape, dtype=bool)
    out.flat[idx[(bot - top + 1 < min_rows) & (top > 0) & (bot < h - 1)]] = True
    return out


def _grow(m, r):
    """Dilate a mask by r pixels (a square); periodic in x, and in t too,
    which only matters within r of the edges, where nothing is removed."""
    for axis in (0, 1):
        g = m.copy()
        for s in range(1, r + 1):
            g |= np.roll(m, s, axis) | np.roll(m, -s, axis)
        m = g
    return m


def generate(size, seed=0, burn=BURN, pen=None, band=256):
    w, h = size
    name = sorted(PRESETS)[seed % len(PRESETS)]
    length, rate, ic_seed = PRESETS[name]

    # One timestep per row of pixels, so a pixel is the same distance in x
    # and in t and "perpendicular to a front" means what it looks like. Two
    # extra rows give the finite differences in t a neighbour at each edge.
    spec, n = _solve(length, h + 2, rate * length / w, ic_seed, burn)

    # u is band-limited, so zero-padding its spectrum to the panel width and
    # transforming back is exact interpolation: the pixels are the solution
    # evaluated at the pixel centres. Derivatives come from the same spectrum.
    # All in PIXEL units (x scaled by L/w), so the Hessian below is isotropic.
    m = min(spec.shape[1] - 1, w // 2 + 1)
    kp = (2 * np.pi * np.fft.rfftfreq(w, d=length / w))[:m] * (length / w)
    # -u_x, its first and second x-derivatives: -(ik), -(ik)^2, -(ik)^3.
    mult = [-1j * kp, kp ** 2, 1j * kp ** 3]

    # Front strengths, from this run's own crests on the solver's grid: every
    # local maximum of -u_x in x, every fourth row. g_ref is a full-strength
    # front; `ranks` maps a crest's steepness to its place among all crests.
    kn = 2 * np.pi * np.fft.rfftfreq(n, d=length / n)
    gs = np.fft.irfft(-1j * kn * spec[::4], n=n, axis=1)
    crest = gs[(gs > np.roll(gs, 1, 1)) & (gs >= np.roll(gs, -1, 1))]
    g_ref = np.percentile(crest, 99.5)
    crest = crest[crest > 0.3 * g_ref]
    ranks = np.percentile(crest, np.linspace(0, 100, 65)) * (length / w)
    g_ref *= length / w                # in the same pixel units as g below
    sigma = (PEN if pen is None else pen) * w

    out = np.zeros((h, w), dtype=np.float32)
    lit = np.zeros((h, w), dtype=bool)
    for r0 in range(0, h, band):
        r1 = min(h, r0 + band)
        # Panel rows r0..r1 are spec rows r0+1..r1, plus one either side.
        s = spec[r0:r1 + 2, :m] * (w / n)
        pad = np.zeros((s.shape[0], w // 2 + 1), dtype=complex)
        fields = []
        for mu in mult:
            pad[:, :m] = s * mu[None, :]
            fields.append(np.fft.irfft(pad, n=w, axis=1).astype(np.float32))
        g, gx, gxx = fields
        # t-derivatives by central differences: a front moves about a pixel
        # per row at most, so the rows are smooth in time.
        gt = 0.5 * (g[2:] - g[:-2])
        gtt = g[2:] - 2 * g[1:-1] + g[:-2]
        gxt = 0.5 * (gx[2:] - gx[:-2])
        g, gx, gxx = g[1:-1], gx[1:-1], gxx[1:-1]

        # RIDGE DISTANCE. The Hessian's most negative eigenvalue lam and its
        # eigenvector e point across the ridge; along e the field is locally
        # g + p s + lam s^2 / 2 with p = grad g . e, whose crest is -p/lam
        # away and -p^2/(2 lam) higher. A pen of that distance draws the crest
        # at a fixed width whatever its angle, and a pixel needs only its own
        # derivatives -- no points to link, so no gaps where a front runs fast.
        rad = np.sqrt((0.5 * (gxx - gtt)) ** 2 + gxt * gxt)
        lam = 0.5 * (gxx + gtt) - rad
        th = 0.5 * np.arctan2(2 * gxt, gxx - gtt)   # along the ridge
        p = -np.sin(th) * gx + np.cos(th) * gt      # slope across it
        ridge = lam < 0
        with np.errstate(divide="ignore", invalid="ignore"):
            d = np.where(ridge, p / lam, np.inf)
            # capped: near the edge of a front the parabola overshoots
            top = np.where(ridge, np.minimum(g - 0.5 * p * d, 1.4 * g), g)
        # Flat-topped, so the core is solid and HUE_SMOOTH's local mean -- the
        # colour the line is given -- is the line's own colour, not ~70% of it.
        prof = np.minimum(1.0, 1.6 * np.exp(-0.5 * (d / sigma) ** 2))

        # Every pixel coloured by the crest it belongs to, so a line is one
        # colour across its width. By RANK among all crests: the steepest fronts
        # are a few percent, and by value nearly every line landed on one hue.
        q = np.minimum(1.0, 0.35 + TOP * np.interp(top, ranks, np.linspace(0, 1, ranks.size)))
        st = np.clip(top / g_ref, 0.0, 1.0)
        # The flat middles of cells have faint ridges in -u_x too. A
        # smoothstep on strength removes them, and fades a newborn front in.
        a = np.clip((st - FADE[0]) / (FADE[1] - FADE[0]), 0.0, 1.0)
        a = a * a * (3 - 2 * a)
        # And fade crests too broad to be a front: where lam and p both pass
        # near zero, their ratio is small by accident and printed hard little
        # shards. kappa is the crest's curvature over its height, 1/width^2
        # in units of x; a front is about a unit wide.
        with np.errstate(divide="ignore", invalid="ignore"):
            kappa = np.where(ridge, -lam / np.maximum(top, 1e-9), 0.0) * (w / length) ** 2
        a = a * np.clip((kappa - KAPPA[0]) / (KAPPA[1] - KAPPA[0]), 0.0, 1.0)
        op = np.clip((prof * a - LIT) / (1.0 - LIT), 0.0, 1.0)
        out[r0:r1] = op * q
        lit[r0:r1] = op > 0

    # Debris, over the whole panel (a stroke can straddle bands), labelled on
    # a ~4K grid of blocks: ample for strokes, nine times cheaper than ss 3.
    f = max(1, w // 3840)
    hb, wb = -(-h // f), -(-w // f)
    blk = np.pad(lit, ((0, hb * f - h), (0, wb * f - w)))
    blk = blk.reshape(hb, f, wb, f).any(axis=(1, 3))
    del lit
    # Every lit pixel sits in a lit block, so dropping blocks leaves no rim.
    drop = _debris(_grow(blk, int(GAP * wb) // 2), int(MIN_T * hb)) & blk
    drop |= _debris(blk, int(FLECK * hb))
    cols = np.arange(w) // f
    for r0 in range(0, h, band):
        r1 = min(h, r0 + band)
        out[r0:r1][drop[np.ix_(np.arange(r0, r1) // f, cols)]] = 0.0
    # x runs one way and t the other; there is nothing to flip.
    return out
