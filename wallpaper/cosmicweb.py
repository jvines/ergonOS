"""Cosmic web -- dark matter in the Zel'dovich approximation.

    x(q, t) = q + D(t) s(q),        div s = -delta_lin(q)

Every particle starts at its Lagrangian position q on a uniform grid and moves
in a straight line, along the displacement s its initial potential gives it,
by an amount that grows with the linear growth factor D(t) (Zel'dovich 1970).
Mass is conserved, so the density is the Jacobian of that map:

    rho / rho_mean = 1 / |det(I + D ds/dq)|

and it diverges wherever the map folds -- where neighbouring particles have
caught each other up and a stream crosses itself. Those folds are caustics,
and they are the web: sheets ("pancakes") where one eigenvalue of the
deformation tensor has gone through -1/D, filaments and knots where two have.
Between them the voids keep emptying outward. Arnold, Shandarin and Zel'dovich
(1982) classified the caustics of this map, and in two dimensions they are
exactly what is drawn here: fold lines that end in cusps, pairs of folds
bounding the three-stream regions that open inside every wall, and knots where
walls meet.

TWO-DIMENSIONAL. The slice is a 2-D universe, periodic on the panel, whose
initial fluctuations have the CDM spectral shape: P(k) ~ k T(k)^2 with the
BBKS transfer function (Bardeen, Bond, Kaiser & Szalay 1986), Gamma = 0.2,
the panel 300 Mpc/h tall. It is not a slice through a 3-D run -- particles in
a real slice leave it -- and it does not pretend to be.

TRUNCATED. Zel'dovich's straight lines do not stop at a caustic: particles
fly through the wall and out the other side, and on scales that went
non-linear long ago the web dissolves into a haze. The cure is to throw those
scales away before moving anything -- smooth the linear field with a Gaussian
at the scale that is just going non-linear (Coles, Melott & Shandarin 1993),
which is what N-body runs say the approximation gets right. So each view is
two numbers, the smoothing and the rms of the smoothed linear density, and
the second is the clock: at ~1 the first walls have formed, past ~2 they have
thickened and merged into a network around voids.

RENDERING. A density, not trajectories, so the particle count only decides
the noise. Particles sit on a lattice of M x M per pixel (100 at M = 10),
which is quiet where Poisson sampling would be grainy. It is not free of
artefacts: a lattice stretched by the voids beats against the pixel grid, and
at M = 6 that showed as concentric moire in the voids under the log stretch.
The displacement at every lattice offset is the band-limited field shifted
exactly, by a phase ramp on its Fourier modes, never interpolated. The
deposit wraps around the edges because the box is periodic.

PINNED. The random phases are drawn on a fixed grid of Fourier modes per
panel height, independent of the pixel count, and zero-padded up to the
panel. The smoothing leaves nothing above that grid's Nyquist, so a 4K and
an 8K render are the same universe, sampled more finely. Views 0 and 1 share
their phases: one universe at two times.

STRETCH. The density spans four decades, so what is returned is
log(rho / RHO_VOID): each decade of compression climbs the ramp at the same
rate -- walls teal, caustics blue, knots pink -- and everything thinner than
RHO_VOID of the mean sits on the desktop colour. Measured from the 2nd
percentile first, the voids were lit too: half the panel is underdense, and
it came out as a solid teal slab with the web drawn on it.
"""

import numpy as np

TITLE = "Cosmic web"
SUBTITLE = "2-D Zel'dovich approximation, cold dark matter"

# Already logarithmic, so a plain percentile clip; 0.8 lifts the walls off
# the ground without washing the knots. Chosen against zscale (the web came
# out one teal), equalize (busy, pink everywhere) and gamma 1.2.
SCALE = "linear"
GAMMA = 0.8
BLEND = 0.85
# Underdensity drawn as empty (see STRETCH).
RHO_VOID = 0.7
# Caustics are one pixel wide: without these they bead and change colour at
# their edges.
SOFTEN = 0.8
HUE_SMOOTH = 3.0
# The lattice is already M x M sub-pixel particles, deposited bilinearly.
SUPERSAMPLE = 1

# Particles per pixel per axis.
M = 10
# Random phases on MASTER Fourier modes per panel height (see PINNED).
MASTER = 640
# Panel height x Gamma: 300 Mpc/h at Gamma = 0.2.
H_GAMMA = 60.0

# (smoothing length as a fraction of panel height, rms of the smoothed linear
# density, seed of the phases -- part of the picture, so pinned, and what
# the view is about). Picked from six; a later time of phases 11 (rms 2.2)
# was dropped because its knots crumple, which is the approximation failing
# rather than the web.
#
# Only the finer scales were chosen on a real desktop. Phases 7 smoothed at
# 0.0040 -- at rms 1.6, the mature web, and at rms 1.0, the same universe
# earlier -- were shown and pruned.
VIEWS = [
    (0.0025, 1.8, 3, "finer scales: small voids nested inside the"
                     " large ones"),
]


def caption(seed):
    return TITLE, ("2-D Zel'dovich approximation, cold dark matter:  "
                   + VIEWS[seed % len(VIEWS)][3])


def _bbks(q):
    """BBKS transfer function, q = k / (Gamma h Mpc^-1)."""
    q = np.maximum(q, 1e-9)
    return (np.log1p(2.34 * q) / (2.34 * q)
            * (1 + 3.89 * q + (16.1 * q) ** 2 + (5.46 * q) ** 3
               + (6.71 * q) ** 4) ** -0.25)


