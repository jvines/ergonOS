"""A fractal tree -- one rule, applied to its own output fifteen times.

Every branch ends by splitting in two. Each child is a copy of its parent,
shorter by a ratio near 0.7, thinner by 1/sqrt(2), and turned off the parent's
line by some angle. That is the entire construction; the canopy is what the
rule does to itself after 2^15 = 32768 twigs.

The thinning is Leonardo's rule, from his notebooks: the cross-sectional area
of a trunk equals the sum of its branches' areas, so a split into two keeps
d_parent^2 = 2 d_child^2 and every level is thinner by 1/sqrt(2). It holds for
real trees surprisingly well (Eloy 2011 argues it is what makes them resist
wind), and it is why this reads as a tree and not a diagram of one: the limbs
thin at the rate the eye expects.

A strictly symmetric tree -- both children equal, same angle every time -- is
the textbook figure and looks it. So the presets break symmetry the ways trees
do. One child LEADS: it turns less and grows longer, and which side leads is
decided at random at every fork, as it is for a real shoot. Angles and lengths
carry a little scatter. And every branch bends slightly toward vertical
(tropism), which is what stops the outer limbs of a symmetric rule from
curling down and round into the trunk.

Colour is depth: the trunk sits at the cool end of the ramp and the twigs at
the warm end, so the fine last levels -- where the fractal is -- carry the
colour, and the limbs that hold them up recede.
"""

import numpy as np

TITLE = "Fractal tree"
# Short on purpose: the trunk stands at the bottom edge just right of centre,
# and a longer line ran the caption straight through it (the outline of each
# glyph cut notches in the trunk). About 72 characters ends near x = 1800 at
# 4K, clear of every preset's trunk.
SUBTITLE = "each fork: children ~0.7 as long, 1/sqrt 2 as thick (Leonardo's rule)"

# The field arrives already coloured by depth, in 0..1 (see generate), so the
# renderer takes it as it is: no stretch has anything to find in it.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85

# No SOFTEN: every stroke is an analytic profile at least two pixels across
# (SOFT below), already band-limited, so there is nothing for it to remove and
# it only blurred the twigs. HUE_SMOOTH stays: without it a twig's soft edge
# steps down the ramp into a different colour from its core (see lib.render).
SOFTEN = 0.0
HUE_SMOOTH = 3.0

# Edge of every stroke, as a fraction of the panel height: 1 px at 4K. The
# last twigs are this and nothing more -- a Gaussian about two pixels across,
# the narrowest a line can be and still keep its profile wherever it falls
# between pixels. At 0.55 px the twigs beaded.
SOFT = 1.0 / 2400

# depth: levels above the trunk.  stem: trunk length, where the first branch
# is 1.  spread: mean turn off the parent, deg.  lead: the leader turns
# (1 - lead) x spread and the other (1 + lead) x spread.  ratio: (leader,
# other) length ratio.  scatter: sd of the turn (deg) and of log length.
# tropism: pull toward vertical, per level.  trunk: half-width / branch 1.
# zoom: > 1 lets the crown run off the edges.
#
# A short stem throughout: at the natural length the trunk took half the
# panel and the crown -- the part that is a fractal -- was cropped away.
#
# Only the tree chosen on a real desktop is here: a jacaranda, grown from
# random seed 7. Two others were built and pruned -- a deterministic "curl"
# (depth 15, stem 0.5, spread 30, lead 0.45, ratio 0.80/0.60, no scatter,
# no tropism: every limb a fern-like spiral) and an "acacia" (depth 14, stem
# 0.5, spread 36, lead 0.2, ratio 0.73/0.68, scatter 4 deg / 0.05,
# tropism 0.18: taller and rounder).
PRESETS = {
    # Wide forks, a strong pull upward and some scatter: a flat-topped
    # crown like a jacaranda's. One level fewer than the others, because at
    # fifteen the random crowns pack solid and the twigs stop reading.
    "jacaranda": dict(depth=14, stem=0.45, spread=40, lead=0.15,
                      ratio=(0.72, 0.70), scatter=(6.0, 0.08), tropism=0.25,
                      trunk=0.035, zoom=1.08),
}

# (preset, random seed) for each background this module offers. The random
# seed is part of the picture: it is what grew this particular tree.
TREES = [("jacaranda", 7)]


