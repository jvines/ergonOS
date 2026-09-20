"""Lorenz attractor — the canonical chaotic ODE.

    dx/dt = s (y - x)
    dy/dt = x (r - z) - y
    dz/dt = x y - b z

with s=10, r=28, b=8/3: Lorenz's own 1963 values, the ones that produce the
butterfly. Classical RK4 at a fixed step rather than an adaptive solver --
nobody is going to quote this result, and a fixed step keeps the sample density
uniform in time, which is what makes the density meaningful rather than an
artefact of where the stepper chose to slow down.

An ENSEMBLE is integrated, not one long trajectory. Stepping a single
trajectory four million times means four million Python-level iterations and
takes minutes; stepping ten thousand trajectories four hundred times each is
the same number of points, vectorises in numpy, and finishes in seconds. It is
also the better object: the union of many trajectories samples the attractor's
invariant measure directly, where one path only approaches it.
"""

import numpy as np

TITLE = "Lorenz attractor"
SUBTITLE = "sigma=10, rho=28, beta=8/3   (Lorenz 1963)"

BLEND = 0.78

# Log density: the lobes are orders of magnitude denser than the sheet between
# them, so a linear scale renders the butterfly as one solid blob. See
# lib.normalise.
SCALE = "linear"

VIEWS = ["xz", "yz", "xy"]


def generate(size, seed=0, ensemble=400, steps=40_000, dt=0.0018, burn=2000):
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
    xs = pts[:, idx[view[0]], :].ravel()
    ys = pts[:, idx[view[1]], :].ravel()

    from lib import histogram2d
    return histogram2d(xs, ys, size)
