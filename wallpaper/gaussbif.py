"""Gauss map -- the bifurcation diagram.

    x' = exp(-alpha x^2) + beta,      alpha = 6.2

asked for over beta from -1 to +1, and drawn over the part of that range
where it is chaotic: the bubble, beta from -0.82 to -0.20.

A Gaussian bump lifted by beta. Like the logistic map it has one smooth
quadratic maximum, at x = 0, so it inherits everything that follows from that:
period doubling with Feigenbaum's delta, chaotic bands with bright caustics
where the images of the maximum pile up, periodic windows. What the logistic
map does not have is a second way to lose chaos. As beta rises the fixed point
sweeps the whole bump, so the cascade that opens on the left runs BACKWARDS on
the right -- chaos folds back into period 4, 2, 1 -- and the picture is a
closed bubble rather than a fan. The flat Gaussian tails also make the map
multistable for some beta: two attractors side by side at one parameter, the
diagram overlapping itself.

The approach is bifurcation.py's, copied rather than shared, because the two
halves of the picture are still different kinds of object: an orbit that has
settled onto a cycle is drawn as anti-aliased line, and only chaotic orbits
make density, stretched on its own. See that file for the full argument. What
changes here:

- the frame is set by hand, not derived, because the trapping interval of
  this map is loose for most beta;
- windows narrower than MIN_WINDOW, and orbits lingering next to one, are
  left out of the picture, or they print a dotted row at x = 0 (see _strip);
- a cycle's line weight counts ATTRACTORS, not orbits. Where two cycles
  coexist, the logistic weighting would draw each at its basin's share of the
  starts -- one branch full, the other faint -- which says more about where
  the starting points were drawn than about the map;
- memory is kept bounded (the fleet's smallest node has 4 GB for this).
"""

import os

import numpy as np

TITLE = "Gauss map"
SUBTITLE = "x' = exp(-6.2 x^2) + beta,   the chaotic bubble, beta from -0.82 to -0.20"

# The field arrives in 0..1 (lines and mist stretched separately, see
# generate), so the renderer takes it as it is. MIST_GAMMA 2.0 is the
# approved logistic value; 1.5 lifted the sparse lower half of the bubble out
# of its dark teal, and lifted the sampling grain with it.
SCALE = "unit"
GAMMA = 1.0
MIST_GAMMA = 2.0

ALPHA = 6.2

# Gaussian pen for the cycles, sigma as a fraction of frame height (see
# bifurcation), set per preset below.
SOFTEN = 0.8
HUE_SMOOTH = 3.0
BLEND = 0.78

# (beta0, beta1, x0, x1, pen, caption). generate() installs the caption:
# render.py reads it after generating.
# (beta from, beta to, x from, x to, pen, caption, sample seed). The sample
# seed draws the beta jitter and the starting points; it is part of the
# picture and pinned here, so pruning a view never changes a kept one.
#
# Only the view chosen on a real desktop is here. The full range asked for,
# beta from -1 to +1 framed to x in (-0.46, 1.10) with a 1.5 px pen, was
# shown and pruned: at that width the chaos is only a fifth of the frame.
PRESETS = [
    # The bubble alone. Measured (burn 3000, 64 starts): period 2 -> 4 at
    # beta = -0.76, chaos from -0.713 to about -0.30 with windows of period
    # 5, 6, 7, 9, 12 inside it, then 8 -> 4 -> 2 back out, the last at
    # -0.2275. The fixed point that coexists with all of this below x = -0.59
    # is left out of frame.
    (-0.82, -0.20, -0.36, 0.80, 0.6 / 2400,
     "x' = exp(-6.2 x^2) + beta,   the chaotic bubble, beta from -0.82 to -0.20", 1),
]

MAX_PERIOD = 128
LINE_PERIOD = 32
# Narrowest window whose cycle is drawn, as a fraction of the frame width:
# 3 px at 4K, whatever the resolution.
MIN_WINDOW = 3 / 3840
# Half-width of the band around x = 0 that tells a laminar orbit, as a
# fraction of the frame height (see _strip); 0 turns the test off.
LAMINAR_DX = 0.001


def _step(x, b):
    return np.exp(-ALPHA * x * x) + b


