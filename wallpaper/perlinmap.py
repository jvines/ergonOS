"""Perlin noise as terrain -- the noise read as elevation and drawn as a map.

perlin.py draws a flow through gradient noise. This is the other thing the
noise is famous for: land. Fractional Brownian motion of Perlin's noise has
the statistics of real topography -- the same roughness at every scale, the
coastline that gets longer the closer you look -- which is why it is under
nearly every generated landscape. Drawn raw it is a soft colour field with
nothing to hold on to; drawn as a MAP, the eye reads it as a place.

The terrain, all from perlin.py's noise:

  * continents: four octaves of fbm, domain-warped at a coarser scale so the
    coast bends into bays and headlands instead of plain fbm's round blobs;
    two finer octaves added unwarped, for the texture of the ground;
  * mountain belts: ridged noise, (1 - |n|)^2 over octaves, whose crests are
    ranges with valleys between them, switched on by a slow noise of its own
    -- on land or in the sea, where the crests make island arcs;
  * sea level: set so 38% of the panel is under water, from a coarse survey
    of the same surface, so it is the same at any resolution.

Drawn as a topographic map: contours at a regular interval, every fifth an
index contour drawn heavier, the coastline heaviest, coloured by elevation.
Shaded relief, and relief with the contours cut into it, were built, shown
and pruned.

Lines are analytic, as in chladni.py: |h - level| / |grad h| is the distance
to the nearest contour, so each line has an exact profile at any angle. Where
contours crowd closer than a few pixels -- steep ground -- the ordinary ones
fade and the index contours carry on, as on a printed map, instead of merging
into a solid band.
"""

import os

import numpy as np

from perlin import noise, fbm, _tables

TITLE = "Perlin noise, as terrain"
SUBTITLE = "a topographic map of an imaginary landscape: fractal gradient noise read as elevation"

# The field arrives already toned, 0..1 (see bifurcation.py for why a
# generator does its own). Lines are analytic, so no SOFTEN; HUE_SMOOTH keeps each
# line's edge in its own colour. Saturation and exposure sit between the house
# lines-on-ground (2.25 / 1.1) and screen-filling (1.5 / 0.95): 62% is land.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
RAMP = "full"
SATURATION = 1.8
EXPOSURE = 1.0
SOFTEN = 0.0
HUE_SMOOTH = 3.0

# The landscape. The noise seed and the pan are part of the picture: they are
# pinned so the map never changes under a kept view. Seed 2 was picked from a
# sheet of 24: a gulf opening to the west, an island off it, a mountain belt
# across the north, and open water bottom left, under the caption.
NOISE_SEED = 2
PAN = (40.0, 60.0)        # noise units: where on the infinite map the panel sits
CELLS = 1.4               # continent-scale noise cells per panel height
WARP = 0.45               # domain warp of the continents, noise units
OCTAVES = 6               # finest wavelength ~55 px at 4K: finer prints as specks
DETAIL = 1 / 24           # weight of the fine octaves (fbm itself would give 1/16)
RIDGE = 0.5               # mountain height, in units of the fbm range
RIDGE_F = 3.5             # ridge noise cells per continent cell: ranges, not rings
BELT = (-0.05, 0.3)       # where the slow belt noise turns mountains on
SEA = 0.38                # fraction of the panel under water

# Contours. LEVELS between the coast and the high ground; every INDEX-th heavy.
LEVELS = 24
INDEX = 5
PX = 1.0 / 2400           # one pixel at 4K, in panel heights
PENS = ((0.25, 0.55), (1.1, 0.75), (1.4, 0.8))  # (core, soft) px: plain, index, coast
LINE_LO = 0.3             # line value at the coast, 1 at the top; defringed, a
                          # hairline shows at ~0.7 of it, so peaks read mauve





def _smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def _ridged(x, y, tab, octaves, crest=0.05):
    """Ridged multifractal (Musgrave): ridges where the noise crosses zero,
    each octave weighted by the one before, so detail gathers on the ridges
    and the valleys between them stay smooth. |n| is softened to
    sqrt(n^2 + e^2), e doubling each octave: a true |n| creases every zero
    set, and in shading each crease is a hard line -- arcs like folded cloth."""
    out, wgt = np.zeros_like(x), np.ones_like(x)
    amp, f, norm = 1.0, 1.0, 0.0
    c, s = np.cos(1.1071), np.sin(1.1071)      # rotate octaves off each other
    rx, ry = x, y
    for k in range(octaves):
        n = noise(rx * f - 11.9 * k, ry * f + 23.1 * k, tab)
        e = crest * 2 ** k                          # softer with each octave
        r = (1.0 + e - np.sqrt(n * n + e * e)) ** 2 * wgt
        out += amp * r
        wgt = 1.0 - (1.0 - np.minimum(2.0 * r, 1.0)) ** 2   # C1: a clip creases too
        norm += amp
        amp *= 0.5; f *= 2.0
        rx, ry = c * rx - s * ry, s * rx + c * ry
    return out / norm


