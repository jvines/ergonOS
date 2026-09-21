"""Kelvin-Helmholtz and Rayleigh-Taylor instability -- the two ways an
interface between fluids fails, drawn as lines of dye carried by the flow.

Kelvin-Helmholtz: two layers sliding past each other. Any ripple on the shear
layer is steepened by the pressure it induces (Bernoulli: the flow speeds up
over a crest and pulls it further out), so every wavelength longer than the
layer's thickness grows. For the tanh profile u = U tanh(y / delta) the
fastest grows at k delta = 0.445 (Michalke 1964), at 0.19 U / delta per unit
time. The ripples roll up into a row of billows -- the cat's-eye vortices of
the breaking-wave clouds -- and neighbouring billows then orbit and merge
(pairing, Winant & Browand 1974), which is how a mixing layer grows.

Rayleigh-Taylor: heavy fluid resting on light fluid under gravity. The flat
interface is an equilibrium and an unstable one: a ripple of wavenumber k
grows as exp(sqrt(A g k) t), with A the Atwood number. Heavy fluid falls in
spikes, light rises in bubbles, and the shear along each spike's flanks is
itself Kelvin-Helmholtz unstable, which rolls every tip into the mushroom cap
seen in supernova remnants (the Crab's filaments) and in a drop of milk in
coffee. Small plumes grow fastest but large ones win, so the mixing zone
coarsens as it deepens (h ~ alpha A g t^2).

The solver is the same for both: two-dimensional incompressible
Navier-Stokes in the Boussinesq approximation, vorticity and buoyancy on a
doubly periodic grid,

    w_t + J(psi, w) = b_x + nu lap w,    b_t + J(psi, b) = kappa lap b,
    lap psi = -w,

pseudo-spectral in space (2/3 dealiased), SSP Runge-Kutta 3 in time. Periodic
in y means every shear layer has an opposite partner and every unstable
interface a stable one; both are placed half a domain away, out of view.

WHAT IS DRAWN is dye: lines of marker laid horizontally through the fluid at
the start and carried by the computed velocity (fourth-order Runge-Kutta
through stored snapshots), with points inserted wherever a line stretches, so
it stays resolved however tightly it is wound. They are material lines, finer
than the grid by construction -- what the fluid would show if its marker did
not diffuse. Colour is the height each line started at. For Rayleigh-Taylor
the light fluid is at the cool end of the ramp and the heavy at the warm, so
where the two are wound together the colours interleave; for Kelvin-Helmholtz
the lines that started in the shear layer are warm and cool with distance
from it, so the billows, made of the layer's own fluid, glow.
"""

import os

import numpy as np

TITLE = "Fluid instability"
SUBTITLE = "an interface between two fluids rolling up"

SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
SOFTEN = 0.0         # the pen is already a band-limited Gaussian
HUE_SMOOTH = 3.0     # one colour across a line's width

# Pen sigma as a fraction of the panel height: 0.8 px at 2400. And how hard
# the pen saturates: opacity is 1 - exp(-INK ink), ink 1 at a line's centre.
# Flat-topped on purpose. HUE_SMOOTH colours a pixel by the value-weighted
# mean of its neighbourhood, so a line's soft shoulders pull its colour down
# the ramp: with a gentler 3 a line meant to be pink came out 0.77 of the way
# up (violet). At 8 it is 0.88 there, for the same 3.3 px apparent width.
PEN = 0.8 / 2400
INK = 8.0

