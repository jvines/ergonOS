"""Belousov-Zhabotinsky reaction -- spiral waves pacing a chemical dish.

    du/dt = (1/eps) [ u - u^2 - f v (u - q) / (u + q) ] + lap u
    dv/dt = u - v

Bromate oxidising an organic acid under a metal-ion catalyst -- malonic acid
and ferroin in the dishes that show waves. Belousov found in 1951 that it
oscillates, and could not publish it: a chemical reaction running back and
forth was taken to violate thermodynamics. Zhabotinsky confirmed it a decade
later, and Field, Koros and Noyes worked out the mechanism (1972) -- eighteen
steps, which Field and Noyes (1974) boiled down to the three-variable
Oregonator and Tyson and Fife (1980) to the two above:

  * u is HBrO2, the autocatalyst. A small excess of it makes more of itself,
    on a timescale eps shorter than anything else, until it runs out of room.
  * v is the oxidised catalyst, and the colour you see: the dish is red with
    reduced ferroin, the waves blue with oxidised ferriin.
  * f and q are stoichiometry and a ratio of rate constants.

A patch of the dish fires the way a relaxation oscillator does: once u passes
a threshold it runs away, oxidises the catalyst, and is refractory until the
catalyst has been reduced again. At the f used here -- between 1/2 and
1 + sqrt 2, for small q -- the steady state is unstable, so the mixture is an
oscillator: stirred in a beaker it would flash on its own, every 4.6 time units
at f = 1.7 and every 5.1 at f = 2.0 (the unit is the catalyst's reduction
time). Unstirred it never gets to. Diffusion of u sets the next patch off, so
each firing travels as a wave -- a chemical nerve impulse -- and the spirals
send one past every 1.84 units (2.33 at f = 2.0), well before a patch would
fire by itself. They pace the whole dish: in the run, 400 points scattered over
it fire at that period to within a time step, and at the end no point of the
dish is back down to the steady state. Two waves meeting do not pass through
each other as water waves do; each runs into the other's refractory wake and
both die. And a wave that is broken has a free end, which curls up around
itself into a spiral that turns forever about a fixed core. Winfree (1972)
photographed them in a dish; they are the same object as the re-entrant waves
of cardiac fibrillation. Every spiral here has the same period and the same
Archimedean pitch, because both are set by the chemistry and nothing else: the
dish is simply divided among them, along the lines where their waves collide.

The catalyst is immobile (Dv = 0), as it is in the gel-loaded dishes these
experiments are done in. u is stiff -- eps is small and the rate term has a
pole just below zero at -q -- so its reaction is stepped linearly implicit,
which cannot overshoot through that pole at any timestep below eps, with
diffusion explicit on the nine-point isotropic Laplacian: the five-point one
makes coarse spirals visibly square.

The start is a phase map: the argument of a smooth random complex field, laid
onto the cycle fire -> refractory -> recovered. Where the field vanishes every
phase meets at one point, and that point cannot settle down -- it becomes a
spiral core, turning one way or the other with the sign of the winding. Where
the cores fall is the random part, and it is pinned per view.

Drawn as the dish shows it: the catalyst v, fading along each wave's
refractory wake as it is reduced back, under the crisp band where u is firing.
The band's edges are the u = 0.35 contour, drawn from the distance to it --
(u - 0.35) / |grad u| -- as the domain walls are in ising.py, so the
wavefront is a clean edge at any resolution while the simulation stays coarse.
"""

import numpy as np

TITLE = "Belousov-Zhabotinsky reaction"
SUBTITLE = "spiral waves in an unstirred dish,  Oregonator  eps = 0.02, f = 1.7, q = 0.002"

# The field arrives toned, 0..1 (see _draw), and is taken as it is. "duo" --
# ground, sky, mauve: the firing band at the mauve end, its wake glowing sky
# as it fades. The full ramp gave every wave two rainbow stripes and read as op
# art; "warm" was lovely and is the Gray-Scott maze's colour already. About
# half the panel is lit, so saturation sits between the house line value and
# the screen-filling one.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
RAMP = "duo"
SATURATION = 1.8
EXPOSURE = 1.0
# The field is a coarse simulation, smoothly upscaled, with analytic edges:
# band-limited already, and supersampling would only simulate the same grid.
SUPERSAMPLE = 1

