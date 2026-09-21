"""Tent map -- the bifurcation diagram.

    x' = mu min(x, 1 - x)

The simplest map there is that is chaotic, and the odd one out among the
bifurcation diagrams: it has no periodic windows at all. Below mu = 1 every
orbit falls into 0. At mu = 1 the attractor is born as the single point 1/2,
and for every mu above it the map is chaotic -- slope mu > 1 everywhere, so
every cycle is unstable and there is nothing for an orbit to settle onto.

What it does instead is BAND MERGING, the logistic map's cascade run the other
way. For 2^(1/2^(k+1)) < mu < 2^(1/2^k) the attractor is 2^k intervals that
the orbit visits in strict rotation; they fuse pairwise at mu = sqrt(2),
2^(1/4), 2^(1/8), ..., piling up on mu = 1. At sqrt(2) the last two merge and
from there to mu = 2 it is one interval, [mu(1 - mu/2), mu/2], growing to the
whole of [0, 1].

So the diagram is all mist, which in the logistic map is where the grain
lives. Here it has none, because it is not sampled. A map that is linear on
each side with slope +-mu has an invariant density known in closed form (Ito,
Tanaka & Nakada 1979; it drops out of the transfer operator in three lines):
a sum of steps at the orbit of the turning point,

    rho(x) ~ sum_n w_n [x <= c_n],    c_n = T^n(1/2),
    w_1 = 1,   w_(n+1) = s_n w_n / mu,   s_n = -1 if c_n > 1/2, else +1.

Each column is computed exactly -- the limit of infinitely many orbits -- and
was checked against a Monte-Carlo histogram of the same map: they agree to
the histogram's own noise, bands, gaps and all. What would have been grain is
structure instead: the curves c_n(mu) are the edges between facets of
constant density, the tent map's version of the bright caustics in the
logistic map's chaos. Steps rather than spikes, because the map has a corner
at its top rather than a smooth maximum.
"""

import os

import numpy as np

TITLE = "Tent map"
SUBTITLE = "x' = mu min(x, 1-x),   chaotic bands merging,  1 < mu < 2"

# One field, no lines, coloured by rank: every facet gets its share of the
# ramp. The density is RELATIVE -- 1 means the column's mass spread evenly over
# its attractor -- not probability per pixel. Per pixel, the colour mostly
# said how wide the attractor was, which is one number per column: the image
# became a left-to-right gradient with the facets faint inside it.
#
# GAMMA below 1 lifts the thinnest facets off the ground: at 1.0 the bottom
# fifth of the ranks is a mix of teal and the dark ground, and the sparse
# lower facets read as grey mud; at 0.55 the shading that gives the facets
# their folded-paper depth is gone and pink takes over. 0.75 between them.
SCALE = "equalize"
GAMMA = 0.75
BLEND = 0.78
# The attractor's edge pixel is only partly covered, so its density is low,
# and colouring by rank turned it cyan: a beaded cyan rim along the top of
# purple facets. HUE_SMOOTH takes the hue from the neighbourhood and lets the
# pixel set only the opacity, so the edge fades out in the facet's own colour
# (rim pixels 383 of 1243 columns -> 31). It works everywhere, not only at the
# edge, so the low side of every step between facets now comes out slightly
# darker, 10-20%: a faint crease at 1:1. At 0.6 the creases are about the
# same and the rim only half goes. SOFTEN must stay 0: blurred into the
# ground, the density's faint tail ranks as a colour of its own and draws a
# dark teal line just outside the edge.
SOFTEN = 0.0
HUE_SMOOTH = 1.0

# (mu0, mu1, x0, x1, caption). generate() installs the caption: render.py
# reads it after generating.
# Only the view chosen on a real desktop is here. A closer view around the
# last merger at mu = sqrt 2 (mu 1.35..1.75, x 0.22..0.88) was shown and
# pruned. The sampling is seeded per strip from the seed, which stays 0 for
# the whole diagram, so the kept picture is unchanged.
PRESETS = [
    (1.0, 2.0, 0.0, 1.0, SUBTITLE),          # the whole thing
]

# Terms kept per column: until the weight mu^-n falls below TOL. Near mu = 1
# that is tens of thousands of iterates, so it is capped at NMAX.
TOL = 1e-12
NMAX = 20000


