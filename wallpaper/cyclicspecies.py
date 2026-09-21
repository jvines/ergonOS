"""Rock-paper-scissors -- three species in cyclic competition, on a plane.

    da/dt = D lap(a) + a (1 - rho) - a c
    db/dt = D lap(b) + b (1 - rho) - b a        rho = a + b + c
    dc/dt = D lap(c) + c (1 - rho) - c b

A eats B, B eats C, C eats A, and each reproduces into empty space. It is the
May-Leonard model (1975) with mobility, in the form Reichenbach, Mobilia &
Frey used to show that moving about decides whether three such species can
live together (Nature 448, 1046, 2007); the real system behind it is three
strains of E. coli, one making the toxin colicin, one immune to it and one
that has shed the cost of both (Kerr et al., Nature 418, 171, 2002). Selection
and reproduction rates are both 1, which sets the unit of time.

Well mixed, the three have an unstable coexistence point (a = b = c = 1/4) and
the populations spiral out from it onto a heteroclinic cycle -- each species in
turn nearly takes over, then is eaten by the next. Spread over a plane, that
cycle becomes a travelling wave: every point runs through B, then A, then C,
and the phase singularities where all three meet wind the waves into spirals
that turn for as long as the simulation runs. Reichenbach et al. mapped the
dynamics near the coexistence point onto the complex Ginzburg-Landau
equation, the same equation that describes the spirals of the
Belousov-Zhabotinsky reaction near onset -- which is why the two look alike.

This is the deterministic rate equation, the mean field of their lattice
model, not the stochastic lattice itself. The lattice has a site per bacterium
and is grain at any panel resolution; the rate equation is the smooth field
the grain averages to, and it winds the same spirals.

STARTED FROM A FEW SINGULARITIES, not from white noise. White noise nucleates a
spiral every wavelength or so, and a panel of them is a crowded glass of short
hooks, none more than a turn long. Here the start is a smooth random mixture
(a complex Gaussian field with a long correlation length, its phase deciding
which species leads): its zeros are the only places where all three meet, so
they are the only spiral cores, and each has room to wind several turns
before its waves collide with a neighbour's along a shock line.

DRAWN WHERE EACH SPECIES HAS TAKEN OVER. Across one arm a species' density is
a hump: about 0.44 at the front where it arrives, where the prey has been
eaten and a sixth of the ground is bare, up to 0.92 at the crest, where it has
all but taken over, and down again as the next species arrives to eat it.
Each species is drawn only where it holds more than CREST of the sites, and
the rest is ground. So every arm is a ribbon along its species' crest, and the
dark between ribbons is the turnover, where the cycle is handing over from one
species to the next. Toward a spiral core the waves' amplitude falls to the
unstable coexistence point, a quarter each, and nobody reaches the crest
there, so each ribbon tapers to a point before the core. The centre of a
pocket between colliding spirals can be dark for the same reason: it
oscillates about coexistence by itself, and its own swing can fall short of
the crest. The ribbon edge is the density contour, drawn from the analytic
distance to it (the excess over CREST divided by its gradient, as ising.py
does), so it is crisp at any resolution. Colouring each species' whole domain
up to the fronts was tried first. Every pixel was then flat, bright colour,
which is a poster, not a surface to put windows on. Each species is a fixed
place on the ramp, so the three interlocking arms read as three colours.
"""

import os

import numpy as np

TITLE = "Rock-paper-scissors"
SUBTITLE = ("three species that each eat the next, A > B > C > A, chasing one"
            " another round spiral waves   (Reichenbach, Mobilia & Frey 2007)")

# Colours by construction: the field is ramp position already.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
# Between the house values for lines (2.25 / 1.1) and for screen-filling
# fields (1.5 / 0.95). About 40% of the panel is lit, in ribbons on ground.
SATURATION = 2.0
EXPOSURE = 1.0
# Hue from the neighbourhood so a ribbon's edge fades out in its own colour
# rather than stepping down the ramp through the other species' colours. Far
# narrower than the dark gap between ribbons, so none borrows a neighbour's hue.
HUE_SMOOTH = 1.5
# Smooth analytic field at panel resolution: already band-limited.
SUPERSAMPLE = 1

# Ramp position of each species, A, B, C: teal, blue-violet, pink, flat. A
# drift across each band was tried and muddied the three colours into one
# gradient. Flat, they read at a glance as three interlocking spirals. B sits
# a quarter of the way from the blue stop to mauve: pure blue came out heavy
# and dark next to the teal and pink.
LEVEL = (0.2, 0.65, 1.0)
# A species is drawn where its density exceeds this: its crest, where it has
# nearly taken over (the crest itself peaks at about 0.92). At 0.8 the ribbons
# were as wide as the gaps and the panel read as stripes. At 0.85 about 40% of
# the panel is lit.
CREST = 0.85
# The ribbon's anti-aliased edge, as a fraction of the panel height: 1.2 px at
# 2400.
EDGE = 1.2 / 2400

