"""Clifford attractor — an iterated map, not an ODE.

    x' = sin(a y) + c cos(a x)
    y' = sin(b x) + d cos(b y)

Two lines of arithmetic with no integrator, no timestep and no stability
question, iterated billions of times. What makes it worth having is that the
density is wildly non-uniform: the orbit returns to some regions constantly and
others almost never, and that is the picture.

The parameters ARE the image -- most of the parameter space is a blob or a
line. The sets below were chosen for structure that survives being blended
down to a background.

RENDERING, which took three attempts to get right:

  * Points are accumulated into the histogram in blocks and never all held at
    once. Two billion points is 32 GB of float64; the histogram is 200 MB
    regardless of how many points go into it.
  * Work is split across every core. The recurrence is serial per orbit, but
    an attractor does not care which orbit you follow -- independent workers
    started from different seeds converge onto the same set, so their
    histograms simply add.
  * The supersampled histogram is Gaussian-blurred BEFORE downsampling. This
    is what removes the visible dots. No sample count fixes them on its own:
    a hard-binned histogram is Poisson in every cell, so the sparse outer
    filaments are specks, and the gamma applied at render time amplifies
    exactly those cells.
"""

import os

import numpy as np

TITLE = "Clifford attractor"
SUBTITLE = "x' = sin(ay) + c cos(ax),  y' = sin(bx) + d cos(by)"

BLEND = 0.75

# Log density. The orbit visits the core orders of magnitude more often than
# the outer filaments, so a linear scale renders the core as a saturated slab
# and the strands -- the thing worth looking at -- as barely-there speckle.
SCALE = "log"

# (a, b, c, d).
PRESETS = {
    "filament": (-1.4, 1.6, 1.0, 0.7),
    "shell": (1.7, 1.7, 0.6, 1.2),
    "ribbon": (-1.7, 1.3, -0.1, -1.21),
    "veil": (-1.8, -2.0, -0.5, -0.9),
}


def _orbit(params, rng, walkers, iters):
    """Iterate `walkers` orbits `iters` times, yielding each step's points."""
    a, b, c, d = params
    x = rng.uniform(-1.5, 1.5, walkers)
    y = rng.uniform(-1.5, 1.5, walkers)
    for _ in range(80):        # burn in onto the attractor
        x, y = np.sin(a * y) + c * np.cos(a * x), np.sin(b * x) + d * np.cos(b * y)
    for _ in range(iters):
        x, y = np.sin(a * y) + c * np.cos(a * x), np.sin(b * x) + d * np.cos(b * y)
        yield x, y


def _worker(args):
    params, seed, walkers, iters, rng_range, shape = args
    x0, x1, y0, y1 = rng_range
    hh, ww = shape
    acc = np.zeros((hh, ww), dtype=np.float32)
    rng = np.random.default_rng(seed)

    # Points are BUFFERED and binned in large batches. np.histogram2d
    # allocates its full output array on every call, so binning each step of
    # 20k points into a 3840x2400 grid allocated 73 MB thousands of times per
    # worker and spent all its time in the allocator rather than in the map.
    # Batching to a few million points makes that cost negligible.
    BATCH = 4_000_000
    bx, by, held = [], [], 0

    def flush():
        nonlocal bx, by, held
        if not held:
            return
        h, _, _ = np.histogram2d(np.concatenate(by), np.concatenate(bx),
                                 bins=(hh, ww), range=[[y0, y1], [x0, x1]])
        acc[:] += h.astype(np.float32)
        bx, by, held = [], [], 0

    for xs, ys in _orbit(params, rng, walkers, iters):
        bx.append(xs); by.append(ys); held += xs.size
        if held >= BATCH:
            flush()
    flush()
    return acc


def generate(size, seed=0, n=2_000_000_000, fit="contain", zoom=1.0,
             ss=3, sigma=1.6, jobs=None):
    from lib import frame, smooth, downsample

    names = sorted(PRESETS)
    params = PRESETS[names[seed % len(PRESETS)]]

    # The window, from a cheap sample. Doing this first is what lets the main
    # accumulation run at a fixed range in bounded memory.
    rng = np.random.default_rng(seed)
    sx, sy = [], []
    for x, y in _orbit(params, rng, 4000, 60):
        sx.append(x); sy.append(y)
    sx = np.concatenate(sx); sy = np.concatenate(sy)
    x0, x1, y0, y1 = frame(sx, sy, size, fit=fit, zoom=zoom)

    w, h = size
    hh, ww = h * ss, w * ss

    jobs = jobs or min(os.cpu_count() or 4, 16)
    walkers = 100_000
    iters = max(1, n // (jobs * walkers))

    work = [(params, seed * 1000 + j, walkers, iters, (x0, x1, y0, y1), (hh, ww))
            for j in range(jobs)]

    # One process per core. Each returns a float32 histogram of the same shape
    # and they are summed -- the attractor is the same set whichever orbit
    # found it.
    if jobs > 1:
        import multiprocessing as mp
        with mp.Pool(jobs) as pool:
            field = None
            for part in pool.imap_unordered(_worker, work):
                field = part if field is None else field + part
    else:
        field = _worker(work[0])

    field = smooth(field, sigma)
    return downsample(field, ss)
