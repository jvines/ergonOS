"""Hydrogen -- where the electron is, |psi|^2 in a plane through the nucleus.

Every bound state of hydrogen is known in closed form. The textbook ones are
separable in spherical coordinates,

    psi_nlm = R_nl(r) Y_lm(theta, phi),
    R_nl ~ rho^l e^{-rho/2} L_{n-l-1}^{2l+1}(rho),   rho = 2r / n a0,

but that is only one of the coordinate systems in which the Coulomb problem
separates. It also separates in PARABOLIC coordinates, xi = r + z and
eta = r - z, where the states are

    psi_{n1 n2 m} ~ e^{-(xi + eta) / 2n} (xi eta)^{|m|/2}
                    L_{n1}^{|m|}(xi / n) L_{n2}^{|m|}(eta / n) e^{i m phi},
    n = n1 + n2 + |m| + 1.

Both sets are exact eigenstates with energy -13.6 eV / n^2; within one shell
they are different bases for the same n^2-fold degenerate space, the degeneracy
that belongs to the hidden SO(4) symmetry of the 1/r potential (the conserved
Runge-Lenz vector). The parabolic states are the ones an electric field picks
out -- the linear Stark effect -- and each carries a permanent electric dipole:
with n1 > n2 the electron sits on one side of the nucleus. Their nodal lines
are confocal parabolas, focus on the nucleus, n1 opening one way and n2 the
other, crossing at right angles.

THE PICTURE. The density in the plane containing the symmetry axis. Nodes --
where psi changes sign -- are the lines the eye reads. The density spans many
decades: the lobes near the nucleus are orders of magnitude denser than the
outer ones, and on a linear scale the whole outer shell is invisible. So
everything within DECADES decades of the peak is lit, everything fainter is
empty ground, and the lit pixels are coloured by RANK of density (the
renderer's 'equalize'): each lobe runs from teal at its rim to pink at its
core, and the densest lobes -- along the axis, near the nucleus -- are pinkest.
A log stretch was tried first; it made every lobe the same flat teal.

THE NODES are drawn as a gap of fixed width, from the first-order distance to
the nodal set, |psi| / |grad psi| -- the same construction as chladni.py and
ising.py. The density's own zero makes a gap whose width depends on how dense
the lobes either side are: a hairline between the bright inner lobes that
beads at 4K, and a broad trough between the faint outer ones. The field handed
to the renderer is the log density, 0 at the floor and 1 at the peak, times
that gap; ranking it ignores the log and keeps the floor and the gaps.

THE VIEWS were picked from a sheet of about thirty states. The Stark states
are the strongest pictures: the n = 26 state with n1 = 20, n2 = 5 opens into a
fan, the electron pushed to one side of the nucleus (the dipole is
(3/2) n (n1 - n2) e a0), and n1 = n2 = 8 has none: a symmetric lens. The
spherical 10k orbital (l = 7, m = 2) is the flower everyone knows from the
textbook: 2 radial nodes, l - m = 5 conical ones, and the z axis. It is framed
so the flower fills the height of the panel.

No supersampling: the field is analytic and every edge in it is a Gaussian a
few pixels wide.

A Kepler-ellipse state (the SO(4) coherent state, Gay, Delande & Bommier 1989)
was built and checked -- nucleus at the focus, apsides where Kepler puts them
-- and pruned: at any n that is affordable here it is a fuzzy ring.
"""

import os
from math import lgamma

import numpy as np

TITLE = "Hydrogen atom"
SUBTITLE = "electron probability density in a plane through the nucleus"

SCALE = "equalize"
GAMMA = 1.0
RAMP = "full"
SATURATION = 1.6
EXPOSURE = 1.0
BLEND = 0.85
SUPERSAMPLE = 1

DECADES = 4.0      # density range shown; below 10^-DECADES of the peak is ground
GAP = 0.0007       # half-width of a node's dark line, in panel heights (~1.7 px at 4K)

# Each view: the state, and where the panel sits on the plane. The plane holds
# the symmetry (z) axis; AXIS is the direction z points on screen (0 = right,
# pi/2 = up), CENTRE the point (z, x) at the middle of the panel and HALF the
# panel's half-height, all in Bohr radii.
# Only the states chosen on a real desktop are here. A symmetric Stark lens,
# (n1, n2, m) = (8, 8, 0), centre (0, 0), half 395, was shown and pruned.
VIEWS = [
    dict(kind="stark", q=(20, 5, 0), axis=np.pi / 2, centre=(412.0, 0.0), half=820.0),
    dict(kind="orbital", q=(10, 7, 2), axis=np.pi / 2, centre=(0.0, 0.0), half=195.0),
]

SPD = "spdfghiklmnoqrtuv"


def _laguerre(k, alpha, x):
    """Generalised Laguerre L_k^alpha(x), by the three-term recurrence."""
    l0 = np.ones_like(x)
    if k == 0:
        return l0
    l1 = 1.0 + alpha - x
    for i in range(1, k):
        l0, l1 = l1, ((2 * i + 1 + alpha - x) * l1 - (i + alpha) * l0) / (i + 1)
    return l1


