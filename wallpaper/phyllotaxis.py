"""Phyllotaxis -- a sunflower head, floret by floret, in Vogel's model.

    theta_n = n x 137.508 deg,    r_n = c sqrt(n)

A capitulum grows from its rim inward, and each new floret appears in the
largest gap left by the ones before it. Vogel (1979) reduced that to the two
lines above: the n-th floret sits a fixed angle round from the last and at a
radius that keeps the area per floret constant, so the head is evenly packed
at every radius. The angle is the golden angle, 360 (1 - 1/phi) deg, and
nothing else will do. Any rational fraction of a turn stacks the florets into
straight spokes with empty wedges between them, and any angle close to one
does the same over a range of radii; the golden angle, as a fraction of a
turn 1/phi^2 = [0; 2, 1, 1, 1, ...], has a continued fraction ending in all
ones, which makes it the worst approximated by fractions, so it never lines
up and the packing never opens a gap. Douady and Couder (1992) got the same
Fibonacci spirals from drops of ferrofluid repelling each other as they
drifted outward, with no biology at all.

THE SPIRALS ARE NOT DRAWN. They are what the eye does with the nearest
neighbours: floret n touches n +- F and n +- F' for two consecutive
Fibonacci numbers, because those are the best rational approximations to the
golden ratio, and each of those steps, repeated, is a spiral arm -- F arms
winding one way and F' the other. How far out you look decides which pair.
In this view it is 13 and 21 near the middle, then 21 and 34, 34 and 55,
55 and 89 in a ring from 0.34 to 0.55 of the screen height from the centre,
89 and 144 beyond that, and 144 and 233 in the far corners. Each hand-over
happens where the old pair's rows have stretched until the next Fibonacci
number fits between them.

COLOUR PICKS OUT A FEW ARMS OF EACH HAND. Every floret of one F-arm has the
same index modulo F, and the arms lie round the head in the order of that
index times F_prev (mod F): by Cassini's identity F_prev^2 = +-1 (mod F), so
multiplying by F_prev turns "which arm" into "how far round". A handful of
arms evenly spaced round the head are lit, of the 55 family winding one way
(pink) and the 89 the other (blue). Where a pink and a blue arm cross, the
florets they share are pink.

INWARD, THE ARMS HAND OVER as the spiral counts do on a real head. A 55-arm
stops being a row of neighbours once 21 is the nearer step of that hand
(21, 55, 144, ... alternate with 34, 89, ... in handedness), and followed
further it breaks into single florets 55 steps apart -- confetti. So every
floret inside a family's zone is lit if its nearest same-hand neighbour
outward is: the lit 55-arms continue as 21-arms, then 8-arms, and the 89s as
34s and 13s, each continuation bending off the arm it grew from. The count of
lit arms drops by about the factor the count of arms does (11 of 55 become
4 of 21), so the young middle is calm, crossed by a few arms running into
it; the lit arms that do not continue end at the hand-over ring.
Outward the 55 family is kept past its zone: there 144 is the contact row,
but 55 steps still line up into clean dotted spirals.

THE UNLIT FLORETS ARE SEEDS, not flat dots. Each disc is shaded like a
sphere lit from the front, brightness sqrt(1 - (r/R)^2) from the centre to
0.65 of it at the edge -- limb darkening -- which rounds it without blurring
its outline. And they follow their age: the young florets in the middle of
the head are lighter and the old ones darken toward the rim, as the
unopened buds at the centre of a real head are paler than the open florets
round them, so the panel reads as one head and not a dotted fabric. They
stay far below the lit arms, which a uniform lift of the dark florets
drowned. Floret size also
follows age: the middle florets are the smallest and swell to full size
outward. Discs are a fixed fraction of the spacing, so neighbours never touch
and the ground shows between them.
"""

import numpy as np

TITLE = "Phyllotaxis"
SUBTITLE = "florets at the golden angle, 137.508 deg, radius ~ sqrt(n) (Vogel 1979)"

# The field arrives already coloured, 0..1, and is taken as it is.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
SOFTEN = 0.0
# Smaller than the line generators' 3: a floret is a solid disc, not a
# hairline, and its hue must not bleed into the dark florets beside it.
HUE_SMOOTH = 2.0
# Analytic discs: already band-limited.
SUPERSAMPLE = 1

GOLDEN = np.pi * (3.0 - np.sqrt(5.0))      # 137.5077... deg, in radians

# Disc edge, fraction of the panel height (1 px = 1/2400 at 4K).
SOFT = 1.0 / 2400

# Colours, on the ramp's 0..1: the second family blue, the first pink.
BLUE, PINK = 0.45, 1.0
# Unlit seeds, kept low (teal is 0.2): the centre value of an old floret at
# the rim, what the youngest add to it, the age (in units of `young`) over
# which that lift fades as a Gaussian, and each disc's edge over its centre.
SEED_OLD, SEED_YOUNG, SEED_AGE, SEED_RATIO = 0.015, 0.065, 3.0, 0.65

FIB = [1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377]

# c      -- spacing constant, fraction of panel height: floret n sits at
#           c sqrt(n) from the centre, and its neighbours about 1.9 c away.
# centre -- head centre, fractions of the panel (x from left, y from top).
# fill   -- disc diameter over the neighbour spacing.
# young  -- sqrt(n) over which the middle florets swell to full size.
# arms   -- ((F, lit), (F', lit')): the two families and how many arms of
#           each are coloured. 55 winds one way on screen and 89 the other
#           (55 x 137.508 deg is 2.9 deg past a whole number of turns, 89 x
#           137.508 deg 1.8 deg short of one).
#
# Only the view chosen on a real desktop is here. A calmer one lighting 5 of
# the 55 and 7 of the 89 was shown and pruned: too close to this one.
VIEWS = [
    dict(name="eleven", c=0.015, centre=(0.5, 0.5), fill=0.78, young=12.0,
         arms=((55, 11), (89, 11))),
]


