"""Bogdanov map -- the phase portrait of an area-preserving twist map.

    y' = y + eps y + k x (x - 1) + mu x y
    x' = x + y'

Arrowsmith's discretisation of the Bogdanov-Takens normal form. With eps = mu
= 0 its Jacobian is exactly 1, so it preserves area: nothing is attracted to
anything, and every orbit stays on whatever structure it started on. The
origin is an elliptic fixed point with the orbits round it turning by
arccos(1 - k/2) per step; (1, 0) is a saddle whose separatrices bound the
region that stays.

The KAM picture: near the centre orbits lie on invariant curves; where the
rotation per step is a rational fraction of a turn a curve breaks into a chain
of islands, each with its own nested loops, with chaos between them; further
out the chaos wins and reaches the saddle, where orbits escape.

RENDERING. Two kinds of orbit, told apart by each orbit's own Lyapunov
exponent (a tangent vector carried along), drawn as two different things:

  * REGULAR orbits are LINES, coloured by orbit -- one colour along each loop,
    stepping through the palette from the centre of its island outward. Each
    is weighted by pixels visited over points held, so every loop is a solid
    line of the same weight however long it is, with no per-orbit grid.
  * CHAOTIC orbits are a density: three million random starts, followed until
    they escape. Area preservation makes the invariant density of the chaotic
    sea UNIFORM -- a well-sampled sea is a flat slab by physics, its only
    structure the folds of orbits on their way out -- so it is a dim veil,
    stretched on its own (as in bifurcation.py, lines and mist differ by
    orders of magnitude and one stretch cannot serve both).
"""

import os

import numpy as np

TITLE = "Bogdanov map"
SUBTITLE = "invariant curves, island chains and chaotic sea,  k = 1.6, eps = mu = 0"

SCALE = "unit"          # the generator does its own two stretches
GAMMA = 1.0
BLEND = 0.85
# No SOFTEN. Here the value of a line IS its colour -- each loop's tone -- and
# the field arrives already stretched, so a blur afterwards lowers a thin
# line's peak and moves it down the ramp: at 0.8 px every loop came out teal
# whatever its tone. The pen in compose() does the band-limiting instead,
# before the opacity is saturated, where it cannot shift a colour.
SOFTEN = 0.0
HUE_SMOOTH = 3.0

# (k, loop spacing along the starting line, frame x0 x1 y0 y1): the region
# bounded by the saddle's separatrices, with the chaotic sea round it.
# Only the view chosen on a real desktop is here. k = 1.2 -- a chain of six
# big islands inside the regular region, framed (-0.80, 1.18, -0.62, 0.62) --
# was good but pruned. The mist's random starts are drawn from the seed, which
# stays 0 for k = 1.6, so the kept picture is unchanged.
PRESETS = [
    (1.6, 0.0105, (-0.91, 1.37, -0.77, 0.655)),
                         # 0.218 turns/step at the centre: a chain of five
                         # islands outside the main one, each with its own
                         # ring of satellites. Framed 15% wider and low so the
                         # lower-left island ends above the caption.
]

STEPS = 400_000          # per loop, after the probe
PROBE = 1 << 16          # steps used to classify each loop and measure it
CHUNK = 2048             # steps held in memory at once
MIST_ORBITS = 3_000_000  # random starts for the chaotic sea
SEA_PROBE = 4096         # steps that decide whether a sea start is chaotic
SEA_STEPS = 60_000       # longest a sea orbit is followed
LAM_REG = 2e-3           # below this Lyapunov exponent an orbit is regular
PEN = 0.55 / 2400        # line half-width, as a fraction of the frame height
TONE = (0.42, 1.0)       # ramp range the loops span, centre -> edge
SAT = 40                 # percentile of line pixels drawn at full opacity
# The veil: log between the 35th and 99.9th percentiles of the lit sea, then
# gamma, topped at 0.09 of the ramp -- under halfway from the ground to the
# first colour stop. At 0.32 and at 0.55 it read as a solid cyan slab with the
# islands cut out of it; here it is smoke and the loops carry the colour.
MIST_LO, MIST_GAMMA, MIST_TOP = 35, 1.2, 0.09
MIST_N = 100             # fewest samples under the mist's kernel that are drawn


