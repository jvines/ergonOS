"""Quantum scars -- a standing wave in a chaotic billiard, piled onto one orbit.

A point particle bouncing inside a Bunimovich stadium -- two semicircles joined
by straight walls -- is chaotic for any length of straight wall (Bunimovich
1979): almost every orbit is unstable and, given time, covers the table
uniformly. The quantum version is the Dirichlet problem

    lap psi + k^2 psi = 0   inside,     psi = 0   on the wall,

and quantum ergodicity (Shnirelman 1974) says almost every high eigenstate
spreads out the same way, looking like a random superposition of plane waves
of wavelength 2 pi / k (Berry 1977). Heller (1984) found the exceptions: some
eigenstates are visibly concentrated along one isolated UNSTABLE periodic
orbit. Classically that orbit has measure zero and a trajectory near it leaves
at once; quantum mechanically a wave launched along it comes back before it has
spread, and interferes with itself constructively. He called the result a scar.
Each picture here is one exact eigenstate, |psi|^2, with its scar.

HOW THE EIGENSTATES ARE COMPUTED (numpy only)
  * Symmetry. The table has two mirror lines, so every eigenstate is even or
    odd about each: four classes, each solved on a quarter of the table.
  * Basis. Standing plane waves of one wavenumber with the class's parities,
    sin|cos(k x cos t) * sin|cos(k y sin t). Each already solves the wave
    equation and the mirror conditions, so only the real wall is left to fit.
  * The scaling method (Vergini & Saraceno 1995). From boundary integrals
    weighted by 1 / (r . n) at one reference k0, a single generalised
    eigenproblem returns every eigenstate in a window around k0, with
    k = k0 - 2 / mu. Near k0 it is accurate to O((k - k0)^3); a state sitting
    exactly ON k0 has zero boundary norm and drops out, so the solve is made a
    little off it on purpose.
  * Checks, run while building this: the number of states found per unit k
    matches Weyl's law with the perimeter term in all four classes (43, 45, 44,
    43 found on 99 < kR < 101 against 43.3, 44.2, 43.7, 43.8), zeros of J_m are
    reproduced on the circle, and every state drawn here leaves the wall with
    a residual |psi|^2 below 1e-5 of its interior norm.

Which states: about 870, in three windows of k, were scored by how much of
|psi|^2 lies in a tube around each short periodic orbit, and the strongest
were looked at. The k of each kept state is pinned below; generate() solves for
it again and refuses to draw anything else. Its NUMBER is from Weyl's law for
the whole table -- counting every state below it exactly would mean solving
thousands -- hence "about".

THE TABLE is 2R tall and 3.2R long -- straight walls of 1.2R -- which is 16:10:
the panel's own shape, so the whole billiard is on screen with an even margin.
Any straight length makes it chaotic; this one was chosen for the frame.

THE SCALE: kR ~ 80, a wavelength of ~90 px at 4K. Scars were looked at near
50, 80 and 120. At 120 the random-wave sea turns to lace and the scar sinks
into it; at 50 each lobe is ~70 px across and reads as out of focus.

THE LOOK: |psi|^2 itself, at unit mean, stretched steeply (the 99th percentile
is full scale, then gamma 2.2) so the random-wave sea sits low and dark and
only the scar's crests reach the top of the ramp; a gentler 97.5 / 1.8 lit the
sea almost as brightly as the scar. Mauve into pink, as for the other
screen-filling fields: the full ramp gave every lobe a teal rim, and the table
read as a teal slab with pink spots. The field is smooth on the scale of a
pixel, so there is no supersampling. The nodal lines -- where psi changes
sign -- are the dark network between the lobes, on the desktop colour.
"""

import numpy as np

TITLE = "Quantum scar"
SUBTITLE = "an eigenstate of the stadium billiard"

SCALE = "unit"
GAMMA = 2.2
RAMP = "warm"
SATURATION = 1.6
EXPOSURE = 1.0
BLEND = 0.85
SUPERSAMPLE = 1

R = 1.0            # end-cap radius: the unit of length
FLAT = 0.6         # half-length of the straight walls, in R
FILL = 0.94        # the table's height, as a fraction of the panel's
TOP = 99.0         # percentile of |psi|^2 that reaches the top of the ramp

# (orbit, symmetry class: parity in x then y, pinned kR).
# One view. A diamond scar at kR 50.50 was dropped: its lobes are too coarse
# to draw the orbit, and what the eye took from it was a ring along the wall.
# The best diamond, rectangle and axis states near kR 80 read the same way --
# rings hugging the wall, or a flat band -- so none of them replaced it.
VIEWS = [
    ("bow-tie", "oe", 80.1622),
]


def _wall(k, ppw=10):
    """Gauss-Legendre nodes on the quarter wall -- the straight piece, then
    the arc -- with weights ds / (r . n), at ppw nodes per wavelength."""
    xs, ys, ws = [], [], []
    n = int(ppw * k * FLAT / (2 * np.pi)) + 24
    g, wg = np.polynomial.legendre.leggauss(n)
    xs.append(FLAT * (g + 1) / 2); ys.append(np.full(n, R)); ws.append(FLAT / 2 * wg / R)
    n = int(ppw * k * (np.pi / 2 * R) / (2 * np.pi)) + 24
    g, wg = np.polynomial.legendre.leggauss(n)
    t = np.pi / 4 * (g + 1)
    xs.append(FLAT + R * np.cos(t)); ys.append(R * np.sin(t))
    ws.append(R * np.pi / 4 * wg / (FLAT * np.cos(t) + R))
    return np.concatenate(xs), np.concatenate(ys), np.concatenate(ws)


