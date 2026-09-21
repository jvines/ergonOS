"""Black hole -- a thin accretion disk around a Schwarzschild hole, ray-traced.

Luminet (A&A 75, 228, 1979) made the first picture of this with a computer
and a pen: a geometrically thin, optically thick disk seen almost edge-on,
its far side thrown up over the hole by the bending of light, its underside
wrapped round the bottom of the shadow, and one side far brighter than the
other. This is that calculation.

LIGHT. In Schwarzschild a photon moves in a plane through the hole, and its
orbit r(phi) obeys the Binet equation (G = c = M = 1, u = 1/r)

    u'' = 3 u^2 - u,        u(0) = 0,  u'(0) = 1/b

traced backwards from the observer at infinity, b being the impact parameter
of the pixel. The orbit depends on b ALONE -- the pixel's angle round the
centre only turns the plane it moves in -- so one integration serves a whole
ring of pixels. The geodesics are integrated once (RK4 in phi) for ~6000
values of b, packed densely round the photon sphere's critical value
b_c = 3 sqrt(3) where the orbit winds, and every pixel reads its r(phi) off
that table. The photon crosses the disk's plane at phi_0 + n pi, phi_0 set by
the pixel's angle and the inclination. n = 0 is the direct image -- above
the hole that is the disk's FAR side, lifted up and over the shadow by the
bending; n = 1 is light that has gone half round the hole -- the underside
hugging the bottom of the shadow, and the thin ring over it; n >= 2 the
photon ring, exponentially thinner each turn. The disk is opaque except at
its tapered outer edge, where the gas thins out: crossings are composited
front to back, so an image behind the faded rim shows through it.

EMISSION. Page & Thorne's (1974) flux for a disk that loses its last torque
at the innermost stable circular orbit, r = 6: zero at the inner edge, a
peak near r = 9.5, r^-3 far out. Each ring of gas orbits at Kepler's
Omega = r^-3/2, and a photon of angular momentum L_z = -b sin(i) cos(angle)
arrives with

    1 + z = (1 + Omega b sin i cos angle) / sqrt(1 - 3/r)

-- Doppler shift and gravitational redshift together, exactly, because E and
L_z are conserved along the ray. The observed bolometric intensity is
F / (1+z)^4. That fourth power is why the approaching side (left) blazes and
the receding side is a dim rim: at r = 10, seen at 80 deg, the gas coming
straight at us is 17 times brighter than the gas going straight away.

TEXTURE. A disk of smooth Page-Thorne light rendered as a pastel slab: the
lensing was there but nothing on the disk showed it. Real disks are
turbulent, and differential rotation shears every clump into a tightly
wound trailing spiral, so the gas carries a lognormal pattern of such
spirals (mean 1: it moves light around, it adds none). Kept weak -- grain
inside the light, not stripes across it -- it is still what lets the eye
follow the far side up and over the shadow and the underside beneath it.

COLOUR. The intensity is the field, on a plain power-law stretch, so the
ratios survive: the beamed side is visibly brighter, the outer disk fades
into the ground. (A histogram stretch, tried first, ranked the dim receding
side up to the same lightness as the beamed one.) The ramp runs ground ->
mauve -> sky, lightness rising all the way, and that makes hue MEAN
something: a blackbody disk seen through a shift g = 1/(1+z) is again a
blackbody, at temperature gT, and its bolometric intensity is sigma
(gT)^4 / pi. Observed intensity and observed colour temperature are one
number, so brighter IS hotter IS bluer -- and the approaching side comes
out brighter and bluer, the receding side dimmer and redder, as it must.
"""

import os

import numpy as np

TITLE = "Black hole"
SUBTITLE = ("a thin disk round a Schwarzschild hole at 80 deg: light bent over the "
            "shadow, the approaching side (left) brighter and bluer   (Luminet 1979)")

# Linear with a gentle gamma: the ratios are the physics (see COLOUR).
SCALE = "linear"
GAMMA = 1.1
BLEND = 0.85
# Ground -> mauve -> sky. The full five-stop ramp is U-shaped in lightness
# (teal and pink light, blue and mauve dark), so it drew the dim receding
# side as bright as the beamed one and striped every ringlet in five hues.
RAMP = "duo"
REVERSE = True
SATURATION = 1.6
EXPOSURE = 1.15
SOFTEN = 0.8        # the photon ring is thinner than a pixel
HUE_SMOOTH = 3.0
# The occluding edges (near disk across the ring) and the higher-order rings
# are genuinely sharp: average several rays per pixel.
SUPERSAMPLE = 3

