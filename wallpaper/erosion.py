"""Hydraulic erosion -- rain on the Perlin landscape, and the rivers it cuts.

perlinmap.py draws gradient noise as a topographic map. Noise has the
roughness of land but not its history: nothing has flowed over it, so its
valleys are wherever the noise happened to dip and no two of them join. Real
relief is carved. Water runs downhill, picks up sediment where it is fast and
drops it where it slows, and over time the channels deepen into a branching
drainage network that organises the whole landscape around it.

The carving here is particle erosion (Beyer 2015, after Mei et al. 2007):
droplets fall at random on the land, RAIN to each cell of it, and each runs
downhill with a little inertia for a few dozen cells.

  * its sediment capacity is proportional to its speed, its water and how
    fast it is descending, c = K v w (-dh);
  * over capacity, or climbing, it deposits (bilinearly, at its position);
    under capacity it erodes, from a small disc of ground under it;
  * v^2 grows with the drop it has fallen, and its water evaporates;
  * one that reaches the sea carries its load out with it. Dropped on the
    last cell of land instead, it built a levee along every coast, and the
    rivers behind it ran along the shore, in pairs, to a hooked mouth;
  * the sea is the base level: land is cut down toward it, never below, so
    the coast is perlinmap's to the pixel.

Droplets run in parallel batches, with every erosion and deposit summed by
bincount -- so the result does not depend on how many cores ran it.

The drainage is then read off the carved ground. Pits are filled by a
priority flood (Barnes et al. 2014) so every cell drains to the sea or the
panel edge; each cell passes its water to its steepest neighbour (D8); the
catchment area A of a cell is the number of cells that drain through it.
Channels are the cells with A above a threshold, as on real ground (a stream
begins where enough land drains to it), and one within CAPTURE cells of a
bigger, lower channel joins it -- two grooves in one valley floor are one
river. (Routing over ground smoothed at the droplets' scale merged them too,
but erased the rills that make D8 converge: planar slopes combed into
straight lines at 0, 45 and 90 degrees.) A filled pit of LAKE_AREA cells or
more is a lake, with a shore; a smaller one is only filled, and the river
runs on through it.

DRAWN as a map: the carved relief as faint contours and the rivers as
analytic strokes over them, wider downstream (width ~ A^0.45,
as channel width follows discharge, Leopold & Maddock 1953) and brighter,
teal at the headwaters to pink at the mouths. The D8 paths are smoothed along
each stream before drawing, so the rivers meander instead of stepping at 45
degrees. The sea is the empty ground.
"""

import heapq

import numpy as np

import lib
import pen
import perlinmap as pm

TITLE = "Hydraulic erosion"
SUBTITLE = ("a Perlin landscape after three droplets of rain to every cell of land;"
            " rivers widen with the area they drain")

# The field arrives toned, 0..1: faint contours, a brighter coast, rivers on
# top (see bifurcation.py for why a generator does its own). Lines are
# analytic strokes, already anti-aliased, so no SOFTEN and no supersampling;
# HUE_SMOOTH keeps each stroke's edge in its own colour.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
RAMP = "full"
SATURATION = 2.0
EXPOSURE = 1.05
SOFTEN = 0.0
HUE_SMOOTH = 3.0
SUPERSAMPLE = 1

GRID = 800                # erosion lattice, cells per panel height
PAD = 24                  # lattice cells carved beyond each panel edge
PX = 1.0 / 2400           # one pixel at 4K, in panel heights

# The droplets, Beyer's parameters. Lengths in cells; heights in cells too,
# sea level at 0 and the land's 98th percentile at RELIEF.
RELIEF = 60.0
INERTIA = 0.1
CAPACITY = 4.0
MIN_CAP = 0.01
ERODE = 0.3
DEPOSIT = 0.3
EVAPORATE = 0.015
GRAVITY = 4.0
RADIUS = 3
LIFE = 64                 # steps a droplet runs
BATCH = 40000             # droplets in flight at once
RAIN = 3                  # droplets to each cell of land (the caption says so)

# Views: zoom and centre (panel heights) on perlinmap's map, and the seed of
# the rain -- part of the picture, so pinned.
# Only "the eastern basins" was chosen on a real desktop; "the continent"
# (zoom 1, centred, seed 1 -- perlinmap's own view) was shown and pruned.
VIEWS = [
    dict(name="the eastern basins", zoom=2.0, centre=(0.25, -0.05), seed=1),
]