# grid: lattice rows per panel height -- a COUNT, so the simulated picture is
#   the same at 4K, 8K or supersampled, and only its upscale changes;
# D: diffusion in lattice cells^2, which sets the wavelength: it scales as
#   sqrt(D), and at D = 2 the power spectrum puts it at 51-54 cells;
# ell: correlation length of the starting mixture, in cells, which sets how
#   far apart the spiral cores are;
# t: how long it ran; mix: seed of the starting mixture -- part of the
#   picture, so pinned here. "pair" stops at 560: by 600 the swing at the
#   centre of its left-hand pocket had just reached the crest, which drew a
#   lone bead 1.5% of the panel height across.
PRESETS = {
    "pair":    dict(grid=600, D=2.0, ell=90.0, t=560.0, mix=3),
    "bold":    dict(grid=450, D=2.0, ell=68.0, t=600.0, mix=1),
    "cluster": dict(grid=600, D=2.0, ell=90.0, t=600.0, mix=4),
}
# Offered on the desktop: the view chosen there. "bold" and "cluster" were shown
# and pruned; their presets stay above.
ORDER = ["pair"]


def _start(gh, gw, ell, seed):
    """a, b, c near coexistence, mixed by a smooth complex Gaussian field.

    Low-passed complex white noise, by FFT so it is periodic like the lattice.
    Its phase says which species leads and by how much; its zeros are the
    points where all three are level, and those become the spiral cores.
    """
    rng = np.random.default_rng(seed)
    z = rng.standard_normal((gh, gw)) + 1j * rng.standard_normal((gh, gw))
    ky = np.fft.fftfreq(gh)[:, None]
    kx = np.fft.fftfreq(gw)[None, :]
    # A Gaussian filter of width ell cells, applied in Fourier space.
    lowpass = np.exp(-2 * (np.pi * ell) ** 2 * (kx * kx + ky * ky))
    z = np.fft.ifft2(np.fft.fft2(z) * lowpass)
    z /= np.abs(z).max()
    # The three species take the field's phase a third of a turn apart, so
    # whichever leads is set by the phase and all three are level at a zero.
    rot = np.exp(-2j * np.pi / 3)
    return [(0.25 + 0.1 * (z * rot ** k).real).astype(np.float32)
            for k in range(3)]


def _simulate(gh, gw, p):
    """Explicit Euler, five-point Laplacian, the three species as one stacked
    array. dt is inside the diffusive limit (D dt <= 1/4) and well under the
    reaction time of 1. Elementwise float32 throughout: no BLAS, no threads,
    so the same seed gives the same spirals on any machine's core count."""
    P = np.stack(_start(gh, gw, p["ell"], p["mix"]))
    dt = np.float32(min(0.1, 0.2 / p["D"]))
    D = np.float32(p["D"])
    for _ in range(int(round(p["t"] / float(dt)))):
        lap = (np.roll(P, 1, 1) + np.roll(P, -1, 1)
               + np.roll(P, 1, 2) + np.roll(P, -1, 2) - 4 * P)
        # Each species grows into the empty fraction and is eaten by the one
        # before it in the cycle: a by c, b by a, c by b.
        P += dt * (D * lap + P * ((1 - P.sum(0)) - P[[2, 0, 1]]))
    return P


def _resample(a, h, w):
    """Periodic Catmull-Rom from the lattice to (h, w), one axis at a time.

    Cubic, not bilinear: a bilinear field has a kink along every lattice line,
    and the walls are the zero set of a difference of these fields, so they
    came out as polygons of lattice-cell facets. Catmull-Rom is C1 and
    interpolating, so the walls are smooth curves through the right places."""
    for axis, n_out in ((0, h), (1, w)):
        n = a.shape[axis]
        x = (np.arange(n_out) + 0.5) * n / n_out - 0.5
        i = np.floor(x).astype(int)
        t = x - i
        wts = (((-0.5 * t + 1.0) * t - 0.5) * t,
               (1.5 * t - 2.5) * t * t + 1.0,
               ((-1.5 * t + 2.0) * t + 0.5) * t,
               (0.5 * t - 0.5) * t * t)
        shape = [1, 1]
        shape[axis] = n_out
        out = 0
        for k, wk in enumerate(wts):
            tap = np.take(a, (i - 1 + k) % n, axis=axis)
            out = out + tap * wk.reshape(shape)
        a = out.astype(np.float32)
    return a


def generate(size, seed=0, cache=None, **kw):
    w, h = size
    p = dict(PRESETS[ORDER[seed % len(ORDER)]], **kw)
    gh = p["grid"]
    gw = int(round(gh * w / h))
    gw += gw % 2

    # The simulation depends only on the preset and the aspect; `cache` keeps
    # it between renders so the walls and colours can be iterated on alone.
    if cache and os.path.exists(cache):
        pop = np.load(cache)
    else:
        pop = _simulate(gh, gw, p)
        if cache:
            np.save(cache, pop)

    # To the panel, each species separately.
    s = np.stack([_resample(q, h, w) for q in pop])
    lead = np.argmax(s, axis=0)
    # The leader's density. Where the lead changes hands it has a kink, but
    # there it is below a half -- two species level, sharing at most the whole
    # ground -- so far below CREST, and the kink is never drawn.
    top = s.max(axis=0)
    del s

    # Distance to the CREST contour, in pixels: the excess divided by how fast
    # it changes. Exact at the contour, where it is linear; an overestimate
    # far from it, where it does not matter because the pixel is already fully
    # on or off.
    gy, gx = np.gradient(top)
    d = (top - CREST) / (np.hypot(gx, gy) + 1e-9)
    del gy, gx, top
    edge = np.clip(d / (EDGE * h) + 0.5, 0.0, 1.0)
    return edge * np.asarray(LEVEL, dtype=np.float32)[lead]