# (inclination deg, disk outer radius, frame width, centre offset x, y), all
# lengths in units of GM/c^2. The frame is a fixed window in those units, so
# 4K, 8K and a thumbnail are one picture. tex: texture amplitude (log).
# "luminet" keeps the whole disk in frame, the hole with room round it;
# "edge" lets the band run off both sides. cy keeps the n = 1 ring under the
# hole clear of the caption by 4% of the panel or more.
VIEWS = {
    "luminet": dict(incl=80.0, r_out=18.0, width=40.0, cx=0.0, cy=0.6,
                    tex=0.2, tex_seed=3),
    "edge": dict(incl=86.0, r_out=24.0, width=44.0, cx=0.0, cy=0.0,
                 tex=0.2, tex_seed=3),
}
# Offered on the desktop: the view chosen there. "edge" was shown and pruned
# (its view stays above).
ORDER = ["luminet"]

R_IN = 6.0          # innermost stable circular orbit
TAPER = 0.18        # outer edge fades over this fraction of r_out
N_IMAGES = 4        # direct image, n = 1, and two turns of the photon ring
DPHI = 0.0025       # RK4 step in phi
B_C = 3.0 * np.sqrt(3.0)

_TABLE = None       # (b grid, u table), inherited by forked workers


def caption(seed):
    v = VIEWS[ORDER[seed % len(ORDER)]]
    return TITLE, (f"a thin disk round a Schwarzschild hole at {v['incl']:.0f} deg: "
                   f"light bent over the shadow, the approaching side (left) "
                   f"brighter and bluer   (Luminet 1979)")


def _geodesics(b_max):
    """u(phi) for a grid of impact parameters, one row per b.

    Captured photons (r < 2) are frozen at u = 1 and escaped ones at u = 0,
    so a later crossing reads r = 1 or r = infinity -- never the disk -- and
    the table needs no masks.
    """
    uniform = np.arange(0.005, b_max + 0.02, 0.01)
    near = 10.0 ** np.linspace(-10.0, 0.6, 1600)
    b = np.unique(np.concatenate([uniform, B_C - near, B_C + near]))
    b = b[b > 0]
    nphi = int(np.ceil((N_IMAGES + 0.05) * np.pi / DPHI)) + 2
    table = np.empty((b.size, nphi), np.float32)
    u = np.zeros(b.size)
    v = 1.0 / b

    def acc(x):
        return 3.0 * x * x - x

    h = DPHI
    for k in range(nphi):
        table[:, k] = u
        k1u, k1v = v, acc(u)
        k2u, k2v = v + 0.5 * h * k1v, acc(u + 0.5 * h * k1u)
        k3u, k3v = v + 0.5 * h * k2v, acc(u + 0.5 * h * k2u)
        k4u, k4v = v + h * k3v, acc(u + h * k3u)
        u = u + h / 6.0 * (k1u + 2 * k2u + 2 * k3u + k4u)
        v = v + h / 6.0 * (k1v + 2 * k2v + 2 * k3v + k4v)
        cap = u >= 0.5
        esc = u <= 0.0
        u[cap], v[cap] = 1.0, 0.0
        u[esc], v[esc] = 0.0, 0.0
    return b, table


def _lookup(bpix, phi):
    """Bilinear read of u at (b, phi) for arrays of pixels."""
    bg, table = _TABLE
    j = np.clip(np.searchsorted(bg, bpix) - 1, 0, bg.size - 2)
    tb = np.clip((bpix - bg[j]) / (bg[j + 1] - bg[j]), 0.0, 1.0)
    x = phi / DPHI
    k = np.clip(x.astype(np.int64), 0, table.shape[1] - 2)
    tp = np.clip(x - k, 0.0, 1.0)
    u0 = table[j, k] * (1 - tp) + table[j, k + 1] * tp
    u1 = table[j + 1, k] * (1 - tp) + table[j + 1, k + 1] * tp
    return u0 * (1 - tb) + u1 * tb


def page_thorne(r):
    """Page-Thorne flux of a Schwarzschild disk (M = Mdot = 1, 8 pi dropped)."""
    r = np.maximum(r, R_IN)
    s, s3, s6 = np.sqrt(r), np.sqrt(3.0), np.sqrt(6.0)
    log = np.log((s + s3) * (s6 - s3) / ((s - s3) * (s6 + s3)))
    return 3.0 / ((r - 3.0) * r ** 2.5) * (s - s6 + 0.5 * s3 * log)