def _strip(args):
    """Columns c0..c1 of the exact density; (c0, (h, cw) float32)."""
    c0, c1, w, h, preset, seed, sub = args
    rng = np.random.default_rng([seed, c0])
    cw = c1 - c0
    # `sub` values of mu per column, one in each equal slice of it, placed at
    # random inside the slice: the high iterates c_n(mu) swing faster than a
    # column is wide, and jitter makes that average into tone, not moire.
    col = np.repeat(np.arange(cw), sub)
    u = (c0 + col + (np.tile(np.arange(sub), cw) + rng.random(cw * sub)) / sub) / w
    m0, m1, xlo, xhi = preset[:4]
    mu = np.maximum(m0 + (m1 - m0) * u, 1.0 + 1e-9)
    hi_c, lo_c = mu / 2.0, mu * (1.0 - mu / 2.0)      # c_1 and c_2
    scale = h / (xhi - xlo)
    nmax = int(min(NMAX, np.ceil(np.log(1 / TOL) / np.log(mu.min()))))

    def orbit():
        c = np.full(mu.size, 0.5)
        wt = np.ones(mu.size)
        for _ in range(nmax):
            c = mu * np.minimum(c, 1.0 - c)
            yield c, wt
            wt = np.where(c > 0.5, -wt, wt) / mu

    # Pass 1: the normalisation Z; R, the sum of all the weights, which is the
    # density BELOW the attractor -- 0 in the limit, not quite 0 once
    # truncated, and cancelled by a step of -R at the attractor's floor c_2;
    # and S, the sum of their sizes, which bounds the rounding error.
    Z = np.zeros(mu.size)
    R = np.zeros(mu.size)
    S = np.zeros(mu.size)
    for c, wt in orbit():
        Z += wt * c
        R += wt
        S += np.abs(wt)
    Z -= R * lo_c
    # Relative density: rho / mean(rho over [c_2, c_1]), each sample 1/sub.
    #
    # CONDITIONING. Close to mu = 1 the sum is catastrophically cancelling:
    # at mu = 1.0012 weights of order 1 add up to a density of order 1e-11,
    # and the rounding left behind printed a faint line down the whole column
    # under the tip. err is that rounding, in the output's units. Where it
    # passes 2% of the density itself (mu within ~0.001 of 1, an attractor a
    # few pixels tall with hundreds of bands in it) the column is drawn as a
    # uniform fill of [c_2, c_1]; elsewhere anything below err is zeroed.
    Zs = np.where(np.abs(Z) > 0, Z, 1.0)
    norm = (hi_c - lo_c) / (sub * Zs)
    err = 4e-16 * S * np.abs(norm)
    bad = ((mu ** -float(nmax) > 1e-6) | (err > 0.02 / sub)).astype(float)
    norm *= 1.0 - bad
    err *= 1.0 - bad

    # Pass 2: deposit the steps. The pixel average of [x <= c] is 1 on every
    # row below the row c falls in, a fraction on that row, 0 above: stored
    # as two increments, then summed down the column.
    H = h + 3
    acc = np.zeros(H * cw)

    def put(c, a):
        n = len(c)
        c, a = np.concatenate(c), np.concatenate(a)
        t = np.clip((xhi - c) * scale, -1.0, float(h))
        k = np.floor(t)
        f = t - k
        i = (k.astype(np.intp) + 1) * cw + np.tile(col, n)
        acc[:] += np.bincount(i, weights=a * (1 - f), minlength=H * cw)
        acc[:] += np.bincount(np.minimum(i + cw, H * cw - 1), weights=a * f,
                              minlength=H * cw)

    bc, bw = [], []                    # one bincount per 64 iterates
    for c, wt in orbit():
        bc.append(c)
        bw.append(wt * norm)
        if len(bc) == 64:
            put(bc, bw)
            bc, bw = [], []
    put(bc + [hi_c, lo_c], bw + [bad / sub, -R * norm - bad / sub])

    dens = np.cumsum(acc.reshape(H, cw), axis=0)[1:h + 1]
    # What is left in the gaps between bands and under the attractor is
    # rounding; the ground there must be exactly 0.
    floor = np.bincount(col, weights=err, minlength=cw)
    dens[dens < np.maximum(floor, 1e-9 * dens.max(0))] = 0.0
    return c0, dens.astype(np.float32)


def generate(size, seed=0, sub=4, jobs=None):
    w, h = size
    k = seed % len(PRESETS)
    procs = jobs or os.cpu_count() or 4
    nstrip = max(procs, w // 120)
    edges = np.linspace(0, w, nstrip + 1).astype(int)
    work = [(edges[j], edges[j + 1], w, h, PRESETS[k], seed, sub)
            for j in range(nstrip) if edges[j + 1] > edges[j]]
    out = np.zeros((h, w), dtype=np.float32)
    import multiprocessing as mp
    with mp.Pool(procs) as pool:
        for c0, d in pool.imap_unordered(_strip, work):
            out[:, c0:c0 + d.shape[1]] = d
    return out
