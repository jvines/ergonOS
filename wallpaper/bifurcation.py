"""Logistic map — the bifurcation diagram.

    x' = r x (1 - x)

The one thing here that is famous as an *image* and not only as a system. May's
1976 review made it the standard example of complexity out of nothing, and the
picture of where its attractor sits as r varies is the picture everyone has
seen.

The horizontal axis is not a coordinate of the system. It is a parameter: every
column is a different map, iterated until it has forgotten where it started,
and what is plotted is the set it settles onto. Nothing else in this set does
that, which is the reason to have it. The attractors are all smoke and
filament; this is hairline curves that split, and split again, and dissolve
into a mist with structure inside it.

r runs from 2.8 -- the fixed point 1 - 1/r, still stable -- through the
period-doubling cascade, which accumulates geometrically at r = 3.5699456 with
the ratio delta = 4.6692016 that Feigenbaum showed in 1978 is the same for
every map with a quadratic maximum, into chaos, and past the period-3 window
opening at the tangent bifurcation r = 1 + sqrt(8) = 3.8284271, which by Li and
Yorke's 1975 theorem is the loudest possible statement that everything to its
left is chaotic.

Vectorised over r, not over time: the recurrence is serial in the iteration
count and embarrassingly parallel in r, so the loop runs `keep` times over an
array of two hundred thousand orbits and never once over a point.
"""

import numpy as np

# Sparse: 22% of cells carry anything at all in the default view, and in the
# period-3 one it is 29% with a third of the panel dead empty -- the cascade is
# a handful of one-pixel curves, and the void under the lower envelope cannot
# be reached by the dynamics at all. That argues for 0.6, but the curves are
# hard, continuous, full-width lines rather than a diffuse density, and a
# bright ruled line across a desktop reads as chrome, as something you could
# click. Pulled back to 0.5 for that reason and no other.
TITLE = "Logistic map"
SUBTITLE = "x' = r x (1-x),  period-doubling cascade"

BLEND = 0.78

# (r0, r1), or (r0, r1, x0, x1) to override the vertical frame. The cascade is
# the whole diagram; the rest are places worth standing close to.
PRESETS = {
    "cascade":    (2.800, 4.000),   # fixed point -> doubling -> chaos, all of it
    "feigenbaum": (3.540, 3.600),   # r_inf = 3.5699456: doubling from the left,
                                    # the chaotic bands merging from the right
    "period3":    (3.820, 3.860),   # chaos collapsing onto three points at
                                    # 1 + sqrt(8), then doubling again from them
    # Inside the period-3 window, cropped to the middle of its three branches
    # (measured: 0.445 to 0.553 over this range, the other two sit near 0.15
    # and 0.96). What fills the panel is the whole diagram again -- one line,
    # doubling, chaos, windows -- because the third iterate restricted to that
    # subinterval is itself a unimodal map with a quadratic maximum, so it has
    # to repeat the entire story at its own scale. That is the renormalisation
    # argument, and the reason Feigenbaum's ratio is universal rather than a
    # fact about x(1-x).
    "renormalise": (3.8450, 3.8565, 0.435, 0.565),
}


def generate(size, seed=0, sub=3, ninit=24, burn=1000, keep=1400):
    w, h = size
    names = sorted(PRESETS)
    window = PRESETS[names[seed % len(PRESETS)]]
    r0, r1 = window[:2]

    rng = np.random.default_rng(seed)

    # `sub` values of r inside each pixel column, placed at random within the
    # column rather than on a lattice. A regular grid of r beats against the
    # period of the orbit and prints moire through the cascade; jitter turns
    # that into the anti-aliasing of a curve, which is what it actually is.
    col = np.repeat(np.arange(w), sub)
    r = r0 + (r1 - r0) * (col + rng.random(col.size)) / w

    # `ninit` starts per r. For almost every r the map has a single attractor,
    # so these are not different outcomes -- they are the same invariant
    # measure sampled in parallel, which is how the column gets enough points
    # without making the serial loop longer.
    r = np.tile(r, ninit)
    col = np.tile(col, ninit)
    # Never exactly 0 or 1: 0 is a fixed point and 1 maps onto it, so either
    # would sit there for the whole run and print a false line along the axis.
    x = rng.uniform(0.05, 0.95, r.size)

    for _ in range(burn):
        x = r * x * (1.0 - x)

    # The frame is the map's own, not a guess. For r in [2, 4] the interval
    # [f(f(1/2)), f(1/2)] -- the first two images of the critical point --
    # traps the dynamics, so it contains the attractor for every r in range,
    # and in the chaotic regions the attractor reaches both ends of it. A
    # preset that names its own x window means it instead, exactly.
    if len(window) == 4:
        xlo, xhi = window[2], window[3]
    else:
        rr = np.linspace(r0, r1, 4096)
        xhi = (rr / 4.0).max()
        xlo = (rr * (rr / 4.0) * (1.0 - rr / 4.0)).min()
        pad = 0.03 * (xhi - xlo)
        xlo, xhi = xlo - pad, xhi + pad

    # Binned directly instead of through lib.histogram2d, which is the only
    # departure from the other generators and is deliberate: that helper makes
    # the bins square so an attractor is not stretched, and here the two axes
    # are a parameter and a state variable. They have no common unit, there is
    # no aspect to preserve, and forcing one would frame empty r beyond 4 where
    # the map escapes to minus infinity. r fills the width, x fills the height.
    field = np.zeros(h * w)
    scale = h / (xhi - xlo)

    # Accumulate through bincount in chunks. Per step it would allocate and
    # zero a 5.5M-cell array fourteen hundred times over for a scatter of two
    # hundred thousand points; np.add.at avoids that and is an order of
    # magnitude slower than either. Chunking costs ~60 MB and neither.
    per_call = max(1, min(keep, 8_000_000 // x.size))
    buf = np.empty((per_call, x.size), dtype=np.intp)
    dump = h * w  # one extra bin, for everything outside the frame
    k = 0
    for _ in range(keep):
        x = r * x * (1.0 - x)
        # xhi - x, not x - xlo: x increases upward, because everyone has seen
        # this diagram that way up and a flipped one reads as a mistake.
        t = (xhi - x) * scale
        row = t.astype(np.intp)
        # Dropped, not clamped. A cropped preset leaves two thirds of the
        # attractor outside the frame, and clamping would stack all of it onto
        # the edge rows as two bright rules that are not in the dynamics.
        buf[k] = np.where((t >= 0) & (row < h), row * w + col, dump)
        k += 1
        if k == per_call:
            field += np.bincount(buf.ravel(), minlength=dump + 1)[:dump]
            k = 0
    if k:
        field += np.bincount(buf[:k].ravel(), minlength=dump + 1)[:dump]

    # Handed over as raw counts, on a linear scale, which is not the obvious
    # choice: the density spans five decades, because a periodic curve puts
    # every sample a column has into one or two cells while the chaotic fan
    # spreads the same count over a thousand rows. That argues for SCALE="log",
    # and log is wrong here. The curves are delta functions and should clip --
    # lib clips at the 99.5th percentile, and since the curves are a rounding
    # error in the cell count, that percentile lands inside the chaotic mist,
    # which is exactly where the structure worth resolving is. Log instead
    # spends most of the range lifting the mist into a flat slab and erases the
    # caustics -- the bright arcs swept out by the images of the critical point
    # -- which are the whole reason the chaotic half is interesting to look at.
    return field.reshape(h, w)
