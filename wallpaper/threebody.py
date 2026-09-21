"""Circular restricted three-body problem -- test particles in a rotating frame.

    x'' - 2y' = dW/dx,    y'' + 2x' = dW/dy
    W(x, y) = (x^2 + y^2)/2 + (1 - mu)/r1 + mu/r2

Two massive bodies on a circular orbit and a massless third that feels them
both and perturbs neither, written in the frame co-rotating with the pair, in
units where their separation, their total mass and their orbital angular
velocity are all 1. mu = m2/(m1 + m2) = 9.5388e-4 is the Sun-Jupiter ratio
(Jupiter system mass, 1/1047.3486 of the Sun): small enough that the picture is
a perturbed circle, large enough that the perturbation is the picture.

The rotating frame is the whole reason this can be a still image. In inertial
coordinates the primaries move and everything smears into annuli; here they sit
at (-mu, 0) and (1-mu, 0) and never move, W does not depend on time, and

    C = 2W - v^2                                    (the Jacobi integral)

is conserved. C is the only integral the problem has -- Poincare's result, and
the reason the three-body problem has no closed solution -- and it is what
draws the picture: v^2 >= 0 forbids the region where 2W < C, so a trajectory is
caged for all time inside a zero-velocity curve, and the topology of that cage
is set by C alone. Every preset here is one choice of it.

Released from REST on the zero-velocity curve, not scattered through the
allowed region. That is forced, not aesthetic: dx dy dvx dvy restricted to a
surface of constant C integrates over the velocity angle to a FLAT measure in
position, so a microcanonical ensemble -- and equally one ergodic orbit
followed long enough -- projects onto the panel as a uniform plate bounded by
the zero-velocity curve, and nothing else. Every visible structure belongs to
an ensemble that is not the invariant measure. A one-parameter family released
from rest on the curve is such an ensemble, it shares C exactly so the cage
still binds it, and it is a physical construction rather than a trick: dust let
go with no motion relative to the pair.

The same argument decides which C are worth rendering, and it is why nothing
here seals the cage at L1. Above C_L1 the allowed region is three separate
pockets, one around each body and the outside, which is the figure every
textbook prints -- but the orbits inside those pockets are eccentric, they
sweep wide annuli, they mix within a few revolutions, and the panel comes out
as a flat plate with a dark ring across it exactly as the measure predicts.
All four presets sit instead in the window between C_L4 and C_L3, which is
2*mu wide -- one part in fifteen hundred -- and holds the co-orbital motion:
particles that stay within a few per cent of r = 1 and librate in longitude,
about L4 and L5 at the bottom of the window and right around through L3 at the
top, instead of circulating. Libration is slow, one period being about 150
years for the Jupiter Trojans against Jupiter's 11.9, so over a run that lasts
seven orbits the ensemble has not mixed and the arcs stay thin. That regime is
the Trojans, Janus and Epimetheus, and every horseshoe co-orbital; it is also
the only part of the C axis that draws arcs rather than a plate.

What is bright in the finished image is mostly the zero-velocity curve itself,
traced from outside by the particles that cannot cross it, with the forbidden
lobe showing through as a darker thread down the middle of each arc.

Vectorised over the ensemble and stepped with classical RK4, following
lorenz.py: sixteen thousand particles for forty-eight time units is 7.7 x 10^7
sampled positions in some twenty-five seconds, where sixteen thousand serial
trajectories would be an afternoon.

Szebehely, Theory of Orbits (1967), ch. 4 and 9, for all of the above.
"""

import numpy as np

# The density spans orders of magnitude. A caustic is a fold, where a whole
# band of initial conditions arrives in one place at once, and it outweighs the
# region it sweeps by a large factor; linear-with-clip renders the folds and
# loses everything between them.


# Between Lorenz and Gray-Scott. Neither a sparse attractor nor a full field:
# the arcs are broad and cover a good half of the panel, but what they do not
# cover is exactly background -- the hole inside the innermost caustic and the
# corners past the outermost are empty, not dim -- so it can carry more colour
# than a field without ever being the brightest thing on the screen.
# 90 particles, not 16000.
#
# The arcs ARE trajectories, and an arc you can follow has to be drawn rather
# than averaged with ten thousand others: at 16000 every part of the allowed
# region is occupied by something at every moment, so the picture is a plate
# bounded by the zero-velocity curve and nothing inside it reads. Steps rise as
# the count falls, so the total drawn path length stays comparable and fewer
# particles does not simply mean an emptier image.
TITLE = "Restricted three-body problem"
SUBTITLE = "Sun-Jupiter rotating frame, mu = 9.5388e-4"

# zscale, the IRAF/DS9 stretch. These density fields have the same shape as an
# astronomical frame -- a core orders of magnitude brighter than the structure
# worth seeing -- and zscale is the algorithm built for exactly that. Measured
# on this attractor it chose z2 = 422 against a field maximum of 10914: it
# saturates the core by a factor of 25 and gives the whole display range to the
# filaments. A percentile clip cannot do that, and log flattens the density
# ridges that ARE the filaments.
SCALE = "zscale"
GAMMA = 0.4