# Simulation cells along the panel height. The grid is fixed in CELLS, not in
# pixels, so every render size simulates the same dish and draws the same
# picture; only the upscale factor changes.
GRID_H = 840
# Space step (in the model's own length units) and the time step: dt is under
# the explicit-diffusion limit 0.375 dx^2 of the nine-point stencil.
DX = 0.14
DT = 0.007

# Drawing. The front is the u = FRONT contour; EDGE is its anti-aliasing ramp
# as a fraction of the panel height (3 px at 2400); TAIL is the level of the
# wake just behind the firing band, fading with v as the catalyst is reduced.
# TAIL_POWER is how fast it fades: at 1 the wake of one wave reached the next,
# the whole dish was lit and the fronts were pink on a solid slab; at 2.5 the
# ground comes through for the second half of every gap.
FRONT = 0.35
EDGE = 3.0 / 2400
TAIL = 0.7
TAIL_POWER = 2.5

# (eps, f, q, core spacing in panel heights, run time in model units, the
# random seed that placed the cores -- part of the picture, so pinned).
# "spiral": one large spiral nearly centred, with five turns showing, among
# its neighbours. "pair": less excitable (larger f), so a larger core and a
# looser, thinner-banded spiral, with a counter-rotating pair in the middle --
# the figure a broken wave makes, one free end curling each way. Chosen from
# six core layouts; (0.02, 1.4) and (0.05, 1.0) were drawn and pruned, their
# firing bands too heavy for the wavelength.
# Only "spiral" was chosen on a real desktop; "pair" (0.03, 2.0, 0.002, 0.60,
# 120.0, core seed 11) was shown and pruned, and so was "spiral" on the warm
# ramp, which is Gray-Scott's colour.
PRESETS = {
    "spiral": (0.02, 1.7, 0.002, 0.60, 120.0, 5),
}


def _preset(seed):
    names = list(PRESETS)
    return names[seed % len(names)], PRESETS[names[seed % len(names)]]


def caption(seed):
    _, (eps, f, q, *_rest) = _preset(seed)
    return TITLE, (f"spiral waves in an unstirred dish,  Oregonator  "
                   f"eps = {eps:g}, f = {f:g}, q = {q:g}")


def _lap9(a):
    """The isotropic nine-point Laplacian, periodic."""
    n, s = np.roll(a, 1, 0), np.roll(a, -1, 0)
    return (4.0 * (n + s + np.roll(a, 1, 1) + np.roll(a, -1, 1))
            + np.roll(n, 1, 1) + np.roll(n, -1, 1)
            + np.roll(s, 1, 1) + np.roll(s, -1, 1) - 20.0 * a) / 6.0


def _rest(f, q):
    """The steady state u = v, where the nullclines cross (the positive root).
    Unstable at these f -- the paced dish never returns to it -- but a fair
    floor to lay the starting cycle on."""
    b = 1.0 - q - f
    return 0.5 * (b + np.sqrt(b * b + 4.0 * q * (1.0 + f)))


def _phase(gh, gw, spacing, rng):
    """Phase in [0, 1) of a smooth random complex field, periodic.

    Its spectrum is a ring at one wavenumber, so the zeros -- the future cores
    -- have a typical spacing and no clumps of tiny vortex pairs. The density
    of zeros of such a field is k^2 / 4 pi per unit area for wavenumber k, so
    k is set from the spacing wanted."""
    k0 = 1.0 / (spacing * np.sqrt(np.pi))    # cycles per cell
    kk = np.hypot(np.fft.fftfreq(gh)[:, None], np.fft.fftfreq(gw)[None, :])
    amp = np.exp(-0.5 * ((kk - k0) / (0.3 * k0)) ** 2)
    noise = rng.standard_normal((2, gh, gw))
    z = np.fft.ifft2(amp * (noise[0] + 1j * noise[1]))
    return (np.angle(z) / (2.0 * np.pi)) % 1.0