# Drawing. Lengths in 4K pixels, values on the 0..1 ramp.
A0 = 300                  # catchment (cells) at which a stream begins
LEVELS = 12               # contour levels from the coast to RELIEF
LINE = (0.05, 0.10)       # contour value, coast to peaks: under the ramp's
                          # first stop, so they sit dim beneath the rivers
COAST = 0.3               # coast and lake shores, with perlinmap's coast pen
RIVER = (0.5, 1.0)        # river value, headwater to the panel's largest
CORE = 0.5                # river core half-width at A0 ...
WIDTH_EXP = 0.45          # ... growing as A^0.45 downstream
SOFT = 0.6                # stroke edge
SMOOTH_PASSES = 6         # (1,2,1)/4 passes along each stream
LAKE = 0.3                # a lake stands this deep (cells) somewhere ...
LAKE_AREA = 40            # ... and covers this many cells
CAPTURE = 3               # cells: a channel this close to a bigger one joins it
MIN_RUN = 12              # cells: shorter streams into the sea are not drawn
CONTOUR_SMOOTH = 2.0      # cells: droplets roughen the ground at their scale
GAP_SMOOTH = 4.0          # cells: the ground whose slope fades crowded contours


def _grid(view, gw, gh):
    """Elevation on the lattice, in units of the land's relief (sea at 0).
    The lattice reaches PAD cells past the panel on every side, so rain
    falls, and rivers run, across the panel edge as if it were not there."""
    s = pm._survey(gw / gh)
    y, x = np.mgrid[-PAD:gh + PAD, -PAD:gw + PAD]
    X = ((x + 0.5) / gh - gw / gh / 2) / view["zoom"] + view["centre"][0]
    Y = ((y + 0.5) / gh - 0.5) / view["zoom"] + view["centre"][1]
    return (pm._height(X, Y) - s["sea"]) / (s["qh"][-2] - s["sea"])


def _erode(H, view):
    """Run the rain over H (in cells: relief RELIEF) in place."""
    gh, gw = H.shape
    flat = H.ravel()
    rng = np.random.default_rng(view["seed"])
    # The erosion brush: the nodes within RADIUS + 1 of the droplet's cell,
    # as flat-index offsets, each weighted by RADIUS - (its distance from the
    # droplet) -- a cone centred on the droplet itself, not on a node, so the
    # ground is removed where the gradient was read.
    # Droplets are kept RADIUS + 3 cells from the edge so it never clips.
    r = RADIUS + 1
    oy, ox = np.mgrid[-r:r + 1, -r:r + 1]
    disc = ox * ox + oy * oy <= r * r
    ox, oy = ox[disc].astype(float), oy[disc].astype(float)
    boff = (oy * gw + ox).astype(np.int64)
    m = r + 2
    # Rain on land only: a cell of land at random, a point anywhere in it --
    # so RAIN droplets fall on each, as the caption says.
    ly, lx = np.nonzero(H[m:gh - m, m:gw - m] > 0)
    total = RAIN * ly.size
    # The sea is the base level: land is cut down toward it and never below.
    # Without that, the load carried out to sea is a sink, the sea ran up
    # every valley it deepened, and the land dissolved into fjords.
    base = np.where(flat > 0, 1e-3, -np.inf)
    for b0 in range(0, total, BATCH):
        n = min(BATCH, total - b0)
        k = rng.integers(0, ly.size, n)
        x = lx[k] + m + rng.random(n)
        y = ly[k] + m + rng.random(n)
        dx = np.zeros_like(x); dy = np.zeros_like(x)
        vel = np.ones_like(x); water = np.ones_like(x); sed = np.zeros_like(x)
        for _ in range(LIFE):
            if x.size == 0:
                break
            ix, iy = x.astype(np.int64), y.astype(np.int64)
            u, v = x - ix, y - iy
            i0 = iy * gw + ix
            a, b_, c, d = flat[i0], flat[i0 + 1], flat[i0 + gw], flat[i0 + gw + 1]
            gx = (b_ - a) * (1 - v) + (d - c) * v
            gy = (c - a) * (1 - u) + (d - b_) * u
            h = a * (1 - u) * (1 - v) + b_ * u * (1 - v) + c * (1 - u) * v + d * u * v
            dx = dx * INERTIA - gx * (1 - INERTIA)
            dy = dy * INERTIA - gy * (1 - INERTIA)
            L = np.hypot(dx, dy)
            moving = L > 1e-12
            dx = np.where(moving, dx / np.maximum(L, 1e-12), 0.0)
            dy = np.where(moving, dy / np.maximum(L, 1e-12), 0.0)
            nx, ny = x + dx, y + dy
            alive = moving & (nx >= m) & (nx < gw - m) & (ny >= m) & (ny < gh - m)
            jx = np.clip(nx, 1, gw - 2.001).astype(np.int64)
            jy = np.clip(ny, 1, gh - 2.001).astype(np.int64)
            p, q = np.clip(nx, 1, gw - 2.001) - jx, np.clip(ny, 1, gh - 2.001) - jy
            j0 = jy * gw + jx
            hn = (flat[j0] * (1 - p) * (1 - q) + flat[j0 + 1] * p * (1 - q)
                  + flat[j0 + gw] * (1 - p) * q + flat[j0 + gw + 1] * p * q)
            dh = hn - h
            cap = np.maximum(-dh * vel * water * CAPACITY, MIN_CAP)
            dep = (sed > cap) | (dh > 0)
            amt = np.where(dh > 0, np.minimum(dh, sed), (sed - cap) * DEPOSIT)
            # A droplet that has stopped or left the map drops its whole load
            # where it stands. One that reaches the sea takes it out to sea.
            sea = alive & (hn <= 0)
            stop = ~alive | sea
            amt = np.where(sea, 0.0, np.where(stop, sed, np.where(dep, amt, 0.0)))
            ero = np.where(dep | stop, 0.0,
                           np.minimum((cap - sed) * ERODE, -dh))
            flat += np.bincount(np.concatenate([i0, i0 + 1, i0 + gw, i0 + gw + 1]),
                                np.concatenate([amt * (1 - u) * (1 - v), amt * u * (1 - v),
                                                amt * (1 - u) * v, amt * u * v]),
                                minlength=gw * gh)
            # Erosion from the cone under the droplet.
            wt = np.maximum(RADIUS - np.hypot(ox - u[:, None], oy - v[:, None]), 0.0)
            wt *= (ero / wt.sum(1))[:, None]
            flat -= np.bincount((i0[:, None] + boff).ravel(), wt.ravel(),
                                minlength=gw * gh)
            np.maximum(flat, base, out=flat)
            sed = sed - amt + ero
            vel = np.sqrt(np.maximum(vel * vel - dh * GRAVITY, 0.0))
            water *= 1 - EVAPORATE
            alive &= ~stop
            x, y, dx, dy = nx[alive], ny[alive], dx[alive], dy[alive]
            vel, water, sed = vel[alive], water[alive], sed[alive]