def caption(seed):
    (f1, k1), (f2, k2) = VIEWS[seed % len(VIEWS)]["arms"]
    return (TITLE,
            f"florets at the golden angle, 137.508 deg (Vogel 1979):"
            f"  {k1} of {f1} spirals pink, {k2} of {f2} blue;"
            f" inward the counts drop to 21 and 34, then 8 and 13")


def lit_arms(n, F, k):
    """True for florets on k of the F arms, spread evenly round the head."""
    Fp = FIB[FIB.index(F) - 1]
    j = np.mod(n * Fp, F)            # the arm's place round the head, 0..F-1
    # Bresenham: exactly one lit arm in each run of F/k consecutive ones, so
    # the gaps are the two whole numbers either side of F/k and never 1 --
    # every-k-th-arm doubled two arms up wherever k does not divide F, and 89
    # is prime.
    return np.mod(j * k, F) < k


def carried(n, F, k):
    """lit_arms(n, F, k), carried inward through F's same-hand families.

    For every floret, the nearest neighbour outward of this hand is n + f for
    one f of F, F_-2, F_-4, ...; the distance to it depends on n alone (the
    angle between them is always f x 137.508 deg), in units of c:

        d^2 = (sqrt(n + f) - sqrt n)^2 + 4 sqrt(n (n + f)) sin^2(f golden / 2)

    Outside F's zone the arm test decides; inside it a floret takes the
    colour of that nearest outward neighbour, working from the rim in.
    """
    fams = np.array([f for f in FIB[FIB.index(F)::-2] if f >= 2])
    a = np.sqrt(n + 0.5)[None, :]
    b = np.sqrt(n[None, :] + fams[:, None] + 0.5)
    d2 = (b - a) ** 2 + 4 * a * b * np.sin(fams[:, None] * GOLDEN / 2) ** 2
    step = fams[np.argmin(d2, axis=0)]
    lit = (step == F) & lit_arms(n, F, k)
    for m in np.nonzero(step != F)[0][::-1]:
        lit[m] = lit[m + step[m]]
    return lit


def discs(X, Y, R, core, rim, size, soft):
    """Anti-aliased discs, value `core` at the centre falling to `rim` at the
    edge as a front-lit sphere does, sqrt(1 - q^2), with a Gaussian edge of
    width `soft`; overlaps take the maximum. Pixels, rows down."""
    w, h = size
    out = np.zeros((h, w), np.float32)
    for x, y, r, vc, vr in zip(X, Y, R, core, rim):
        reach = r + 3.0 * soft + 1.0
        xa, xb = max(0, int(x - reach)), min(w, int(x + reach) + 2)
        ya, yb = max(0, int(y - reach)), min(h, int(y + reach) + 2)
        if xa >= xb or ya >= yb:
            continue
        d = np.hypot(np.arange(xa, xb) + 0.5 - x,
                     np.arange(ya, yb)[:, None] + 0.5 - y)
        q = np.minimum(d / r, 1.0)
        edge = np.exp(-(np.maximum(d - r, 0.0) / soft) ** 2)
        v = ((vr + (vc - vr) * np.sqrt(1.0 - q * q)) * edge).astype(np.float32)
        np.maximum(out[ya:yb, xa:xb], v, out=out[ya:yb, xa:xb])
    return out


def generate(size, seed=0, **over):
    v = dict(VIEWS[seed % len(VIEWS)], **over)
    w, h = size
    c = v["c"] * h
    cx, cy = v["centre"][0] * w, v["centre"][1] * h

    # Enough florets that the head covers the farthest corner of the panel,
    # plus a few rings more so no floret at the edge is missing.
    far = max(np.hypot(x - cx, y - cy) for x in (0, w) for y in (0, h))
    n = np.arange(int((far / c + 3) ** 2), dtype=np.int64)
    th = n * GOLDEN
    r = c * np.sqrt(n + 0.5)
    X = cx + r * np.cos(th)
    Y = cy - r * np.sin(th)          # rows count down; up is up

    # Each floret owns an area pi c^2; packed near-hexagonally that is a
    # neighbour spacing of sqrt(2 pi / sqrt 3) c = 1.905 c.
    spacing = np.sqrt(2 * np.pi / np.sqrt(3)) * c
    age = np.sqrt(n + 0.5) / v["young"]
    R = 0.5 * v["fill"] * spacing * (1.0 - 0.55 * np.exp(-age))

    # Seeds: lighter in the young middle, darkening with age toward the rim.
    core = SEED_OLD + SEED_YOUNG * np.exp(-(age / SEED_AGE) ** 2)
    rim = core * SEED_RATIO
    (f1, k1), (f2, k2) = v["arms"]
    for lit, val in ((carried(n, f2, k2), BLUE), (carried(n, f1, k1), PINK)):
        core[lit], rim[lit] = val, val

    keep = (X > -2 * c) & (X < w + 2 * c) & (Y > -2 * c) & (Y < h + 2 * c)
    return discs(X[keep], Y[keep], R[keep], core[keep], rim[keep], size,
                 SOFT * h)
