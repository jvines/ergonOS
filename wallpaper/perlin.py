"""Perlin noise -- streamlines of a flow whose direction is gradient noise.

Perlin's gradient noise (1985; the "improved" fade, 2002) is the standard way
to make a random function that is smooth. A random unit vector is pinned to
every integer lattice point, and the value anywhere is the blend of the four
surrounding corners' dot products with the offset to that corner, weighted by
the quintic fade 6t^5 - 15t^4 + 10t^3 so the result has continuous first and
second derivatives. It is zero on the lattice and has no preferred feature
size but one: the lattice spacing. Summing octaves at doubling frequency and
halving amplitude -- fractional Brownian motion -- gives structure at every
scale, the way terrain and clouds have it.

What is drawn here is not the noise but a flow through it. The noise is read
as a DIRECTION, theta = 2 pi k fbm(x, y), and long streamlines are traced
through that direction field from seeds spread over the panel. A direction
field with no divergence constraint has sinks: neighbouring streamlines are
pulled together along them, so the lines gather into bundles and ribbons, and
where the field turns they fan out again. That gathering is the picture.

The flow is DOMAIN-WARPED (Quilez): the noise is evaluated not at p but at
p + w q(p), where q is itself a pair of fbm fields. Warping bends the
straight-ish lanes of plain fbm into eddies and hooks, which is what makes it
read as a fluid rather than as combed hair.

RENDERING, following what the attractors taught:

  * Few long lines rather than many short ones; each is traced forwards and
    backwards from its seed for a large fraction of the panel.
  * Each line is splatted bilinearly and TAPERED -- its weight rises and falls
    as a sine over its length -- so lines fade in and out like brush strokes
    instead of ending in hard stubs.
  * Steps are shorter than a supersampled pixel, so the drawn path is
    continuous without needing to be subdivided.
  * Traced in parallel across bands of seeds; the bands' fields simply add.
"""

import os

import numpy as np

TITLE = "Perlin noise"
SUBTITLE = "streamlines of a flow whose direction is domain-warped fractal gradient noise"

# Lines on empty ground, so the house treatment for lines: zscale fitted on the
# lit pixels, full ramp, 2.25 / 1.1. A lone line lands on teal; where the flow
# gathers lines into a bundle the density climbs through blue to pink, so the
# colour marks the drainage network rather than decorating it. Gamma 0.5 keeps
# single lines bright enough to read at 4K; they are a third of a pixel wide
# before SOFTEN.
SCALE = "zscale"
GAMMA = 0.5
BLEND = 0.85
SOFTEN = 0.8
HUE_SMOOTH = 3.0
# The domain-warped fbm drawn directly as a field was tried first and rejected
# on sight: equalised over the ramp it is tie-dye, a soft screen-filling blur
# with nothing for the eye to follow.

_N = 1024                     # lattice period; far larger than the panel needs


def _tables(seed):
    """Permutation and gradient tables for one noise function."""
    rng = np.random.default_rng(seed)
    p = rng.permutation(_N)
    ang = rng.uniform(0, 2 * np.pi, _N)
    return np.concatenate([p, p]), np.cos(ang), np.sin(ang)


def _fade(t):
    return t * t * t * (t * (t * 6 - 15) + 10)


def noise(x, y, tab):
    """2-D gradient noise at arbitrary points, vectorised. Range ~[-1, 1]."""
    P, GX, GY = tab
    xf, yf = np.floor(x), np.floor(y)
    fx, fy = x - xf, y - yf
    xi = xf.astype(np.int64) & (_N - 1)
    yi = yf.astype(np.int64) & (_N - 1)
    u, v = _fade(fx), _fade(fy)
    a, b = P[xi], P[xi + 1]

    def corner(h, dx, dy):
        return GX[h] * dx + GY[h] * dy
    n00 = corner(P[a + yi], fx, fy)
    n10 = corner(P[b + yi], fx - 1, fy)
    n01 = corner(P[a + yi + 1], fx, fy - 1)
    n11 = corner(P[b + yi + 1], fx - 1, fy - 1)
    top = n00 + (n10 - n00) * u
    bot = n01 + (n11 - n01) * u
    return (top + (bot - top) * v) * np.sqrt(2)


def fbm(x, y, tab, octaves=5, gain=0.5):
    """Fractional Brownian motion: octaves at doubling frequency.

    Each octave is rotated by an irrational-ish angle and offset, so the
    lattices of different octaves never line up -- aligned lattices leave a
    faint grid in the sum that the eye finds at once.
    """
    out = np.zeros_like(x)
    amp, f, norm = 1.0, 1.0, 0.0
    c, s = np.cos(0.6435), np.sin(0.6435)      # the 3-4-5 triangle's angle
    rx, ry = x, y
    for k in range(octaves):
        out += amp * noise(rx * f + 17.3 * k, ry * f - 31.7 * k, tab)
        norm += amp
        amp *= gain; f *= 2.0
        rx, ry = c * rx - s * ry, s * rx + c * ry
    return out / norm


