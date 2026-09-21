"""Koch snowflakes -- nested into a vortex.

Koch (1904) built the curve to exhibit something continuous and nowhere
differentiable: replace the middle third of every segment with two sides of an
equilateral triangle, and repeat forever. Round a triangle, it closes into the
snowflake -- finite area, infinite perimeter, dimension log 4 / log 3 = 1.2619.

A single snowflake is a roundish object in a 16:10 panel, and every framing of
one either leaves the sides dead or crops away the thing itself. An exact
property of the snowflake gives a composition that fills the screen instead:
the Koch curve is self-similar under ratio 1/sqrt(3) as well as under 1/3 --
two reduced copies of it make one (Cesaro's decomposition).

NESTED. A snowflake has six outer tips on a circle of radius R and six inner
notches on a circle of radius R / sqrt(3), halfway between them in angle. So a
copy shrunk by 1/sqrt(3) and turned 30 degrees has its tips exactly on the
notches of the first, and fits inside it; and a copy of that inside it; and so
on, a vortex of snowflakes each touching the last at six points, converging
on the centre. The panel sees the outer ones as fractal coastlines sweeping
across it at large scale and the inner ones whole. Colour runs cool to warm
inward, and the pen gets no lighter toward the centre, so the heart of the
vortex -- where the flakes crowd -- is where the ramp reaches pink.

The same property also tiles the plane with flakes of two sizes; that view was
built, shown and pruned (see VORTEX below).

No tone between the lines. An earlier version had one and it did not survive:
lib.render takes a line's hue from its neighbourhood, and a faint fill next to
a bright line gets that line's hue at the fill's tiny opacity, which is darker
than the fill on its own -- so every line sat in a dark halo.
"""

import numpy as np

TITLE = "Koch snowflakes"
SUBTITLE = ("nested at ratio 1/sqrt 3, each flake touching the next at six points;"
            "  dimension log 4 / log 3 = 1.26")

# The field arrives already coloured, 0..1 (see pen.py), and is taken as it is.
# Strokes are analytic and band-limited, so no SOFTEN; HUE_SMOOTH keeps a
# line's soft edge in the line's own colour (see fractaltree.py).
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
SOFTEN = 0.0
HUE_SMOOTH = 3.0

# Stroke edge and flat core, fractions of panel height (1 px = 1 / 2400 at 4K).
# A thin core: the curve is all corners, and a heavy pen rounds them off.
SOFT = 1.0 / 2400
CORE = 1.0 / 2400

# Target length of the finest segment, same units. Below about this a bump and
# the pen are the same size and the curve prints as a fuzzy rope.
FINEST = 7.0 / 2400

# Flakes at or below this circumradius (panel heights) take the warm end of the
# ramp in the nested view: smaller ones are specks.
SMALL = 0.06

# The nested vortex: centre (panel heights from the middle) and turn. This
# framing -- the heart two-thirds of the way across, the left half given to
# the two largest coastlines -- is the one chosen on a real desktop. Pruned:
# the same vortex centred (centre 0, 0, turn 90), and the exact tiling of
# the plane by flakes of two sizes in ratio sqrt 3 (3.2 big flakes across,
# each sublattice of the triangular lattice in its own colour).
VORTEX = dict(centre=(0.28, -0.04), rot=0.0)


def snowflake(level):
    """Edge start points (m, 2) of a snowflake of circumradius 1,
    counter-clockwise, vertices at 0, 120 and 240 degrees."""
    a = np.radians([0.0, 120.0, 240.0])
    p = np.stack([np.cos(a), np.sin(a)], 1)
    c, s = np.cos(np.radians(-60)), np.sin(np.radians(-60))
    for _ in range(level):
        d = (np.roll(p, -1, 0) - p) / 3
        p1 = p + d
        # Counter-clockwise, so outward is to the right of travel: the apex is
        # the middle third turned 60 degrees clockwise.
        apex = p1 + np.stack([c * d[:, 0] - s * d[:, 1],
                              s * d[:, 0] + c * d[:, 1]], 1)
        p = np.stack([p, p1, apex, p + 2 * d], 1).reshape(-1, 2)
    return p


def turn(deg):
    r = np.radians(deg)
    return np.array([[np.cos(r), np.sin(r)], [-np.sin(r), np.cos(r)]])


def steps(R):
    """How many Koch steps a flake of circumradius R (panel heights) shows.

    ROUNDED, so the finest segment lands within a factor sqrt 3 of FINEST
    (4-12 px at 4K). It was floored first, which only bounds it from below:
    a flake whose ideal step count was 5.98 got 5, and printed 20 px zig-zags
    beside a neighbour drawn at 7 px -- a textbook level-4 figure where the
    panel should show a coastline.
    """
    seg = np.sqrt(3) * R / FINEST
    return int(np.clip(np.round(np.log(max(seg, 1.0)) / np.log(3)), 1, 7))


def generate(size, seed=0, jobs=None, **over):
    import pen

    q = dict(VORTEX, **over)
    w, h = size
    half = 0.5 * w / h
    # World units are panel heights, origin at the middle.
    px, py, _ = pen.to_pixels((-half, half, -0.5, 0.5), size)

    a, b, val, core = [], [], [], []
    cx, cy = q["centre"]
    corner = np.hypot(half + abs(cx), 0.5 + abs(cy))
    # From the first flake whose inner notches reach into the panel, in
    # steps of 1/sqrt 3, down to one a few pixels across.
    R = corner * np.sqrt(3)
    flakes = []
    k = 0
    while R * h > 4.0 * h / 2400:
        flakes.append((R, q["rot"] + 30.0 * k))
        R /= np.sqrt(3)
        k += 1
    # Colour by SIZE on a log scale, cool outside to warm inside, spread
    # over the flakes big enough to read -- by index, half the ramp went
    # to specks at the centre and every flake that fills the panel came
    # out the same teal. From 0.4, so the outer coastlines sit at sky and
    # the whole ramp is used between them and the heart.
    #
    # Weight: a flat core of 1.3 px at least, even on the smallest flakes.
    # Lighter than that the heart could not reach pink: a hairline shows
    # at about 0.7 of the value it is drawn with (pen.py), which stopped
    # the centre at violet. The outer coastlines go a little heavier.
    R0 = flakes[0][0]
    for R, rot in flakes:
        p = R * snowflake(steps(R)) @ turn(rot) + [cx, cy]
        u = np.clip(np.log(R0 / R) / np.log(R0 / SMALL), 0.0, 1.0)
        a.append(p); b.append(np.roll(p, -1, 0))
        val.append(np.full(len(p), 0.4 + 0.6 * u))
        core.append(np.full(len(p), CORE * h * np.clip(np.sqrt(R / 0.3), 1.3, 2.0)))

    a, b = np.concatenate(a), np.concatenate(b)
    val, core = np.concatenate(val), np.concatenate(core)
    return pen.draw(px(a[:, 0]), py(a[:, 1]), px(b[:, 0]), py(b[:, 1]),
                    core, core, val, size, soft=SOFT * h, jobs=jobs)
