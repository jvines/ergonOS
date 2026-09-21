"""Ikeda map -- light going round a ring cavity with a nonlinear medium in it.

    z' = 1 + u z exp(i t),     t = 0.4 - 6 / (1 + |z|^2)

z is the complex field amplitude of a light pulse after each round trip: the
1 is fresh input light, u < 1 is what survives the mirrors, and t is the phase
the pulse picks up in the medium, which depends on its own intensity |z|^2.
That dependence is the whole nonlinearity (Ikeda 1979).

The picture follows the well-known one: 2000 random starting points, drawn
from a normal of width 10 about the origin, each trajectory drawn as a path
through its successive iterates. Measured at u = 0.918 (not assumed):

  * Far out t is almost exactly 0.4 rad, so the map is a rotation by 23 degrees
    and a shrink by u: every trajectory comes in along the same logarithmic
    spiral. That is the vortex.
  * Near the origin the intensity term takes over, the rotation changes
    violently from step to step, and the paths are thrown about the ghost of
    the famous Ikeda attractor -- at this u a chaotic SADDLE, no longer an
    attractor. Orbits linger on it and then leave: half have left by step 64,
    95% by 136, the last after 1314.
  * Every one of them ends on the single attractor there is, the stable focus
    at z* = 2.598 + 4.465 i, whose eigenvalues are 0.918 exp(+-19.06 i): the
    paths wind into it by 19 degrees a step.

HOW A STEP IS DRAWN. Each step is exactly a rotation by t and a shrink by u
about the point z_c = 1 / (1 - u exp(i t)):  z' - z_c = u exp(i t) (z - z_c).
So a step is drawn as that motion done continuously -- the arc of logarithmic
spiral from z to z' about z_c -- rather than as the straight chord between
them. Both end on the same iterates. Chords were tried first: far out a chord
is 0.4 |z| long whatever the zoom, so wherever the frame's edge falls it cut
through 300-900 px straight segments kinked by 23 degrees at every iterate,
scratchy beside the smooth vortex they approximate. Arcs are continuous lines
in the same sense the chords were: subdivided at half a pixel, deposited
bilinearly, ink proportional to length, so a line's brightness does not depend
on how fast the orbit moved along it. The rotation is taken the short way
round, |t| <= pi, which leaves the end point unchanged.
"""

import os

import numpy as np

U = 0.918
NPOINTS = 2000
STEPS = 1500

TITLE = "Ikeda map"
SUBTITLE = "trajectories of 2000 random points,  u = 0.918"

# The stretch is done in generate(), and the renderer takes it as it is.
# It is LOG, floored and shouldered:
#
#   * FLOORED at about one path's ink (F0), so a lone path sits low on the
#     ramp, a dim line near the ground, and colour is kept for where paths
#     bunch. lib's log put the knee at six paths and lifted it with gamma 0.55:
#     a region crossed by ten paths reached 0.43 of the ramp, which is most of
#     the vortex, and the screen was one teal edge to edge.
#   * SHOULDERED at the top instead of clipped: the log of the ink reaches 1 at
#     the TOP percentile of lit pixels and then rolls over smoothly toward 1.
#     The focus is a 1/r pile of converging spirals and the saddle a web
#     crossed by every path, and a clip at the 99.5th percentile flattened both
#     into featureless pink slabs; the shoulder keeps their gradients.
#
# Measured at 4K: half the lit pixels carry about one path's ink, 90% under
# two, 1% over fifteen. So the vortex is teal hairlines and the colour lives
# where paths really bunch -- the rim arc, the saddle, the focus. Gamma below 1
# was tried to push the vortex bluer; it lifts the lone paths with it and the
# screen floods teal again (78% lit at 0.6).
SCALE = "unit"
GAMMA = 1.0
F0 = 1.0                 # ink of about one path, in pixels of line
TOP = 99.0               # percentile of lit pixels the log maps to 1; at 99.9
                         # the cores stopped at blue and the vortex went grey
KNEE = 3.0               # sharpness of the shoulder: x / (1 + x^KNEE)^(1/KNEE)
BLEND = 0.85
SOFTEN = 0.8
HUE_SMOOTH = 3.0

# (centre x, centre y, half-width in x). The builder framed the whole vortex,
# both cores and the outer spirals, at half-width 22; on a real desktop that
# read as too far out, and 1.9x closer (tried against 1.15, 1.33, 1.5 and
# 1.7) was chosen: the cores and the inner spirals fill the panel.
PRESETS = [
    (1.0, 1.5, 22.0 / 1.9),
]


def _step(z):
    t = 0.4 - 6.0 / (1.0 + z.real ** 2 + z.imag ** 2)
    return 1.0 + U * z * np.exp(1j * t)