def _orbits(x, y, k, steps, lyap=None):
    """Iterate a batch of orbits together, yielding (points, points, index).

    Blocks are (CHUNK, n) arrays for the n orbits still in play, with their
    indices into the starting arrays. An orbit that leaves |x|, |y| < 10 is on
    its way to infinity and is dropped after the block it left in, so starts
    that mostly escape cost what the ones that stay cost. With `lyap`, a
    tangent vector is carried along and its log-growth summed into
    lyap[index]: the Lyapunov exponent times the steps (NaN if it escaped).
    """
    idx = np.arange(x.size)
    x, y = x.copy(), y.copy()
    vx, vy = np.ones_like(x), np.zeros_like(x)
    with np.errstate(all="ignore"):
        for c0 in range(0, steps, CHUNK):
            xs = np.empty((min(CHUNK, steps - c0), x.size)); ys = np.empty_like(xs)
            for i in range(xs.shape[0]):
                if lyap is not None:
                    # Tangent map at the current point: dy' = dy + k(2x-1) dx,
                    # dx' = dx + dy'. Renormalised before it can overflow.
                    vy += k * (2 * x - 1) * vx
                    vx += vy
                    if i % 32 == 31:
                        nrm = np.hypot(vx, vy)
                        lyap[idx] += np.log(nrm)
                        vx /= nrm; vy /= nrm
                y += k * x * (x - 1)
                x += y
                xs[i], ys[i] = x, y
            yield xs, ys, idx
            ok = (np.abs(x) < 10) & (np.abs(y) < 10)
            if not ok.all():
                if lyap is not None:
                    lyap[idx[~ok]] = np.nan
                x, y, vx, vy, idx = x[ok], y[ok], vx[ok], vy[ok], idx[ok]
            if not x.size:
                return


def _splat(px, py, wt, acc, ww, hh):
    """Bilinear deposit into a flat guard-padded grid, in place. np.add.at, not
    bincount: bincount's grid-sized output, page-faulted afresh on every call,
    serialised parallel workers (measured: six ran slower than one)."""
    W = ww + 2
    ix = np.floor(px + 1.0)
    iy = np.floor(py + 1.0)
    ok = (ix >= 0) & (ix <= ww) & (iy >= 0) & (iy <= hh)   # NaN fails too
    tx, ty = (px + 1.0 - ix)[ok], (py + 1.0 - iy)[ok]
    wt = np.broadcast_to(wt, px.shape)[ok].astype(acc.dtype)
    i = iy[ok].astype(np.int64) * W + ix[ok].astype(np.int64)
    np.add.at(acc, i, (1 - tx) * (1 - ty) * wt)
    np.add.at(acc, i + 1, tx * (1 - ty) * wt)
    np.add.at(acc, i + W, (1 - tx) * ty * wt)
    np.add.at(acc, i + W + 1, tx * ty * wt)


