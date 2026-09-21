"""Gravitational lensing -- a star field's caustics, an Einstein ring, a cluster's arcs.

Light passing a mass is deflected, and the lens equation maps each point x
of the sky we see (the image plane) to the point beta it came from (the
source plane):  beta = x - alpha(x).  Where the Jacobian det(d beta/d x)
vanishes the map folds, a source there is infinitely magnified, and the
images of those critical curves in the source plane are the CAUSTICS: fold
lines meeting in cusps. The views show the two halves of the equation.

"stars" -- the SOURCE plane. The magnification map of a quasar microlensed
by the stars of a foreground galaxy, as Wambsganss first computed it (1990):
Salpeter stars over smooth matter and external shear, in Witt's (1990) form

    zeta = (1 - kappa_s) z + gamma z* - sum_i m_i / (z - z_i)*.

Inverse ray shooting: a lattice of rays in the image plane, each carried to
the source plane and deposited (bilinearly) with its image-plane area, so
the density of arrivals IS the magnification. Smooth, not grainy, because
  * the lattice is fine enough that rays land under half a pixel apart, and
    a cell the local Jacobian stretches wider is split, up to 8 x 8;
  * cells stretched further still -- the faint demagnified images right by
    each star, whose few rays would otherwise sprinkle dots over the map --
    are deposited on a coarser grid matched to their footprint and
    interpolated back up: their light is kept, as smooth as it really is;
  * the map is convolved with the quasar's accretion disk, a Gaussian a
    fixed fraction of the panel across -- the physical reason no light
    curve ever reaches a caustic's infinite peak.
Each star's pull is summed exactly for the few stars near a tile of rays
and as a Taylor series in z for the rest (the deflection is analytic away
from the masses), so a thousand stars cost little more than a handful.
Folds are bright on their inner side and fall off as 1/sqrt(distance);
cusps are the points of the filigree. Shown: log magnification over the
median, ranked.

"ring", "cluster" -- the IMAGE plane. Background spiral galaxies seen through
isothermal lenses, drawn by surface-brightness conservation, I(x) =
S(beta(x)): one lens-equation evaluation per pixel, so the image is exactly
as smooth as the sources. The spirals are exponential disks with
logarithmic arms and star-forming knots, because structure in the source is
what lets the eye see it repeated and sheared. In "ring" one compact spiral
sits a little off the axis of an elliptical galaxy: its faint outskirts
close a thin Einstein ring, its bright body is drawn out into a giant arc,
and on the far side of the lens it appears once more, small and mirror-
reversed (a saddle image, inside the critical curve). The source is small
on purpose -- a lensed image is as thick as its source is wide, and a big
disk smeared into a fat, soft tube in which nothing could be recognised; in
"cluster" a dozen lie behind a galaxy cluster -- a cored, elliptical halo
and its member galaxies -- and those near its caustics are drawn out into
giant arcs, those further off only sheared tangentially. The lenses' own
light is drawn too, unlensed.
"""

import os

import numpy as np

TITLE = "Gravitational lensing"
SUBTITLE = "where light from behind a mass is focused"

# Each view does its own stretch in generate (they need different ones: a
# screen-filling map is ranked, galaxies on empty sky are clipped), so the
# renderer takes the field as is.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
# Mauve into pink. The full ramp put a teal-grey wash over the map's
# low-magnification plains and flooded the rings teal; two hues read as
# light. House saturation and exposure: both held up on the map.
RAMP = "warm"
SATURATION = 2.25
EXPOSURE = 1.1
# No SOFTEN and no HUE_SMOOTH: every field here is smooth by construction
# (a source-sized kernel on the map, analytic galaxies on the sky), and hue
# smoothing drew a dark rim along the outside of every fold.
SOFTEN = 0.0
HUE_SMOOTH = 0.0
SUPERSAMPLE = 1