def _texture(r, az, v):
    """Brightness fluctuations of the gas, sheared by differential rotation.

    Any clump in a Keplerian disk is wound up by the shear, inner part ahead
    of outer, into a tightly wound trailing spiral; after a few orbits it is
    nearly a ring. So the texture is a sum of logarithmic spirals
    m az + K ln r with K >> m, random phases, pinned by the view's seed.
    Lognormal with mean 1, so it redistributes light without adding any.
    """
    rng = np.random.default_rng(v["tex_seed"])
    n = 48
    m = rng.integers(0, 4, n)
    k = rng.uniform(12.0, 70.0, n)
    ph = rng.uniform(0, 2 * np.pi, n)
    a = k ** -0.5
    a /= np.sqrt(0.5 * np.sum(a * a))
    s = np.zeros(r.shape)
    lr = np.log(r)
    for i in range(n):
        s += a[i] * np.cos(m[i] * az + k[i] * lr + ph[i])
    A = v["tex"]
    return np.exp(A * s - 0.5 * A * A)


def _band(job):
    r0, r1, w, h, v = job
    scale = v["width"] / w
    x = (np.arange(w) + 0.5 - w / 2) * scale + v["cx"]
    y = (h / 2 - np.arange(r0, r1) - 0.5) * scale + v["cy"]
    X, Y = np.meshgrid(x, y)
    b = np.hypot(X, Y)
    ca = X / np.maximum(b, 1e-12)
    sa = Y / np.maximum(b, 1e-12)
    inc = np.radians(v["incl"])
    # First crossing of the disk plane, in (0, pi): the photon's position is
    # r (cos phi o + sin phi s) with o toward the observer and s the pixel's
    # direction on the sky; its height above the disk vanishes there.
    phi0 = np.arctan2(np.cos(inc), -sa * np.sin(inc))
    r_out = v["r_out"] * (1 + TAPER)
    out = np.zeros(b.shape, np.float32)
    # Transmission along the ray, composited front to back. The outer taper
    # is the gas thinning out, so it is OPACITY as well as emission: where the
    # near side has faded to nothing it must also stop hiding the image behind
    # it. Treating every crossing inside r_out as opaque clipped the n = 1
    # ring along the faded rim's straight edge.
    T = np.ones(b.shape, np.float32)
    for n in range(N_IMAGES):
        u = _lookup(b, phi0 + n * np.pi)
        r = 1.0 / np.maximum(u, 1e-9)
        on = (T > 1e-3) & (r >= R_IN) & (r <= r_out)
        if on.any():
            rr, bb, cc = r[on], b[on], ca[on]
            one_z = (1 + rr ** -1.5 * bb * np.sin(inc) * cc) / np.sqrt(1 - 3 / rr)
            edge = np.clip((r_out - rr) / (2 * TAPER * v["r_out"]), 0, 1)
            edge = edge * edge * (3 - 2 * edge)
            # Where on the disk: the crossing point's azimuth in the disk
            # plane, from the same position vector that fixed phi0.
            ph = phi0[on] + n * np.pi
            az = np.arctan2(-np.cos(ph) * np.sin(inc) + np.sin(ph) * sa[on] * np.cos(inc),
                            np.sin(ph) * cc)
            tex = _texture(rr, az, v) if v.get("tex", 0) > 0 else 1.0
            out[on] += T[on] * edge * page_thorne(rr) * tex / one_z ** 4
            T[on] *= 1.0 - edge
    return r0, out


def generate(size, seed=0, bands=96, **kw):
    import multiprocessing as mp
    global _TABLE
    w, h = size
    v = dict(VIEWS[ORDER[seed % len(ORDER)]])
    v.update({k: kw[k] for k in ("incl", "r_out", "width", "cx", "cy", "tex") if k in kw})
    half_diag = 0.5 * v["width"] * np.hypot(1, h / w) + np.hypot(v["cx"], v["cy"])
    _TABLE = _geodesics(half_diag + 0.5)
    # A fixed number of row bands, whatever the machine: the result does not
    # depend on how many cores rendered it.
    edges = np.linspace(0, h, bands + 1).astype(int)
    jobs = [(a, c, w, h, v) for a, c in zip(edges[:-1], edges[1:]) if c > a]
    field = np.zeros((h, w), np.float32)
    with mp.get_context("fork").Pool(min(os.cpu_count(), 16)) as pool:
        for r0, a in pool.imap(_band, jobs):
            field[r0:r0 + a.shape[0]] = a
    return field
