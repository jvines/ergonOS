"""Leaf venation -- veins grown toward the hormone that calls for them.

A leaf's veins are not laid down to a plan. Cells that sense the hormone auxin
pump it on to their neighbours, the flux canalises into files of cells, and the
files become veins draining auxin into the network. Runions et al. (2005,
"Modeling and visualization of leaf venation patterns") made that an algorithm,
SPACE COLONISATION: auxin SOURCES are scattered through the blade, no closer
than a birth distance b to each other or to a vein; every vein node a source
calls steps a distance D toward it (toward the sum of unit vectors, if several
call it); a source is used up once the veins reaching for it have arrived.

A source calls every node in its RELATIVE NEIGHBOURHOOD -- each node that no
other node is nearer to both it and the source -- Runions' closed form: veins
converge on it from several sides and join, closing the loops (areoles) of a
reticulate dicot leaf. (Calling only the nearest node, the open form, gives a
tree of free-ending veinlets; as the whole network that looked like speckle.)

The hierarchy comes from growth, as Runions found. First MARGINAL growth: the
blade is small and extends at its edge, the midvein following the apex. New
tissue is only the strip the margin sweeps, so the few coarse sources are born
there, each calls just its nearest vein, and the secondaries chase the
receding margin. In a real blade, and in Runions' simulations, the leaf
elongates while they form and they come out acute, arching toward the tip.
This runs in the final leaf's coordinates and moves no tissue, so a pull
along the axis toward the apex, as strong as the sources' own, stands in for
that: a rib called straight out leaves the midrib at 45 degrees. Then
UNIFORM growth: the tissue expands, gaps between veins widen relative to the
chemistry, and new sources fit between them -- simulated in the final leaf's
coordinates as a birth distance that shrinks with time -- so tertiary and finer
veins fill in, each order inside the last. Where the leaf has a MARGINAL vein
it forms at full size and the last loops close onto it.

WIDTH is the pipe model under Murray's law: a vein carries the flow of all vein
beyond it (downstream length standing for the area drained), and the cube of
its radius is proportional to that flow, so r^3 is conserved at every fork --
derived for blood vessels, borne out in leaves (McCulloh et al. 2003). Colour
is the same flow on a log scale, raised to a power near 1/2 so the ink spreads
over the ramp: midrib pink, secondaries mauve, tertiaries blue, the finest
veinlets teal. No blade fill: a faint fill beside bright lines makes dark
halos under HUE_SMOOTH (see koch.py), so the network's edge is the leaf's.

Views: 0 the whole blade, cropped large, with a marginal vein; 1 a close-up
beside the midrib, areoles large; 2 the blade without a marginal vein, its
edge a fringe of free vein ends.
"""

import numpy as np

TITLE = "Leaf venation"
SUBTITLE = ("veins grown toward auxin sources as the blade expands (Runions 2005);"
            " widths by Murray's law")

# Lines on the ground colour, built in 0..1 (see pen.py), so no stretch.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
SOFTEN = 0.0
HUE_SMOOTH = 3.0

# Stroke edge and least flat core, fractions of panel height (1 px at 4K =
# 1 / 2400). The core floor lets the finest veins reach their colour, which a
# pure Gaussian hairline cannot under HUE_SMOOTH (see shown()).
SOFT = 0.8 / 2400
MINCORE = 0.6 / 2400

# The sharpest a growing vein tip may turn in one step D.
TURN = np.radians(60.0)

# Leaf units: the blade runs x = 0 (base) to 1 (apex); y is across it.
# width/base/tip: half-width at the widest and the exponents of x^base
# (1 - x)^tip.  b0, bmin: source spacing at the start and the finest.  step: D.
# grow: iterations of marginal growth, blade from g0 to full size.  tau:
# e-folding of the spacing in uniform growth.  settle: iterations at bmin so
# the last veinlets arrive.  reach: influence radius / b.  kill: kill distance
# / b, held between D and 2 D -- an arrived vein is joined to its source by a
# straight segment, and at the coarse spacing an uncapped 0.3 b drew those as
# long stubs.  margin: flow of the marginal vein (0: none).  apex: pull along
# the axis toward the apex, against a unit pull from the sources, on every vein
# growing while the blade elongates: a rib called straight out leaves the
# midrib at atan(1 / apex).
# Framing: length (panel heights), angle (deg), centre (panel heights from the
# middle, where x = 0.5 lands), bend (sag of the midrib, leaf units).
# rmax: midrib half-width, panel heights.  murray: the exponent.
# smooth: (passes, flow at which a vein is fully smoothed in leaf units, how
# much of its vein's shift a finer vein keeps each step D along it).
# ink: (floor, power) of the colour, floor + (1 - floor) u^power on log flow u.
LEAF = dict(width=0.27, base=0.55, tip=1.15, petiole=0.12,
            b0=0.07, bmin=0.0045, step=0.0016, g0=0.12, grow=170, tau=26.0,
            settle=45, reach=2.2, kill=0.3, margin=0.0, apex=1.0,
            length=1.9, angle=24.0, centre=(0.10, -0.02), bend=0.05,
            rmax=0.0042, murray=3.0, smooth=(400, 3.0, 0.85), ink=(0.35, 0.55))