VIEWS = {
    # kappa_*, kappa_s: surface density in stars and in smooth matter;
    # gamma: external shear; width: source-plane frame in Einstein radii of
    # the mean star; mass: Salpeter range, relative; star_seed pins the
    # field; source: the quasar disk's Gaussian sigma, panel heights;
    # floor: magnification (over the median) that lands on the ground.
    "stars": dict(kind="map", kstar=0.36, ksmooth=0.09, gamma=0.20,
                  width=22.0, mass=(0.1, 1.5), star_seed=7, source=0.9 / 2400,
                  floor=0.8, gamma_disp=2.0,
                  about="magnification map of a quasar behind a field of stars",
                  params="kappa = 0.45, 80% in stars, shear 0.20"),
    # Image-plane views, lengths in Einstein radii of the main lens.
    # height: frame height; shear: external (gamma, angle); lenses: (x, y,
    # Einstein radius, ellipticity, angle, core, light peak, light r_e);
    # sources: spirals (x, y, disk scale, cos incl, angle, arm pitch deg,
    # knots, knot seed, brightness); arm: (sharpness, inter-arm level
    # [, knot size, knot brightness]);
    # members / behind: (count, seed) of cluster galaxies and of sources
    # drawn by a pinned generator; floor, clip, gamma_disp: the stretch.
    # The ring's frame (height 3.0) keeps the arc's lower tip ~8% of the
    # panel clear of the caption.
    "ring": dict(kind="sky", height=3.0, shear=(0.03, 1.2),
                 lenses=((0.0, 0.0, 1.0, 0.06, 0.35, 0.002, 0.8, 0.3),),
                 sources=((0.06, 0.02, 0.03, 0.9, 0.6, 18.0, 8, 4, 1.0),),
                 arm=(10, 0.08, 1.0, 1.5), floor=0.01, gamma_disp=0.6, clip=96.0,
                 about=("a spiral galaxy behind an elliptical: an Einstein ring, "
                        "a giant arc and a mirrored copy of the spiral"),
                 params="isothermal lens with shear"),
    # Seeds scanned for the cluster: (members, behind) = (3,6) (4,13) (3,11)
    # (3,12) had sources caught between the radial and tangential
    # caustics, tangled round the central galaxy; (6,18) is the cleanest.
    "cluster": dict(kind="sky", height=3.4, shear=(0.05, 0.3),
                    lenses=((0.0, 0.0, 0.95, 0.15, 0.45, 0.04, 0.9, 0.35),),
                    sources=(), members=(7, 6), behind=(12, 18),
                    arm=(5, 0.12), floor=0.01, gamma_disp=0.6, clip=97.0,
                    about="galaxies behind a galaxy cluster, drawn out into giant arcs",
                    params="cored isothermal cluster, 7 member galaxies"),
}
# Offered on the desktop: the views chosen there. "stars", the microlensing
# magnification map, was shown and pruned (its view and code stay above).
ORDER = ["ring", "cluster"]

E0 = 0.45           # target ray spacing in the source plane, pixels
EMAX = 0.6          # a cell mapped wider than this is split...
KMAX = 8            # ...into up to KMAX x KMAX rays; wider still, coarse grid
LMAX = 6            # coarsest grid 2^LMAX pixels at 2400 high; cells wider are dropped
TILE = 1.2          # ray tile, Einstein radii
NEAR = 0.25         # tile radius / distance of the nearest far star
TERMS = 16          # Taylor terms for the far stars
CHUNKS = 16         # fixed work split: the map does not depend on core count


def caption(seed):
    v = VIEWS[ORDER[seed % len(ORDER)]]
    return TITLE, f"{v['about']};  {v['params']}"


# -- the star field ---------------------------------------------------------

def _geometry(size, v):
    w, h = size
    k, g = v["kstar"] + v["ksmooth"], v["gamma"]
    lx, ly = 1 - k + g, 1 - k - g
    ws = v["width"]
    hs = ws * h / w
    margin = 3.0
    # The coarsest grid is a fixed fraction of the panel, not of pixels.
    lmax = LMAX + max(0, int(round(np.log2(h / 2400))))
    return dict(w=w, h=h, a=1 - v["ksmooth"], g=g, lx=lx, ly=ly, ws=ws, hs=hs, lmax=lmax,
                p=ws / w, xi=(ws / 2 + margin) / abs(lx),
                yi=(hs / 2 + margin) / abs(ly))


def _stars(v, geo):
    """Positions and masses, uniform in a disk well beyond the ray field.

    Inside a uniform disk the mean pull of the stars is exactly kappa_* z,
    so the macro-lens is the same everywhere the rays go. The count and the
    draws depend only on the view, never on the resolution.
    """
    R = np.hypot(geo["xi"], geo["yi"]) + 8.0
    n = int(round(v["kstar"] * R * R))
    rng = np.random.default_rng(v["star_seed"])
    lo, hi = v["mass"]
    q = -1.35                                   # Salpeter: dN/dm ~ m^-2.35
    m = (lo ** q + rng.random(n) * (hi ** q - lo ** q)) ** (1 / q)
    m /= m.mean()
    r = R * np.sqrt(rng.random(n))
    t = 2 * np.pi * rng.random(n)
    return r * np.exp(1j * t), m


_STARS = None