def _worker(args):
    x, y, tone, k, extent, shape = args
    hh, ww = shape
    x0, x1, y0, y1 = extent
    npx = (hh + 2) * (ww + 2)
    cov = np.zeros(npx, np.float32)      # line coverage
    ton = np.zeros(npx, np.float32)      # coverage x tone
    mist = np.zeros(npx)                 # chaotic density

    def pix(xs, ys):
        # Raster rows grow downward: y flipped so physical up is up.
        return (xs - x0) * (ww / (x1 - x0)) - 0.5, (y1 - ys) * (hh / (y1 - y0)) - 0.5

    # LOOPS. Pass 1 classifies each start and measures its loop: the length is
    # the number of distinct cells it visits on a grid six times coarser than
    # the one drawn on, where 65k points visit all of them; a line crosses
    # cells in the same proportion at any scale, so six times that is its
    # length here. Pass 2 runs the same orbits again -- deterministic, so
    # identical -- and deposits them. A start that proves chaotic joins the mist.
    lp = tone > 0
    lx, ly, lt = x[lp], y[lp], tone[lp]
    N = lx.size
    lyap = np.zeros(N)
    codes = []
    for xs, ys, i in _orbits(lx, ly, k, PROBE, lyap):
        px, py = pix(xs, ys)
        c = np.clip(px // 6, -1, ww // 6 + 1) * (hh // 6 + 3) + np.clip(py // 6, -1, hh // 6 + 1)
        codes.append((c.astype(np.int64) * N + i).ravel())
    cells = np.bincount(np.unique(np.concatenate(codes)) % N, minlength=N) if N else lyap
    line = lyap / PROBE < LAM_REG                        # NaN (escaped): False
    wgt = 6.0 * cells / (PROBE + STEPS)
    for xs, ys, i in _orbits(lx, ly, k, PROBE + STEPS):
        px, py = pix(xs, ys)
        l = line[i]
        w = np.broadcast_to(wgt[i][l], (px.shape[0], l.sum()))
        _splat(px[:, l], py[:, l], w, cov, ww, hh)
        _splat(px[:, l], py[:, l], w * lt[i][l], ton, ww, hh)
        _splat(px[:, ~l], py[:, ~l], 1.0, mist, ww, hh)

    # SEA, in batches so a block of points stays under 100 MB. A short probe
    # drops the starts that landed on a loop or inside an island -- drawn, they
    # would put curves at random spacing among the even ones -- and the rest
    # run again from the start, deposited until they escape or SEA_STEPS pass.
    sx, sy = x[~lp], y[~lp]
    for b in range(0, sx.size, 3072):
        bx, by = sx[b:b + 3072], sy[b:b + 3072]
        lyap = np.zeros(bx.size)
        for _ in _orbits(bx, by, k, SEA_PROBE, lyap):
            pass
        ch = ~(lyap / SEA_PROBE < 10 * LAM_REG)
        for xs, ys, _ in _orbits(bx[ch], by[ch], k, SEA_STEPS):
            _splat(*pix(xs, ys), 1.0, mist, ww, hh)

    def crop(a):
        return a.reshape(hh + 2, ww + 2)[1:-1, 1:-1].astype(np.float32)
    return crop(cov), crop(ton), crop(mist)


def _starts(k, spacing, xmax=1.2, n=3000, steps=32768):
    """Where to start the loops, and each loop's tone.

    Two symmetry lines are scanned: y = 0 (x_{n+1} = x_{n-1}) and
    y = -k x (x-1) / 2 (x_{n+1} = x_n); symmetric island chains are centred on
    them. An invariant curve's rotation number about the origin changes
    smoothly from start to start (the twist); every orbit in a chain of q
    islands turns by exactly p/q, so a chain is a PLATEAU of constant, rational
    rotation number. Curves start along y = 0 at even spacing, plus the
    outermost regular start of each band, so a band's edge is a line and not a
    gap. Each chain starts once, from its longest plateau, middle outward, and
    every island is toned centre to edge like a small copy of the main one.
    """
    xs = np.linspace(0.0, xmax, n + 1)[1:]
    out, chains = [], {}
    for li, ys in enumerate((np.zeros_like(xs), -0.5 * k * xs * (xs - 1))):
        lyap = np.zeros_like(xs)
        turn = np.zeros_like(xs)
        prev = np.arctan2(ys, xs)
        for bx, by, i in _orbits(xs, ys, k, steps, lyap):
            a = np.arctan2(by, bx)
            d = np.diff(np.vstack([prev[i], a]), axis=0)
            turn[i] += np.sum(np.remainder(d + np.pi, 2 * np.pi) - np.pi, axis=0)
            prev[i] = a[-1]
        rho = np.abs(turn) / (2 * np.pi * steps)
        reg = lyap / steps < 5e-3                        # NaN (escaped): False
        # Plateaus: 8 or more consecutive regular starts sharing a rotation
        # number within 8e-6 of a p/q with q <= 16. An orbit inside an island
        # wobbles round the island's own centre, which moves its measured
        # rotation by a few 1e-6 over the probe. The fraction test is what
        # stops the centre of the main island, where the twist is stationary,
        # passing for a chain -- it did, at 2e-5 and q <= 40.
        q = np.arange(1, 17)
        err = np.abs(rho[:, None] * q - np.round(rho[:, None] * q)) / q
        rat = err.min(1) < 8e-6
        qq = q[np.argmax(err < 8e-6, axis=1)]
        same = (reg & rat)[:-1] & (reg & rat)[1:] & (np.abs(np.diff(rho)) < 5e-6)
        e = np.flatnonzero(np.diff(np.r_[0, same.astype(np.int8), 0]))
        flat = np.zeros_like(reg)
        for a, b in zip(e[::2], e[1::2]):                # starts a..b
            if b - a >= 7 and a > 0:
                flat[a:b + 1] = True
                m = (a + b) // 2
                key = (int(round(rho[m] * qq[m])), int(qq[m]))
                if b - a > chains.get(key, (0,))[0]:
                    chains[key] = (b - a, xs[m], xs[b], li)
        if li == 0:
            curve = np.flatnonzero(reg & ~flat)
            last = curve.max()
            pick = set(np.searchsorted(xs, np.arange(spacing, xs[last], spacing)))
            ends = np.flatnonzero(np.diff(np.r_[reg & ~flat, False].astype(np.int8)) < 0)
            pick = np.array(sorted((pick | set(ends)) & set(curve)))
            # Tone runs to the edge of the MAIN island -- the first start that
            # is not regular -- so it spans the whole ramp there; the curves
            # beyond it, between and around the chains, take the top colour.
            edge = xs[np.argmin(reg) - 1] if not reg.all() else xs[last]
            out.append(np.stack([xs[pick], ys[pick], TONE[0] + (TONE[1] - TONE[0])
                                 * np.minimum(xs[pick] / edge, 1.0)]))
    for _, xc, xe, li in chains.values():
        m = max(2, int(round((xe - xc) / spacing)))
        t = np.arange(1, m + 1) / m
        x = xc + (xe - xc) * t
        y = np.zeros_like(x) if li == 0 else -0.5 * k * x * (x - 1)
        out.append(np.stack([x, y, TONE[0] + (TONE[1] - TONE[0]) * t]))
    return np.concatenate(out, axis=1)


def generate(size, seed=0, jobs=None, parts=False):
    w, h = size
    k, spacing, frame = PRESETS[seed % len(PRESETS)]
    # Fill the 16:10 panel: widen whichever axis is short about its centre.
    x0, x1, y0, y1 = frame
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hx, hy = (x1 - x0) / 2, (y1 - y0) / 2
    hx, hy = max(hx, hy * w / h), max(hy, hx * h / w)
    extent = (cx - hx, cx + hx, cy - hy, cy + hy)

    lx, ly, ltone = _starts(k, spacing)
    rng = np.random.default_rng(seed)
    mx = rng.uniform(extent[0], extent[1], MIST_ORBITS)
    my = rng.uniform(extent[2], extent[3], MIST_ORBITS)
    xs = np.concatenate([lx, mx]); ys = np.concatenate([ly, my])
    tones = np.concatenate([ltone, np.zeros(MIST_ORBITS)])
    order = rng.permutation(xs.size)     # balance the workers
    xs, ys, tones = xs[order], ys[order], tones[order]

    # Eight workers: three grids each, 1.3 GB at 4K x 3.
    jobs = jobs or min(os.cpu_count() or 4, 8)
    chunks = np.array_split(np.arange(xs.size), jobs)
    work = [(xs[c], ys[c], tones[c], k, extent, (h, w)) for c in chunks]
    cov = ton = mist = None
    import multiprocessing as mp
    with mp.Pool(jobs) as pool:
        for c, t, m in pool.imap_unordered(_worker, work):
            cov = c if cov is None else cov + c
            ton = t if ton is None else ton + t
            mist = m if mist is None else mist + m
    # parts=True hands back the raw layers, so the look can be re-tuned
    # through compose() without re-running the orbits.
    return np.stack([cov, ton, mist]) if parts else compose(cov, ton, mist)


def compose(cov, ton, mist):
    import lib
    # The loops through a Gaussian pen, sized as a fraction of the frame so the
    # look does not change with resolution (as in bifurcation.py).
    s = PEN * cov.shape[0]
    c = lib.smooth(cov, s)
    t = lib.smooth(ton, s)
    hue = np.where(c > 1e-9, t / np.maximum(c, 1e-9), 0.0)
    # Opacity saturates at the level line cores reach, MEASURED rather than
    # predicted: the per-orbit weights make every loop the same density on
    # average, but how that lands on a pixel after bilinear deposit and the pen
    # depends on the resolution and the angle of the line. A percentile of the
    # lit pixels -- above the soft edges, in the cores -- is set to full, so
    # loops are solid lines with anti-aliased edges.
    lit = c[c > 1e-4 * c.max()]
    q = np.percentile(lit, SAT) if lit.size else 1.0
    lines = np.clip(c / q, 0.0, 1.0) * hue
    # The sea: log between a floor and a ceiling, both percentiles of its lit
    # cells, so the thin haze of escaping orbits sinks to the ground and the
    # folds and the dense layer round the islands share the veil's range.
    sig = 2.5 * s
    m = lib.smooth(mist, sig)
    ml = m[m > 0]
    if ml.size:
        lo, hi = np.percentile(ml, [MIST_LO, 99.9])
        # Never below 10% sampling noise (m holds m 4 pi sig^2 samples): the
        # 35th percentile held 19, and at k = 1.2 the escaping haze speckled.
        lo = max(lo, MIST_N / (4 * np.pi * sig * sig))
        m = np.clip(np.log(np.maximum(m, lo) / lo) / np.log(hi / lo), 0.0, 1.0)
    m = m ** MIST_GAMMA * MIST_TOP
    # The brighter wins: a loop over the mist is the loop's colour.
    return np.maximum(lines, m)