PRESETS = {
    "blade": dict(LEAF, margin=1.0),
    # 4.2 panel heights long, the midrib across the top, descending to the
    # right so the caption sits over areoles rather than a vein.
    "closeup": dict(LEAF, length=4.2, angle=-24.0, centre=(0.05, 0.30),
                    bend=0.0, bmin=0.004, rmax=0.007),
    "fringe": dict(LEAF),
}

# (preset, random seed): the seed placed every auxin source, so it is part of
# the picture.
# Only the leaf chosen on a real desktop is offered. A close-up beside the
# midrib ("closeup", seed 3) and the blade without a marginal vein ("fringe",
# seed 1) were shown and pruned; their presets stay above.
LEAVES = [("blade", 1)]


def halfwidth(x, p):
    """Half-width of the blade at x (leaf units), widest at base/(base+tip)."""
    a, b = p["base"], p["tip"]
    xm = a / (a + b)
    xc = np.clip(x, 0.0, 1.0)
    return p["width"] * xc ** a * (1 - xc) ** b / (xm ** a * (1 - xm) ** b)


def inblade(c, g, p):
    """Which points lie in the blade grown to size g (base-anchored)."""
    return (c[:, 0] < g) & (np.abs(c[:, 1]) < g * halfwidth(c[:, 0] / g, p))


def to_panel(q, p):
    """Leaf units -> panel heights from the middle: sag, scale, turn, place."""
    x = q[:, 0]
    y = q[:, 1] + p["bend"] * 4 * x * (1 - x)
    a = np.radians(p["angle"])
    X, Y = (x - 0.5) * p["length"], y * p["length"]
    cx, cy = p["centre"]
    return np.stack([cx + X * np.cos(a) - Y * np.sin(a),
                     cy + X * np.sin(a) + Y * np.cos(a)], 1)


def ramp(c):
    """0, 1, .., c[0]-1, 0, 1, .., c[1]-1, ...: position inside each run."""
    return np.arange(int(c.sum())) - np.repeat(np.cumsum(c) - c, c)


class Grid:
    """Points bucketed in square cells, for every pair closer than a radius.

    numpy has no k-d tree, and each step asks which nodes are near which
    sources a few hundred thousand times. Sorting the points by cell and
    looking in the 3 x 3 cells round each query answers it in O(n log n),
    provided the radius is at most the cell.
    """

    def __init__(self, pts, cell):
        self.pts, self.cell = pts, cell
        k = self.key(np.floor(pts / cell).astype(np.int64))
        self.order = np.argsort(k, kind="stable")
        self.keys = k[self.order]

    @staticmethod
    def key(ij):
        return (ij[:, 0] + (1 << 20)) * (1 << 21) + ij[:, 1] + (1 << 20)

    def pairs(self, q, r):
        """(query index, point index, distance) for every pair closer than r."""
        base = np.floor(q / self.cell).astype(np.int64)
        qi, pi = [], []
        for off in ((-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 0), (0, 1),
                    (1, -1), (1, 0), (1, 1)):
            kk = self.key(base + off)
            s = np.searchsorted(self.keys, kk, "left")
            c = np.searchsorted(self.keys, kk, "right") - s
            if c.sum():
                qi.append(np.repeat(np.arange(len(q)), c))
                pi.append(self.order[np.repeat(s, c) + ramp(c)])
        if not qi:
            e = np.zeros(0, np.int64)
            return e, e, np.zeros(0)
        qi, pi = np.concatenate(qi), np.concatenate(pi)
        d = np.hypot(q[qi, 0] - self.pts[pi, 0], q[qi, 1] - self.pts[pi, 1])
        return qi[d < r], pi[d < r], d[d < r]


