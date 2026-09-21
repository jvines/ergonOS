"""Mandelbrot set -- the whole of it.

    z -> z^2 + c,   z0 = 0

c belongs to the set when the orbit of 0 stays bounded. Everything else
escapes, and how FAST it escapes is what these pictures are made of. This
module holds the escape-time machinery that the Julia sets and the deep zooms
share (julia.py and mandelbrotdeep.py import it); as a background of its own
it is the whole set, framed to fill the panel.

TWO NUMBERS PER PIXEL, both from the same orbit.

  * the smooth escape count  nu = n + 1 - log2(ln|z_n|). The integer count
    bands; this does not, because once |z| is large ln|z| doubles every step,
    so the fraction says where between two steps the orbit crossed out.
  * the exterior distance estimate  d = |z_n| ln|z_n| / |dz_n/dc|, the
    Hubbard-Douady potential over its gradient. By Koebe's quarter theorem the
    true distance to the set lies between half and twice it, which is what
    lets a filament far thinner than a pixel be drawn at all: the pixel does
    not have to land on the filament, only near it.

THE LOOK: the boundary as light, and nothing else. A pixel is lit by how
close it is to the set -- a line about two 4K pixels wide -- and its hue is
the escape count of the boundary around it, RANKED, so the fast-escaping
hair tips come out teal and sky and the slow places (the valleys between
bulbs, where orbits creep past a parabolic point for hundreds of steps) come
out mauve and pink. The interior, and everything not near the boundary,
stays on the ground colour.

Each alternative was rendered at 4K and looked at, 1:1:
  * colouring the whole exterior by escape count -- the classic picture --
    floods the panel with a smooth gradient whose only structure is the
    set's silhouette; the hairs, which are the point, disappear into it.
  * a glow around the lines. A wide one mixes the ramp's low end with the
    dark ground into a murky grey-green slab between the hairs, and its long
    fade exposes the 512-step colormap as visible terraces. A tight one
    still greys out wherever filaments are closer than a few pixels. Lines
    alone were the cleanest and the most vivid.
  * a Gaussian line, peaked at the boundary. The renderer takes a line's
    hue from its neighbourhood weighted by brightness (HUE_SMOOTH), so a
    thin peaked line never reaches its own colour: after anti-aliasing its
    peak is ~0.6, and every Julia set came out one mid-ramp blue whatever
    its hue said. A flat core of full brightness fixes that.
"""

import os

import numpy as np

TITLE = "Mandelbrot set"
SUBTITLE = "z -> z^2 + c from z = 0;  drawn by distance to the set, hue by escape time"

# The field is handed over already in 0..1 (see compose): a line profile
# times a hue, which no single stretch in the renderer can build. GAMMA 0.6
# then lifts the lines' shoulders, which is what lets a two-pixel line hold
# its hue through the renderer's hue smoothing; at 1.0 thin lines sank to
# the ramp's middle.
SCALE = "unit"
GAMMA = 0.6
# Anti-aliasing at the resolution being coloured (see lib.render): without
# these, one-pixel lines bead into moire and change colour at their edges.
SOFTEN = 0.8
HUE_SMOOTH = 3.0
BLEND = 0.85
# Saturation and exposure stay at the house 2.25 / 1.1: this is lines on an
# empty ground, the case those were chosen for.

# The line, in pixels of a 3840-wide panel -- a fixed fraction of the frame,
# so the drawing is the same at 4K, 8K or 2880: full brightness within CORE
# of the set, then a Gaussian shoulder of PEN.
CORE = 1.0
PEN = 0.6
# How far the hue averages the escape count along the boundary, same units.
REGION = 12.0
# Where on the ramp the fastest-escaping boundary starts. Below ~0.25 the
# hair tips fall into the ramp's first stop, which is the fade from ground
# to teal, and render dim rather than coloured.
HUE_FLOOR = 0.3

# Bailout |z| = 1000, not 2. Both nu and d are asymptotic in |z|; at 2 the
# smooth count still shows faint steps and d is off by tens of percent. The
# price is three or four extra steps per pixel.
R2 = 1e6

# (centre, frame width, rotation). The set spans -2.0 .. 0.47 on the real
# axis and +-1.12 on the imaginary. 3.3 keeps all of it bar the tips of the
# top and bottom antennae. A tighter 2.7 (centre -0.60) that gave up the
# needle to enlarge the valleys was good but pruned: the whole set is the
# picture people recognise.
VIEWS = [
    (complex(-0.72, 0.0), 3.30, 0.0),
]


