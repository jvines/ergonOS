"""Fraunhofer diffraction -- what an aperture does to a plane wave, seen far away.

A plane wave through an aperture A(x) arrives at a distant screen (or at the
focus of a lens) as the Fourier transform of the aperture,

    I(u) = | integral A(x) exp(-2 pi i u.x) d^2x |^2,     u = theta / lambda,

so the pattern is the aperture's power spectrum: every edge in the aperture
throws a spike perpendicular to itself, every repeat throws a grid of peaks,
every hole throws a set of rings. Drawn on a LOG scale, as an astronomer
displays a star, because the interesting part of each pattern lies four to
eight decades below its core.

The views, each one aperture:

  * a SEGMENTED MIRROR, JWST-like: eighteen hexagonal segments 1.32 m across
    flat to flat, 7 mm apart, the centre one missing, and three struts
    holding the secondary mirror -- one straight up, two at 30 degrees either
    side of straight down. The six great spikes are the segment edges; the
    faint horizontal pair is the vertical strut (the other two lie along
    edges, so their spikes hide under the big ones); it fades out at the
    sides of the screen, just short of the first zero of the strut's own
    5 cm width, at lambda / 5 cm = 130 lambda/D. The hexagonal grid of
    knots is the segment array acting as a grating, and the fine rings
    inside each knot are the whole 6.6 m mirror. Out to 114 lambda/D on the
    long axis, at one wavelength -- a narrow filter. A 20% band was built
    and shown: the pattern scales with lambda, so every knot smears radially
    into a streak, which is what a broad-band image of a bright star does and
    is also a soft, featureless blur on a panel this size.
  * a PENROSE TILING of pinholes, lit by a laser with a Gaussian beam. The
    tiling has no period, yet its pattern is a sharp set of Bragg peaks with
    tenfold symmetry -- a symmetry no crystal can have. Mackay made this
    optical transform in 1982, two years before Shechtman et al. published
    the same tenfold pattern in electron diffraction from a real alloy. The pinholes
    are de Bruijn's pentagrid vertices (1981).
  * a SIERPINSKI CARPET: a square with its middle ninth removed, and the
    middle ninth of each of the eight squares left, five times over. Its
    transform is a product, one factor per level, so the pattern repeats
    itself each time the scale shrinks by three.

HOW. The mirror by a matrix Fourier transform (Soummer et al. 2007): the pupil
is rasterised with analytic anti-aliased edges and transformed with two matrix
products straight onto the panel's pixel grid, so there is no FFT wrap-around
and the angular scale is set freely. The pinholes are a sum over holes, also
two matrix products (the phase exp(-2 pi i u.x) separates into rows and
columns); the carpet is closed form. Intensity is averaged over each pixel
before the logarithm, as a detector would, so the dark zeros between fringes
land on a finite value instead of beading into pinpricks.
"""

import numpy as np

TITLE = "Fraunhofer diffraction"
SUBTITLE = "an aperture's far-field pattern: the squared modulus of its Fourier transform, on a log scale"

# The generator does its own logarithmic stretch (see _tone) and hands over 0..1.
# GAMMA 0.7 on top of it: at 1.0 most of what is lit sits in the ramp's first
# stop and the whole pattern is one teal; 0.7 carries the spikes and the
# bright Bragg peaks up into blue and mauve. The stretch's soft toe keeps that
# lift from reaching the faintest light (see _tone).
SCALE = "unit"
GAMMA = 0.7
BLEND = 0.85
RAMP = "full"
SATURATION = 1.8
EXPOSURE = 1.0
SOFTEN = 0.0
HUE_SMOOTH = 3.0
# Everything here is band-limited already -- an aperture of finite size has a
# transform with no detail finer than lambda over twice its width -- and the
# pixel averaging is done inside, before the logarithm, where it belongs.
SUPERSAMPLE = 1