def neighbourhood(S, P, si, vi, d):
    """Keep the pairs (source, node) in the source's relative neighbourhood.

    v is dropped if some node u is nearer than d(s, v) to both s and v. Any
    such u is nearer the source than v, so it is among the source's own
    candidates: with each source's candidates sorted by distance, pair j is
    tested against those ranked before it. Exact; in chunks, so a crowded
    early step cannot exhaust memory.
    """
    o = np.lexsort((d, si))
    si, vi, d = si[o], vi[o], d[o]
    cnt = np.bincount(si, minlength=len(S))
    st = (np.cumsum(cnt) - cnt)[si]
    rank = np.arange(len(si)) - st
    blocked = np.zeros(len(si), bool)
    cum = np.cumsum(rank)
    j0 = 0
    while j0 < len(si):
        j1 = max(j0 + 1, int(np.searchsorted(cum, cum[j0] - rank[j0] + 8_000_000, "right")))
        tj = np.repeat(np.arange(j0, j1), rank[j0:j1])
        tu = st[tj] + ramp(rank[j0:j1])
        hit = np.hypot(*(P[vi[tu]] - P[vi[tj]]).T) < d[tj]
        blocked[j0:j1] = np.bincount(tj[hit] - j0, minlength=j1 - j0) > 0
        j0 = j1
    return si[~blocked], vi[~blocked], d[~blocked]