def _escape(p, maxiter, julia):
    """nu and distance for a 1-D array of pixels p (complex)."""
    nu = np.zeros(p.size, np.float32)
    de = np.full(p.size, -1.0, np.float32)
    idx = np.arange(p.size)
    dz = np.ones(p.size, complex)
    if julia is None:
        # Mandelbrot: z1 = c, dz1/dc = 1, and the derivative gains +1 a step.
        c, z, k, n = p.copy(), p.copy(), 1.0, 1
        # Cardioid and period-2 disc, closed-form. They are most of the
        # interior of the whole set, and each would otherwise cost maxiter.
        x, y = p.real, p.imag
        q = (x - 0.25) ** 2 + y * y
        keep = ~((q * (q + x - 0.25) <= 0.25 * y * y) | ((x + 1) ** 2 + y * y <= 0.0625))
        c, z, dz, idx = c[keep], z[keep], dz[keep], idx[keep]
    else:
        # Julia: c fixed, z0 = the pixel, derivative with respect to z0.
        c, z, k, n = julia, p.copy(), 0.0, 0
    per_c = julia is None

    def step(z, dz, c):
        # IN PLACE, in complex128: five passes over memory per step and no
        # allocation. The first version wrote x, y, dx, dy as separate real
        # arrays with a fresh temporary per operation -- sixteen passes -- and
        # sixteen processes doing that were limited by memory bandwidth, not
        # arithmetic: measured 130 ns per pixel-iteration. dz first: it needs
        # the old z.
        dz *= z
        dz *= 2.0
        if k:
            dz += k
        z *= z
        z += c

    # Brent's cycle test: an orbit that comes back to within 1e-13 of a stored
    # point has converged onto an attracting cycle and is interior. The stored
    # point moves at doubling step counts, so every period is caught
    # eventually. Checked only at block ends; a deep minibrot's interior would
    # otherwise run the full maxiter, which dominates the cost of that view.
    ref, next_ref = z.copy(), 64
    K = 8
    while n < maxiter and z.size:
        kk = min(K, maxiter - n)
        z0, dz0 = z.copy(), dz.copy()
        # K steps with no test: the test and the compaction cost as much as a
        # step. Anything that escaped mid-block has overflowed to inf or nan
        # by now; it is replayed below from the saved state.
        for _ in range(kk):
            step(z, dz, c)
        esc = ~(z.real * z.real + z.imag * z.imag <= R2)
        keep = ~esc
        if esc.any():
            ez, edz = z0[esc], dz0[esc]
            ec = c[esc] if per_c else c
            hit = np.zeros(ez.size, bool)
            it = np.zeros(ez.size)
            fz, fdz = np.zeros(ez.size, complex), np.zeros(ez.size, complex)
            for j in range(kk):
                step(ez, edz, ec)
                new = ~hit & ~(ez.real * ez.real + ez.imag * ez.imag <= R2)
                it[new], fz[new], fdz[new] = n + j + 1, ez[new], edz[new]
                hit |= new
            r = np.abs(fz)
            lr = np.log(r)
            nu[idx[esc]] = it + 1.0 - np.log2(lr)
            de[idx[esc]] = r * lr / np.maximum(np.abs(fdz), 1e-300)
        n += kk
        d = z - ref
        keep &= ~(d.real * d.real + d.imag * d.imag < 1e-26)
        if not keep.all():
            z, dz, ref, idx = z[keep], dz[keep], ref[keep], idx[keep]
            if per_c:
                c = c[keep]
        if n >= next_ref:
            ref, next_ref = z.copy(), next_ref * 2
    return nu, de


def _band(job):
    """Escape nu and distance for rows r0..r1 of the frame. One process each.

    Every pixel is independent, so the frame splits into row bands with no
    communication, and the pool balances the slow bands (near the boundary)
    against the fast. Inside a band the pixels go through in chunks of 8192
    so each process's working set stays in cache.
    """
    r0, r1, w, h, cx0, cy0, width, rot, maxiter, julia = job
    u = ((np.arange(w) + 0.5) / w - 0.5) * width
    # Top row = +imaginary: the raster's rows grow downward.
    v = (0.5 - (np.arange(r0, r1) + 0.5) / h) * width * h / w
    off = (u[None, :] + 1j * v[:, None]) * np.exp(1j * rot)
    # Centre plus a SMALL offset: at a 1e-9 frame the offsets carry the
    # precision and the centre only places them.
    p = (complex(cx0, cy0) + off).ravel()
    nu = np.empty(p.size, np.float32)
    de = np.empty(p.size, np.float32)
    with np.errstate(all="ignore"):
        for s in range(0, p.size, 8192):
            nu[s:s + 8192], de[s:s + 8192] = _escape(p[s:s + 8192], maxiter, julia)
    return r0, nu.reshape(r1 - r0, w), de.reshape(r1 - r0, w)