def _drainage(H, land):
    """Priority-flood fill, D8 receivers and catchment area on the lattice:
    H the ground the water is routed over, land the cells above the sea."""
    gh, gw = H.shape
    n = gh * gw
    land = land.ravel()
    F = H.ravel().copy()
    iy, ix = np.divmod(np.arange(n), gw)
    border = (iy == 0) | (iy == gh - 1) | (ix == 0) | (ix == gw - 1)
    nb = [(dy, dx) for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dy or dx]
    # Outlets: sea cells touching land, and land on the panel edge.
    L2 = land.reshape(gh, gw)
    shore = np.zeros_like(L2)
    for dy, dx in nb:
        shore |= np.roll(np.roll(L2, dy, 0), dx, 1)
    seeds = np.flatnonzero((~land & shore.ravel()) | (land & border))
    done = bytearray(n)
    for i in seeds:
        done[i] = 1
    heap = [(F[i], int(i)) for i in seeds]
    heapq.heapify(heap)
    Fl = F.tolist()
    lnd = land.tolist()
    offs = [dy * gw + dx for dy, dx in nb]
    eps = 1e-7
    while heap:
        f, c = heapq.heappop(heap)
        cy, cx = divmod(c, gw)
        for (dy, dx), o in zip(nb, offs):
            yy, xx = cy + dy, cx + dx
            if yy < 0 or yy >= gh or xx < 0 or xx >= gw:
                continue
            m = c + o
            if done[m] or not lnd[m]:
                continue
            done[m] = 1
            if Fl[m] <= f + eps:
                Fl[m] = f + eps
            heapq.heappush(heap, (Fl[m], m))
    F = np.array(Fl).reshape(gh, gw)
    # D8: steepest descent on the filled surface, slopes over true distance.
    best = np.zeros((gh, gw)); rec = np.full((gh, gw), -1, np.int64)
    idx = np.arange(n).reshape(gh, gw)
    for dy, dx in nb:
        sh = np.roll(np.roll(F, -dy, 0), -dx, 1)
        slope = (F - sh) / np.hypot(dy, dx)
        tgt = np.roll(np.roll(idx, -dy, 0), -dx, 1)
        inside = np.ones((gh, gw), bool)
        if dy: inside[(0 if dy < 0 else gh - 1), :] = False
        if dx: inside[:, (0 if dx < 0 else gw - 1)] = False
        better = inside & (slope > best)
        best = np.where(better, slope, best)
        rec = np.where(better, tgt, rec)
    rec = rec.ravel()
    rec[~land | border] = -1
    # Catchment: pass each cell's area down, highest cells first.
    order = np.flatnonzero(land)
    order = order[np.argsort(-F.ravel()[order], kind="stable")].tolist()

    def catchment(rec):
        acc, rl = [1.0] * n, rec.tolist()
        for i in order:
            if rl[i] >= 0:
                acc[rl[i]] += acc[i]
        return np.array(acc)
    acc = catchment(rec)
    # Two channels a few cells apart on one valley floor are one channel:
    # D8 on the droplets' rills ran them side by side to the sea, like rails.
    # A channel cell with a bigger channel within CAPTURE cells, lower down,
    # drains into it (downhill only, so no loops), and the areas are summed
    # again. Rounded strokes wider than the gap would have merged them anyway.
    Ff, idx = F.ravel(), np.arange(n)
    inner = (iy >= CAPTURE) & (iy < gh - CAPTURE) & (ix >= CAPTURE) & (ix < gw - CAPTURE)
    for _ in range(2):
        top = np.where(acc >= A0 / 2, acc, np.inf)
        to = np.full(n, -1)
        for dy in range(-CAPTURE, CAPTURE + 1):
            for dx in range(-CAPTURE, CAPTURE + 1):
                if 0 < dy * dy + dx * dx <= CAPTURE * CAPTURE:
                    j = np.roll(np.roll(idx.reshape(gh, gw), -dy, 0), -dx, 1).ravel()
                    ok = (acc[j] > top) & (Ff[j] < Ff) & land[j] & (rec >= 0) & inner
                    top = np.where(ok, acc[j], top)
                    to = np.where(ok, j, to)
        rec = np.where(to >= 0, to, rec)
        acc = catchment(rec)
    return rec, acc, _lakes((F - H).reshape(gh, gw))