# kind: 'kh' or 'rt'. box: domain (Lx, Ly); grid: (nx, ny). KH lengths are in
# shear-layer half-thicknesses delta and speeds in U, so lambda_max = 14.1;
# RT lengths in domain widths, buoyancy jump 2B = 2. nu = kappa. modes:
# (wavenumber index, amplitude) pairs added to a random band; seed: of that
# band's phases and amplitudes -- part of the picture, so pinned. t: the
# instant drawn; snap: snapshot interval for the dye. lines: (reach, count,
# stretch): starting heights of the dye relative to the interface, out to
# +-reach, spaced up to cosh(stretch) times wider at the edges than at the
# middle, where the rolling-up happens. view: (x-centre,
# y-centre relative to the interface, width).
#
# The shear layer is seeded at four fastest-growing wavelengths with a
# subharmonic, so they roll up into four billows and pair into two -- and
# with a trace of the domain-length mode, so the two are not twins: with it
# they begin to orbit each other for the next pairing, which is the instant
# drawn. Without it the survivors sat level and identical, two ringed eyes
# over a band, which reads as a face. Re = U delta / nu = 800.
PRESETS = {
    "billows": dict(kind="kh", box=(4 * 14.13, 1.25 * 4 * 14.13), grid=(512, 640),
                    nu=1.25e-3, delta=1.0, modes=((4, 0.05), (2, 0.02), (1, 0.02)),
                    band=(1, 9, 0.004), seed=3, t=110.0, snap=0.2,
                    lines=(17.0, 51, 1.2), tone=("core", 3.0), view=(37.3, 0.0, 56.52),
                    about="a shear layer rolled up into billows, two of them pairing   Re = 800"),
    "plumes": dict(kind="rt", box=(1.0, 0.78125), grid=(640, 500),
                   nu=8e-5, delta=0.004, modes=(), band=(3, 8, 0.0015),
                   seed=7, t=2.0, snap=0.008,
                   lines=(0.3, 41, 0.0), tone=("split", 0.03), view=(0.5, 0.0, 1.0),
                   about="heavy fluid falling into light, curling into mushroom caps"),
    "merger": dict(kind="kh", box=(3 * 14.13, 1.25 * 3 * 14.13), grid=(384, 480),
                   nu=1.25e-3, delta=1.0, modes=((3, 0.05),), band=(1, 6, 0.01),
                   seed=4, t=110.0, snap=0.2,
                   lines=(17.0, 51, 1.2), tone=("core", 3.0), view=(21.2, 0.0, 42.39),
                   about="three billows on a shear layer, paired and merged into one   Re = 800"),
}
# Offered on the desktop: the views chosen there. "merger" was shown and pruned
# (its preset stays above).
ORDER = ["billows", "plumes"]
NAMES = {"kh": "Kelvin-Helmholtz instability", "rt": "Rayleigh-Taylor instability"}

EPS = 0.5            # insert a dye point where neighbours are this many cells apart


def _perturb(p, x, rng):
    """Interface displacement eta(x): the named modes plus a random band."""
    L = p["box"][0]
    eta = np.zeros_like(x)
    for n, a in p["modes"]:
        eta += a * np.cos(2 * np.pi * n * x / L + rng.uniform(0, 2 * np.pi))
    n0, n1, rms = p["band"]
    ns = np.arange(n0, n1 + 1)
    amp = rng.normal(0.0, 1.0, ns.size)
    ph = rng.uniform(0, 2 * np.pi, ns.size)
    band = sum(a * np.cos(2 * np.pi * n * x / L + f) for n, a, f in zip(ns, amp, ph))
    # Normalised by the exact mean square of the series, not a sample of it,
    # so every caller gets the same interface whatever x it asks at.
    return eta + rms * band / np.sqrt(0.5 * np.sum(amp ** 2))


def _initial(p):
    """(w, b) on the grid, and the interface height y0 in the domain."""
    (Lx, Ly), (nx, ny), d = p["box"], p["grid"], p["delta"]
    x = np.arange(nx) * Lx / nx
    y = (np.arange(ny) * Ly / ny)[:, None]
    rng = np.random.default_rng(p["seed"])
    eta = _perturb(p, x, rng)[None, :]
    if p["kind"] == "kh":
        # u = U [tanh((y-y1)/d) - tanh((y-y2)/d) - 1]: -U, +U between the
        # layers, -U again. w = -u_y. The partner layer gets its own ripple.
        y1, y2 = Ly / 4, 3 * Ly / 4
        eta2 = _perturb(p, x, rng)[None, :]
        w = (-1 / np.cosh((y - y1 - eta) / d) ** 2 + 1 / np.cosh((y - y2 - eta2) / d) ** 2) / d
        return w, None, y1
    # Buoyancy -1 above the interface (heavy), +1 below; the product tapers
    # to zero at the domain edge, where the stable partner interface sits.
    y0, ds = Ly / 2, 6 * d
    s = np.tanh((y - y0 - eta) / d) * np.tanh(y / ds) * np.tanh((Ly - y) / ds)
    return np.zeros((ny, nx)), -s, y0