def grow(p, rng, aspect):
    """Run the colonisation: node positions, parents, loop joins, margin."""
    cap = 1_500_000
    P = np.zeros((cap, 2)); par = np.full(cap, -1)
    D = p["step"]
    # The petiole and the first node of the midvein, which the blade grows from.
    k = int(p["petiole"] / D) + 1
    P[:k, 0] = np.linspace(-p["petiole"], 0.0, k)
    par[1:k] = np.arange(k - 1)
    n, mid = k, k - 1
    S = np.zeros((0, 2)); age = np.zeros(0, int)
    jv, jp, rim = [], [], [np.zeros(0, int)]
    lim = np.array([0.5 * aspect + 0.03, 0.53])
    iters = p["grow"] + int(p["tau"] * np.log(p["b0"] / p["bmin"])) + p["settle"]
    gp = p["g0"]
    for it in range(iters):
        g = min(1.0, p["g0"] + (1 - p["g0"]) * it / p["grow"])
        b = max(p["bmin"], p["b0"] * np.exp(-max(0, it - p["grow"]) / p["tau"]))
        dk, ri = max(D, min(p["kill"] * b, 2 * D)), p["reach"] * b

        # The midvein keeps pace with the apex while the blade extends.
        while P[mid, 0] + D <= 0.985 * g:
            P[n] = P[mid] + (D, 0.0); par[n] = mid
            mid, n = n, n + 1

        # The marginal vein: from the base round both edges to the apex.
        if p["margin"] and it == p["grow"]:
            x = np.linspace(0.0, 0.985, 20000)
            for side in (1.0, -1.0):
                e = np.stack([x, side * halfwidth(x, p)], 1)
                s = np.r_[0.0, np.cumsum(np.hypot(*np.diff(e, axis=0).T))]
                q = np.stack([np.interp(np.arange(D, s[-1], D), s, e[:, j])
                              for j in (0, 1)], 1)
                P[n:n + len(q)] = q
                par[n:n + len(q)] = np.r_[k - 1, np.arange(n, n + len(q) - 1)]
                rim.append(np.arange(n, n + len(q)))
                n += len(q)

        # New sources: darts over the blade's bounding box, kept where the
        # blade is and b clear of veins and sources. While the blade grows at
        # its margin only the strip the margin swept this step is new tissue;
        # after that, only what the panel shows is filled in.
        marginal = it < p["grow"]
        m = 4000 if marginal else int(min(60000, 0.35 * 2 * p["width"] * g * g / b ** 2))
        c = rng.random((m, 2)) * (g, 2 * p["width"] * g) - (0.0, p["width"] * g)
        keep = inblade(c, g, p)
        if marginal and it:
            keep &= ~inblade(c, gp, p)
        elif not marginal:
            keep &= np.all(np.abs(to_panel(c, p)) < lim, axis=1)
        c, gp = c[keep], g
        grid = Grid(P[:n], ri)
        if len(c):
            ok = np.ones(len(c), bool)
            ok[grid.pairs(c, b)[0]] = False
            if len(S):
                ok[Grid(S, b).pairs(c, b)[0]] = False
            c = c[ok]
            qi, pi, _ = Grid(c, b).pairs(c, b)
            ok = np.ones(len(c), bool); ok[qi[pi < qi]] = False
            S = np.concatenate([S, c[ok]]); age = np.r_[age, np.zeros(ok.sum(), int)]
        if not len(S):
            continue

        # Which nodes each source calls. A node with three branches already is
        # passed over and the next node along its vein answers instead:
        # otherwise one node could sprout toward every source round it, and
        # drew as a thick stub ending in a star of thirty veinlets.
        si, vi, d = grid.pairs(S, ri)
        nkid = np.bincount(par[:n][par[:n] >= 0], minlength=n)
        free = nkid[vi] < 3
        si, vi, d = si[free], vi[free], d[free]
        if marginal:    # the open form while the margin grows (see the top)
            o = np.lexsort((d, si)); si, vi, d = si[o], vi[o], d[o]
            f = np.r_[True, si[1:] != si[:-1]]; si, vi, d = si[f], vi[f], d[f]
        else:
            si, vi, d = neighbourhood(S, P, si, vi, d)

        # A source is used up when every vein it called has arrived; where two
        # or more arrived they are joined at it, closing a loop. After the
        # first arrival the rest get as long as crossing the influence radius
        # takes, no longer: a caller that cannot come (pulled level by another
        # source) would otherwise hold its neighbourhood sprouting for ever.
        called = np.bincount(si, minlength=len(S)) > 0
        far = np.bincount(si, weights=d >= dk, minlength=len(S))
        age += np.bincount(si, weights=d < dk, minlength=len(S)) > 0
        dead = called & ((far == 0) | (age > 2 * ri / D))
        arr = dead[si] & (d < dk)
        j = arr & (np.bincount(si[arr], minlength=len(S))[si] >= 2)
        jv.append(vi[j]); jp.append(S[si[j]])

        # Every called node steps toward the sum of its sources' directions;
        # nodes within the kill distance of one stop reaching for it.
        live = ~dead[si] & (d >= dk)
        si, vi, d = si[live], vi[live], d[live]
        if len(vi):
            ux = np.bincount(vi, weights=(S[si, 0] - P[vi, 0]) / d, minlength=n)
            uy = np.bincount(vi, weights=(S[si, 1] - P[vi, 1]) / d, minlength=n)
            gv = np.unique(vi)
            L = np.hypot(ux[gv], uy[gv])
            gv, L = gv[L > 0.3], L[L > 0.3]
            u = np.stack([ux[gv], uy[gv]], 1) / L[:, None]
            # While the blade elongates, a pull along its axis (see LEAF).
            if marginal:
                u[:, 0] += p["apex"]
                u /= np.maximum(np.hypot(*u.T), 1e-12)[:, None]
            # A growing TIP turns at most TURN a step: a vein is a file of
            # cells and cannot double back on itself. Side branches, from
            # nodes that already have a child, leave at any angle.
            prev = P[gv] - P[np.maximum(par[gv], 0)]
            prev /= np.maximum(np.hypot(*prev.T), 1e-12)[:, None]
            cs = (u * prev).sum(1)
            bad = (nkid[gv] == 0) & (par[gv] >= 0) & (cs < np.cos(TURN))
            if bad.any():
                w = u[bad] - cs[bad, None] * prev[bad]
                wl = np.hypot(*w.T)[:, None]
                w = np.where(wl > 1e-9, w / np.maximum(wl, 1e-12),
                             np.stack([-prev[bad, 1], prev[bad, 0]], 1))
                u[bad] = np.cos(TURN) * prev[bad] + np.sin(TURN) * w
            k = len(gv)
            assert n + k <= cap, "vein growth ran away"
            P[n:n + k] = P[gv] + D * u
            par[n:n + k] = gv
            n += k
        S, age = S[~dead], age[~dead]
    return P[:n], par[:n], np.concatenate(jv), np.concatenate(jp), np.concatenate(rim)


def shown(val, core):
    """The value to draw so a stroke is SHOWN at `val` (see phylogeny.py):
    under HUE_SMOOTH a hairline shows at 1/sqrt 2 of its value."""
    c = 2 * core / SOFT
    return val * (c + np.sqrt(np.pi)) / (c + np.sqrt(np.pi / 2))