def _height(x, y):
    """Elevation at (x, y), in panel heights from the centre."""
    t = [_tables(NOISE_SEED + 101 * k) for k in range(5)]
    X, Y = x * CELLS + PAN[0], y * CELLS + PAN[1]
    # The warp bends the continents only. Warping every octave shears the fine
    # ones into parallel streaks -- marble, not land -- so the detail octaves
    # are added unwarped and stay isotropic.
    u = X + WARP * fbm(0.5 * X, 0.5 * Y, t[1], 3)
    v = Y + WARP * fbm(0.5 * X + 5.2, 0.5 * Y + 1.3, t[1], 3)
    h = fbm(u, v, t[0], 4) + DETAIL * fbm(16 * X, 16 * Y, t[3], OCTAVES - 4, 0.45)
    # Mountain belts: ridges wherever a slow noise says so, on land or in the
    # sea (where their crests make island arcs). Gating by elevation instead
    # put a uniform rise just inland of every coast -- a plateau with cliffs.
    belt = _smooth(BELT[0], BELT[1], fbm(0.6 * X + 9.1, 0.6 * Y - 4.3, t[1], 2))
    rx, ry = RIDGE_F * (X + u) / 2, RIDGE_F * (Y + v) / 2
    hc = h + RIDGE * belt * _ridged(rx, ry, t[2], 4)
    return hc


def _survey(aspect):
    """Sea level, land-elevation quantiles and contour step, from a coarse grid
    over the panel -- the same numbers at any resolution."""
    ny = 240
    nx = int(round(ny * aspect))
    y, x = np.mgrid[0:ny, 0:nx]
    x = (x + 0.5) / ny - aspect / 2
    y = (y + 0.5) / ny - 0.5
    h = _height(x, y)
    sea = float(np.quantile(h, SEA))
    land = h[h > sea]
    qh = np.quantile(land, np.linspace(0, 1, 65))
    return dict(sea=sea, qh=qh, step=(qh[-2] - sea) / LEVELS)


def _pen(d, core, soft, px):
    """Stroke profile: a flat core with Gaussian shoulders (see pen.py)."""
    soft = np.maximum(soft * PX, 1.2 * px)
    return np.exp(-(np.maximum(d - core * PX, 0.0) / soft) ** 2)


def _contours(h, gx, gy, grad, s, px, coast=True):
    """Line intensity 0..1 of the contour map: plain, index and coast."""
    k = (h - s["sea"]) / s["step"]
    n = np.round(k)
    d = np.abs(k - n) * s["step"] / grad          # distance to the line, panel heights
    gap = s["step"] / grad                        # spacing of neighbouring contours
    kind = np.where(n == 0, 2, np.where(n % INDEX == 0, 1, 0))
    core = np.choose(kind, [p[0] for p in PENS])
    soft = np.choose(kind, [p[1] for p in PENS])
    ink = _pen(d, core, soft, px)
    # Crowded lines fade: plain ones when their gap nears a few pixels, index
    # ones when theirs (five gaps) does, so steep ground keeps a readable grid.
    fade = np.where(kind == 0, _smooth(1.5 * PX, 5 * PX, gap),
                    np.where(kind == 1, _smooth(1.5 * PX, 5 * PX, INDEX * gap), 1.0))
    # So do loops tighter than a few pixels -- a knoll that only just crosses a
    # level prints as a speck of dust, not a contour. The level line's radius
    # of curvature is |grad h|^3 / (h_xx h_y^2 - 2 h_xy h_x h_y + h_yy h_x^2).
    hxy, hxx = np.gradient(gx, px)
    hyy = np.gradient(gy, px, axis=0)
    bend = np.abs(hxx * gy * gy - 2 * hxy * gx * gy + hyy * gx * gx) / grad ** 3
    fade = fade * _smooth(1.5 * PX, 3 * PX, 1.0 / (bend + 1e-9))
    return np.where(n >= 0 if coast else n > 0, ink * fade, 0.0)




def _band(args):
    """One band of rows, computed with two rows of margin for the derivatives."""
    j0, j1, w, hpx, s = args
    px = 1.0 / hpx
    x = (np.arange(w) + 0.5) * px - w * px / 2
    y = (np.arange(j0 - 2, j1 + 2) + 0.5) * px - 0.5
    X, Y = np.meshgrid(x, y)
    h = _height(X, Y)
    gy, gx = np.gradient(h, px)
    grad = np.hypot(gx, gy) + 1e-9
    t = np.interp(h, s["qh"], np.linspace(0, 1, s["qh"].size))
    out = (LINE_LO + (1 - LINE_LO) * t) * _contours(h, gx, gy, grad, s, px)
    return j0, np.clip(out[2:-2], 0.0, 1.0).astype(np.float32)


def generate(size, seed=0, jobs=None, rows=48):
    w, h = size
    s = _survey(w / h)
    work = [(j, min(j + rows, h), w, h, s) for j in range(0, h, rows)]
    out = np.zeros((h, w), np.float32)
    import multiprocessing as mp
    with mp.Pool(jobs or os.cpu_count() or 4) as pool:
        for j0, band in pool.imap_unordered(_band, work):
            out[j0:j0 + band.shape[0]] = band
    return out
