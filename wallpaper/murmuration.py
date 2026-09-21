"""Murmuration -- starlings wheeling over their roost at dusk, drawn as the
paths a few hundred of them flew in the last three quarters of a minute.

A self-propelled particle model in three dimensions, in the family of
Reynolds' boids (1987) and Vicsek's model (1995), with the one ingredient that
is specifically starling: each bird attends to its SEVEN nearest neighbours,
whatever their distance, not to every bird within a fixed radius. That is what
Ballerini et al. measured from 3-D reconstructions of real flocks over Rome
(PNAS 105, 1232, 2008), and it is why a starling flock can stretch, thin and
fold without tearing: a bird on a thinning edge still has seven neighbours, so
the flock holds together at any density. Each of 3000 birds

    keeps apart   from any of its seven closer than about a wingspan,
    aligns        its heading with theirs,
    closes up     toward the ones further off,
    holds         a cruising speed of 10 m/s and an altitude of about 60 m,
    sinks         in a turn, because a banked wing lifts less,
    is turned     back over the roost once it strays past 90 m from it,

plus a little random steering. The last three are from StarDisplay, the model
built to reproduce real murmurations (Hildenbrandt, Carere & Hemelrijk, Behav.
Ecol. 21, 1349, 2010). The roost's pull switches on sharply: the birds that
cross the line first turn first, the rest only when their neighbours do, and
that lag -- a turn spreading bird to bird through the neighbour network -- is
what folds and twists the flock as it wheels, and banking makes every turn a
dive as well.

One view adds a falcon, stooping twice from behind and above at the flock's
centre. Birds near it break away; the rest react only through their
neighbours. Most of the shapes that make murmurations famous -- splits,
flash expansions, the flock folding round an empty hole -- are escapes of this
kind (Storms et al., Behav. Ecol. Sociobiol. 73, 10, 2019).

WHAT IS DRAWN. One bird in ten, each as a single line through everywhere it
flew in the window, seen from the ground like a long exposure of the evening
sky. Colour is time: the oldest end of every path at the bottom of the ramp,
the birds' present positions at the top, and the oldest quarter fading in so
the tail is a comet's rather than a brush cut off square where the window
happens to open. A path is resampled along its own length, so it is equally
bright wherever it goes, and drawn with a Gaussian pen whose width is a
fraction of the panel height. Where the flock is a sheet seen edge on, paths
pile into a solid band; where it is seen face on, or has scattered, they
separate into threads.

Why not every bird, and why not longer: all 3000 paths drawn together were a
solid brush stroke with no threads in it, and every extra loop over the roost
laid another ribbon across the first until it was a ball of wool.

Nothing here is multithreaded, and the neighbour search does not use BLAS:
the flock is chaotic, and a matrix product whose rounding depends on the
number of cores would give every machine a different flock.
"""

import os

import numpy as np

TITLE = "Murmuration"
# The fallback; the per-view caption comes from caption(seed).
SUBTITLE = ("300 of 3000 starlings wheeling over their roost, 45 s; each follows"
            " its 7 nearest neighbours   (Ballerini et al. 2008)")

# Line opacity times line colour, already in 0..1: the renderer takes it as is.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
SOFTEN = 0.0         # the pen is already a band-limited Gaussian
HUE_SMOOTH = 3.0     # one colour across a line's width
# Rendered at twice the panel and averaged down. The pen is band-limited, so
# this only has to keep a line's profile from depending on where it falls
# between pixels; 3 costs 2.25 times the memory for no visible difference.
SUPERSAMPLE = 2

# Pen sigma as a fraction of the panel height: 0.8 px at 2400.
PEN = 0.8 / 2400
# Ramp position of the oldest and newest point of the window; how fast
# overlapping lines saturate; and the fraction of the window over which the
# oldest part of each path fades in.
TONE = (0.25, 1.0)
# 4, not 2: at 2 a lone line never reached full opacity, and a part-covered
# line over the ground colour read a step down the ramp from the band it
# belonged to -- lone violet threads came out cyan beside a violet band.
OPACITY = 4.0
FADE = 0.25