# Per view: fov is the panel HEIGHT in the pattern's natural unit (lambda/D for
# the mirror, 1/edge for the tiling, 1/side for the carpet); decades is the
# log range shown, down from top (log10 of the level, relative to the peak,
# where the ramp saturates); os is how many samples per pixel per axis are
# averaged before the logarithm.
#
# The mirror: 4 decades leaves the ground between the spikes empty, which is
# the point; at 4.3 and above the faint lattice of knots scatters over it like
# dust, and past 4.6 the star drowns. Its fov is not fixed: the panel's
# half-WIDTH is set to `edge` times the strut's first zero (lambda / 5 cm, 130
# lambda/D), so the horizontal spike fades out at the sides of the screen at
# any aspect ratio instead of breaking into a dark eye and a detached stub
# (143 lambda/D tall at 16:10). Wider fields (200, and 72, 36, 24 lambda/D the
# other way) were tried: 200 put that break on screen, the others were one
# screen-filling slab of speckle.
# The tiling: radius and taper (the beam amplitude falls as exp(-r^2/2 taper^2)) set
# the size of every peak. Taper 17 blurred the densest clusters of peaks into
# rings; 24 made them pinpricks. 4 decades; 5.5 filled the dark between the
# rows of peaks with a dust of weak ones.
# The pinholes, and the tiling's pentagrid offsets, are part of the picture.
VIEWS = [
    dict(name="mirror", fov=None, edge=0.88, top=-2.5, decades=4.0, os=2,
         band=0.0, nlam=1, pupil=1536),
    dict(name="penrose", fov=6.0, top=-1.5, decades=4.0, os=1,
         radius=66.0, taper=19.0, hole=0.12, gamma=(0.1, 0.23, -0.17, 0.31, -0.47)),
    dict(name="carpet", fov=100.0, top=-1.5, decades=5.0, os=2, levels=5),
]


def caption(seed):
    v = VIEWS[seed % len(VIEWS)]
    if v["name"] == "mirror":
        return ("Diffraction, a segmented mirror",
                "a star through 18 hexagonal segments and three struts, as on JWST:"
                f"  one wavelength, log intensity over {v['decades']:g} decades")
    if v["name"] == "penrose":
        return ("Diffraction, a Penrose tiling",
                "laser light through pinholes at the vertices of a Penrose tiling:"
                "  tenfold Bragg peaks, forbidden to any crystal")
    return ("Diffraction, a Sierpinski carpet",
            f"a square aperture with its middle ninth removed, {v['levels']} levels deep:"
            "  the pattern repeats at a third of the scale")


def _grid(w, h, fov, os):
    """Pixel-centre coordinates of the panel, os x os samples per pixel, in the
    view's unit: the panel height spans fov, the width the same scale."""
    ys = ((np.arange(h * os) + 0.5) / os - h / 2) / h * fov
    xs = ((np.arange(w * os) + 0.5) / os - w / 2) / h * fov
    return xs, ys


# -- the segmented mirror ----------------------------------------------------

SEG = 1.32        # segment flat-to-flat, m
GAP = 0.007       # between segments, m
STRUT = 0.05      # strut width, m
D_REF = 6.5       # the "D" of lambda/D, m


def _hexnorm(x, y):
    """Distance-like norm whose unit ball is a flat-topped hexagon of inradius 1:
    the largest projection on the three edge normals (90, 30, 150 degrees)."""
    c = np.sqrt(3) / 2
    return np.maximum(np.abs(y), np.maximum(np.abs(c * x + 0.5 * y), np.abs(c * x - 0.5 * y)))


