"""Clifford attractor — an iterated map, not an ODE.

    x' = sin(a y) + c cos(a x)
    y' = sin(b x) + d cos(b y)

Two lines of arithmetic with no integrator, no timestep and no stability
question, iterated a few million times. What makes it worth having is that the
density is wildly non-uniform: the orbit returns to some regions constantly and
others almost never, and binning that produces filamentary structure at every
scale. It is the cheapest thing here and the most striking.

The parameters are the whole character of the image, and most of the parameter
space is either a blob or a line. The sets below were chosen for structure that
survives being blended down to a background.
"""

import numpy as np

# (a, b, c, d). Named so a seed choice is reproducible and reviewable rather
# than four magic floats.
# How far toward full colour this generator may be taken. A property of the
# GENERATOR, not of the renderer: a sparse attractor leaves most of the panel
# at background and can carry strong colour where it does land, while a
# space-filling field covers every pixel and has to be whispered or it fights
# every window on screen. One global value made the attractors dull and the
# reaction-diffusion unusable at the same time.
BLEND = 0.55

PRESETS = {
    "filament": (-1.4, 1.6, 1.0, 0.7),
    "shell": (1.7, 1.7, 0.6, 1.2),
    "ribbon": (-1.7, 1.3, -0.1, -1.21),
    "veil": (-1.8, -2.0, -0.5, -0.9),
}


def generate(size, seed=0, n=6_000_000):
    names = sorted(PRESETS)
    a, b, c, d = PRESETS[names[seed % len(names)]]

    # Iterate in float64 and in one vectorised pass over a chunked buffer:
    # six million python-level loop iterations would take minutes, and the
    # recurrence is inherently serial, so the compromise is to run the loop in
    # numpy over a block of points started from slightly different seeds. They
    # converge onto the same attractor -- that is what an attractor is -- so
    # the union is the same density, reached in a fraction of the time.
    rng = np.random.default_rng(seed)
    blocks = 2000
    per = max(1, n // blocks)
    x = rng.uniform(-1, 1, per)
    y = rng.uniform(-1, 1, per)

    xs = np.empty(blocks * per)
    ys = np.empty(blocks * per)
    for i in range(blocks):
        x, y = np.sin(a * y) + c * np.cos(a * x), np.sin(b * x) + d * np.cos(b * y)
        xs[i * per:(i + 1) * per] = x
        ys[i * per:(i + 1) * per] = y

    from lib import histogram2d
    return histogram2d(xs, ys, size)