def _lakes(depth):
    """The lakes: pools of the filled surface of LAKE_AREA cells or more,
    LAKE deep somewhere -- water stands there, and a river drawn across one
    would be a D8 artefact. Smaller pits are only filled, and the river runs
    through them: drawn as lakes they had no visible shore and cut it into
    dashes. Pools are labelled by propagating the largest cell index across
    each, with pointer jumping (a label is itself a cell of the pool)."""
    wet = depth > 0.02
    lab = np.where(wet, np.arange(wet.size).reshape(wet.shape), -1)
    while True:
        new = lab
        for ax in (0, 1):
            for s in (1, -1):
                new = np.maximum(new, np.roll(lab, s, ax))
        new = np.where(wet, new, -1).ravel()
        new = np.where(new >= 0, new[np.maximum(new, 0)], -1).reshape(wet.shape)
        if np.array_equal(new, lab):
            break
        lab = new
    pool = lab[wet]
    area = np.bincount(pool, minlength=wet.size)
    deep = np.zeros(wet.size)
    np.maximum.at(deep, pool, depth[wet])
    lake = np.zeros(wet.shape, bool)
    lake[wet] = (area >= LAKE_AREA)[pool] & (deep > LAKE)[pool]
    return lake.ravel()


def _cubic(a, n, axis):
    """Resample `a` along `axis` to n samples: Keys cubic (a = -1/2), C1, so
    the contours drawn from its gradient have no creases at cell edges. The
    lattice spans the panel: cell i is centred at (i + 0.5) / m of it."""
    m = a.shape[axis]
    t = (np.arange(n) + 0.5) * m / n - 0.5
    i0 = np.floor(t).astype(np.int64)
    f = t - i0
    out = 0.0
    for k in (-1, 0, 1, 2):
        s = np.abs(f - k)
        wk = np.where(s <= 1, 1.5 * s ** 3 - 2.5 * s ** 2 + 1,
                      np.where(s < 2, -0.5 * s ** 3 + 2.5 * s ** 2 - 4 * s + 2, 0.0))
        shape = [1, 1]; shape[axis] = n
        out = out + np.take(a, np.clip(i0 + k, 0, m - 1), axis=axis) * wk.reshape(shape)
    return out