def _pupil(n):
    """Transmission of the mirror on an n x n grid spanning 7 m, with edges
    anti-aliased from their signed distance (coverage = 1/2 + distance/pixel)."""
    L = 7.0
    px = L / n
    c = (np.arange(n) + 0.5) * px - L / 2
    X, Y = np.meshgrid(c, -c)          # row 0 at the top of the mirror
    s = SEG + GAP                      # centre spacing
    P = np.zeros((n, n))
    for q in range(-2, 3):
        for r in range(-2, 3):
            ring = (abs(q) + abs(r) + abs(q + r)) // 2
            if ring not in (1, 2):
                continue
            cx, cy = s * np.sqrt(3) / 2 * q, s * (r + q / 2)
            d = SEG / 2 - _hexnorm(X - cx, Y - cy)
            P = np.maximum(P, np.clip(0.5 + d / px, 0, 1))
    # Struts from the centre to beyond the rim: up, and 30 deg either side of down.
    for ang in (90.0, 240.0, 300.0):
        ux, uy = np.cos(np.radians(ang)), np.sin(np.radians(ang))
        along = X * ux + Y * uy
        across = np.abs(-X * uy + Y * ux)
        d = np.where(along > 0, across - STRUT / 2, np.inf)
        P *= np.clip(0.5 + d / px, 0, 1)
    return P, c


# Output rows per band. The mirror and the carpet are computed a band at a
# time so their sample arrays stay bounded at 8K (15360 x 9600 samples at
# os 2 is 2.4 GB for one complex array); the pixel average is taken per band.
ROWS = 240


def _pixels(I, os):
    """Average each pixel's os x os samples -- what a detector pixel records."""
    if os == 1:
        return I
    h, w = I.shape[0] // os, I.shape[1] // os
    return I.reshape(h, os, w, os).mean(axis=(1, 3))