# A preset: noise cells per panel
# height, turning (theta spans 2 pi k times the fbm's range), warp strength,
# how many lines, and each line's run as a fraction of the panel width.
#
# Chosen from a grid at 4K. Stronger warp (3.0) crumpled the flow into
# something like creased paper; more turning (k 2.5 to 3.5) did not wind the
# lines into spirals as hoped, it crinkled them. 3000 lines is about the most
# before the gaps between bundles close up and the ground stops showing.
# Pruned after being shown: "bold" (cells 1.2, k 1.3, warp 2.0, 3000 lines,
# length 0.7), a denser network; and "fine" (cells 1.6, k 1.0, warp 1.4, 1500
# lines, length 1.0), the most open. Their pictures were good but the same
# kind of picture as broad.
PRESETS = [
    # Broad: under one cell per screen height, so a few big basins, each
    # draining into a pink trunk with tributaries fanning out of it.
    dict(cells=0.9, k=1.0, warp=2.5, lines=2000, length=0.7),
]


def _angle(x, y, tabs, g):
    """Flow direction at noise coordinates (x, y): warped fbm, as an angle."""
    qx = fbm(x, y, tabs[1], 4)
    qy = fbm(x + 5.2, y + 1.3, tabs[1], 4)
    return 2 * np.pi * g["k"] * fbm(x + g["warp"] * qx, y + g["warp"] * qy, tabs[0], 5)


def _splat(px, py, wt, shape, acc):
    """Weighted bilinear deposit in pixel coordinates, one bincount."""
    h, w = shape
    fx, fy = px - 0.5, py - 0.5
    ok = (fx >= 0) & (fx < w - 1) & (fy >= 0) & (fy < h - 1)
    fx, fy, wt = fx[ok], fy[ok], wt[ok]
    ix, iy = fx.astype(np.int64), fy.astype(np.int64)
    tx, ty = fx - ix, fy - iy
    i = iy * w + ix
    acc += np.bincount(np.concatenate([i, i + 1, i + w, i + w + 1]),
                       np.concatenate([wt * (1 - tx) * (1 - ty), wt * tx * (1 - ty),
                                       wt * (1 - tx) * ty, wt * tx * ty]),
                       minlength=h * w)


def _trace(args):
    """Trace one band of seeds both ways; return that band's field."""
    g, seed, sx, sy, shape, half, h_step = args
    h, w = shape
    tabs = (_tables(seed), _tables(seed + 7919))
    to_noise = g["cells"] / h                   # pixels -> noise units
    acc = np.zeros(h * w, dtype=np.float32)
    np.seterr(all="ignore")
    for sgn in (1.0, -1.0):
        x, y = sx.copy(), sy.copy()
        bx, by, bw = [], [], []
        for j in range(half):
            # Midpoint (RK2): a streamline, not a polyline that cuts corners.
            a = _angle(x * to_noise, y * to_noise, tabs, g)
            mx, my = x + 0.5 * sgn * h_step * np.cos(a), y + 0.5 * sgn * h_step * np.sin(a)
            a = _angle(mx * to_noise, my * to_noise, tabs, g)
            x, y = x + sgn * h_step * np.cos(a), y + sgn * h_step * np.sin(a)
            # Taper over the whole line (backward half, then forward), so the
            # ends fade to nothing rather than stopping.
            i = half + j if sgn > 0 else half - 1 - j
            bx.append(x); by.append(y)
            bw.append(np.full(x.size, np.sin(np.pi * (i + 0.5) / (2 * half))))
            if len(bx) * x.size >= 4_000_000 or j == half - 1:
                _splat(np.concatenate(bx), np.concatenate(by), np.concatenate(bw),
                       shape, acc)
                bx, by, bw = [], [], []
    return acc


# (preset, noise seed) for each background offered. The noise seed is part of
# the picture -- it drew these particular basins -- so it is pinned here and
# pruning never changes a picture that was kept.
FLOWS = [(0, 3)]


def generate(size, seed=0, jobs=None, length=None, step=0.6):
    """size is the supersampled (w, h). length overrides the preset's run.
    step is in supersampled pixels, under one so the path needs no
    subdivision; the path is the same curve at any resolution, because the
    noise is scaled to the panel height."""
    w, h = size
    preset, noise_seed = FLOWS[seed % len(FLOWS)]
    g = PRESETS[preset]
    length = g["length"] if length is None else length
    rng = np.random.default_rng(noise_seed)
    # Seeds spread a little past the edges: lines born just outside flow in,
    # so the borders are not thinner than the middle.
    n = g["lines"]
    sx = rng.uniform(-0.1, 1.1, n) * w
    sy = rng.uniform(-0.1, 1.1, n) * h
    half = int(length * w / step / 2)
    jobs = jobs or min(os.cpu_count() or 4, 16)
    bands = np.array_split(np.arange(n), jobs)
    work = [(g, noise_seed, sx[b], sy[b], (h, w), half, step) for b in bands]
    import multiprocessing as mp
    with mp.Pool(jobs) as pool:
        acc = None
        for part in pool.imap_unordered(_trace, work):
            acc = part if acc is None else acc + part
    return acc.reshape(h, w)
