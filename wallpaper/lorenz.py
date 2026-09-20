"""Lorenz attractor — the canonical chaotic ODE.

    dx/dt = s (y - x)
    dy/dt = x (r - z) - y
    dz/dt = x y - b z

with s=10, r=28, b=8/3: Lorenz's own 1963 values, the ones that produce the
butterfly. Classical RK4 at a fixed step rather than an adaptive solver --
nobody is going to quote this result, and a fixed step keeps the sample density
uniform in time, which is what makes the density meaningful rather than an
artefact of where the stepper chose to slow down.

THREE trajectories, integrated a long way -- not a large ensemble.

A big ensemble was tried first and is wrong for this picture. It samples the
invariant measure beautifully and renders as a filled smear: with twelve
thousand orbits every part of the attractor is visited by something at every
moment, so the sheet fills in solid and the structure that makes a Lorenz plot
worth looking at -- the individual loops, the spiral bands winding out from
each fixed point, the thin ribbon where the trajectory crosses between lobes --
is averaged away. Statistically better, visually mush.

Few orbits followed a long way give the opposite: you see the winding, because
you are looking at a CURVE rather than at a density. The drawing is what makes
this affordable -- deposit_path subdivides each step to sub-pixel spacing, so
160k steps draw as continuous line rather than 160k dots.
"""

import numpy as np

TITLE = "Lorenz attractor"
SUBTITLE = "3 orbits, t=120,  sigma=10, rho=28, beta=8/3   (Lorenz 1963)"

# 3 orbits over t=120, roughly 420 loops. Chosen by looking, and the number
# matters more than it sounds: at 4 orbits x t=624 the passes overlap into a
# hatch and the attractor reads as a smear, while one orbit over t=60 is too
# sparse to show the sheet. GAMMA 0.4 with it -- at 1.0 the median lit pixel
# sits at 0.18 of the ramp, which is its dark end, so the palette's upper half
# never appears and the whole image comes out one colour.

# zscale, the IRAF/DS9 stretch. These density fields have the same shape as an
# astronomical frame -- a core orders of magnitude brighter than the structure
# worth seeing -- and zscale is the algorithm built for exactly that. Measured
# on this attractor it chose z2 = 422 against a field maximum of 10914: it
# saturates the core by a factor of 25 and gives the whole display range to the
# filaments. A percentile clip cannot do that, and log flattens the density
# ridges that ARE the filaments.
SCALE = "zscale"
GAMMA = 0.4

BLEND = 0.78

# Log density: the lobes are orders of magnitude denser than the sheet between
# them, so a linear scale renders the butterfly as one solid blob. See
# lib.normalise.


VIEWS = ["xz", "yz", "xy"]


def generate(size, seed=0, ensemble=3, steps=48_000, dt=0.0025, burn=3000):
    s, r, b = 10.0, 28.0, 8.0 / 3.0

    def deriv(p):
        x, y, z = p
        return np.stack([s * (y - x), x * (r - z) - y, x * y - b * z])

    def step(p):
        k1 = deriv(p)
        k2 = deriv(p + dt / 2 * k1)
        k3 = deriv(p + dt / 2 * k2)
        k4 = deriv(p + dt * k3)
        return p + dt / 6 * (k1 + 2 * k2 + 2 * k3 + k4)

    rng = np.random.default_rng(seed)
    # (3, ensemble): the leading axis is the state vector so deriv stays
    # readable as x, y, z.
    p = np.stack([
        rng.uniform(-15, 15, ensemble),
        rng.uniform(-20, 20, ensemble),
        rng.uniform(5, 40, ensemble),
    ])

    # Burn in: the initial cloud is not on the attractor and its approach is
    # not part of the structure. A shared burn also decorrelates the ensemble.
    for _ in range(burn):
        p = step(p)

    pts = np.empty((steps, 3, ensemble))
    for i in range(steps):
        p = step(p)
        pts[i] = p

    view = VIEWS[seed % len(VIEWS)]
    idx = {"x": 0, "y": 1, "z": 2}
    # NOT ravelled: kept as (steps, ensemble) so each column is one continuous
    # trajectory and the drawing joins consecutive states of the SAME orbit.
    xs = pts[:, idx[view[0]], :]
    ys = pts[:, idx[view[1]], :]

    from lib import histogram2d
    # zoom 1.0: the butterfly IS the picture, and cropping past its bounding
    # box cuts the tops off both lobes.
    return histogram2d(xs, ys, size, path=True, zoom=1.0)