def escape_field(size, centre, width, rot=0.0, maxiter=2000, julia=None,
                 band=8, procs=None):
    """nu and distance (in units of the complex plane; -1 = interior)."""
    import multiprocessing as mp
    w, h = size
    jobs = [(r, min(r + band, h), w, h, centre.real, centre.imag, width, rot,
             maxiter, julia) for r in range(0, h, band)]
    nu = np.zeros((h, w), np.float32)
    de = np.full((h, w), -1.0, np.float32)
    with mp.get_context("fork").Pool(procs or os.cpu_count()) as pool:
        for r0, a, b in pool.imap_unordered(_band, jobs):
            nu[r0:r0 + a.shape[0]] = a
            de[r0:r0 + b.shape[0]] = b
    return nu, de


def cstr(c, digits):
    """A complex number for a caption: '-1', 'i', '-0.123 + 0.745i'."""
    re, im = round(c.real, digits), round(c.imag, digits)

    def num(v):
        s = f"{v:.{digits}f}"
        return s.rstrip("0").rstrip(".") if "." in s else s

    if im == 0:
        return num(re)
    imag = ("" if abs(im) == 1 else num(abs(im))) + "i"
    if re == 0:
        return ("-" if im < 0 else "") + imag
    return f"{num(re)} {'-' if im < 0 else '+'} {imag}"


def compose(nu, de, width, pen=PEN, core=CORE, region=REGION, hue_floor=HUE_FLOOR):
    """The picture: boundary lines, hued by escape time. 0..1, 0 = ground."""
    import lib
    h, w = nu.shape
    # Distance in pixels of a 3840-wide panel. Full brightness out to `core`,
    # then a Gaussian shoulder of width `pen`.
    u = de * np.float32(3840.0 / width)
    body = np.where(de >= 0, np.exp(-0.5 * (np.maximum(u - core, 0) / pen) ** 2),
                    0).astype(np.float32)
    del u
    lit = body > 1e-3
    if not lit.any():
        return body

    # THE HUE IS REGIONAL: the brightness-weighted mean of log escape time
    # over ~`region` pixels, not the pixel's own count.
    #
    # Per pixel was tried first and is wrong for lines. Near the set nu runs
    # like -log2(distance), so it changes faster ACROSS a line than along
    # the boundary: the core and the shoulders of one line got different
    # hues, and after anti-aliasing every thin line of a Julia set came out
    # the same mid-ramp blue. Averaged over a neighbourhood the count stops
    # seeing the line's cross-section and keeps what varies along the
    # boundary -- how deep and how dense the set is there -- so a line is
    # one colour across and changes colour as it travels, like the Lorenz
    # curves. Computed on a grid ~1280 wide, where the blur is cheap.
    key = np.where(lit, np.log(np.maximum(nu, 1.0)), 0).astype(np.float32)
    f = max(1, w // 1280)
    s = region * (w / 3840.0) / f
    reg = (lib.smooth(lib.downsample(key * body, f), s) /
           np.maximum(lib.smooth(lib.downsample(body, f), s), 1e-12))
    del key
    reg = np.repeat(np.repeat(reg, f, 0), f, 1)
    reg = np.pad(reg, ((0, h - reg.shape[0]), (0, w - reg.shape[1])), mode="edge")

    # Ranked, not scaled: the counts span three decades and bunch at the low
    # end, so any value stretch paints nearly everything one colour. The
    # quantiles come from line CORES only, so the dim shoulders do not take
    # a share of the ramp that nobody can see.
    grid = np.linspace(0.0, 1.0, 1025)
    cores = reg[body > 0.5]
    q = np.quantile(cores[:: max(1, cores.size // 2_000_000)], grid)
    field = np.zeros_like(body)
    field[lit] = (hue_floor + (1.0 - hue_floor) * np.interp(reg[lit], q, grid)) * body[lit]
    return field


def generate(size, seed=0, maxiter=3000, **kw):
    centre, width, rot = VIEWS[seed % len(VIEWS)]
    # 3000 steps: at this scale fewer than one pixel in 30000 is still
    # running at 90% of it, and those are hairs a pixel from the set.
    nu, de = escape_field(size, centre, width, rot, maxiter=maxiter)
    return compose(nu, de, width)