def _mirror(xs, ys, v, os):
    P, eta = _pupil(v["pupil"])
    out = np.zeros((ys.size // os, xs.size // os))
    # Wavelengths evenly across the band; lambda / lambda0 = s scales the pattern,
    # and 1/s^2 gives every wavelength the same total flux (Parseval).
    for s in np.linspace(1 - v["band"] / 2, 1 + v["band"] / 2, v["nlam"]):
        k = -2j * np.pi / (D_REF * s)
        T = P @ np.exp(k * np.outer(eta, xs))                 # (n, W)
        for j in range(0, ys.size, ROWS * os):
            # Pupil rows run top-down, so the pupil's y is -eta.
            F = np.exp(k * np.outer(ys[j:j + ROWS * os], -eta)) @ T
            out[j // os:j // os + ROWS] += _pixels(F.real ** 2 + F.imag ** 2, os) / s ** 2
    return out


# -- the Penrose tiling -------------------------------------------------------

def _penrose(radius, gamma):
    """Vertices of a rhombic Penrose tiling of unit edge within `radius`, by de
    Bruijn's pentagrid: every crossing of two grid lines is a rhombus, and its
    four corners are sum_j K_j e_j with K_j the index of the strip it lies in."""
    e = np.array([[np.cos(2 * np.pi * j / 5), np.sin(2 * np.pi * j / 5)] for j in range(5)])
    g = np.asarray(gamma)
    K = int(radius / 2.5) + 3            # vertices lie at ~2.5 x their grid point
    ks = np.arange(-K, K + 1)
    out = []
    for r in range(5):
        for s in range(r + 1, 5):
            kr, kk = np.meshgrid(ks, ks)
            kr, kk = kr.ravel(), kk.ravel()
            M = np.array([e[r], e[s]])
            x = np.linalg.solve(M, np.stack([kr - g[r], kk - g[s]]))   # (2, n)
            idx = np.ceil(e @ x + g[:, None])                          # (5, n)
            for dr in (0, 1):
                for ds in (0, 1):
                    idx[r], idx[s] = kr + dr, kk + ds
                    out.append((idx.T @ e))
    V = np.unique(np.round(np.concatenate(out), 6), axis=0)
    return V[np.hypot(V[:, 0], V[:, 1]) < radius]


def _j1(x):
    """Bessel J1 by its integral, J1(x) = (1/pi) int_0^pi cos(t - x sin t) dt;
    numpy has no Bessel functions and the argument here stays below ~20."""
    t = np.linspace(0, np.pi, 257)
    wts = np.full(t.size, t[1]); wts[[0, -1]] /= 2
    return (np.cos(t[None, :] - np.asarray(x)[..., None] * np.sin(t)[None, :]) @ wts) / np.pi


def _penrose_pattern(xs, ys, v, os):
    V = _penrose(v["radius"], v["gamma"])
    wgt = np.exp(-(V ** 2).sum(1) / (2 * v["taper"] ** 2))      # the laser's beam
    F = np.zeros((ys.size, xs.size), np.complex128)
    for i in range(0, len(V), 3000):
        c = slice(i, i + 3000)
        Ey = np.exp(-2j * np.pi * np.outer(ys, V[c, 1])) * wgt[c]
        Ex = np.exp(-2j * np.pi * np.outer(V[c, 0], xs))
        F += Ey @ Ex
    I = F.real ** 2 + F.imag ** 2
    # Each pinhole is a disc of radius `hole`: its Airy pattern is the envelope.
    q = np.hypot(xs[None, :], ys[:, None])
    qq = np.linspace(0, q.max() * 1.01, 4096)
    z = 2 * np.pi * v["hole"] * qq
    airy = np.where(z > 1e-9, 2 * _j1(z) / np.maximum(z, 1e-9), 1.0) ** 2
    return _pixels(I * np.interp(q, qq, airy), os)


# -- the Sierpinski carpet ----------------------------------------------------

def _carpet(xs, ys, v, os):
    """Transform of the level-n carpet on the unit square, closed form:
    F_n(u) = (1/9) G(u) F_{n-1}(u/3), G summing the eight kept sub-squares."""
    out = np.zeros((ys.size // os, xs.size // os))
    n = 3 ** v["levels"]
    for j in range(0, ys.size, ROWS * os):
        u, w = xs[None, :], ys[j:j + ROWS * os, None]
        F = np.sinc(u / n) * np.sinc(w / n) + 0j       # the smallest square
        for k in range(v["levels"]):
            a, b = u / 3 ** k, w / 3 ** k
            Su = 1 + np.exp(-2j * np.pi * a / 3) + np.exp(-4j * np.pi * a / 3)
            Sv = 1 + np.exp(-2j * np.pi * b / 3) + np.exp(-4j * np.pi * b / 3)
            F *= (Su * Sv - np.exp(-2j * np.pi * (a + b) / 3)) / 9
        out[j // os:j // os + ROWS] = _pixels(F.real ** 2 + F.imag ** 2, os)
    return out


# The toe spans the bottom half of the log range (2 decades on the mirror).
# A quarter softened the rims but left the faint knots as bright teal as the
# spikes; half dims them, so the lattice between the spikes and the carpet's
# outskirts fade into the ground.
TOE = 0.5


def _tone(I, v):
    """Map log10 intensity relative to the peak: `top` and above is 1,
    `top - decades` and below is 0 -- the empty ground.

    With a SOFT TOE. A plain clip leaves the stretch meeting the floor at a
    finite slope, and the GAMMA below 1 applied afterwards turns that slope
    infinite: every faint knot became a flat teal cut-out with a hard rim, and
    the ground between the spikes a scatter of opaque dots. Multiplying by a
    smoothstep over the bottom TOE of the range makes the stretch leave the
    floor with zero slope (as s^3, and s^2.1 after the gamma), so faint light
    fades into the ground instead of stopping at it. Above the toe nothing
    changes."""
    L = np.log10(np.maximum(I / I.max(), 1e-30))
    s = np.clip((L - (v["top"] - v["decades"])) / v["decades"], 0.0, 1.0)
    t = np.clip(s / v.get("toe", TOE), 0.0, 1.0)
    return s * t * t * (3 - 2 * t)


def generate(size, seed=0, **kw):
    v = dict(VIEWS[seed % len(VIEWS)], **kw)
    w, h = size
    if v["fov"] is None:
        # The mirror: half-width = edge x the strut's first zero, D / STRUT in
        # lambda/D; the height follows from the panel's aspect ratio.
        v["fov"] = 2 * v["edge"] * (D_REF / STRUT) * h / w
    xs, ys = _grid(w, h, v["fov"], v["os"])
    fn = {"mirror": _mirror, "penrose": _penrose_pattern, "carpet": _carpet}[v["name"]]
    return _tone(fn(xs, ys, v, v["os"]), v)
