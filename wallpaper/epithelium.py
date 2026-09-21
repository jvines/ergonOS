"""Cell tissue -- an epithelium, relaxed from a random start.

An epithelium is a sheet one cell thick -- skin, gut lining, a fly's wing
before it unfolds -- and seen from above it is a mosaic of polygons, because
cells packed under tension meet along straight junctions. Which polygons is
not arbitrary. A random (Poisson-Voronoi) packing is 29% hexagons, a relaxed
honeycomb is all hexagons, and real proliferating epithelia sit between: in
the Drosophila wing disc Gibson et al. (Nature 442, 1038, 2006) counted about
29% pentagons, 46% hexagons and 20% heptagons, the same numbers in frog tail
and in Hydra, because it is set by division and not by species.

Built here as a power (Laguerre) diagram: Poisson seeds, each carrying a
weight for how far through its cell cycle it is -- a cell doubles its area
between divisions, so the target area is 2^age -- relaxed by Lloyd's algorithm
(each seed moved to the centroid of its cell). Relaxation walks the topology
from Poisson toward the honeycomb and is stopped part way: the growing view
comes out at 4/29/49/16/2% four- to eight-sided, and its areas obey Lewis's
law (1928), a cell's area growing with its number of sides -- five-, six- and
seven-sided cells average 0.82, 1.04 and 1.25 of the mean, against Lewis's
(n - 2)/4 = 0.75, 1.00, 1.25. No law was put in; those fall out.

The mature view starts from a honeycomb shaken by a third of a cell and is
relaxed further, to 13/80/7% five/six/seven-sided -- the packing of a fly's
pupal wing once divisions stop and junctions remodel (Classen et al., Dev.
Cell 9, 805, 2005). In a honeycomb a five-sided cell beside a seven-sided one
is a dislocation, and here they line up in chains, as dislocations do where
two patches of crystal meet at a slight angle.

What is drawn is a two-channel fluorescence micrograph in cartoon: each cell's
cortex -- the ring of actin under the membrane -- as a rim tinted by the
cell's number of sides (four and five teal, six blue, seven mauve, eight or
more pink), a grainy cytoplasm, and a nucleus with a nucleolus, as bright as
its DNA content: a growing tissue's nuclei differ twofold, G1 against G2. A
few of the largest cells are dividing: rounded up, the chromosomes condensed
into separate rods, lined up across the metaphase plate or pulled apart in
anaphase -- each daughter set a row of Vs, the centromere leading toward its
pole and the arms trailing behind it, the two rows mirror images because
sister chromatids are copies.

Every membrane is an exact distance field. Each pixel finds, among the seeds
near it, the one it belongs to and its distance to every bisector around it;
the smallest is its distance to the cell wall, so edges are anti-aliased at
any resolution with nothing supersampled. A soft minimum over those
distances rounds the corners -- cells under cortical tension are not sharp at
their three-way junctions. The tissue is relaxed and its neighbours counted
on a raster fixed in panel-height units, so an 8K render counts the same
sides as a 4K one.
"""

import numpy as np

TITLE = "Cell tissue"

SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
SATURATION = 2.0
EXPOSURE = 1.05
SUPERSAMPLE = 1
# Hue from the neighbourhood (see lib.render): the soft edge of a pink rim
# otherwise steps down the whole ramp and comes out blue and teal. Kept
# small: the cleft between two differently tinted rims is ~3 px at 4K, and
# the darkening a defringe puts beside a bright edge stays a hairline.
HUE_SMOOTH = 1.0

# Lengths, as fractions of the panel height.
SIZE = 0.075            # mean cell diameter
GAP = 0.0007            # half the dark cleft between neighbouring cells
RIM = 0.0028            # width of the cortex rim
HAZE = 0.004            # reach of the faint cortical haze inside it
ROUND = 0.06            # corner rounding, as a fraction of SIZE
# Edge anti-aliasing, in PIXELS -- the one length here that is not in panel
# units, because it is a filter on the pixel grid, like HUE_SMOOTH, and has
# to match it: set as 0.45/1000 of the height it was 2 px at 8K, too wide for
# a 1 px defringe, and the 8K master grew back the blue edges on pink rims.
AA_PX = 1.0
# Raster, in samples per panel height, on which the tissue is relaxed.
RASTER = 640

# Tone of each part: rims by side count (<=4, 5, 6, 7, >=8), then cytoplasm,
# bloom, nucleus, chromosomes.
SIDES = (0.26, 0.36, 0.60, 0.86, 0.97)
CYTO, CORTEX, BLOOM, NUC, CHROM = 0.005, 0.018, 0.05, 0.13, 0.30