def _simulate(gh, gw, eps, f, q, spacing, t_end, rng_seed):
    rng = np.random.default_rng(rng_seed)
    th = _phase(gh, gw, spacing * gh, rng)

    # The phase laid onto one cycle: the first 6% firing, v climbing through
    # it, the rest a wake in which v relaxes back down. Rough, and it does
    # not need to be better -- a few rotations forget it entirely, and what
    # survives is only the topology: where the cores are and which way each
    # one turns.
    us = _rest(f, q)
    fire = 0.06
    u = np.where(th < fire, 0.8, us)
    v = np.where(th < fire, us + 0.15 * th / fire,
                 us + 0.15 * np.exp(-(th - fire) / 0.25))

    k = DT / eps
    decay = np.exp(-DT)
    for _ in range(int(round(t_end / DT))):
        # Linearly implicit Euler for the reaction: the rate and its slope at
        # the old u, solved as if linear. The slope is at most 1, so with
        # k < 1 the denominator stays positive; where the slope is large and
        # negative -- the stiff recovery, u pinned near q -- it damps instead
        # of overshooting through the pole.
        r = u - u * u - f * v * (u - q) / (u + q)
        dr = 1.0 - 2.0 * u - 2.0 * f * v * q / (u + q) ** 2
        u = u + (DT * _lap9(u) / DX ** 2 + k * r) / (1.0 - k * dr)
        np.maximum(u, 0.0, out=u)
        # v is linear given u: stepped exactly.
        v = u + (v - u) * decay
    return u, v


def _upscale(a, h, w):
    """Bilinear and periodic, from the simulation grid to (h, w)."""
    gh, gw = a.shape
    y = (np.arange(h) + 0.5) * gh / h - 0.5
    x = (np.arange(w) + 0.5) * gw / w - 0.5
    y0, x0 = np.floor(y).astype(int), np.floor(x).astype(int)
    fy, fx = (y - y0)[:, None], (x - x0)[None, :]
    y0, y1 = y0 % gh, (y0 + 1) % gh
    x0, x1 = x0 % gw, (x0 + 1) % gw
    top = a[y0][:, x0] * (1 - fx) + a[y0][:, x1] * fx
    bot = a[y1][:, x0] * (1 - fx) + a[y1][:, x1] * fx
    return top * (1 - fy) + bot * fy


def _draw(u, v, w, h, front=None, edge=None, tail=None, tail_power=None):
    front = FRONT if front is None else front
    edge = EDGE if edge is None else edge
    tail = TAIL if tail is None else tail
    tail_power = TAIL_POWER if tail_power is None else tail_power
    gh = u.shape[0]
    cell = h / gh                                  # pixels per cell

    # Distance to the front, in cells, on the simulation grid, then upscaled.
    # Taken on the coarse grid and not from the upscaled u because a bilinear
    # surface has a gradient that jumps at every cell edge, and dividing by it
    # would print the grid into the ramp. It is clipped to a few cells first:
    # far from a front the ratio means nothing, and inside the band, where u
    # is flat, it is enormous.
    gy = 0.5 * (np.roll(u, -1, 0) - np.roll(u, 1, 0))
    gx = 0.5 * (np.roll(u, -1, 1) - np.roll(u, 1, 1))
    d = np.clip((u - front) / (np.hypot(gx, gy) + 1e-6), -4.0, 4.0)
    band = np.clip(0.5 + _upscale(d, h, w) * cell / (edge * h), 0.0, 1.0)

    # The wake: v above its resting level, as a fraction of its crest.
    vs = np.percentile(v, 5)
    vt = np.percentile(v, 99.5)
    wake = np.clip((_upscale(v, h, w) - vs) / (vt - vs), 0.0, 1.0)
    return np.maximum(band, tail * wake ** tail_power)


def generate(size, seed=0, **kw):
    w, h = size
    _, (eps, f, q, spacing, t_end, rng_seed) = _preset(seed)
    gh = GRID_H
    gw = 2 * int(round(gh * w / h / 2))
    u, v = _simulate(gh, gw, eps, f, q, spacing, t_end, rng_seed)
    return _draw(u, v, w, h, **kw)
