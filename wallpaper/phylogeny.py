"""Tree of life -- a speciation process run forward and drawn round.

Every living lineage splits in two at a constant rate lambda: the pure-birth
process Yule (1925) wrote down for the number of species in a genus, and still
the null model of macroevolution. Add a death rate mu and it is the
birth-death process of Kendall (1948), the model under which most dated
phylogenies are fitted today. The process is run forward from a single
split until it holds the requested number of living species, and stopped at a
uniformly random moment before the next event, so the youngest pair of sisters
is not artificially identical.

RADIAL LAYOUT. Time runs outward from the root at the centre to the present
on the rim, so every branch length is a span of time and every living species
ends on the same circle. Each tip gets an equal slice of angle in the order of
a depth-first walk, so every clade occupies one contiguous wedge; a split sits
at the mean angle of its two daughters and is joined to them by an arc at the
radius of the moment it happened.

What the shape says. Under a birth process the number of lineages grows as
exp((lambda - mu) t), so the middle of the disc is a few long, early branches
and the rim is a dense fringe of recent splits -- the same picture as the
real tree of life, whose outer ring is almost all of its species. With
extinction the complete tree includes the lineages that died: they stop short
of the rim, and fill the disc with the history the living species do not show.

COLOUR is angle: each clade takes the ramp colour of the centre of its wedge,
so clades read as bands of colour round the ring and a deep branch carries the
mean colour of everything it gave rise to. WIDTH grows with the square root of
a lineage's living descendants, the area-preserving rule of fractaltree.py:
the root lineages are the thickest strokes, the terminal twigs hairlines.

A 40-degree gap is left in the ring at the lower left, where the first clade
would meet the last and where the caption sits.

Views: 0 a Yule tree of 2,500 species; 1 a birth-death tree (mu = 0.55
lambda) of 1,400 living species with its extinct lineages; 2 the tree of view
0 LADDERISED, the smaller daughter clade always first.
"""

import numpy as np

TITLE = "Tree of life"

# Lines on the ground colour, built in 0..1 (see pen.py), so no stretch.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
SOFTEN = 0.0
HUE_SMOOTH = 3.0

# Stroke edge and the least flat core, fractions of panel height (1 px at 4K
# = 1 / 2400). Every stroke gets a core of at least 0.6 px: a pure Gaussian
# hairline shows at 1/sqrt 2 of its value under HUE_SMOOTH and could not get
# past mauve, so the warm clades never reached pink (see shown()). The edge is
# a little tighter than fractaltree.py's so the flat core does not fatten it.
SOFT = 0.8 / 2400
MINCORE = 0.6 / 2400
# Longest chord an arc is cut into, panel heights: sub-pixel sag at any radius.
CHORD = 0.004

# n: living species.  mu: death rate, lambda = 1.  radius: rim, panel heights.
# centre: where the root sits, panel heights from the middle.  gap: degrees
# left open where the last clade meets the first, pointing at gapdir.
# rmax: half-width of a lineage holding every species, panel heights.
PRESETS = {
    "yule": dict(n=2500, mu=0.0, radius=0.64, centre=(0.0, 0.0), gap=40.0,
                 gapdir=240.0, rmax=0.0024),
    "extinction": dict(n=1400, mu=0.55, radius=0.64, centre=(0.0, 0.0),
                       gap=40.0, gapdir=240.0, rmax=0.0024),
}

# (preset, random seed): the seed is the history that happened.
# Only the tree chosen on a real desktop is offered: the birth-death tree
# with its extinct lineages. The pure-birth tree ("yule", seed 4) and the
# same tree ladderised ("ladder", seed 4) were shown and pruned.
TREES = [("extinction", 2)]
PRESETS["ladder"] = dict(PRESETS["yule"], ladder=True)


def shown(val, core):
    """The value to draw so a stroke is SHOWN at `val` on the ramp.

    Under HUE_SMOOTH a stroke's colour is its value-weighted mean over its
    own profile (pen.py): for a flat core of half-width c with Gaussian
    shoulders of scale s that is (2c + s sqrt(pi/2)) / (2c + s sqrt(pi)) of
    the value drawn -- 0.71 for a hairline, near 1 for a broad stroke.
    Dividing by it puts every lineage at its intended colour whatever its
    width, so the thin clades on the warm side reach pink instead of
    stopping at mauve. A ratio of lengths, so the same at any resolution.
    """
    c = 2 * core / SOFT
    return val * (c + np.sqrt(np.pi)) / (c + np.sqrt(np.pi / 2))


def caption(seed):
    """From the preset alone, so a re-colour from a saved field agrees."""
    p = PRESETS[TREES[seed % len(TREES)][0]]
    # Short: the ring's gap at the lower left is where the caption sits, and
    # a line much longer than this runs out of it into the tips.
    if p["mu"] == 0:
        return TITLE, (f"Yule pure-birth speciation to {p['n']:,} species;"
                       + (" smaller branch first" if p.get("ladder")
                          else " time runs outward"))
    return TITLE, (f"species split, and die out at {100 * p['mu']:.0f}% of that"
                   f" rate; {p['n']:,} living")