# The flock (SI units: metres, seconds).
K = 7                 # topological neighbours (Ballerini et al. 2008)
V0 = 10.0             # cruising speed
Z0 = 60.0             # preferred altitude
ROOST = 90.0          # radius past which the roost pulls a bird back
DT = 0.05             # time step
VHAWK = 20.0          # a falcon in a shallow stoop
HUNT = 8.0            # how long one attack lasts

# n birds, of which `drawn` are drawn; burn-in and drawn window (s);
# separation distance (m); weights of separation, alignment, cohesion (m/s^2
# per unit); the roost's pull (m/s^2) and the distance past ROOST over which
# it switches on (m); altitude spring (1/s^2); sink per unit of turning
# acceleration (banking); steering noise (m/s^2); aim: how far to one side of
# the roost the flock starts, flying past it -- its angular momentum about the
# roost per unit speed, 0 sending it straight through and back and ROOST
# round the edge; the falcon's attack times (s), push (m/s^2) and the
# distance at which birds break away (m); flock: the seed of the start and of
# the noise -- part of the picture, so pinned. view: camera azimuth and
# elevation (degrees) and zoom.
BASE = dict(n=3000, drawn=300, burn=30.0, window=45.0, rsep=1.5, ws=15.0,
            wa=6.0, wc=1.5, wr=5.0, edge=15.0, wz=0.15, kb=0.3, noise=2.0,
            aim=90.0, attacks=(), wf=30.0, fear=25.0, flock=1)
# Tight, banking turns at the roost's edge: the flock swings through in petals.
WHEEL = dict(BASE, aim=30.0, edge=8.0, wr=8.0, kb=0.8, wz=0.1)
PRESETS = {
    "figure": dict(WHEEL, view=(160.0, 25.0, 1.1),
                   about="wheeling over their roost"),
    "twist":  dict(WHEEL, view=(30.0, 35.0, 1.0),
                   about="banking round their roost"),
    "falcon": dict(BASE, aim=50.0, attacks=(42.0, 58.0), wf=8.0, fear=40.0,
                   wa=10.0, view=(160.0, 25.0, 1.1),
                   about="scattering from a falcon's two stoops"),
}
# Offered on the desktop: the view chosen there. "twist" (the same flight from
# the other side) and "falcon" were shown and pruned; their presets stay above.
ORDER = ["figure"]


def caption(seed):
    """From the preset alone, so a re-colour from a saved field gets it too."""
    p = PRESETS[ORDER[seed % len(ORDER)]]
    return TITLE, (f"{p['drawn']} of {p['n']} starlings {p['about']},"
                   f" {p['window']:.0f} s; each follows its 7 nearest"
                   " neighbours   (Ballerini et al. 2008)")


def _neighbours(x, k):
    """Indices of each bird's k nearest, by brute force.

    Elementwise, not a matrix product: see the module docstring. float32 is
    ample to rank distances of tens of metres."""
    xf = x.astype(np.float32)
    d2 = np.zeros((x.shape[0], x.shape[0]), np.float32)
    for c in range(3):
        diff = xf[:, c][:, None] - xf[:, c][None, :]
        d2 += diff * diff
    np.fill_diagonal(d2, np.inf)
    return np.argpartition(d2, k, axis=1)[:, :k]