def _splat(px, py, wt, acc, ww, hh):
    """Bilinear deposit of pixel-space points into a flat guard-padded grid.

    np.add.at in place rather than bincount, whose grid-sized output is
    freshly page-faulted on every call and serialises parallel workers.
    """
    W = ww + 2
    px = px + 1.0                        # the guard column
    py = py + 1.0
    ix = np.floor(px)
    iy = np.floor(py)
    ok = (ix >= 0) & (ix <= ww) & (iy >= 0) & (iy <= hh)
    tx, ty, wt = (px - ix)[ok], (py - iy)[ok], wt[ok]
    i = iy[ok].astype(np.int64) * W + ix[ok].astype(np.int64)
    np.add.at(acc, i, (1 - tx) * (1 - ty) * wt)
    np.add.at(acc, i + 1, tx * (1 - ty) * wt)
    np.add.at(acc, i + W, (1 - tx) * ty * wt)
    np.add.at(acc, i + W + 1, tx * ty * wt)


def _arcs(z, acc, extent, ww, hh, spacing=0.5):
    """Draw every step of every path (columns of z) as its spiral arc.

    Each arc is cut into its own number of pieces no longer than `spacing`
    pixels -- the first step from a point thirty units out is ten thousand
    times longer than one near the focus -- and each piece carries its length
    as weight. Pieces off the frame are dropped by _splat; nothing is culled
    earlier, because an arc can bulge into the frame from endpoints outside it.
    """
    x0, x1, y0, y1 = extent
    sc = ww / (x1 - x0)                  # pixels per unit; square pixels
    a = z[:-1].ravel()
    t = 0.4 - 6.0 / (1.0 + a.real ** 2 + a.imag ** 2)
    t = np.remainder(t + np.pi, 2 * np.pi) - np.pi       # the short way round
    zc = 1.0 / (1.0 - U * np.exp(1j * t))
    r = a - zc
    lnu = np.log(U)
    # |d/ds (zc + r exp((ln u + i t) s))| = |r| hypot(ln u, t) u^s, s in 0..1
    speed = np.abs(r) * np.hypot(lnu, t) * sc
    n = np.maximum(1, np.ceil(speed * (1 - U) / -lnu / spacing)).astype(np.int64)
    # In chunks of about four million pieces, so memory stays bounded.
    cs = np.cumsum(n)
    start = 0
    while start < n.size:
        end = max(start + 1, int(np.searchsorted(
            cs, cs[start] - n[start] + 4_000_000, side="right")))
        nn = n[start:end]
        seg = np.repeat(np.arange(start, end), nn)
        off = np.arange(seg.size) - np.repeat(np.cumsum(nn) - nn, nn)
        s = (off + 0.5) / n[seg]
        p = zc[seg] + r[seg] * np.exp((lnu + 1j * t[seg]) * s)
        # Raster rows grow downward: y is flipped so physical up is up. -0.5
        # puts a point on a pixel centre wholly into that pixel.
        _splat((p.real - x0) * sc - 0.5, (y1 - p.imag) * sc - 0.5,
               speed[seg] * U ** s / n[seg], acc, ww, hh)
        start = end


def _worker(args):
    x, y, extent, shape = args
    hh, ww = shape
    z = np.empty((STEPS + 1, x.size), complex)
    z[0] = x + 1j * y
    for i in range(STEPS):
        z[i + 1] = _step(z[i])
    acc = np.zeros((hh + 2) * (ww + 2))
    _arcs(z, acc, extent, ww, hh)
    return acc.reshape(hh + 2, ww + 2)[1:-1, 1:-1].astype(np.float32)


def ink(size, seed=0, jobs=None):
    """The raw ink: about one per pixel of length for each path."""
    w, h = size
    cx, cy, hx = PRESETS[seed % len(PRESETS)]
    hy = hx * h / w
    extent = (cx - hx, cx + hx, cy - hy, cy + hy)

    # The SAME 2000 starting points for every view.
    rng = np.random.default_rng(918)
    x = rng.normal(0.0, 10.0, NPOINTS)
    y = rng.normal(0.0, 10.0, NPOINTS)

    # Each worker holds one float64 grid, 660 MB at 4K x 3.
    jobs = jobs or min(os.cpu_count() or 4, 10)
    chunks = np.array_split(np.arange(NPOINTS), jobs)
    work = [(x[c], y[c], extent, (h, w)) for c in chunks]
    field = None
    import multiprocessing as mp
    with mp.Pool(jobs) as pool:
        for part in pool.imap_unordered(_worker, work):
            field = part if field is None else field + part
    return field


def stretch(field, f0=F0, top=TOP, knee=KNEE):
    """Ink -> 0..1: log above a one-path floor, rolled over at the top."""
    lit = field[field > 1e-3 * f0]
    L = np.log1p(np.percentile(lit, top) / f0) if lit.size else 1.0
    x = np.log1p(np.maximum(field, 0) / f0) / L
    return (x / (1.0 + x ** knee) ** (1.0 / knee)).astype(np.float32)


def generate(size, seed=0, jobs=None):
    return stretch(ink(size, seed, jobs))