# BLEND 1.0: the colormap undiluted.
#
# This started at 0.55 to keep a wallpaper from competing with the windows on
# it, and every complaint since -- washed, dim, no colour -- traced back to
# that one number. On a real desktop the undiluted version is the one that
# reads. The constraint was wrong for these images.
BLEND = 1.0

MU = 9.5388e-4

# Plummer softening on each body, as eps^2. A test particle that falls onto a
# point mass takes the integrator with it, and no fixed step survives it.
#
# Jupiter's is the one that matters, and it is set by the step rather than by
# guesswork: a circular orbit at the softening length has period
# 2 pi sqrt(eps^3 / mu), and eps2 = 0.014 makes that 34 steps long at the dt
# below, so the softened core is resolved and the Jacobi constant holds to
# 3e-6 -- a thousandth of the width of the window the presets live in -- for
# every particle including the ones that go through it. At eps2 = 0.003, which
# is closer to the real Jupiter, the core is three steps long, a quarter of the
# widest preset's ensemble comes within 0.02 of it, and C breaks by 0.6 for
# them -- three hundred times the whole window. The cage stops binding and the
# picture is numerics. The cost of the honest choice is that eps2 is a fifth of
# Jupiter's Hill radius, so a deep pass is a smooth deflection where the real
# thing would be a slingshot. That is a bounded approximation in place of an
# unbounded error, and it is the usual reason to soften.
#
# The Sun's is only a guard. Nothing comes within 0.37 of it in any preset,
# twelve times eps1, so its value never enters the result.
E1, E2 = 0.030 ** 2, 0.014 ** 2

# Barycentric and 3:2, so L3 (-1, 0) and Jupiter (1, 0) sit symmetrically about
# the centre and the triangular points (0.5, +-sqrt(3)/2) fall just inside the
# top and bottom edges rather than on them.
EXTENT = (-1.575, 1.575, -1.05, 1.05)

# Fraction of the way from C_L4 up to C_L3. Anchored to the Lagrange points
# rather than written out, because the four numbers mean nothing on their own
# -- they agree to the fourth decimal place and the window they divide is 2*mu
# wide -- and because anchoring survives a change of mu or of the softening,
# which literal constants would not.
#
# The fraction is the libration amplitude: the forbidden lobes grow with C from
# tight caps on L4 and L5 to crescents that nearly touch at L3, and a particle
# released on a lobe has to go around it.
PRESETS = {
    # Two short arcs and nothing else. Stays between 31 and 110 degrees of
    # Jupiter in longitude and between r = 0.95 and 1.05 -- a Trojan.
    "tadpole":    0.10,
    # The arcs have grown until they meet behind the Sun: one ring, drawn
    # around L3, broken where the particles turn back 15 degrees short of
    # Jupiter, never closer to it than a quarter of the separation.
    "horseshoe":  0.30,
    # The turning points have reached Jupiter. Two per cent of the ensemble
    # passes inside the softened core and is thrown across the interior, and
    # those are the filaments that fan out of the ring.
    "encounter":  0.60,
    # A sixth of them, now, out to r = 3 and back. The ring survives as the
    # brightest thing on the panel because the scattered ones are spread thin
    # over everything inside that.
    "scattering": 0.95,
}


def _grad(x, y):
    """dW/dx, dW/dy. Also the acceleration on a particle at rest.

    r^-3 as q*sqrt(q) and not q**-1.5: this is the innermost expression in the
    generator, evaluated four times a step, and numpy's power with a fractional
    exponent is a libm call per element where sqrt is one vector instruction.
    Eight times faster for the same answer.
    """
    dx1 = x + MU
    dx2 = x - 1.0 + MU
    yy = y * y
    q1 = dx1 * dx1 + yy + E1
    q2 = dx2 * dx2 + yy + E2
    s1 = (1.0 - MU) / (q1 * np.sqrt(q1))
    s2 = MU / (q2 * np.sqrt(q2))
    return x - s1 * dx1 - s2 * dx2, y - (s1 + s2) * y


def _potential(x, y):
    r1 = np.sqrt((x + MU) ** 2 + y * y + E1)
    r2 = np.sqrt((x - 1.0 + MU) ** 2 + y * y + E2)
    return 0.5 * (x * x + y * y) + (1.0 - MU) / r1 + MU / r2


def _jacobi_window():
    """C at L4 and at L3, the two ends of the window the presets divide.

    L3 is a root of dW/dx on y = 0 and has no closed form -- it is one of the
    quintics Euler was left with in 1767. Bisection rather than Newton: it is a
    single scalar root found once, dW/dx is monotone between the singularities
    either side of it so the bracket cannot be wrong, and Newton would want
    guarding against the softened core. L4 is exact: r1 = r2 = 1 is an
    equilibrium for every mu, which is Lagrange's 1772 result and the reason
    the Trojans exist at all.

    Both are evaluated from the SOFTENED W, the same one the integrator uses.
    Softening moves each of them by 9e-4 and the width between them by 2e-6, so
    presets expressed as a fraction of the window are unmoved -- which is the
    argument for expressing them that way.
    """
    a, b, fa = -1.8, -0.2, _grad(np.float64(-1.8), np.float64(0.0))[0]
    for _ in range(120):
        m = 0.5 * (a + b)
        if (_grad(np.float64(m), np.float64(0.0))[0] > 0) == (fa > 0):
            a = m
        else:
            b = m
    l4 = 2.0 * _potential(0.5 - MU, np.sqrt(0.75))
    l3 = 2.0 * _potential(0.5 * (a + b), 0.0)
    return l4, l3