def _solve(p, log=None):
    """Integrate to p['t']; return (u, v) snapshots every p['snap']."""
    (Lx, Ly), (nx, ny) = p["box"], p["grid"]
    dx, dy = Lx / nx, Ly / ny
    kx = 2 * np.pi * np.fft.rfftfreq(nx, dx)[None, :]
    ky = 2 * np.pi * np.fft.fftfreq(ny, dy)[:, None]
    k2 = kx * kx + ky * ky
    inv = np.where(k2 > 0, 1.0 / np.where(k2 > 0, k2, 1.0), 0.0)
    keep = (np.abs(kx) < (2 / 3) * np.pi / dx) & (np.abs(ky) < (2 / 3) * np.pi / dy)
    nu = p["nu"]
    w, b, y0 = _initial(p)
    fft, ifft = np.fft.rfft2, (lambda a: np.fft.irfft2(a, s=(ny, nx)))
    W = fft(w) * keep
    B = fft(b) * keep if b is not None else None

    def vel(W):
        return ifft(1j * ky * inv * W), ifft(-1j * kx * inv * W)

    def rhs(W, B):
        u, v = vel(W)
        nw = -fft(u * ifft(1j * kx * W) + v * ifft(1j * ky * W)) * keep - nu * k2 * W
        if B is None:
            return nw, None, u, v
        nb = -fft(u * ifft(1j * kx * B) + v * ifft(1j * ky * B)) * keep - nu * k2 * B
        return nw + 1j * kx * B, nb, u, v

    snaps = []
    # Even, because the dye steps over snapshots two at a time.
    count = 2 * int(round(p["t"] / (2 * p["snap"])))
    u, v = vel(W)
    for k in range(count + 1):
        snaps.append((u.astype(np.float32), v.astype(np.float32)))
        if k == count:
            break
        # Step to the next snapshot in n equal steps, n from the CFL limit.
        cfl = 0.5 * min(dx, dy) / max(1e-6, np.abs(u).max() + np.abs(v).max())
        n = int(np.ceil(p["snap"] / min(cfl, p["snap"])))
        dt = p["snap"] / n
        for _ in range(n):
            a, c, _, _ = rhs(W, B)
            W1 = W + dt * a
            B1 = B + dt * c if B is not None else None
            a, c, _, _ = rhs(W1, B1)
            W2 = 0.75 * W + 0.25 * (W1 + dt * a)
            B2 = 0.75 * B + 0.25 * (B1 + dt * c) if B is not None else None
            a, c, _, _ = rhs(W2, B2)
            W = W / 3 + (2 / 3) * (W2 + dt * a)
            B = B / 3 + (2 / 3) * (B2 + dt * c) if B is not None else None
        u, v = vel(W)
        if log and k % 50 == 0:
            log(f"t = {(k + 1) * p['snap']:.3f}  umax {np.abs(u).max():.3f}  dt {dt:.4f}")
    return snaps, y0


_SNAPS = None        # the velocity history, inherited by forked workers
_BOX = None


def _interp(a, x, y):
    """Bilinear, periodic sample of grid field a at physical (x, y)."""
    ny, nx = a.shape
    gx, gy = x * (nx / _BOX[0]), y * (ny / _BOX[1])
    i, j = np.floor(gx).astype(np.int64), np.floor(gy).astype(np.int64)
    fx, fy = gx - i, gy - j
    i0, i1, j0, j1 = i % nx, (i + 1) % nx, j % ny, (j + 1) % ny
    return ((a[j0, i0] * (1 - fx) + a[j0, i1] * fx) * (1 - fy)
            + (a[j1, i0] * (1 - fx) + a[j1, i1] * fx) * fy)