def _lines(z, gx, gy, grad, gap, px):
    """perlinmap's contours (its pens, its fades), except that crowded lines
    fade by `gap`, the contour spacing on smoother ground: on the rough ground
    droplets leave, the local spacing flickers along a line, and so did the
    fade, which chopped steep contours into dashes."""
    step = RELIEF / LEVELS
    k = z / step
    n = np.round(k)
    kind = np.where(n == 0, 2, np.where(n % pm.INDEX == 0, 1, 0))
    ink = pm._pen(np.abs(k - n) * step / grad, np.choose(kind, [p[0] for p in pm.PENS]),
                  np.choose(kind, [p[1] for p in pm.PENS]), px)
    fade = np.where(kind == 0, pm._smooth(1.5 * PX, 5 * PX, gap),
                    np.where(kind == 1, pm._smooth(1.5 * PX, 5 * PX, pm.INDEX * gap), 1.0))
    hxy, hxx = np.gradient(gx, px)
    hyy = np.gradient(gy, px, axis=0)
    bend = np.abs(hxx * gy * gy - 2 * hxy * gx * gy + hyy * gx * gx) / grad ** 3
    fade = fade * pm._smooth(1.5 * PX, 3 * PX, 1.0 / (bend + 1e-9))
    return np.where(n >= 0, ink * fade, 0.0)


def _contours(Hs, Ls, G, size, rows=200):
    """Faint contours of the carved relief, the coast, and the lake shores
    (Ls: the smoothed lake mask, shore at 0.5), in bands with a margin. G is
    the slope of smoother ground, per panel height, for the crowding fade."""
    w, h = size
    px = 1.0 / h
    step = RELIEF / LEVELS
    out = np.zeros((h, w), np.float32)
    for j0 in range(0, h, rows):
        a, b = max(0, j0 - 2), min(h, j0 + rows + 2)
        z = Hs[a:b]
        gy, gx = np.gradient(z, px)
        grad = np.hypot(gx, gy) + 1e-9
        tone = LINE[0] + (LINE[1] - LINE[0]) * np.clip(z / RELIEF, 0, 1)
        tone = np.where(np.round(z / step) == 0, COAST, tone)
        ink = tone * _lines(z, gx, gy, grad, step / (G[a:b] + 1e-9), px)
        # A lake's surface is flat: no contours on it, and its shore drawn
        # with the coast's pen, as a distance to the mask's half level.
        m = Ls[a:b]
        ly, lx = np.gradient(m, px)
        d = np.abs(m - 0.5) / (np.hypot(lx, ly) + 1e-9)
        ink = np.maximum(ink * np.clip((0.6 - m) / 0.2, 0, 1),
                         COAST * pm._pen(d, *pm.PENS[2], px))
        j1 = min(h, j0 + rows)
        out[j0:j1] = ink[j0 - a:j0 - a + (j1 - j0)]
    return out