def _fly(p):
    """Integrate the flock; return every bird's position over the window,
    shaped (steps, birds, 3)."""
    rng = np.random.default_rng(p["flock"])
    n = p["n"]
    # A loose cloud `aim` metres to one side of the roost, flying past it.
    x = rng.normal(0.0, 12.0, (n, 3)) + np.array([0.0, -p["aim"], Z0])
    v = np.array([V0, 0.0, 0.0]) + rng.normal(0.0, 2.0, (n, 3))
    burn = int(round(p["burn"] / DT))
    keep = int(round(p["window"] / DT))
    out = np.empty((keep, n, 3))
    for step in range(burn + keep):
        nb = _neighbours(x, K)
        rel = x[nb] - x[:, None, :]                        # (n, K, 3)
        d = np.sqrt((rel * rel).sum(-1)) + 1e-9
        u = rel / d[..., None]
        # Keep apart: a push that grows as a neighbour closes inside rsep.
        push = np.clip((p["rsep"] - d) / p["rsep"], 0.0, 1.0)
        sep = -(u * push[..., None]).sum(1)
        # Align: toward the neighbours' mean heading.
        e = v / (np.sqrt((v * v).sum(-1, keepdims=True)) + 1e-9)
        ali = e[nb].mean(1) - e
        # Close up: toward the neighbours beyond rsep.
        coh = (rel * (d > p["rsep"])[..., None]).mean(1)
        acc = p["ws"] * sep + p["wa"] * ali + p["wc"] * coh
        # The roost: a horizontal pull that switches on over `edge` metres
        # past ROOST. Sharp, so the birds that cross first turn first and the
        # rest follow through their neighbours -- which is what folds the
        # flock.
        rh = np.sqrt(x[:, 0] ** 2 + x[:, 1] ** 2) + 1e-9
        over = np.clip((rh - ROOST) / p["edge"], 0.0, 1.0) * p["wr"]
        acc[:, 0] -= over * x[:, 0] / rh
        acc[:, 1] -= over * x[:, 1] / rh
        # Altitude: a soft spring, lightly damped, so the flock can rise and
        # dive but not drift away.
        acc[:, 2] -= p["wz"] * (x[:, 2] - Z0) + 0.3 * v[:, 2]
        # Banking: a bird turns by rolling, and a rolled wing lifts less, so
        # it sinks in a turn in proportion to how hard it is turning.
        vv = (v * v).sum(-1, keepdims=True)
        lat = acc - (acc * v).sum(-1, keepdims=True) * v / vv
        acc[:, 2] -= p["kb"] * np.sqrt((lat[:, :2] ** 2).sum(-1))
        # A falcon's stoop: from behind and above, at the flock's centre.
        # Birds inside `fear` metres of it break away, harder the closer it
        # is; the rest react only through their neighbours.
        for t0 in p["attacks"]:
            k = step - int(round(t0 / DT))
            if k == 0:
                c, vm = x.mean(0), v.mean(0)
                hp = c - 4.0 * vm + np.array([0.0, 0.0, 20.0])
                hv = (c - hp) / np.linalg.norm(c - hp) * VHAWK
            if 0 <= k < int(round(HUNT / DT)):
                to = x.mean(0) - hp
                hv = hv + DT * 3.0 * (to / np.linalg.norm(to) * VHAWK - hv)
                hp = hp + DT * hv
                r = x - hp
                dh = np.sqrt((r * r).sum(-1, keepdims=True)) + 1e-9
                acc += p["wf"] * r / dh * np.clip(1.0 - dh / p["fear"], 0.0, 1.0)
        # Cruise speed, along the heading.
        s = np.sqrt((v * v).sum(-1, keepdims=True)) + 1e-9
        acc += (V0 - s) / 0.5 * (v / s)
        acc += rng.normal(0.0, p["noise"], (n, 3))
        # A bird cannot pull more than about 3 g in a turn.
        a = np.sqrt((acc * acc).sum(-1, keepdims=True))
        acc *= np.minimum(1.0, 30.0 / (a + 1e-9))
        v = v + DT * acc
        x = x + DT * v
        if step >= burn:
            out[step - burn] = x
    return out


def _project(pts, az, el):
    """Orthographic view from the ground: azimuth az, looking up at el."""
    az, el = np.radians(az), np.radians(el)
    right = np.array([-np.sin(az), np.cos(az), 0.0])
    up = np.array([-np.sin(el) * np.cos(az), -np.sin(el) * np.sin(az),
                   np.cos(el)])
    return pts @ right, pts @ up