def _strip(args):
    """Columns c0..c1: returns (c0, cycle lines, chaotic counts), float32.

    Every column is a different map and none of them interact, so strips are
    independent and run one per core with nothing shared.
    """
    c0, c1, w, h, b0, b1, xlo, xhi, seed, sub, ninit, burn, keep, minw = args
    rng = np.random.default_rng([seed, c0])
    # Iterated with a halo of minw columns each side, which is looked at but
    # not drawn: the window-width test below has to see a window whole when
    # it straddles two strips.
    a0, a1 = max(0, c0 - minw), min(w, c1 + minw)
    cw = a1 - a0
    M = cw * sub

    # beta jittered inside each column -- a lattice of beta beats against the
    # cycle periods and prints moire through the cascade.
    # One per equal slice of the column (stratified), as in tentbif.
    col = np.repeat(np.arange(cw), sub)
    u = (np.tile(np.arange(sub), cw) + rng.random(M)) / sub
    b = b0 + (b1 - b0) * (a0 + col + u) / w
    b = np.tile(b, ninit)
    col = np.tile(col, ninit)
    # Starts spread over the whole range the map can reach, [beta, 1 + beta],
    # so both basins are sampled where two attractors coexist.
    x = b + rng.random(b.size)

    for _ in range(burn):
        x = _step(x, b)

    scale = h / (xhi - xlo)
    hist = np.empty((MAX_PERIOD, x.size))
    for k in range(MAX_PERIOD):
        x = _step(x, b)
        hist[k] = x
    close = np.abs(hist[-1] - hist[-2::-1]) < 0.25 / scale
    period = np.where(close.any(0), close.argmax(0) + 1, 0)

    # WHICH cycle: its lowest point identifies it. Then, per beta sample, how
    # many of the starts found that same cycle -- the weight divides by it, so
    # each distinct cycle draws at full strength however few starts found it.
    k = np.arange(MAX_PERIOD)[:, None]
    sig = np.where(k >= MAX_PERIOD - np.maximum(period, 1), hist, np.inf).min(0)
    del hist, close
    P = period.reshape(ninit, M)
    S = sig.reshape(ninit, M)
    same = ((P[:, None] == P[None]) & (np.abs(S[:, None] - S[None]) < 1.0 / scale))
    nsame = same.sum(1).ravel()
    del same
    # Windows narrower than MIN_WINDOW are dropped from BOTH fields. Each drew
    # one short tick per branch -- and since every window's cycle passes next
    # to the critical point, the ticks lined up into a dotted rule along
    # x = 0 across the chaos. True, and read as an artefact. Dropped, a window
    # is what it looks like at this resolution: a column where the mist thins.
    #
    # The cut is on WIDTH, not period: a period cut deep enough to clear the
    # dots also erased the period-5/6/7/9/12 windows that are the point of
    # the picture. Width is measured per FAMILY -- the period with its
    # factors of 2 removed -- so a window and its own doubling cascade count
    # as one run of columns, and the cascade is not cut off where each
    # doubled cycle gets narrow. A run that reaches the edge of the frame is
    # taken as wide. Cycles above LINE_PERIOD are dropped regardless.
    lined = (period > 0) & (period <= LINE_PERIOD)
    fam = np.where(lined, period, 0)
    for _ in range(5):
        fam = np.where(fam % 2 == 0, fam // 2, fam)
    pres = np.zeros((LINE_PERIOD + 1, cw), dtype=np.int64)
    pres[fam[lined], col[lined]] = 1
    run_l, run_r = pres.copy(), pres.copy()
    run_l[:, 0] *= 1 + w * (a0 == 0)
    run_r[:, -1] *= 1 + w * (a1 == w)
    for j in range(1, cw):
        run_l[:, j] *= run_l[:, j - 1] + 1
        run_r[:, cw - 1 - j] *= run_r[:, cw - j] + 1
    wide = (run_l + run_r - 1 >= minw)[fam, col]
    wline = np.where(lined & wide,
                     period / (keep * sub * np.maximum(nsame, 1.0)), 0)
    wchaos = (period == 0).astype(float)

    # Drop the halo: only this strip's own columns are drawn.
    inner = (col >= c0 - a0) & (col < c1 - a0)
    x, b, col = x[inner], b[inner], col[inner] - (c0 - a0)
    wline, wchaos = wline[inner], wchaos[inner]
    cw = c1 - c0

    # Bilinear in x, batched through bincount; a guard row each side so a
    # point just off the frame still feeds the edge row, and anything further
    # out goes to a dump bin rather than piling up on the edge.
    H = h + 2
    dump = H * cw
    line = np.zeros(dump + 1)
    mist = np.zeros(dump + 1)
    per_call = max(1, min(keep, 4_000_000 // x.size))
    idx = np.empty((per_call, x.size), dtype=np.intp)
    frac = np.empty((per_call, x.size))

    def flush(n):
        i = idx[:n].ravel()
        up = np.minimum(i + cw, dump)
        f = frac[:n].ravel()
        for acc, wt in ((line, wline), (mist, wchaos)):
            wt = np.broadcast_to(wt, (n, wt.size)).ravel()
            acc += np.bincount(i, weights=(1.0 - f) * wt, minlength=dump + 1)
            acc += np.bincount(up, weights=f * wt, minlength=dump + 1)

    # LAMINAR PHASES. The narrow windows leave a second, subtler row of dots
    # at x = 0, in the mist: next to a window an orbit lingers on the ghost of
    # its cycle (intermittency), or has not quite settled onto it, and every
    # period it comes back to the critical point -- a few thousand visits to
    # one pixel, where a chaotic orbit makes a handful. So the mist is taken
    # batch by batch, and an orbit that returned to within dx0 of x = 0 three
    # times or more in a batch of ~100 iterates is left out of the mist for
    # that batch. The bar rises with the strip's mean, because near the onset
    # of chaos x = 0 sits in a narrow band that chaotic orbits visit that
    # often anyway.
    dx0 = LAMINAR_DX * (xhi - xlo)
    chaotic = wchaos > 0
    wmist = wchaos
    near = np.zeros(x.size)
    n = 0
    for k in range(keep):
        x = _step(x, b)
        near += np.abs(x) < dx0
        t = (xhi - x) * scale + 0.5          # x up, rows down
        row = np.floor(t).astype(np.intp)
        ok = (row >= 0) & (row < H - 1)
        idx[n] = np.where(ok, row * cw + col, dump)
        frac[n] = np.where(ok, t - row, 0.0)
        n += 1
        if n == per_call or k == keep - 1:
            if dx0 > 0 and chaotic.any():
                bar = max(3.0, 4.0 * near[chaotic].mean())
                wchaos = np.where(near < bar, wmist, 0.0)   # seen by flush
            flush(n)
            near[:] = 0
            n = 0
    return (c0, line[:dump].reshape(H, cw)[1:-1].astype(np.float32),
            mist[:dump].reshape(H, cw)[1:-1].astype(np.float32))


def _equalise(field, gamma, rows=512):
    """In place: lit values -> their rank among lit values, then ** gamma.

    lib.normalise('equalize') on the full supersampled field needs several
    float64 copies and two argsorts of 80 million values -- more memory than
    the smallest node has. The rank is taken instead from 4096 quantiles of a
    subsample, and interpolated: at that resolution the result is
    indistinguishable, and it needs one band of rows at a time.
    """
    s = field[::3, ::3]
    s = s[s > 0]
    if s.size == 0:
        return field
    q = np.quantile(s, np.linspace(0.0, 1.0, 4097))
    q = q + np.arange(q.size) * 1e-12 * max(q[-1], 1e-30)   # strictly rising
    lv = np.linspace(0.0, 1.0, q.size)
    for a in range(0, field.shape[0], rows):
        band = field[a:a + rows]
        lit = band > 0
        band[lit] = np.interp(band[lit], q, lv) ** gamma
    return field


def generate(size, seed=0, sub=4, ninit=36, burn=1500, keep=6000, jobs=None,
             mist_gamma=None, pen=None):
    import lib

    w, h = size
    b0, b1, xlo, xhi, ppen, _, sample = PRESETS[seed % len(PRESETS)]
    minw = max(1, int(round(MIN_WINDOW * w)))

    # Sampling: 4 beta x 36 starts x 6000 kept iterates per column, three
    # times bifurcation.py's. At its 288k the mist was visibly speckled at 1:1
    # in the sparse lower half of the bubble, which equalisation then lifts
    # into the middle of the ramp.
    #
    # Many narrow strips rather than one per core: each worker then holds a
    # few tens of MB, and the pool keeps every core busy to the end.
    procs = jobs or os.cpu_count() or 4
    nstrip = max(procs, w // 240)
    edges = np.linspace(0, w, nstrip + 1).astype(int)
    work = [(edges[j], edges[j + 1], w, h, b0, b1, xlo, xhi, sample, sub, ninit,
             burn, keep, minw) for j in range(nstrip) if edges[j + 1] > edges[j]]
    line = np.zeros((h, w), dtype=np.float32)
    mist = np.zeros((h, w), dtype=np.float32)
    import multiprocessing as mp
    with mp.Pool(procs) as pool:
        for c0, lp, mp_ in pool.imap_unordered(_strip, work):
            line[:, c0:c0 + lp.shape[1]] = lp
            mist[:, c0:c0 + mp_.shape[1]] = mp_

    _equalise(mist, MIST_GAMMA if mist_gamma is None else mist_gamma)

    # The cycles through the Gaussian pen, rescaled so a branch peaks at 1
    # wherever it falls between rows; blurred band by band with a halo, and
    # merged into the mist as it goes (the brighter wins).
    sigma = (ppen if pen is None else pen) * h
    gain = sigma * np.sqrt(2 * np.pi)
    halo = int(4 * sigma) + 2
    for a in range(0, h, 512):
        z = min(h, a + 512)
        lo, hi = max(0, a - halo), min(h, z + halo)
        blur = lib.smooth(line[lo:hi], sigma)[a - lo:a - lo + (z - a)]
        np.maximum(mist[a:z], np.clip(blur * gain, 0.0, 1.0), out=mist[a:z])
    del line
    return mist