def generate(size, seed=0, jobs=None, **over):
    import pen

    name, rng_seed = LEAVES[seed % len(LEAVES)]
    p = dict(PRESETS[name], **over)
    w, h = size
    P, par, jv, jp, rim = grow(p, np.random.default_rng(rng_seed), w / h)

    # PIPE MODEL: each node carries the vein length beyond it. Parents are
    # always created before their children, so one pass from the newest node
    # back accumulates every subtree. Not through the marginal vein: it is a
    # thin collector, and its veinlets drain inward through the loops they
    # close, not all the way round the edge to the base.
    seg = np.zeros(len(P))
    seg[1:] = np.hypot(*(P[1:] - P[par[1:]]).T)
    onrim = np.zeros(len(P), bool); onrim[rim] = True
    Q = seg.tolist(); pl = par.tolist(); orl = onrim.tolist()
    for v in range(len(P) - 1, 0, -1):
        if not orl[pl[v]]:
            Q[pl[v]] += Q[v]
    Q = np.maximum(np.array(Q), p["step"])
    Q[rim] = p["margin"]

    # SMOOTH the major veins, drawn toward a few coarse sources in turn and
    # bent where each was used up: each node relaxes toward its parent and its
    # main child (the one carrying most flow), fading out below a given flow
    # so the fine mesh keeps its shape. Hundreds of passes, because a bend
    # spans tens of steps D and diffusion straightens it only as fast as the
    # square of its length. Three last passes take every vein, rounding the
    # corner each step D leaves.
    ch = np.nonzero(par >= 0)[0]
    ch = ch[np.lexsort((-Q[ch], par[ch]))]
    first = np.r_[True, par[ch][1:] != par[ch][:-1]]
    main = np.full(len(P), -1); main[par[ch][first]] = ch[first]
    v = np.nonzero((main >= 0) & (par >= 0) & ~onrim)[0]
    passes, qfull, follow = p["smooth"]
    wgt = np.clip(np.log(Q[v] / (0.1 * qfull)) / np.log(10.0), 0.0, 1.0)[:, None]
    P0 = P.copy()
    for i in range(passes):
        P[v] += wgt * (0.25 * (P[par[v]] + P[main[v]]) - 0.5 * P[v])
    # A vein too fine to be smoothed follows the vein it hangs from, fading by
    # `follow` a step, so straightening a rib does not stretch the first
    # segment of every veinlet off it; a loop's join point moves with its veins.
    d = (P - P0).tolist()
    still = ~onrim; still[v[wgt[:, 0] > 0]] = False
    for x in np.nonzero(still & (par >= 0))[0].tolist():
        d[x] = [follow * d[pl[x]][0], follow * d[pl[x]][1]]
    d = np.array(d); P = P0 + d
    _, grp = np.unique(jp, axis=0, return_inverse=True)
    grp = grp.ravel()
    jp = jp + np.stack([np.bincount(grp, d[jv, j]) / np.bincount(grp)
                        for j in (0, 1)], 1)[grp]
    for i in range(3):
        P[v] += 0.25 * (P[par[v]] + P[main[v]]) - 0.5 * P[v]

    # Murray: r^3 proportional to flow. Colour: log flow, the midrib at the
    # warm end -- that way round because strokes combine by MAXIMUM (pen.py):
    # with the midrib cool, every veinlet touching it painted its warmer
    # colour over the midrib's edge and the midrib came out striped.
    r = MINCORE + p["rmax"] * (Q / Q.max()) ** (1.0 / p["murray"])
    u = (np.log(Q / Q.min()) / np.log(Q.max() / Q.min())) ** p["ink"][1]
    val = shown(p["ink"][0] + (1 - p["ink"][0]) * u, r)

    # A loop's joins meet at their source and take the width and colour of the
    # THINNEST vein meeting there: with its own node's width, a join from the
    # side of a secondary was a thick stub.
    jr = np.full(grp.max() + 1 if len(grp) else 0, np.inf)
    jval = jr.copy()
    np.minimum.at(jr, grp, r[jv])
    np.minimum.at(jval, grp, val[jv])

    half = 0.5 * w / h
    px, py, _ = pen.to_pixels((-half, half, -0.5, 0.5), size)
    A = to_panel(P, p)
    B0, B1 = np.concatenate([A[par[ch]], A[jv]]), np.concatenate([A[ch], to_panel(jp, p)])
    core = np.concatenate([r[ch], jr[grp]])
    v = np.concatenate([val[ch], jval[grp]])
    return pen.draw(px(B0[:, 0]), py(B0[:, 1]), px(B1[:, 0]), py(B1[:, 1]),
                    core * h, core * h, v, size, soft=SOFT * h, jobs=jobs)