# lloyd iterations, weight of the cell-cycle size spread, fraction of cells in
# mitosis, and the random seed of the whole tissue -- part of the picture, so
# pinned; every random stream below is derived from it.
# Only the tissue chosen on a real desktop is offered. A mature honeycomb
# ("packed": lloyd 20, beta 0.1, no mitosis, seed 5, jitter 0.3) was shown and
# pruned; its caption branch below is kept for reference.
PRESETS = {
    "disc":   dict(lloyd=11, beta=0.4, mitosis=0.02, seed=7),
}


def caption(seed):
    name = list(PRESETS)[seed % len(PRESETS)]
    if name == "disc":
        return TITLE, ("a growing epithelium, each cell tinted by its number of neighbours"
                       " -- mostly five, six and seven, as in a fly's wing; a few dividing")
    return TITLE, ("a mature epithelium settled into a honeycomb; its five-seven pairs"
                   " are the dislocations of a two-dimensional crystal")


def _index(sx, sy, W, nbx, nby):
    bx = np.minimum((sx / W * nbx).astype(np.int64), nbx - 1)
    by = np.minimum((sy * nby).astype(np.int64), nby - 1)
    key = by * nbx + bx
    order = np.argsort(key, kind="stable")
    return order, np.searchsorted(key[order], np.arange(nbx * nby + 1))