def _field(z, near_z, near_m, coef, c):
    """F = sum m / (z - z_i) and dF/dz: near stars exactly, far by Taylor."""
    d = z - c
    F = np.full(z.shape, coef[-1], complex)
    dF = np.full(z.shape, (len(coef) - 1) * coef[-1], complex)
    for n in range(len(coef) - 2, -1, -1):
        F = F * d + coef[n]
        if n >= 1:
            dF = dF * d + n * coef[n]
    for zi, mi in zip(near_z, near_m):
        q = 1.0 / (z - zi)
        F += mi * q
        dF -= mi * q * q
    return F, dF


def _chunk(job):
    """Shoot the rays of a set of tile rows; return their deposit per grid level."""
    rows, geo = job
    zs, ms = _STARS
    w, h, p, a, g = geo["w"], geo["h"], geo["p"], geo["a"], geo["g"]
    ntx, nty, tx, ty, nx, ny = geo["tiles"]
    hx, hy = tx / nx, ty / ny
    dims = [(-(-h // 2 ** l), -(-w // 2 ** l)) for l in range(geo["lmax"] + 1)]
    acc = [np.zeros(hh * ww) for hh, ww in dims]
    buf = [([], []) for _ in dims]

    def put(zeta, wt, l=0):
        hh, ww = dims[l]
        s = p * 2 ** l
        fx = (zeta.real + geo["ws"] / 2) / s - 0.5
        fy = (geo["hs"] / 2 - zeta.imag) / s - 0.5
        ix, iy = np.floor(fx).astype(np.int64), np.floor(fy).astype(np.int64)
        ux, uy = fx - ix, fy - iy
        for dx, dy, f in ((0, 0, (1 - ux) * (1 - uy)), (1, 0, ux * (1 - uy)),
                          (0, 1, (1 - ux) * uy), (1, 1, ux * uy)):
            cx, cy = ix + dx, iy + dy
            ok = (cx >= 0) & (cx < ww) & (cy >= 0) & (cy < hh)
            buf[l][0].append(cy[ok] * ww + cx[ok])
            buf[l][1].append((f * wt)[ok])

    def flush():
        for l, (ii, ww_) in enumerate(buf):
            if ii:
                acc[l] += np.bincount(np.concatenate(ii), np.concatenate(ww_), acc[l].size)
                ii.clear(), ww_.clear()

    ox = (np.arange(nx) + 0.5) * hx
    oy = (np.arange(ny) + 0.5) * hy
    rho = 0.5 * np.hypot(tx, ty)
    for j in rows:
        for i in range(ntx):
            x0, y0 = -geo["xi"] + i * tx, -geo["yi"] + j * ty
            c = complex(x0 + tx / 2, y0 + ty / 2)
            near = np.abs(zs - c) < rho / NEAR
            # Taylor coefficients about c of the far stars' sum m / (z - z_i):
            # a_n = -sum m / (z_i - c)^(n+1).
            inv = 1.0 / (zs[~near] - c)
            coef, pw = [], ms[~near] * inv
            for _ in range(TERMS):
                coef.append(-pw.sum())
                pw = pw * inv
            nz, nm = zs[near], ms[near]
            z = ((x0 + ox)[None, :] + 1j * (y0 + oy)[:, None]).ravel()
            F, dF = _field(z, nz, nm, coef, c)
            zeta = a * z + g * np.conj(z) - np.conj(F)
            # Local Jacobian: d zeta/dz = a, d zeta/dz* = s. A cell's two
            # edges map to lengths hx |A e_x| and hy |A e_y|, in pixels.
            s = g - np.conj(dF)
            Lx = hx * np.hypot(a + s.real, s.imag) / p
            Ly = hy * np.hypot(s.imag, a - s.real) / p
            kx, ky = np.ceil(Lx / EMAX), np.ceil(Ly / EMAX)
            one = (kx <= 1) & (ky <= 1)
            put(zeta[one], hx * hy)
            split = ~one & (kx <= KMAX) & (ky <= KMAX)
            for kk in np.unique((kx[split] * 16 + ky[split]).astype(int)):
                sel = split & (kx * 16 + ky == kk)
                kxx, kyy = kk // 16, kk % 16
                sx = ((np.arange(kxx) + 0.5) / kxx - 0.5) * hx
                sy = ((np.arange(kyy) + 0.5) / kyy - 0.5) * hy
                zz = (z[sel][:, None] + (sx[None, :] + 1j * sy[:, None]).ravel()).ravel()
                F2, _ = _field(zz, nz, nm, coef, c)
                put(a * zz + g * np.conj(zz) - np.conj(F2), hx * hy / (kxx * kyy))
            wide = ~one & ~split
            lev = np.ceil(np.log2(np.maximum(Lx, Ly)[wide] / EMAX)).astype(int)
            zw = zeta[wide]
            for l in range(1, geo["lmax"] + 1):
                put(zw[lev == l], hx * hy, l)
            if sum(x.size for x in buf[0][0]) > 6_000_000:
                flush()
    flush()
    return [x.astype(np.float32) for x in acc]


def _upsample(a, f, h, w):
    """Bilinear from a grid of f-pixel cells to the full one (centres aligned)."""
    yy = np.clip((np.arange(h) + 0.5) / f - 0.5, 0, a.shape[0] - 1)
    xx = np.clip((np.arange(w) + 0.5) / f - 0.5, 0, a.shape[1] - 1)
    rows = np.array([np.interp(xx, np.arange(a.shape[1]), r) for r in a])
    return np.array([np.interp(yy, np.arange(a.shape[0]), c) for c in rows.T]).T


def magnification(size, v):
    """The source-plane magnification map, before the quasar is applied."""
    import multiprocessing as mp
    global _STARS
    geo = _geometry(size, v)
    _STARS = _stars(v, geo)
    ntx = int(np.ceil(2 * geo["xi"] / TILE))
    nty = int(np.ceil(2 * geo["yi"] / TILE))
    tx, ty = 2 * geo["xi"] / ntx, 2 * geo["yi"] / nty
    # Isotropic, and set by the LOCAL map, not the macro one. Point masses
    # add no convergence, so wherever the rays go the Jacobian's eigenvalues
    # are (1 - kappa_s) +- |shear|: never below 1 - kappa_s in the stretched
    # direction, and twice that on the critical curves. The macro-lens's
    # strong mean compression is an average over the granularity and holds
    # nowhere in particular; a lattice planned on it was five times too
    # coarse exactly where the caustics are made.
    nx = int(np.ceil(tx * geo["a"] / (E0 * geo["p"])))
    ny = int(np.ceil(ty * geo["a"] / (E0 * geo["p"])))
    geo["tiles"] = (ntx, nty, tx, ty, nx, ny)
    jobs = [(list(range(k, nty, CHUNKS)), geo) for k in range(CHUNKS)]
    acc = None
    with mp.get_context("fork").Pool(min(os.cpu_count(), CHUNKS)) as pool:
        for part in pool.imap(_chunk, jobs):
            acc = part if acc is None else [x + y for x, y in zip(acc, part)]
    w, h, p = geo["w"], geo["h"], geo["p"]
    mu = acc[0].reshape(h, w).astype(np.float64)
    for l in range(1, geo["lmax"] + 1):
        f = 2 ** l
        coarse = acc[l].reshape(-(-h // f), -(-w // f)) / f ** 2
        mu += _upsample(coarse, f, h, w)
    return mu / p ** 2


def _caustic_map(size, v):
    import lib
    w, h = size
    mu = lib.smooth(magnification(size, v).astype(np.float32), v["source"] * h)
    lm = np.maximum(np.log(mu / (v["floor"] * np.median(mu))), 0)
    return lib.normalise(lm, gamma=v["gamma_disp"], scale="equalize")


# -- the sky seen through the lens ------------------------------------------

def _spiral(bx, by, src, arm):
    """A two-armed disk galaxy seen at an angle, with star-forming knots.

    Exponential disk and bulge; logarithmic-spiral arms of the given pitch;
    HII knots strung along the arm ridges by a pinned seed. Written in the
    galaxy's own plane and projected by q = cos(inclination).
    """
    x0, y0, rd, q, th, pitch, knots, kseed, amp = src
    u, t = bx - x0, by - y0
    ct, st = np.cos(th), np.sin(th)
    ue, te = ct * u + st * t, (-st * u + ct * t) / q
    r = np.hypot(ue, te)
    wind = 1.0 / np.tan(np.radians(pitch))
    psi = 2 * (np.arctan2(te, ue) - wind * np.log(r / rd + 0.15))
    img = np.exp(-r / rd) * (arm[1] + (0.5 + 0.5 * np.cos(psi)) ** arm[0])
    img += 1.2 * np.exp(-(r / (0.18 * rd)) ** 1.5)
    # Knot size and brightness scale, optional in `arm`: the draws below are
    # the same either way, so a view that leaves them out is unchanged.
    ksz, kamp = (tuple(arm) + (1.0, 1.0))[2:4]
    rng = np.random.default_rng(kseed)
    for _ in range(knots):
        rk = rd * rng.uniform(0.5, 2.4)
        pk = wind * np.log(rk / rd + 0.15) + np.pi * rng.integers(0, 2) + rng.normal(0, 0.12)
        sk = ksz * rd * rng.uniform(0.06, 0.11)
        ak = kamp * rng.uniform(0.8, 1.6) * np.exp(-rk / (2 * rd))
        img += ak * np.exp(-0.5 * ((ue - rk * np.cos(pk)) ** 2 +
                                   (te - rk * np.sin(pk)) ** 2) / sk ** 2)
    return amp * img


def _population(v):
    """Lenses and sources of a view: its own lists, plus any drawn by seed.

    A cluster's member galaxies and the galaxies behind it are drawn from a
    pinned generator, so the picture is fixed by the view's numbers alone.
    """
    lenses, sources = list(v["lenses"]), list(v["sources"])
    if "members" in v:
        n, seed = v["members"]
        rng = np.random.default_rng(seed)
        for _ in range(n):
            r, a = rng.uniform(0.35, 1.5), rng.uniform(0, 2 * np.pi)
            b = rng.uniform(0.05, 0.12)
            lenses.append((r * np.cos(a), r * np.sin(a) * 0.8, b, rng.uniform(0, 0.1),
                           rng.uniform(0, np.pi), 0.004, 0.5, 1.6 * b))
    if "behind" in v:
        n, seed = v["behind"]
        rng = np.random.default_rng(seed)
        for k in range(n):
            r, a = 1.7 * rng.uniform(0.02, 1.0) ** 0.8, rng.uniform(0, 2 * np.pi)
            sources.append((r * np.cos(a), r * np.sin(a), rng.uniform(0.03, 0.06),
                            rng.uniform(0.5, 0.95), rng.uniform(0, np.pi),
                            rng.uniform(15, 30), 10, 100 + k + 1000 * seed,
                            rng.uniform(0.6, 1.0)))
    return lenses, sources


def _sky_band(job):
    r0, r1, w, h, v = job
    s = v["height"] / h
    X, Y = np.meshgrid((np.arange(w) + 0.5 - w / 2) * s,
                       (h / 2 - np.arange(r0, r1) - 0.5) * s)
    lenses, sources = _population(v)
    g, gt = v["shear"]
    g1, g2 = g * np.cos(2 * gt), g * np.sin(2 * gt)
    bx = X - (g1 * X + g2 * Y)
    by = Y - (g2 * X - g1 * Y)
    light = np.zeros_like(X)
    for x0, y0, b, e, pa, core, la, lr in lenses:
        # Isothermal elliptical potential b sqrt(core^2 + (1-e)x'^2 + (1+e)y'^2)
        # -- Einstein radius ~b -- and the galaxy's own light, unlensed:
        # de Vaucouleurs with the central cusp softened, flattened alike.
        cp, sp = np.cos(pa), np.sin(pa)
        xr, yr = cp * (X - x0) + sp * (Y - y0), -sp * (X - x0) + cp * (Y - y0)
        den = np.sqrt(core ** 2 + (1 - e) * xr * xr + (1 + e) * yr * yr)
        axr, ayr = b * (1 - e) * xr / den, b * (1 + e) * yr / den
        bx -= cp * axr - sp * ayr
        by -= sp * axr + cp * ayr
        rs = np.sqrt((1 - 2 * e) * xr * xr + (1 + 2 * e) * yr * yr + 1.6e-5) / lr
        light += la * np.exp(-7.67 * (rs ** 0.25 - (0.004 / lr) ** 0.25))
    img = light
    for src in sources:
        img += _spiral(bx, by, src, v["arm"])
    return r0, img.astype(np.float32)


def _sky(size, v, bands=64):
    import multiprocessing as mp
    import lib
    w, h = size
    edges = np.linspace(0, h, bands + 1).astype(int)
    img = np.zeros((h, w), np.float32)
    with mp.get_context("fork").Pool(min(os.cpu_count(), 16)) as pool:
        for r0, a in pool.imap(_sky_band, [(a, b, w, h, v) for a, b in
                                            zip(edges[:-1], edges[1:])]):
            img[r0:r0 + a.shape[0]] = a
    # Sky level off, meeting the ground with ZERO SLOPE: (x - f)^2 / x is
    # exactly 0 below f and ~ x - 2f well above it. A plain max(x - f, 0)
    # drew the lens galaxy as a flat disc with an edge.
    f = v["floor"]
    img = np.where(img > f, (img - f) ** 2 / np.maximum(img, f), 0.0)
    return lib.normalise(img, gamma=v["gamma_disp"], scale="linear", clip=v["clip"])


def generate(size, seed=0, **kw):
    v = dict(VIEWS[ORDER[seed % len(ORDER)]])
    v.update({k: kw[k] for k in kw if k in v})
    if v["kind"] == "map":
        return _caustic_map(size, v)
    return _sky(size, v)