def _modes(aspect, smooth_len, sigma, seed):
    """Fourier coefficients of delta on the master grid, with k in radians
    per panel height. Scaled so the smoothed field has rms `sigma`."""
    my = MASTER
    mx = int(round(MASTER * aspect))
    lx = mx / my                                  # box width, panel heights
    rng = np.random.default_rng(seed)
    c = np.fft.rfft2(rng.standard_normal((my, mx))) / (my * mx)
    ky = 2 * np.pi * np.fft.fftfreq(my, 1.0 / my)[:, None]
    kx = 2 * np.pi * np.fft.rfftfreq(mx, lx / mx)[None, :]
    k = np.hypot(kx, ky)
    # q = k / Gamma in h/Mpc; k here is per panel height.
    amp = np.sqrt(k * _bbks(k / H_GAMMA) ** 2)
    amp *= np.exp(-0.5 * (k * smooth_len) ** 2)
    amp[0, 0] = 0.0
    c *= amp
    c[my // 2, :] = 0.0                            # Nyquist row and column
    c[:, -1] = 0.0
    rms = np.fft.irfft2(c * (my * mx), s=(my, mx)).std()
    return c * (sigma / rms), lx


def _embed(c, h, w):
    """Master coefficients zero-padded into an (h, w) rfft2 array."""
    my, mc = c.shape
    out = np.zeros((h, w // 2 + 1), complex)
    ny = min(my // 2, h // 2)
    nc = min(mc, w // 2 + 1)
    out[:ny, :nc] = c[:ny, :nc]
    out[h - ny:, :nc] = c[my - ny:, :nc]
    return out * (h * w)


def _worker(args):
    """Deposit the particles of one row of lattice offsets. Periodic."""
    sx_k, sy_k, lx, h, w, m, row = args
    acc = np.zeros(h * w)
    ky = 2 * np.pi * np.fft.fftfreq(h, 1.0 / h)
    kx = 2 * np.pi * np.fft.rfftfreq(w, lx / w)
    jy = np.arange(h, dtype=float)[:, None]
    jx = np.arange(w, dtype=float)[None, :]
    oy = (row + 0.5) / m
    for col in range(m):
        ox = (col + 0.5) / m
        # The field at the lattice shifted by (ox, oy) pixels: exact for a
        # band-limited field, and costs one phase ramp per axis.
        ph = (np.exp(1j * ky * oy / h)[:, None]
              * np.exp(1j * kx * ox * lx / w)[None, :])
        # Displacements in pixels.
        dx = np.fft.irfft2(sx_k * ph, s=(h, w)) * (w / lx)
        dy = np.fft.irfft2(sy_k * ph, s=(h, w)) * h
        fx = jx + ox + dx - 0.5
        fy = jy + oy + dy - 0.5
        del dx, dy
        ix = np.floor(fx)
        iy = np.floor(fy)
        tx = (fx - ix).ravel()
        ty = (fy - iy).ravel()
        ix = ix.astype(np.int64).ravel() % w
        iy = iy.astype(np.int64).ravel() % h
        del fx, fy
        ix1 = (ix + 1) % w
        iy1 = (iy + 1) % h
        for cy, cx, wt in ((iy, ix, (1 - tx) * (1 - ty)),
                           (iy, ix1, tx * (1 - ty)),
                           (iy1, ix, (1 - tx) * ty),
                           (iy1, ix1, tx * ty)):
            acc += np.bincount(cy * w + cx, weights=wt, minlength=h * w)
    return acc


def density(size, seed=0, m=M, jobs=None, view=None):
    """rho / rho_mean on an (h, w) grid; rows count from the top."""
    w, h = size
    r, sig, phase_seed = (VIEWS[seed % len(VIEWS)] if view is None
                          else view)[:3]
    # A worker holds about fifteen full-panel float64 arrays at once; keep
    # the pool inside ~16 GB (six at 4K, two at 8K). The split into chunks
    # is fixed, so this changes the wall time and never the picture.
    jobs = jobs or max(1, min(6, int(16e9 / (120 * w * h))))
    c, lx = _modes(w / h, r, sig, phase_seed)
    d_k = _embed(c, h, w)
    ky = 2 * np.pi * np.fft.fftfreq(h, 1.0 / h)[:, None]
    kx = 2 * np.pi * np.fft.rfftfreq(w, lx / w)[None, :]
    k2 = kx ** 2 + ky ** 2
    k2[0, 0] = 1.0
    # s_k = i k delta_k / k^2, so that div s = -delta.
    sx_k = 1j * kx * d_k / k2
    sy_k = 1j * ky * d_k / k2
    work = [(sx_k, sy_k, lx, h, w, m, row) for row in range(m)]
    # One chunk per row of offsets: a fixed split, summed in a fixed order,
    # so the result does not depend on the machine's core count.
    if jobs > 1:
        import multiprocessing as mp
        with mp.Pool(min(jobs, m)) as pool:
            parts = pool.map(_worker, work)
    else:
        parts = [_worker(a) for a in work]
    rho = np.zeros(h * w)
    for p in parts:
        rho += p
    return (rho / (m * m)).reshape(h, w)


def generate(size, seed=0, m=M, jobs=None, view=None):
    rho = density(size, seed=seed, m=m, jobs=jobs, view=view)
    return np.clip(np.log(np.maximum(rho, 1e-12) / RHO_VOID), 0.0, None)