def _seed_on_curve(c, n, rng):
    """n points on the zero-velocity curve 2W = c, by Newton on the level set.

    Scatter candidates over the frame and push each one along grad W onto the
    curve: x <- x + (c/2 - W) grad W / |grad W|^2 is Newton's method for a
    scalar field and lands on whichever branch is nearest. Doing it this way
    rather than contouring means the seeding never has to know how many
    branches the chosen C has or where they are, which is the entire difference
    between the presets and would otherwise be four special cases. Candidates
    that stall near a Lagrange point, where the gradient vanishes and the
    method has nothing to descend, are dropped rather than nursed: they are a
    set of measure zero on the curve and their neighbours either side cover it.
    """
    span = 1.35 * EXTENT[1]
    xs, ys, got = [], [], 0
    while got < n:
        x = rng.uniform(-span, span, 4 * n)
        y = rng.uniform(-span, span, 4 * n)
        for _ in range(120):
            gx, gy = _grad(x, y)
            g2 = gx * gx + gy * gy
            # Cap the stride. Far from the curve the linear model is worthless
            # and an uncapped Newton step throws the candidate off the frame.
            step = (0.5 * c - _potential(x, y)) / np.maximum(g2, 1e-12)
            lim = 0.08 / np.sqrt(g2 + 1e-12)
            step = np.clip(step, -lim, lim)
            x = x + step * gx
            y = y + step * gy
        ok = (np.abs(2.0 * _potential(x, y) - c) < 1e-9) & (np.hypot(x, y) < span)
        xs.append(x[ok])
        ys.append(y[ok])
        got += int(ok.sum())
    return np.concatenate(xs)[:n], np.concatenate(ys)[:n]


def _deriv(p):
    x, y, vx, vy = p
    ax, ay = _grad(x, y)
    # Coriolis, and the reason the rotating frame earns its bookkeeping: it
    # does no work, so it leaves C alone while bending every path into an
    # epicycle. Without it there is no libration and no tadpole.
    return np.stack([vx, vy, ax + 2.0 * vy, ay - 2.0 * vx])


def generate(size, seed=0, ensemble=90, steps=22_000, dt=0.010, chunk=300):
    names = sorted(PRESETS)
    c4, c3 = _jacobi_window()
    c = c4 + PRESETS[names[seed % len(PRESETS)]] * (c3 - c4)

    rng = np.random.default_rng(seed)
    x, y = _seed_on_curve(c, ensemble, rng)
    p = np.stack([x, y, np.zeros(ensemble), np.zeros(ensemble)])

    # dt = 0.01 is six hundred steps to the orbit, and it can be that generous
    # because a co-orbital particle has almost no velocity relative to Jupiter
    # -- that is what C near 3 means, and it is the Tisserand criterion. The
    # only fast thing left in the problem is a deep pass, which the softening
    # above is sized to resolve. Accuracy matters here beyond the usual: C is
    # what draws the edges of the picture, so a stepper that leaked energy
    # would let particles soak across the zero-velocity curve and the cage
    # would blur shut.
    from lib import histogram2d
    field = np.zeros((size[1], size[0]))
    # Binned in blocks rather than at the end: the run is 1.2 GB of positions
    # and the histogram is the only thing any of them is wanted for. EXTENT is
    # passed on every call so the blocks land on identical bins and the sum is
    # the density of the whole run; letting histogram2d choose an extent per
    # block would give each one a different grid.
    buf = np.empty((chunk, 2, ensemble))
    held = 0

    def flush():
        nonlocal held
        if held:
            # zoom=1 because EXTENT is already the composition and not a
            # bounding box: it is placed so that Jupiter, L3 and the triangular
            # points land where they do, and cropping past it would push L4 and
            # L5 off the top and bottom edges.
            # path=True and NOT ravelled: buf is (step, coord, particle), so
            # axis 0 is time and each column is one particle's continuous
            # trajectory. Ravelling would join the end of one particle's arc to
            # the start of another's and draw a line between unrelated orbits;
            # depositing the points alone leaves the arcs as strings of dots
            # wherever a particle is moving fast, which near the primaries is
            # everywhere that matters.
            field[:] += histogram2d(
                buf[:held, 0], buf[:held, 1], size,
                extent=EXTENT, zoom=1.0, path=True,
            )
            held = 0

    for _ in range(steps):
        k1 = _deriv(p)
        k2 = _deriv(p + dt / 2 * k1)
        k3 = _deriv(p + dt / 2 * k2)
        k4 = _deriv(p + dt * k3)
        p = p + dt / 6 * (k1 + 2 * k2 + 2 * k3 + k4)
        buf[held] = p[:2]
        held += 1
        if held == chunk:
            flush()
    flush()
    return field
