"""Gray-Scott reaction-diffusion — a PDE, not an attractor.

    du/dt = Du lap(u) - u v^2 + F (1 - u)
    dv/dt = Dv lap(v) + u v^2 - (F + k) v

Two chemicals, one feeding on the other. Unlike the attractors here this has no
trajectory and no density: it is a field evolving in place, and what you see is
the pattern it settles into. That is the point of including it -- attractors
all look like attractors, and a wallpaper set needs a family that does not.

(F, k) decides everything. The presets are the named regions of Pearson's 1993
classification; a few percent away from them the field either dies to uniform u
or fills solid, with the interesting behaviour on a knife edge between.

Explicit Euler with a five-point Laplacian. Crude, and correct here: the
timestep is well inside the stability limit for this diffusion rate, and an
implicit scheme would be more code for a picture.
"""

import numpy as np

# (feed, kill), after Pearson's letters for the regimes.
TITLE = "Gray-Scott reaction-diffusion"
SUBTITLE = "two chemicals, one feeding on the other"

BLEND = 0.34

PRESETS = {
    "coral":    (0.0545, 0.0620),
    "mitosis":  (0.0367, 0.0649),
    "solitons": (0.0300, 0.0620),
    "maze":     (0.0290, 0.0570),
}


def _laplacian(a):
    # Periodic boundaries via roll: the wallpaper tiles conceptually and a
    # zero-flux edge would leave a visible frame of different texture.
    return (
        np.roll(a, 1, 0) + np.roll(a, -1, 0)
        + np.roll(a, 1, 1) + np.roll(a, -1, 1)
        - 4 * a
    )


def generate(size, seed=0, steps=6000, scale=3):
    names = sorted(PRESETS)
    feed, kill = PRESETS[names[seed % len(PRESETS)]]
    du, dv, dt = 0.16, 0.08, 1.0

    # Simulated at a fraction of the panel size and scaled up at the end. The
    # pattern has an intrinsic length scale set by the diffusion rates, so
    # simulating at full 4K resolution does not produce more detail -- it
    # produces the same pattern with more pixels per feature, and takes
    # sixteen times as long.
    w, h = size
    gw, gh = max(64, w // scale), max(64, h // scale)

    u = np.ones((gh, gw))
    v = np.zeros((gh, gw))

    # Seed with a few random blobs. A single central blob gives a symmetric
    # pattern that reads as a target rather than as a texture.
    rng = np.random.default_rng(seed)
    for _ in range(20):
        cy, cx = rng.integers(0, gh), rng.integers(0, gw)
        r = max(3, min(gh, gw) // 40)
        ys, xs = np.ogrid[-cy:gh - cy, -cx:gw - cx]
        mask = xs * xs + ys * ys <= r * r
        u[mask] = 0.50
        v[mask] = 0.25
    v += rng.random((gh, gw)) * 0.02

    for _ in range(steps):
        uvv = u * v * v
        u += dt * (du * _laplacian(u) - uvv + feed * (1 - u))
        v += dt * (dv * _laplacian(v) + uvv - (feed + kill) * v)

    # v is the pattern-forming species; u is its negative.
    field = v
    # Nearest-neighbour upscale. Smooth interpolation would blur exactly the
    # sharp fronts that make the pattern legible at a distance.
    field = np.repeat(np.repeat(field, scale, 0), scale, 1)[:h, :w]
    if field.shape != (h, w):
        out = np.zeros((h, w))
        out[:field.shape[0], :field.shape[1]] = field
        field = out
    return field
