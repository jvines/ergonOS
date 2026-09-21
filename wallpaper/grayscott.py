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

# The look chosen on a real desktop: ranked (screen-filling, and its values
# bunch), mauve into pink, softer than the line-on-ground house values. The
# stripes sit on the desktop colour because generate() subtracts the level
# between them (see there).
SCALE = "equalize"
GAMMA = 1.8
RAMP = "warm"
SATURATION = 1.5
EXPOSURE = 0.95
BLEND = 0.85

# A simulation cell as a fraction of the panel height: 3 px at 2400.
CELL = 3.0 / 2400
# Seed blobs one per SPACING x SPACING cells.
SPACING = 60
# The field is a coarse simulation, upscaled smoothly: already band-limited.
SUPERSAMPLE = 1

# (feed, kill, random seed of the starting blobs -- part of the picture, so
# pinned). Only the regime chosen on a real desktop is here; coral (0.0545,
# 0.0620), mitosis (0.0367, 0.0649) and solitons (0.0300, 0.0620) were
# rendered and pruned.
PRESETS = {
    "maze":     (0.0290, 0.0570, 1),
}


def _laplacian(a):
    # Periodic boundaries via roll: the wallpaper tiles conceptually and a
    # zero-flux edge would leave a visible frame of different texture.
    return (
        np.roll(a, 1, 0) + np.roll(a, -1, 0)
        + np.roll(a, 1, 1) + np.roll(a, -1, 1)
        - 4 * a
    )


def _upscale(a, h, w):
    """Bilinear, periodic, from the simulation grid to (h, w).

    It was nearest-neighbour, to keep the fronts sharp -- and at 3 px a cell
    that printed every front as a staircase of 3-px blocks, the one artefact
    rejected everywhere else in this set. The fronts are a few cells wide in
    the simulation itself, so bilinear keeps them crisp at panel scale."""
    gh, gw = a.shape
    y = (np.arange(h) + 0.5) * gh / h - 0.5
    x = (np.arange(w) + 0.5) * gw / w - 0.5
    y0, x0 = np.floor(y).astype(int), np.floor(x).astype(int)
    fy, fx = (y - y0)[:, None], (x - x0)[None, :]
    y0, y1 = y0 % gh, (y0 + 1) % gh
    x0, x1 = x0 % gw, (x0 + 1) % gw
    top = a[y0][:, x0] * (1 - fx) + a[y0][:, x1] * fx
    bot = a[y1][:, x0] * (1 - fx) + a[y1][:, x1] * fx
    return top * (1 - fy) + bot * fy


def generate(size, seed=0, steps=20000, cell=None):
    names = sorted(PRESETS)
    feed, kill, blob_seed = PRESETS[names[seed % len(PRESETS)]]
    du, dv, dt = 0.16, 0.08, 1.0

    # Simulated at a fraction of the panel size and scaled up at the end. The
    # pattern has an intrinsic length scale set by the diffusion rates, so
    # simulating at full 4K resolution does not produce more detail -- it
    # produces the same pattern with more pixels per feature, and takes
    # sixteen times as long. The cell is a fraction of the panel HEIGHT, not a
    # pixel count, so a supersampled or 8K render is the same picture.
    w, h = size
    scale = max(1, round((cell or CELL) * h))
    gw, gh = max(64, w // scale), max(64, h // scale)

    # float32: the loop is memory-bound, and twenty thousand steps over a
    # million cells in float64 took twice as long for the same picture.
    u = np.ones((gh, gw), np.float32)
    v = np.zeros((gh, gw), np.float32)

    # Seed the WHOLE panel: a blob every ~SPACING cells, jittered. Twenty
    # random blobs left most of the panel empty after 6000 steps -- the slow
    # regimes (mitosis) grow about a cell per hundred steps, so one surviving
    # cluster sat alone on a dark screen. Seeded everywhere, the pattern forms
    # everywhere at once and the steps go into letting it mature.
    rng = np.random.default_rng(blob_seed)
    n = max(20, int(gw * gh / SPACING ** 2))
    r = 3
    for _ in range(n):
        cy, cx = rng.integers(0, gh), rng.integers(0, gw)
        ys, xs = np.ogrid[-cy:gh - cy, -cx:gw - cx]
        mask = xs * xs + ys * ys <= r * r
        u[mask] = 0.50
        v[mask] = 0.25
    v += (rng.random((gh, gw)) * 0.02).astype(np.float32)

    for _ in range(steps):
        uvv = u * v * v
        u += dt * (du * _laplacian(u) - uvv + feed * (1 - u))
        v += dt * (dv * _laplacian(v) + uvv - (feed + kill) * v)

    # v is the pattern-forming species; u is its negative. The level between
    # the stripes is not zero -- v settles to a small background -- and drawn
    # as it is, the gaps took colour too and the panel was flooded end to end.
    # Subtracting it puts the gaps on the desktop colour.
    v = v - np.quantile(v, 0.25)
    return np.clip(_upscale(v.astype(np.float64), h, w), 0.0, None)