def _parity(u, odd):
    """The 1-D factor and its derivative for one parity."""
    return (np.sin(u), np.cos(u)) if odd else (np.cos(u), -np.sin(u))


def _basis(x, y, k, th, cls):
    """Basis values and their dilation derivatives (r . grad) at points."""
    ux, uy = k * np.outer(x, np.cos(th)), k * np.outer(y, np.sin(th))
    sx, dsx = _parity(ux, cls[0] == "o")
    sy, dsy = _parity(uy, cls[1] == "o")
    return sx * sy, ux * dsx * sy + uy * sx * dsy


def _solve(k0, cls, window=0.15, eps=1e-14):
    """All eigenstates of one class with |k - k0| < window: (k, coefs, angles)."""
    x, y, w = _wall(k0)
    # Enough directions to carry angular momentum up to k * (FLAT + R), the
    # table's far corner, twice over: more only worsens the conditioning.
    nb = int(k0 * (FLAT + R)) + 30
    th = (np.arange(nb) + 0.5) / nb * np.pi / 2
    P, D = _basis(x, y, k0, th, cls)
    F = P.T @ (w[:, None] * P)
    G = P.T @ (w[:, None] * D)
    G = (G + G.T) / k0
    # F is the boundary norm; it is singular along combinations of the
    # overcomplete basis that vanish everywhere, which are dropped.
    lam, V = np.linalg.eigh(F)
    keep = lam > eps * lam.max()
    Pm = V[:, keep] / np.sqrt(lam[keep])
    mu, U = np.linalg.eigh(Pm.T @ G @ Pm)
    with np.errstate(divide="ignore"):
        k = k0 - 2.0 / mu
    sel = np.abs(k - k0) < window
    return k[sel], Pm @ U[:, sel], th


def _residual(k, c, th, cls):
    """Wall residual: the integral of psi^2 along the wall over its integral
    over the quarter table. Zero for an exact eigenstate."""
    x, y, w = _wall(k)
    rn = np.where(x < FLAT, R, FLAT * (x - FLAT) / R + R)
    edge = np.sum(w * rn * (_basis(x, y, k, th, cls)[0] @ c) ** 2)
    ng = 400
    g = (np.arange(ng) + 0.5) / ng
    ps = _field(c, th, k, cls, g * (FLAT + R), g * R)
    X, Y = np.meshgrid(g * (FLAT + R), g * R)
    return edge / (np.sum(ps[_inside(X, Y)] ** 2) * (FLAT + R) * R / ng ** 2)


def _field(c, th, k, cls, x, y):
    """psi on the grid x (w,) by y (h,). Every basis function is a product of
    a function of x and one of y, so the whole raster is one matrix product."""
    sx, _ = _parity(k * np.outer(x, np.cos(th)), cls[0] == "o")
    sy, _ = _parity(k * np.outer(y, np.sin(th)), cls[1] == "o")
    return sy @ (c[:, None] * sx.T)


def _inside(X, Y):
    ax = np.maximum(np.abs(X) - FLAT, 0.0)
    return ax * ax + Y * Y <= R * R


def _state(cls, kpin):
    """The pinned eigenstate, solved again and checked."""
    k, C, th = _solve(kpin + 0.03, cls)
    i = int(np.argmin(np.abs(k - kpin)))
    if abs(k[i] - kpin) > 2e-3:
        raise RuntimeError(f"no {cls} eigenstate at kR = {kpin}: nearest {k[i]:.5f}")
    res = _residual(k[i], C[:, i], th, cls)
    if res > 1e-4:
        raise RuntimeError(f"{cls} state at kR = {k[i]:.5f} fails the wall: {res:.1e}")
    return k[i], C[:, i], th


def _number(k):
    """Weyl's estimate of how many states of the whole table lie below k."""
    area = np.pi * R * R + 4 * FLAT * R
    perim = 2 * np.pi * R + 4 * FLAT
    return (area * k * k - perim * k) / (4 * np.pi)


def caption(seed):
    orbit, cls, k = VIEWS[seed % len(VIEWS)]
    n = int(round(_number(k), -1))
    # Short: the caption sits over the table's lower-left wall.
    return ("Quantum scar",
            f"{orbit} orbit; stadium eigenstate ~{n:,}, kR = {k:.2f}")


def generate(size, seed=0, **kw):
    orbit, cls, kpin = VIEWS[seed % len(VIEWS)]
    k, c, th = _state(cls, kpin)
    w, h = size
    half = R / FILL                               # panel half-height, in R
    x = (np.arange(w) + 0.5 - w / 2) / h * 2 * half
    y = -(np.arange(h) + 0.5 - h / 2) / h * 2 * half
    psi = _field(c, th, k, cls, x, y)
    X, Y = np.meshgrid(x, y)
    inside = _inside(X, Y)
    p = np.where(inside, psi * psi, 0.0)
    del psi, X, Y
    # Unit mean over the table, then the stretch: the TOP percentile of the
    # table's own |psi|^2 is full scale. A percentile, not the maximum --
    # a handful of crests where the orbit crosses itself would otherwise set
    # the scale for the whole picture.
    p /= p[inside].mean()
    top = np.percentile(p[inside][:: max(1, inside.sum() // 2_000_000)], TOP)
    return np.clip(p / top, 0.0, 1.0)