def _ink(px, py, tone, wgt, w, h, spacing=0.5, batch=64):
    """Deposit paths (steps, birds) in pixel coordinates, each resampled
    every `spacing` pixels along its own arc so that brightness is per unit
    length, not per unit time. Returns (ink, ink * tone), flattened: `tone`
    and `wgt` (per step) are carried along every path for colour and ink.
    Bilinear, and a batch of birds per bincount, since each bincount costs a
    pass over the whole panel."""
    c, q = np.zeros(w * h), np.zeros(w * h)
    for b0 in range(0, px.shape[1], batch):
        pts = []
        for b in range(b0, min(b0 + batch, px.shape[1])):
            x, y = px[:, b], py[:, b]
            seg = np.hypot(np.diff(x), np.diff(y))
            arc = np.concatenate([[0.0], np.cumsum(seg)])
            t = np.arange(0.0, arc[-1], spacing)
            j = np.clip(np.searchsorted(arc, t, side="right") - 1, 0, x.size - 2)
            u = (t - arc[j]) / np.maximum(seg[j], 1e-12)
            pts.append(np.stack([x[j] + (x[j + 1] - x[j]) * u,
                                 y[j] + (y[j + 1] - y[j]) * u,
                                 tone[j] + (tone[j + 1] - tone[j]) * u,
                                 wgt[j] + (wgt[j + 1] - wgt[j]) * u]))
        x, y, tn, wn = np.concatenate(pts, axis=1)
        ix, iy = np.floor(x).astype(np.int64), np.floor(y).astype(np.int64)
        fx, fy = x - ix, y - iy
        for dx, dy, wt in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)),
                           (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
            cx, cy = ix + dx, iy + dy
            m = (cx >= 0) & (cx < w) & (cy >= 0) & (cy < h)
            if m.any():
                idx = cy[m] * w + cx[m]
                wm = wt[m] * wn[m]
                c += np.bincount(idx, weights=wm, minlength=w * h)
                q += np.bincount(idx, weights=wm * tn[m], minlength=w * h)
    return c, q


def generate(size, seed=0, cache=None, view=None, birds=None, **kw):
    import lib

    w, h = size
    p = dict(PRESETS[ORDER[seed % len(ORDER)]], **kw)
    # The flight is independent of the panel; `cache` keeps it between
    # renders so framing and colour can be iterated without re-flying it.
    if cache and os.path.exists(cache):
        pts = np.load(cache)
    else:
        pts = _fly(p)
        if cache:
            np.save(cache, pts)
    # The birds are in random order (the starting cloud is random), so the
    # first `drawn` are a random tenth of the flock.
    pts = pts[:, :birds or p["drawn"]]

    az, el, zoom = view or p["view"]
    X, Y = _project(pts, az, el)
    Y = -Y                                   # up is up: row 0 is the top
    # Cropped to fill the panel, the flight's full extent a little past it.
    x0, x1, y0, y1 = lib.frame(X, Y, size, fit="cover", zoom=zoom)
    px = (X - x0) / (x1 - x0) * w - 0.5
    py = (Y - y0) / (y1 - y0) * h - 0.5

    f = np.linspace(0.0, 1.0, X.shape[0])
    tone = TONE[0] + (TONE[1] - TONE[0]) * f
    e = np.clip(f / FADE, 0.0, 1.0)
    c, q = _ink(px, py, tone, e * e * (3 - 2 * e), w, h)

    # Pen: a Gaussian; `ink` is 1 at the centre of a single line wherever it
    # falls. Opacity saturates, so a band of many paths is solid rather than
    # over full, and HUE_SMOOTH's local mean is the line's own colour.
    sigma = PEN * h
    c = lib.smooth(c.reshape(h, w).astype(np.float32), sigma)
    q = lib.smooth(q.reshape(h, w).astype(np.float32), sigma)
    ink = c * (sigma * np.sqrt(2 * np.pi) / 2.0)          # 2 samples per px
    with np.errstate(divide="ignore", invalid="ignore"):
        hue = np.where(c > 1e-9, q / c, 0.0)
    return ((1.0 - np.exp(-OPACITY * ink)) * hue).astype(np.float32)
