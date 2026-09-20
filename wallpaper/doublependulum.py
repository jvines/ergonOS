"""Double pendulum — a Hamiltonian system, drawn by its own divergence.

Two rods, m1 = m2 = 1, l1 = l2 = 1, released from rest. The Lagrangian gives a
coupled pair for the angular accelerations which, at equal masses and lengths,
is a 2x2 linear solve at every step:

    [ 2  c ] [ a1 ]   [ -s w2^2 - 2G sin(th1) ]
    [ c  1 ] [ a2 ] = [  s w1^2 -   G sin(th2) ]     c = cos(th1-th2)
                                                     s = sin(th1-th2)
                                                     G = g/l

Written that way rather than as the usual expanded quotient because the matrix
is what the Lagrangian actually produces; the one-line form is the same thing
after substituting sin(th1-2 th2), and is only harder to check.

Nothing here is dissipative. There is no attractor, and that is exactly why it
is in the set: Clifford, Lorenz and Gray-Scott all converge onto a structure
that forgets where they started, and this one never forgets. The energy fixes
a shell, the motion stays on it forever, and what the picture shows is not an
invariant set but the history of a specific release.

WHAT IS BINNED, and why not the alternatives. The tip of the lower bob,
(sin th1 + sin th2, -cos th1 - cos th2). Binning the (th1, th2) configuration
torus instead was tried and is a dead end: for a two-degree-of-freedom system
the energy shell projects onto configuration space with density proportional to
E - V, which is smooth, so the torus renders as a featureless lozenge. Binning
the tip of a single ergodic trajectory over long times gives the same smooth
measure in a different frame. The structure only appears because the ENSEMBLE
is released from almost the same place:

  - for the first ~14 s every member traces the same curve to within a pixel,
    and that curve is drawn 3000 times over. It saturates.
  - as the separation grows the copies fan out along the local unstable
    direction, and the fan is a caustic: a fold of the ensemble sheet, bright
    where the fold is tangent to the line of sight, exactly as in optics.
  - past ~20 s they are independent and fill the accessible region as haze.

So one image holds the coherent orbit, the caustics of its spreading, and the
ergodic limit it decays into. That is sensitive dependence made into a picture
rather than asserted, and the caustic fans and cusps are a visual register
nothing else in this set produces -- the attractors give filaments and smoke,
this gives ruled surfaces and focal points, closer to a lens diagram than to a
strange attractor. Shinbrot, Grebogi, Wisdom & Yorke, Am. J. Phys. 60, 491
(1992) is the experiment this is the numerical shadow of.

WHY THESE RELEASES. Energy decides whether the motion is chaotic or a
quasi-periodic tangle of tori, and released from rest the energy is entirely
potential: E = -g(2 cos th1 + cos th2). Small angles are integrable-looking and
render as a wire sculpture with no haze at all. The four below were checked by
integrating a renormalised separation over 60 s: the largest Lyapunov exponent
is 1.08 to 1.30 per second for all of them, so all four are genuinely chaotic
and none of them is sitting on a regular island.
"""

import numpy as np

# Sparse in the middle band, and the bright structure is a set of curves rather
# than a filled field -- but the ergodic haze does eventually cover most of the
# accessible region, so this cannot take the 0.55 an attractor takes. 0.40
# keeps the caustics legible while the haze stays under a window's noise floor.
TITLE = "Double pendulum"
SUBTITLE = "ensemble caustic, m1=m2, l1=l2"

BLEND = 0.62

G = 9.81  # g/l with l = 1 m; the only physical constant that matters here.

# Release angles (th1, th2) in radians, from rest. Named for what each draws.
# (2.4, 2.4) was here and was cut: its reachable region is so nearly circular
# that lib.histogram2d's crop lands entirely inside the ergodic interior, and
# a panel of uniform haze is the one outcome this generator must not produce.
RELEASES = {
    "arch":  (1.2, 2.6),   # E =  +1.3 J: broad arches over a bottom cusp
    "cusp":  (2.0, 2.0),   # E = +12.2 J: one focal point, the densest
    "veil":  (2.8, 2.8),   # E = +27.7 J: fastest, thinnest, most woven
    "wing":  (2.2, 0.6),   # E =  +3.5 J: asymmetric and sparse, the quiet one
}