def _rivers(rec, acc, lake, pw, gh, size):
    """The channel network as smoothed, width-graded strokes. pw is the padded
    lattice's width, gh the panel's height in cells."""
    w, h = size
    riv = np.flatnonzero((acc >= A0) & ~lake)
    loc = np.full(acc.size, -1, np.int64)
    for k in range(2):
        loc[:] = -1
        loc[riv] = np.arange(riv.size)
        r = rec[riv]
        down = np.where(r >= 0, loc[np.maximum(r, 0)], -1)
        if k:
            break
        # A slope that only gathers A0 a cell or two from the shore made a
        # stub across the coastline, and a coast of them read as hatching:
        # a stream whose longest run to the sea or a lake is under MIN_RUN
        # cells is not drawn. Area grows downstream, so sorting by it orders
        # every stream from its source to its mouth.
        o = np.argsort(acc[riv], kind="stable").tolist()
        dl, run, keep = down.tolist(), [0] * riv.size, [True] * riv.size
        for i in o:
            if dl[i] >= 0:
                run[dl[i]] = max(run[dl[i]], run[i] + 1)
        for i in reversed(o):
            keep[i] = keep[dl[i]] if dl[i] >= 0 else run[i] + 1 >= MIN_RUN
        riv = riv[np.array(keep)]
    # The main stem upstream of each cell: its largest tributary.
    src = np.flatnonzero(down >= 0)
    dst = down[src]
    o = np.lexsort((acc[riv][src], dst))
    src, dst = src[o], dst[o]
    last = np.r_[dst[1:] != dst[:-1], True]
    up = np.full(riv.size, -1, np.int64)
    up[dst[last]] = src[last]
    # Cell centres, in cells from the panel's corner.
    X = (riv % pw) + 0.5 - PAD
    Y = (riv // pw) + 0.5 - PAD
    # Where a stream leaves the network -- into the sea -- it ends at that
    # sea cell's centre, which stays put.
    ex = np.where(r >= 0, np.maximum(r, 0) % pw + 0.5 - PAD, X)
    ey = np.where(r >= 0, np.maximum(r, 0) // pw + 0.5 - PAD, Y)
    edge = r < 0
    # Smooth each stream along itself, (1, 2, 1)/4 per pass: the D8 zigzag
    # goes, the junctions stay joined because both ends move together.
    for _ in range(SMOOTH_PASSES):
        xd = np.where(down >= 0, X[np.maximum(down, 0)], ex)
        yd = np.where(down >= 0, Y[np.maximum(down, 0)], ey)
        xu = np.where(up >= 0, X[np.maximum(up, 0)], X)
        yu = np.where(up >= 0, Y[np.maximum(up, 0)], Y)
        X = np.where(edge, X, (xd + 2 * X + xu) / 4)
        Y = np.where(edge, Y, (yd + 2 * Y + yu) / 4)
    xd = np.where(down >= 0, X[np.maximum(down, 0)], ex)
    yd = np.where(down >= 0, Y[np.maximum(down, 0)], ey)
    a = acc[riv]
    k = ~edge
    cell = h / gh                                   # pixels per cell
    core = CORE * PX * h * (a / A0) ** WIDTH_EXP
    # Colour runs up to the largest river IN the panel.
    seen = (X > 0) & (X < pw - 2 * PAD) & (Y > 0) & (Y < gh)
    lvl = np.clip(np.log(a / A0) / np.log(a[seen].max() / A0), 0, 1)
    val = RIVER[0] + (RIVER[1] - RIVER[0]) * lvl
    return pen.draw(X[k] * cell, Y[k] * cell, xd[k] * cell, yd[k] * cell,
                    core[k], core[k], val[k], size, SOFT * PX * h)


def caption(seed):
    v = VIEWS[seed % len(VIEWS)]
    return TITLE, f"{SUBTITLE} ({v['name']})"


def carve(view, gw, gh):
    """The landscape after the rain, on a (gh, gw) lattice, heights in cells."""
    H = _grid(view, gw, gh) * RELIEF
    _erode(H, view)
    return H


def draw(H, size):
    """The map of carved ground H (padded) at panel size: contours, rivers."""
    w, h = size
    gh, gw = H.shape[0] - 2 * PAD, H.shape[1] - 2 * PAD
    H32 = H.astype(np.float32)
    rec, acc, lake = _drainage(H, H > 0)

    def panel(a):                     # lattice -> panel pixels, smoothly
        return _cubic(_cubic(a[PAD:PAD + gh, PAD:PAD + gw].astype(np.float64), h, 0), w, 1)
    # The relief for the contours: lightly smoothed (particle erosion leaves
    # cell-scale pits that would print as specks), then resampled smoothly.
    Hl = lib.smooth(H32, CONTOUR_SMOOTH)
    Hs = panel(Hl)
    Ls = panel(lib.smooth(lake.reshape(H.shape).astype(np.float32), 1.5))
    gy, gx = np.gradient(lib.smooth(H32, GAP_SMOOTH).astype(np.float64))
    G = panel(np.hypot(gx, gy) * gh)  # heights per panel height
    field = _contours(Hs, Ls, G, size)
    del Hs, Ls, G
    # No river within a cell of a lake: along a shore the D8 path threads
    # in and out of the lake cells and drew as a row of dashes.
    near = lake.reshape(H.shape).copy()
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        near |= np.roll(np.roll(lake.reshape(H.shape), dy, 0), dx, 1)
    # Nor past the coast as drawn: a river mouth cut down to sea level lies
    # under the smoothed coastline, and the rivers ran on out to sea.
    near |= Hl <= 0
    return np.maximum(field, _rivers(rec, acc, near.ravel(), gw + 2 * PAD, gh, size))


def generate(size, seed=0):
    w, h = size
    return draw(carve(VIEWS[seed % len(VIEWS)], int(round(GRID * w / h)), GRID), size)