def _legendre(l, m, x):
    """Orthonormal associated Legendre function, so that
    Y_lm = _legendre(l, m, cos theta) e^{i m phi}. Stable recurrence."""
    s = np.sqrt(np.maximum(0.0, 1.0 - x * x))
    p = np.full_like(x, 1.0 / np.sqrt(4 * np.pi))
    for i in range(1, m + 1):
        p = -np.sqrt((2 * i + 1) / (2.0 * i)) * s * p
    if l == m:
        return p
    p1 = x * np.sqrt(2 * m + 3) * p
    for L in range(m + 2, l + 1):
        a = np.sqrt((4.0 * L * L - 1) / (L * L - m * m))
        b = np.sqrt(((L - 1) ** 2 - m * m) / (4.0 * (L - 1) ** 2 - 1))
        p, p1 = p1, a * (x * p1 - b * p)
    return p1


def _psi(view, z, x):
    """The (real) wavefunction at plane points (z, x), up to normalisation.
    x < 0 is the half-plane phi = pi; the real combination cos(m phi) is
    drawn, whose sign there is (-1)^m."""
    if view["kind"] == "stark":
        n1, n2, m = view["q"]
        n = n1 + n2 + m + 1
        r = np.hypot(x, z)
        xi, eta = r + z, r - z
        return (np.exp(-(xi + eta) / (2 * n)) * x ** m
                * _laguerre(n1, m, xi / n) * _laguerre(n2, m, eta / n))
    n, l, m = view["q"]
    r = np.hypot(x, z)
    rho = 2.0 * r / n
    ct = np.where(r > 0, z / np.maximum(r, 1e-300), 1.0)
    # rho^l e^{-rho/2}, in logs: at n = 9 the two factors alone span 1e20.
    rad = np.exp(l * np.log(np.maximum(rho, 1e-300)) - rho / 2
                 + 0.5 * (lgamma(n - l) - lgamma(n + l + 1)))
    ang = _legendre(l, m, ct) * np.where(x < 0, (-1.0) ** m, 1.0)
    return rad * _laguerre(n - l - 1, 2 * l + 1, rho) * ang


def _plane(view, s, t):
    """Screen coordinates (s right, t up; Bohr radii from the panel centre)
    to plane coordinates (z, x)."""
    c, sn = np.cos(view["axis"]), np.sin(view["axis"])
    cz, cx = view["centre"]
    return cz + s * c + t * sn, cx - s * sn + t * c


def _peak(view, aspect):
    """Peak density over the panel, from a fixed coarse survey -- the same
    number at any resolution, so the stretch is too."""
    ny = 600
    nx = int(ny * aspect)
    h = view["half"]
    s = ((np.arange(nx) + 0.5) / ny - aspect / 2) * 2 * h
    t = (0.5 - (np.arange(ny) + 0.5) / ny) * 2 * h
    S, T = np.meshgrid(s, t)
    return float((_psi(view, *_plane(view, S, T)) ** 2).max())


def _band(job):
    """One band of rows: log density, cut by the nodal gaps."""
    j0, j1, w, hpx, vi, peak = job
    view = VIEWS[vi]
    h = view["half"]
    px = 2 * h / hpx                                  # Bohr radii per pixel
    s = (np.arange(w) + 0.5 - w / 2) * px
    t = (hpx / 2 - (np.arange(j0 - 1, j1 + 1) + 0.5)) * px
    S, T = np.meshgrid(s, t)
    psi = _psi(view, *_plane(view, S, T))
    gy, gx = np.gradient(psi, px)
    # Distance to the nearest node, in panel heights.
    d = np.abs(psi) / (np.hypot(gx, gy) + 1e-300) / (2 * h)
    lit = np.clip(1.0 + np.log10(psi * psi / peak + 1e-300) / DECADES, 0.0, 1.0)
    out = lit * (1.0 - np.exp(-(d / GAP) ** 2))
    return j0, out[1:-1].astype(np.float32)


def caption(seed):
    v = VIEWS[seed % len(VIEWS)]
    # Short: the lower-left corner is all the empty ground these views leave.
    if v["kind"] == "stark":
        n1, n2, m = v["q"]
        n = n1 + n2 + m + 1
        return ("Hydrogen atom, Stark state",
                f"n = {n}; n1 = {n1}, n2 = {n2}, m = {m}; parabolic nodes")
    n, l, m = v["q"]
    return ("Hydrogen atom", f"the {n}{SPD[l]} orbital, m = {m}, through the nucleus")


def generate(size, seed=0, jobs=None, rows=48):
    w, h = size
    vi = seed % len(VIEWS)
    peak = _peak(VIEWS[vi], w / h)
    work = [(j, min(j + rows, h), w, h, vi, peak) for j in range(0, h, rows)]
    out = np.zeros((h, w), np.float32)
    import multiprocessing as mp
    with mp.get_context("fork").Pool(jobs or os.cpu_count() or 4) as pool:
        for j0, band in pool.imap_unordered(_band, work):
            out[j0:j0 + band.shape[0]] = band
    return out