def grow(p, rng):
    """Every segment of the tree: arrays x0, y0, x1, y1, w0, w1, depth.

    Built a whole level at a time rather than recursively, so 65 thousand
    branches cost fifteen numpy steps rather than 65 thousand calls.
    """
    x = np.zeros(1); y = np.zeros(1)
    ang = np.array([np.pi / 2]); ln = np.array([p["stem"]])
    wd = np.array([p["trunk"]])
    taper = 1 / np.sqrt(2)
    sa, sl = np.radians(p["scatter"][0]), p["scatter"][1]
    sp = np.radians(p["spread"])
    segs = []
    for d in range(p["depth"] + 1):
        ex, ey = x + ln * np.cos(ang), y + ln * np.sin(ang)
        segs.append((x, y, ex, ey, wd, wd * taper, np.full(x.size, d)))
        if d == p["depth"]:
            break
        n = x.size
        # Which side leads: always the left, or a coin per fork -- except at
        # the first fork, which leads left so the two halves of the crown
        # come out as a balanced pair rather than one limb and a stub.
        side = np.ones(n) if (p.get("fixed") or d == 0) else rng.choice([-1.0, 1.0], n)
        kids = []
        for turn, r in ((side * sp * (1 - p["lead"]), p["ratio"][0]),
                        (-side * sp * (1 + p["lead"]), p["ratio"][1])):
            a = ang + turn + sa * rng.standard_normal(n)
            # Tropism: cos(a) is zero pointing straight up and +-1 lying
            # flat, so flat limbs are turned upward hardest, from either side.
            a = a + p["tropism"] * np.cos(a)
            kids.append((a, (1.0 if d == 0 else ln) * r *
                         np.exp(sl * rng.standard_normal(n))))
        x = np.concatenate([ex, ex]); y = np.concatenate([ey, ey])
        ang = np.concatenate([kids[0][0], kids[1][0]])
        ln = np.concatenate([kids[0][1], kids[1][1]])
        wd = np.concatenate([wd, wd]) * taper
    return [np.concatenate(c) for c in zip(*segs)]


def caption(seed):
    """(title, subtitle) from the preset alone, so a re-colour from a saved
    field -- which never calls generate() -- gets the same caption."""
    p = PRESETS[TREES[seed % len(TREES)][0]]
    # A fixed-ratio tree has two exact ratios; the random ones scatter about
    # ~0.7, so that is what their caption says.
    lengths = ("children {:g} and {:g} as long".format(*p["ratio"]) if p.get("fixed")
               else "each child ~0.7 as long")
    return TITLE, f"{p['depth']} levels; {lengths}, 1/sqrt 2 as thick (Leonardo's rule)"


def generate(size, seed=0, zoom=None, jobs=None, **over):
    import pen

    name, rng_seed = TREES[seed % len(TREES)]
    p = dict(PRESETS[name], **over)
    rng = np.random.default_rng(rng_seed)
    x0, y0, x1, y1, w0, w1, depth = grow(p, rng)

    # FRAMING: the base of the trunk on the bottom edge, the crown filling
    # the rest, cropped rather than shrunk. The panel is 16:10 and a crown
    # is rarely that shape; fitting it whole left the tree standing in a box
    # with dead space both sides, so the window takes whichever of the
    # crown's width or height fills the panel first and lets the other run
    # off the edge. Only what stands above the ground counts.
    w, h = size
    aspect = w / h
    xs = np.concatenate([x0, x1]); ys = np.concatenate([y0, y1])
    up = ys >= 0
    bw, bh = np.ptp(xs[up]), ys.max()
    zoom = zoom or p.get("zoom", 1.0)
    span = bh * aspect / zoom
    cx = 0.5 * (xs[up].min() + xs[up].max())
    ext = (cx - span / 2, cx + span / 2, -0.01 * span, 0.99 * span / aspect)
    px, py, s = pen.to_pixels(ext, size)

    # Depth -> colour. A power below one hands most of the ramp to the last
    # few levels, which hold nearly all the branches, and leaves the heavy
    # limbs in the cool quarter where they carry the shape without shouting.
    D = p["depth"]
    val = p.get("v0", 0.1) + (1 - p.get("v0", 0.1)) * (depth / D) ** p.get("vpow", 1.0)
    return pen.draw(px(x0), py(y0), px(x1), py(y1), w0 * s, w1 * s, val,
                    size, soft=SOFT * h, jobs=jobs)