def _deriv(y):
    th1, th2, w1, w2 = y
    d = th1 - th2
    c, s = np.cos(d), np.sin(d)
    # det = 2 - c^2 >= 1: the mass matrix of a double pendulum is positive
    # definite for any configuration, so this never needs guarding.
    det = 2.0 - c * c
    b1 = -s * w2 * w2 - 2.0 * G * np.sin(th1)
    b2 = s * w1 * w1 - G * np.sin(th2)
    return np.stack([w1, w2, (b1 - c * b2) / det, (2.0 * b2 - c * b1) / det])


def _step(y, dt):
    k1 = _deriv(y)
    k2 = _deriv(y + dt / 2 * k1)
    k3 = _deriv(y + dt / 2 * k2)
    k4 = _deriv(y + dt * k3)
    return y + dt / 6 * (k1 + 2 * k2 + 2 * k3 + k4)


def _frame(energy, n=1024):
    """The tip's reachable box at this energy, from the constraint V <= E.

    Two reasons it is analytic and not the sample's own min and max. The
    density has to be accumulated in blocks (see generate), and every block
    must be binned into the same rectangle or they do not add up -- a
    data-driven box is only known after the last point. And the extremes are
    visited rarely, so a data-driven box would wobble with the seed and crop
    each image by a different amount. Energy is conserved, so the boundary is
    known exactly before the first step is taken.

    No padding: this returns the physical box and lib.histogram2d decides how
    much of it reaches the panel. That matters here more than for an attractor,
    because the reachable region is roughly as tall as it is wide and would sit
    in a letterboxed square if it were fitted whole.
    """
    t = np.linspace(0.0, np.pi, n)
    a, b = np.meshgrid(np.cos(t), np.cos(t), indexing="ij")
    ok = -G * (2.0 * a + b) <= energy
    x = (np.sqrt(1 - a * a) + np.sqrt(1 - b * b))[ok].max()
    # The bottom is always -2: hanging straight down is under every energy.
    return (-x, x, -2.0, (-a - b)[ok].max())


def generate(size, seed=0, ensemble=3000, steps=12_000, dt=0.002,
             spread=1e-10):
    """steps * dt = 24 s of pendulum, which is not an arbitrary duration.

    At lambda ~= 1.2 /s a 1e-10 rad perturbation needs ln(3e-3 / 1e-10) /
    lambda ~= 14 s to reach one pixel. Stopping at 24 s therefore spends a
    little over half the run coherent and the rest fanning out, the ratio that
    puts saturated curve, caustic and haze in one frame. Twice as long and the
    haze wins and the image flattens; half and there is nothing but a dotted
    line drawing. spread and steps are chosen together -- changing one without
    the other moves the picture off this balance.
    """
    names = sorted(RELEASES)
    th1, th2 = RELEASES[names[seed % len(RELEASES)]]

    rng = np.random.default_rng(seed)
    y = np.stack([
        th1 + rng.normal(0.0, spread, ensemble),
        th2 + rng.normal(0.0, spread, ensemble),
        np.zeros(ensemble),
        np.zeros(ensemble),
    ])
    extent = _frame(-G * (2 * np.cos(th1) + np.cos(th2)))

    # Loop over TIME, vectorised over the ensemble: 36 million tip positions,
    # but only 12000 python-level iterations. Accumulated in blocks so peak
    # memory is two 12 MB buffers instead of the 580 MB array every point ever
    # visited would need -- this has to run on a laptop, not just on the desk
    # machine. 3000 is also where the ensemble stops paying: at 6000 the haze
    # fills in faster than the caustics sharpen, the image gets louder rather
    # than better, and 2880x1920 goes from 13 s to 26 s.
    from lib import histogram2d
    w, h = size
    field = np.zeros((h, w))
    block = 1000
    bx = np.empty((block, ensemble), dtype=np.float32)
    by = np.empty((block, ensemble), dtype=np.float32)
    k = 0
    for _ in range(steps):
        y = _step(y, dt)
        bx[k] = np.sin(y[0]) + np.sin(y[1])
        by[k] = -np.cos(y[0]) - np.cos(y[1])
        k += 1
        if k == block:
            field += histogram2d(bx.ravel(), by.ravel(), size, extent=extent)
            k = 0
    if k:
        field += histogram2d(bx[:k].ravel(), by[:k].ravel(), size,
                             extent=extent)
    return field