def _insert(x, y, eps):
    """Add a point mid-way along every segment longer than eps: four-point
    (cubic) interpolation, so it lands on the curve as it turns."""
    i = np.nonzero(np.hypot(np.diff(x), np.diff(y)) > eps)[0]
    if i.size == 0:
        return x, y
    a, d = np.maximum(i - 1, 0), np.minimum(i + 2, x.size - 1)
    end = (a == i) | (d == i + 1)
    out = []
    for c in (x, y):
        m = (-c[a] + 9 * c[i] + 9 * c[i + 1] - c[d]) / 16
        m[end] = 0.5 * (c[i] + c[i + 1])[end]
        out.append(np.insert(c, i + 1, m))
    return out[0], out[1]


def _advect(args):
    """One line of dye through the stored history: RK4 over pairs of
    snapshot intervals, the middle snapshot supplying the half step."""
    x, y, h, eps = args
    for k in range(0, len(_SNAPS) - 2, 2):
        (ua, va), (ub, vb), (uc, vc) = _SNAPS[k], _SNAPS[k + 1], _SNAPS[k + 2]
        k1x, k1y = _interp(ua, x, y), _interp(va, x, y)
        k2x, k2y = _interp(ub, x + h * k1x, y + h * k1y), _interp(vb, x + h * k1x, y + h * k1y)
        k3x, k3y = _interp(ub, x + h * k2x, y + h * k2y), _interp(vb, x + h * k2x, y + h * k2y)
        k4x, k4y = (_interp(uc, x + 2 * h * k3x, y + 2 * h * k3y),
                    _interp(vc, x + 2 * h * k3x, y + 2 * h * k3y))
        x = x + h / 3 * (k1x + 2 * k2x + 2 * k3x + k4x)
        y = y + h / 3 * (k1y + 2 * k2y + 2 * k3y + k4y)
        x, y = _insert(x, y, eps)
    return x, y


def _simulate(p, jobs, log=None):
    global _SNAPS, _BOX
    _BOX = p["box"]
    _SNAPS, y0 = _solve(p, log)
    Lx = p["box"][0]
    eps = EPS * Lx / p["grid"][0]
    # Each line spans exactly one period, so tiling it by Lx draws every
    # stretch of dye exactly once, however far the stream has carried it.
    xs = np.linspace(0.0, Lx, int(Lx / eps) + 1)
    rng = np.random.default_rng(p["seed"])
    eta = _perturb(p, xs, rng) if p["kind"] == "rt" else 0.0
    work = [(xs.copy(), y0 + h0 + eta + 0 * xs, p["snap"], eps)
            for h0 in _heights(p)]
    import multiprocessing as mp
    with mp.get_context("fork").Pool(jobs) as pool:
        lines = pool.map(_advect, work, chunksize=1)
    _SNAPS = None
    return lines, y0