def _tessellate(sx, sy, wt, W, h, w, soft=None):
    """Per pixel of an (h, w) raster over [0, W) x [0, 1), periodic: the power
    cell it lies in; with `soft` (per-cell corner radius), also its rounded
    distance to that cell's wall and its offset from the cell's seed.

    Seeds are bucketed on a grid one cell wide, and each block of pixels
    tests only the seeds in the 5 x 5 buckets around it -- every seed that
    can own a pixel there or bound its cell."""
    nby, nbx = max(1, round(1.0 / SIZE)), max(1, round(W / SIZE))
    order, starts = _index(sx, sy, W, nbx, nby)
    lab = np.empty((h, w), np.int64)
    if soft is not None:
        ds, ox, oy = (np.empty((h, w), np.float32) for _ in range(3))
    for jy in range(nby):
        r0, r1 = (min(h, max(0, int(np.ceil(k / nby * h - 0.5)))) for k in (jy, jy + 1))
        for jx in range(nbx):
            c0, c1 = (min(w, max(0, int(np.ceil(k * W / nbx * h - 0.5)))) for k in (jx, jx + 1))
            if r1 <= r0 or c1 <= c0:
                continue
            ids, cx, cy = [], [], []
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    yy, xx = jy + dy, jx + dx
                    k = (yy % nby) * nbx + (xx % nbx)
                    ii = order[starts[k]:starts[k + 1]]
                    ids.append(ii)
                    cx.append(sx[ii] + (xx // nbx) * W)   # periodic images
                    cy.append(sy[ii] + (yy // nby) * 1.0)
            ids, cx, cy = np.concatenate(ids), np.concatenate(cx), np.concatenate(cy)
            X, Y = np.meshgrid((np.arange(c0, c1) + 0.5) / h, (np.arange(r0, r1) + 0.5) / h)
            X, Y = X.reshape(-1, 1), Y.reshape(-1, 1)
            P = (X - cx) ** 2 + (Y - cy) ** 2 - wt[ids]      # power distance
            i1 = np.argmin(P, axis=1)
            shape = (r1 - r0, c1 - c0)
            lab[r0:r1, c0:c1] = ids[i1].reshape(shape)
            if soft is None:
                continue
            ar = np.arange(i1.size)
            ax, ay = cx[i1][:, None], cy[i1][:, None]
            # Distance to the bisector with each other seed; the minimum is
            # the distance to the cell wall (the cell is convex).
            with np.errstate(divide="ignore", invalid="ignore"):
                d = (P - P[ar, i1][:, None]) / (2.0 * np.hypot(cx - ax, cy - ay))
            d[ar, i1] = np.inf
            d[~np.isfinite(d)] = np.inf
            dm = d.min(axis=1)
            k = soft[ids[i1]]
            ds[r0:r1, c0:c1] = (dm - k * np.log(np.exp(-(d - dm[:, None]) / k[:, None])
                                                .sum(axis=1))).reshape(shape)
            ox[r0:r1, c0:c1] = (X - ax).reshape(shape)
            oy[r0:r1, c0:c1] = (Y - ay).reshape(shape)
    return lab if soft is None else (lab, ds, ox, oy)


def _wrap(d, L):
    return (d + L / 2) % L - L / 2


def tissue(W, lloyd, beta, seed, jitter=None):
    """Relaxed seeds and weights, and per-cell centroid, second moments,
    area and number of neighbours, all measured on the fixed raster.

    Seeds are Poisson, or with `jitter` a honeycomb lattice shaken by that
    fraction of a cell -- a tissue that has already packed, whose disorder
    is what relaxation has not yet annealed out."""
    rng = np.random.default_rng([seed, 0])
    A0 = 0.866 * SIZE ** 2
    if jitter is None:
        n = int(round(W / A0))
        sx, sy = rng.random(n) * W, rng.random(n)
    else:
        # An even number of rows, so the lattice closes on itself across
        # the periodic seam; the columns stretch a little to fit the width.
        rows = 2 * max(1, round(1 / (0.866 * SIZE) / 2))
        cols = max(1, round(W / SIZE))
        j, i = np.mgrid[0:rows, 0:cols]
        sx = ((i + 0.5 * (j % 2)) * W / cols).ravel()
        sy = (j / rows).ravel()
        n = sx.size
        sx = (sx + rng.normal(0, jitter * SIZE, n)) % W
        sy = (sy + rng.normal(0, jitter * SIZE, n)) % 1.0
    age = rng.random(n)                          # how far through the cell cycle
    g = 2.0 ** age                               # area doubles over it
    wt = beta * A0 * (g / g.mean() - 1.0)
    rh, rw = RASTER, int(round(RASTER * W))
    XX, YY = np.meshgrid((np.arange(rw) + 0.5) / rh, (np.arange(rh) + 0.5) / rh)
    for it in range(lloyd + 1):
        lab = _tessellate(sx, sy, wt, W, rh, rw)
        L = lab.ravel()
        cnt = np.bincount(L, minlength=sx.size).astype(float)
        dx, dy = _wrap(XX - sx[lab], W), _wrap(YY - sy[lab], 1.0)
        mx = np.bincount(L, dx.ravel(), sx.size) / np.maximum(cnt, 1)
        my = np.bincount(L, dy.ravel(), sx.size) / np.maximum(cnt, 1)
        if it == lloyd:
            break
        # Lloyd: every seed to its cell's centroid. A heavily out-weighed
        # seed can lose its cell altogether; it is simply dropped.
        keep = cnt > 0
        sx, sy, wt, age = ((sx + mx) % W)[keep], ((sy + my) % 1.0)[keep], wt[keep], age[keep]
    dx, dy = dx - mx[lab], dy - my[lab]
    mom = [np.bincount(L, q.ravel(), sx.size) / np.maximum(cnt, 1)
           for q in (dx * dx, dy * dy, dx * dy)]
    # Neighbours: label changes between adjacent raster samples, counting a
    # junction only if it is at least an eighth of a cell long -- a sliver at
    # a near-four-way vertex is not a side anyone would see.
    pairs = []
    for b in (np.roll(lab, -1, 1), np.roll(lab, -1, 0)):
        m = lab != b
        pairs.append(np.minimum(lab[m], b[m]) * sx.size + np.maximum(lab[m], b[m]))
    code, ln = np.unique(np.concatenate(pairs), return_counts=True)
    code = code[ln >= 0.12 * SIZE * RASTER]
    nb = np.bincount(code // sx.size, minlength=sx.size) + \
        np.bincount(code % sx.size, minlength=sx.size)
    return dict(sx=sx, sy=sy, wt=wt, age=age, mx=mx, my=my, mom=mom, nb=nb,
                area=cnt / rh ** 2, n=sx.size)


def _noise(W, h, w, cell, seed):
    """Smooth value noise on a lattice fixed in panel-height units."""
    g = np.random.default_rng(seed).random((int(1 / cell) + 3, int(W / cell) + 3))
    fy, fx = (np.arange(h) + 0.5) / h / cell, (np.arange(w) + 0.5) / h / cell
    iy, ix = fy.astype(int), fx.astype(int)
    ty, tx = fy - iy, fx - ix
    ty, tx = (ty * ty * (3 - 2 * ty))[:, None], (tx * tx * (3 - 2 * tx))[None, :]
    a = g[iy][:, ix] * (1 - tx) + g[iy][:, ix + 1] * tx
    b = g[iy + 1][:, ix] * (1 - tx) + g[iy + 1][:, ix + 1] * tx
    return (a * (1 - ty) + b * ty).astype(np.float32)


def _blur(a, sigma):
    """Gaussian of `sigma` pixels, done on a coarser copy: the bloom is
    smooth, and a full-resolution kernel that wide costs a minute."""
    import lib
    k = max(1, int(sigma // 3))
    h, w = a.shape
    c = lib.smooth(lib.downsample(a, k), sigma / k)
    y = np.clip((np.arange(h) + 0.5) / k - 0.5, 0, c.shape[0] - 1)
    x = np.clip((np.arange(w) + 0.5) / k - 0.5, 0, c.shape[1] - 1)
    y0, x0 = np.minimum(y.astype(int), c.shape[0] - 2), np.minimum(x.astype(int), c.shape[1] - 2)
    fy, fx = (y - y0)[:, None], (x - x0)[None, :]
    top = c[y0][:, x0] * (1 - fx) + c[y0][:, x0 + 1] * fx
    bot = c[y0 + 1][:, x0] * (1 - fx) + c[y0 + 1][:, x0 + 1] * fx
    return top * (1 - fy) + bot * fy


def _ellipse(ox, oy, cx, cy, th, ra, rb, aa):
    """Anti-aliased filled ellipse, per pixel of its own cell; also q, the
    ellipse radius coordinate (0 at the centre, 1 on the edge)."""
    dx, dy = ox - cx, oy - cy
    c, s = np.cos(th), np.sin(th)
    q = np.hypot((dx * c + dy * s) / ra, (-dx * s + dy * c) / rb)
    return np.clip(0.5 + (1 - q) * rb / aa, 0, 1), q


def _chromosomes(rng, ana, sep):
    """Condensed chromosomes of one dividing cell as rods (a0, b0, a1, b1,
    tone), in units of the cell's radius: a along the spindle, b along the
    plate. Metaphase: each chromosome a rod across the plate. Anaphase: two
    mirrored rows of Vs, the vertex -- the centromere -- toward the pole."""
    k = int(rng.integers(10, 15))
    tone = rng.uniform(0.85, 1.0, k)
    if not ana:
        # Seen edge-on, the plate is a comb: arms stick out toward the
        # poles, nearly parallel, the ends ragged.
        b = np.linspace(-0.40, 0.40, k) + rng.normal(0, 0.015, k)
        a = rng.normal(0, 0.03, k)
        th, half = rng.normal(0, 0.22, k), 0.5 * rng.uniform(0.12, 0.22, k)
        da, db = half * np.cos(th), half * np.sin(th)
        return np.stack([a - da, b - db, a + da, b + db, tone], 1)
    b = np.linspace(-0.38, 0.38, k) + rng.normal(0, 0.015, k)
    lead = rng.normal(0, 0.02, k)                      # how far ahead each is
    arm = rng.uniform(0.15, 0.35, k)                   # half-opening of the V
    tilt = rng.normal(0, 0.15, k)
    l1 = rng.uniform(0.08, 0.15, k)
    l2 = l1 * np.where(rng.random(k) < 0.25, 0.0, rng.uniform(0.5, 1.0, k))
    rods = []
    for s in (1, -1):                                  # the two daughter sets
        av = s * (sep + lead + rng.normal(0, 0.01, k))
        bv = b + rng.normal(0, 0.01, k)
        for ang, ln in ((tilt + arm, l1), (tilt - arm, l2)):
            keep = ln > 0
            rods.append(np.stack([av, bv, av - s * ln * np.cos(ang),
                                  bv + ln * np.sin(ang), tone], 1)[keep])
    return np.concatenate(rods)


def _rods(a, b, segs, rad, aa):
    """Union of anti-aliased capsules (segments with round ends) at the
    points (a, b); the exact distance to each, so crisp at any scale."""
    out = np.zeros_like(a)
    for a0, b0, a1, b1, tone in segs:
        da, db = a1 - a0, b1 - b0
        t = np.clip(((a - a0) * da + (b - b0) * db) / max(da * da + db * db, 1e-18), 0, 1)
        d = np.hypot(a - a0 - t * da, b - b0 - t * db) - rad
        out = np.maximum(out, tone * np.clip(0.5 - d / aa, 0, 1))
    return out


def generate(size, seed=0, **kw):
    w, h = size
    W = w / h
    p = dict(PRESETS[list(PRESETS)[seed % len(PRESETS)]]); p.update(kw)
    t = tissue(W, p["lloyd"], p["beta"], p["seed"], p.get("jitter"))
    n, rng = t["n"], np.random.default_rng([p["seed"], 1])
    r = np.sqrt(t["area"] / np.pi)

    # Dividing cells: drawn from the largest third, since a cell divides
    # after it has doubled. They round up, so their corners soften further.
    big = np.nonzero(t["area"] >= np.quantile(t["area"], 2 / 3))[0]
    mit = np.zeros(n, bool)
    mit[rng.choice(big, int(round(p["mitosis"] * n)), replace=False)] = True
    soft = np.where(mit, 0.15, ROUND) * SIZE
    lab, ds, ox, oy = _tessellate(t["sx"], t["sy"], t["wt"], W, h, w, soft=soft)
    aa = AA_PX / h

    tone = np.array(SIDES)[np.clip(t["nb"], 4, 8) - 4][lab].astype(np.float32)
    e = ds - GAP
    inside = np.clip(0.5 + e / aa, 0, 1)
    ring = np.clip(0.5 + (RIM - e) / aa, 0, 1)
    rim = tone * inside * ring
    grain = _noise(W, h, w, 0.004, [p["seed"], 2])
    haze = CORTEX * np.exp(-np.maximum(e - RIM, 0) / HAZE)
    f = np.maximum(rim, inside * (CYTO * (0.5 + grain) + haze))
    f += BLOOM * _blur(rim, 0.006 * h)

    # Nuclei: centred near the centroid, elongated along the cell's own long
    # axis, about 0.3 of its radius -- nucleus size tracks cell size.
    sxx, syy, sxy = t["mom"]
    th = 0.5 * np.arctan2(2 * sxy, sxx - syy)
    half = np.sqrt(np.maximum((sxx - syy) ** 2 / 4 + sxy ** 2, 0))
    el = (np.sqrt((sxx + syy) / 2 + half) / np.sqrt(np.maximum((sxx + syy) / 2 - half, 1e-12))) ** 0.4
    ra, rb = 0.28 * r * el, 0.28 * r / el
    jx, jy = t["mx"] + rng.normal(0, 0.08, n) * r, t["my"] + rng.normal(0, 0.08, n) * r
    L = lab
    nuc, q = _ellipse(ox, oy, jx[L], jy[L], th[L], ra[L], rb[L], aa)
    # One nucleolus each, a darker spot off centre.
    ang, off = rng.random(n) * 2 * np.pi, 0.35 * rng.random(n)
    nx, ny = jx + off * ra * np.cos(ang), jy + off * rb * np.sin(ang)
    nol, _ = _ellipse(ox, oy, nx[L], ny[L], th[L], 0.22 * rb[L], 0.18 * rb[L], aa)
    chrom = _noise(W, h, w, 0.0016, [p["seed"], 3])
    # Brightness is DNA content: 2C until S phase, 4C after it, so a stained
    # nucleus doubles in brightness through the cycle. A tissue that has
    # stopped dividing sits at 2C throughout.
    dna = 1 + np.clip((t["age"] - 0.35) / 0.35, 0, 1) if p["mitosis"] > 0 else np.ones(n)
    nuc = NUC * dna[L] * nuc * (0.72 + 0.28 * chrom) * (1 - 0.45 * nol)

    # Mitoses: no nuclear envelope, the chromosomes condensed into rods
    # across the middle (metaphase) or pulled apart (anaphase), every other
    # one. The plate lies along phi, the spindle across it. Each cell's rods
    # come from its own stream, pinned to the preset's seed and its index.
    phi = rng.random(n) * np.pi
    m = mit[L]
    pix = np.nonzero(m.ravel())[0]
    who = L.ravel()[pix]
    chroms = np.zeros(pix.size, np.float32)
    for k, i in enumerate(np.nonzero(mit)[0]):
        sel = who == i
        u = ox.ravel()[pix[sel]] - t["mx"][i]
        v = oy.ravel()[pix[sel]] - t["my"][i]
        cp, sp = np.cos(phi[i]), np.sin(phi[i])
        segs = _chromosomes(np.random.default_rng([p["seed"], 4, i]), k % 2 == 1, 0.32)
        segs[:, :4] *= r[i]
        chroms[sel] = _rods(-u * sp + v * cp, u * cp + v * sp, segs, 0.022 * r[i], aa)
    nuc = nuc.ravel()
    nuc[pix] = CHROM * chroms
    return np.maximum(f, nuc.reshape(h, w)).astype(np.float64)