def simulate(p, rng):
    """Lineages as lists: start, end, parent, extant? and daughters."""
    lam, mu, n = 1.0, p["mu"], p["n"]
    while True:
        start, end, parent, kids = [0.0, 0.0], [0.0, 0.0], [-1, -1], [[], []]
        alive, t = [0, 1], 0.0
        while alive and len(alive) < n:
            t += rng.exponential(1.0 / (len(alive) * (lam + mu)))
            i = int(rng.integers(len(alive)))
            e = alive[i]
            end[e] = t
            if rng.random() < lam / (lam + mu):
                a = len(start)
                start += [t, t]; end += [t, t]; parent += [e, e]
                kids[e] = [a, a + 1]; kids += [[], []]
                alive[i] = a; alive.append(a + 1)
            else:
                alive[i] = alive[-1]; alive.pop()
        if len(alive) >= n:
            break
    # Stop at a uniform moment before the next event would have happened.
    T = t + rng.random() * rng.exponential(1.0 / (n * (lam + mu)))
    extant = np.zeros(len(start), bool)
    for e in alive:
        end[e] = T
        extant[e] = True
    return np.array(start), np.array(end), np.array(parent), kids, extant, T


def layout(start, end, parent, kids, extant, ladder=False):
    """Tip slots in depth-first order; each lineage's angle slot and wedge.

    LADDERISED, the smaller daughter clade is always walked first, the
    convention of most published trees: every split then turns the same way
    and the tree winds round the ring like a shell.
    """
    m = len(start)
    slot = np.zeros(m); lo = np.zeros(m); hi = np.zeros(m)
    ndesc = extant.astype(float)
    tips = np.ones(m)
    for e in range(m - 1, -1, -1):          # daughters are always newer
        if kids[e]:
            tips[e] = tips[kids[e][0]] + tips[kids[e][1]]
    order, stack, nt = [], [1, 0], 0
    while stack:
        e = stack.pop()
        order.append(e)
        if kids[e]:
            a, b = kids[e]
            stack += [a, b] if ladder and tips[a] > tips[b] else [b, a]
        else:
            slot[e] = lo[e] = hi[e] = nt
            nt += 1
    # Post-order: a split sits at the mean of its daughters.
    for e in reversed(order):
        if kids[e]:
            a, b = kids[e]
            slot[e] = 0.5 * (slot[a] + slot[b])
            lo[e], hi[e] = min(lo[a], lo[b]), max(hi[a], hi[b])
            ndesc[e] = ndesc[a] + ndesc[b]
    return slot, lo, hi, ndesc, nt


def generate(size, seed=0, jobs=None, **over):
    import pen

    name, rng_seed = TREES[seed % len(TREES)]
    p = dict(PRESETS[name], **over)
    start, end, parent, kids, extant, T = simulate(p, np.random.default_rng(rng_seed))
    slot, lo, hi, ndesc, nt = layout(start, end, parent, kids, extant, p.get("ladder", False))

    # Slot -> angle, the gap centred on gapdir; time -> radius.
    span = np.radians(360.0 - p["gap"])
    a0 = np.radians(p["gapdir"] + 0.5 * p["gap"])
    ang = a0 + span * (slot + 0.5) / nt
    R = p["radius"]
    r0, r1 = R * start / T, R * end / T

    # Colour: the centre of the lineage's wedge along the ramp.
    core = MINCORE + p["rmax"] * np.sqrt(ndesc / p["n"])
    val = shown(0.3 + 0.7 * (0.5 * (lo + hi) + 0.5) / nt, core)

    # Radial strokes, one per lineage.
    X0, Y0 = r0 * np.cos(ang), r0 * np.sin(ang)
    X1, Y1 = r1 * np.cos(ang), r1 * np.sin(ang)
    V, C = val, core

    # Arcs: at the radius of the split, from the parent's angle to the
    # daughter's, cut into chords no longer than CHORD.
    e = np.nonzero(parent >= 0)[0]
    ta, tb, rr = ang[parent[e]], ang[e], r0[e]
    k = np.maximum(1, np.ceil(np.abs(tb - ta) * rr / CHORD)).astype(int)
    idx = np.repeat(np.arange(len(e)), k)
    f = np.arange(idx.size) - np.repeat(np.cumsum(k) - k, k)
    fa, fb = f / k[idx], (f + 1) / k[idx]
    tha = ta[idx] + (tb - ta)[idx] * fa
    thb = ta[idx] + (tb - ta)[idx] * fb
    X0 = np.concatenate([X0, rr[idx] * np.cos(tha)])
    Y0 = np.concatenate([Y0, rr[idx] * np.sin(tha)])
    X1 = np.concatenate([X1, rr[idx] * np.cos(thb)])
    Y1 = np.concatenate([Y1, rr[idx] * np.sin(thb)])
    V = np.concatenate([V, val[e][idx]])
    C = np.concatenate([C, core[e][idx]])

    w, h = size
    half = 0.5 * w / h
    px, py, _ = pen.to_pixels((-half, half, -0.5, 0.5), size)
    cx, cy = p["centre"]
    return pen.draw(px(X0 + cx), py(Y0 + cy), px(X1 + cx), py(Y1 + cy),
                    C * h, C * h, V, size, soft=SOFT * h, jobs=jobs)
