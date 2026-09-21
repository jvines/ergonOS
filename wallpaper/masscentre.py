"""The uniform mass-centre triangle fractal.

Take a triangle, join each of its corners to its centre of mass -- the
centroid, where the medians cross -- and it falls into three triangles. Do the
same to each of those, and to each of theirs, every triangle to the same depth
(that is the "uniform"): after g steps there are 3^g triangles and every edge
of every one of them is drawn.

What makes it more than a subdivided triangle is that the pieces are not
alike. An equilateral triangle splits into three 30-30-120 triangles; each of
those splits into one fatter and two flatter ones; and the flat ones only get
flatter. Almost every triangle in the limit is a sliver, lying along an edge
of its parent, so the construction piles its lines into lens-shaped bundles
along every edge it ever drew, and every corner becomes the hub of a fan of
lines -- 3 x 2^(g-1) of them at the centre of the first split. The self-
similarity is not of shape but of arrangement: bundles of bundles, fans of
fans.
One view: a single triangle about its centroid, just large enough that its
edges clear the corners of the panel, so the whole screen is its interior and
the first split's fan sits in the middle. A triangular lattice of them, each
node a twelve-fold star, was built and pruned.

Colour and weight follow the step that drew the line, each step finer and
warmer. In practice the colour ends up saying where the lines crowd: the
finest steps pile hundreds of lines into each bundle, and a bundle glows in
the warm colour of what it is made of while the few coarse lines between
bundles stay cool and bare.
"""

import numpy as np

TITLE = "Mass-centre triangle fractal"
SUBTITLE = "a triangle split in three through its centroid, and every piece again, 8 times"

# The field arrives already coloured, 0..1 (see pen.py), and is taken as it is.
# Strokes are analytic and band-limited, so no SOFTEN; HUE_SMOOTH keeps a
# line's soft edge in the line's own colour (see fractaltree.py).
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
SOFTEN = 0.0
HUE_SMOOTH = 3.0

# Stroke edge and the core of the step-0 lines, fractions of panel height
# (1 px = 1 / 2400 at 4K). Cores shrink by THIN per step down to nothing,
# after which every line is a bare ~2 px Gaussian.
SOFT = 1.0 / 2400
CORE = 2.2 / 2400
THIN = 0.55
# depth: steps.  zoom: how much larger than the panel the triangle's
# inscribed circle is.  rot: turn, degrees.
VIEW = dict(depth=8, zoom=1.02, rot=0.0)


def split(tri, depth):
    """Lines drawn at each step: list over steps of (starts, ends) arrays."""
    out = []
    for _ in range(depth):
        g = tri.mean(axis=1)                               # centroids
        out.append((tri.reshape(-1, 2), np.repeat(g, 3, axis=0)))
        a, b, c = tri[:, 0], tri[:, 1], tri[:, 2]
        tri = np.concatenate([np.stack([a, b, g], 1),
                              np.stack([b, c, g], 1),
                              np.stack([c, a, g], 1)])
    return out


def generate(size, seed=0, jobs=None, **over):
    import pen

    q = dict(VIEW, **over)
    w, h = size
    depth = q["depth"]
    rot = np.radians(q["rot"])
    R = np.array([[np.cos(rot), np.sin(rot)], [-np.sin(rot), np.cos(rot)]])

    # One equilateral triangle about the origin, its inscribed circle
    # `zoom` times the panel's half-diagonal. At 1 an edge would graze two
    # corners; a touch above, every edge runs just outside the panel and
    # nothing on screen is outside the triangle. (At 0.9 the two top corners
    # were empty wedges of ground.)
    r_in = q["zoom"] * np.hypot(w, h) / 2 / h          # in panel heights
    ext = (-w / h / 2, w / h / 2, -0.5, 0.5)
    a = np.radians([90.0, 210.0, 330.0])
    tri = (2 * r_in * np.stack([np.cos(a), np.sin(a)], 1))[None]
    tri = tri @ R
    px, py, s = pen.to_pixels(ext, size)

    # Step 0: the triangle's own edges.
    segs = [(tri.reshape(-1, 2), np.roll(tri, -1, 1).reshape(-1, 2))]
    segs += split(tri, depth)

    # Assemble every step, coarsest first, with its colour and pen.
    xa, ya, xb, yb, core, val = [], [], [], [], [], []
    for k, (p, q2) in enumerate(segs):
        xa.append(px(p[:, 0])); ya.append(py(p[:, 1]))
        xb.append(px(q2[:, 0])); yb.append(py(q2[:, 1]))
        core.append(np.full(len(p), CORE * h * THIN ** k))
        val.append(np.full(len(p), 0.14 + 0.86 * (k / depth) ** 0.9))
    c = np.concatenate(core)
    return pen.draw(np.concatenate(xa), np.concatenate(ya),
                    np.concatenate(xb), np.concatenate(yb), c, c,
                    np.concatenate(val), size, soft=SOFT * h, jobs=jobs)