def _curve(c, q, xs, ys, tone, size, extent, spacing=0.5):
    """Deposit a curve resampled every `spacing` pixels along its own arc,
    through a Catmull-Rom spline, so tight turns stay round."""
    w, h = size
    x0, x1, y0, y1 = extent
    s = h / (y1 - y0)
    px = (xs - x0) * s - 0.5
    py = (y1 - ys) * s - 0.5                        # up is up: row 0 at the top
    if px.max() < -8 or px.min() > w + 8 or py.max() < -8 or py.min() > h + 8:
        return
    seg = np.hypot(np.diff(px), np.diff(py))
    arc = np.concatenate([[0.0], np.cumsum(seg)])
    t = np.arange(0.0, arc[-1], spacing)
    j = np.clip(np.searchsorted(arc, t, side="right") - 1, 0, px.size - 2)
    u = ((t - arc[j]) / np.maximum(seg[j], 1e-12))[:, None]
    a, d = np.maximum(j - 1, 0), np.minimum(j + 2, px.size - 1)
    P = np.stack([px, py], axis=1)
    p0, p1, p2, p3 = P[a], P[j], P[j + 1], P[d]
    pt = 0.5 * (2 * p1 + (p2 - p0) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u ** 2
                + (3 * p1 - p0 - 3 * p2 + p3) * u ** 3)
    px, py = pt[:, 0], pt[:, 1]
    keep = (px > -8) & (px < w + 8) & (py > -8) & (py < h + 8)
    px, py = px[keep], py[keep]
    ix, iy = np.floor(px).astype(np.int64), np.floor(py).astype(np.int64)
    fx, fy = px - ix, py - iy
    for dx, dy, wt in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)),
                       (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
        cx, cy = ix + dx, iy + dy
        m = (cx >= 0) & (cx < w) & (cy >= 0) & (cy < h)
        if m.any():
            idx = cy[m] * w + cx[m]
            c += np.bincount(idx, weights=wt[m], minlength=w * h)
            q += np.bincount(idx, weights=wt[m] * tone, minlength=w * h)


def _heights(p):
    reach, n, a = p["lines"]
    s = np.linspace(-1.0, 1.0, n)
    return reach * (np.sinh(a * s) / np.sinh(a) if a > 0 else s)


def _tones(p):
    """A ramp position per line, from the height it started at."""
    h = _heights(p)
    kind, s = p["tone"]
    if kind == "split":
        # Lower fluid to the cool end, upper to the warm, graded over s.
        return 0.6 + 0.4 * np.tanh(h / s)
    # "core": the layer itself warm, fading to cool with distance from it.
    return 1.0 - 0.8 * np.tanh(np.abs(h) / s)


def caption(seed):
    """(title, subtitle) from the preset alone, so a re-colour from a saved
    field -- which never calls generate() -- gets the same caption."""
    p = PRESETS[ORDER[seed % len(ORDER)]]
    return NAMES[p["kind"]], p["about"]


def generate(size, seed=0, jobs=None, cache=None, view=None, log=None):
    import lib

    w, h = size
    p = PRESETS[ORDER[seed % len(ORDER)]]
    if cache and os.path.exists(cache):
        z = np.load(cache)
        cut = np.cumsum(z["n"])[:-1]
        lines = list(zip(np.split(z["lx"], cut), np.split(z["ly"], cut)))
        y0 = float(z["y0"])
    else:
        lines, y0 = _simulate(p, jobs or min(14, os.cpu_count() or 4), log)
        if cache:
            np.savez(cache, n=[l[0].size for l in lines], y0=y0,
                     lx=np.concatenate([l[0] for l in lines]),
                     ly=np.concatenate([l[1] for l in lines]))

    Lx = p["box"][0]
    vx, vy, width = view or p["view"]
    height = width * h / w
    extent = (vx - width / 2, vx + width / 2, y0 + vy - height / 2, y0 + vy + height / 2)
    tone = _tones(p)
    c, q = np.zeros(w * h), np.zeros(w * h)
    for (lx, ly), tn in zip(lines, tone):
        for k in range(int(np.floor((extent[0] - lx.max()) / Lx)),
                       int(np.ceil((extent[1] - lx.min()) / Lx)) + 1):
            _curve(c, q, lx + k * Lx, ly, tn, size, extent)

    sigma = PEN * h
    c = lib.smooth(c.reshape(h, w).astype(np.float32), sigma)
    q = lib.smooth(q.reshape(h, w).astype(np.float32), sigma)
    ink = c * (sigma * np.sqrt(2 * np.pi) / 2.0)
    with np.errstate(divide="ignore", invalid="ignore"):
        hue = np.where(c > 1e-9, q / c, 0.0)
    return ((1.0 - np.exp(-INK * ink)) * hue).astype(np.float32)
