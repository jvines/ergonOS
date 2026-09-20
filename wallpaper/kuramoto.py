"""Kuramoto-Sivashinsky -- one-dimensional spatiotemporal chaos, drawn as
space against time.

    u_t + u_xx + u_xxxx + u u_x = 0,    x in [0, L), periodic

Kuramoto's equation for phase turbulence in reaction-diffusion (1976) and
Sivashinsky's for the wrinkling of a laminar flame front (1977), which turned
out to be the same equation. The u_xx term has the wrong sign, so long
wavelengths are pumped rather than damped; u_xxxx kills the short ones; u u_x
moves energy between the two and stops the balance from ever settling. It is
the cheapest system that is genuinely turbulent, and the standard proving
ground for spectral methods.

Everything else here is a picture of a state space. This is the only one in
which an axis is TIME: x runs across the panel, t runs down it, so a row is the
front at one instant and a column is the history of one point on it. That is
what it contributes -- cells that are born, drift, and merge into their
neighbours, giving a field of soft diagonal streaks with a direction and a
grain. The attractors have no direction and the reaction-diffusion field has no
history.

Pseudo-spectral in x, ETDRK4 in time (Kassam & Trefethen, SIAM J. Sci. Comput.
26, 1214, 2005 -- this is their kursiv.m in numpy). The fourth derivative makes
the linear part violently stiff: mode k decays as exp(-k^4 t), so at the grid
scale an explicit stepper would need a timestep some five orders of magnitude
below anything the picture needs. ETDRK4 integrates that part exactly by
exponentiating it, leaving the step size to be set by the advection, which is
slow. The whole run is a few thousand transforms of a few hundred points.
"""

import numpy as np

# A field, not a trajectory: every pixel has a value and the image has no empty
# regions the way an attractor does, so it has to be whispered. Slightly above
# Gray-Scott's 0.20 because the troughs sit at exactly the background and the
# panel is not uniformly covered -- roughly half of it is bare desktop between
# the ridges, which buys back a little headroom.
TITLE = "Kuramoto-Sivashinsky"
SUBTITLE = "u_t + u_xx + u_xxxx + u u_x = 0,  space vs time"

BLEND = 0.37

# No SCALE: lib's linear default is correct here. The log option exists for
# histogram densities that span orders of magnitude between the busy and the
# rarely visited; this is a bounded field whose values span a factor of a few,
# and log would flatten what contrast it has.

# (L, rate). L is the only parameter the equation has: rescaling x and t
# removes every coefficient and leaves the domain length, so L alone fixes how
# many cells fit across the panel (floor(L/2pi) modes are linearly unstable).
# L = 32pi is the domain of every published KS figure since Trefethen's; below
# about L = 22 the flow stops being chaotic and relaxes onto a travelling wave
# (the minimal chaotic domain of Cvitanovic, Davidchack & Siminos 2010), and
# far above it the cell count grows without the character changing. `rate` is
# time units per unit length, i.e. how much the picture is stretched along t:
# 1.0 draws time at the same scale as space, below that cells elongate into
# columns, above it they shear and merge within a shorter vertical distance.
PRESETS = {
    "cells":   (32 * np.pi, 1.00),
    "columns": (26 * np.pi, 0.70),
    "drift":   (44 * np.pi, 2.20),
    "weave":   (64 * np.pi, 1.70),
}

# ETDRK4 is stable well past this for KS; the cap only matters for small
# previews, where a row of pixels would otherwise be a third of a time unit and
# the advection would be integrated coarsely enough to see.
MAX_STEP = 0.25

# Time discarded before the first row. The initial condition is not on the
# attractor and its collapse onto one is a transient that looks nothing like
# the rest of the image.
BURN = 150.0


def _coeffs(lin, dt, m=32):
    """ETDRK4's weights, by contour integral.

    The weights are combinations like (e^z - 1)/z: exact in algebra and
    catastrophic in floating point as z -> 0, which is precisely where the
    long-wavelength modes that carry the whole solution live. Kassam &
    Trefethen evaluate them instead as a mean over a circle of radius 1 about
    each z -- the functions are analytic there, so the mean is the value at the
    centre, obtained only from arguments far from the singularity. Half a
    circle suffices because `lin` is real and conjugate points pair up.
    """
    r = np.exp(1j * np.pi * (np.arange(1, m + 1) - 0.5) / m)
    z = dt * lin[:, None] + r[None, :]
    ez = np.exp(z)
    z3 = z ** 3
    q = dt * np.real(np.mean((np.exp(z / 2) - 1) / z, axis=1))
    f1 = dt * np.real(np.mean((-4 - z + ez * (4 - 3 * z + z * z)) / z3, axis=1))
    f2 = dt * np.real(np.mean((2 + z + ez * (z - 2)) / z3, axis=1))
    f3 = dt * np.real(np.mean((-4 - 3 * z - z * z + ez * (4 - z)) / z3, axis=1))
    return np.exp(dt * lin), np.exp(dt * lin / 2), q, f1, f2, f3


def generate(size, seed=0, burn=BURN):
    w, h = size
    name = sorted(PRESETS)[seed % len(PRESETS)]
    length, rate = PRESETS[name]

    # Grid. Resolution is set by the physics, not by the panel: the linear
    # growth rate k^2 - k^4 is negative for every k > 1, so the spectrum falls
    # off a cliff above it -- measured on a settled run, mode k = 8 sits eleven
    # orders of magnitude below the peak. At 2.6 points per unit length the
    # Nyquist wavenumber lands at 8 or beyond, which is already past the point
    # where the modes are at round-off. The panel gets an interpolation of this
    # at the end, not a finer simulation.
    n = 1 << int(np.ceil(np.log2(2.6 * length)))
    x = length * np.arange(n) / n
    k = 2 * np.pi * np.fft.rfftfreq(n, d=length / n)

    lin = k ** 2 - k ** 4
    deriv = -0.5j * k
    # The Nyquist mode of a real signal carries no phase, so its derivative is
    # not representable on this grid; left in, it feeds a sawtooth back in.
    deriv[-1] = 0.0

    # Two-thirds rule on the quadratic term. KS damps the top of the spectrum
    # so hard that aliasing is usually ignored here (kursiv.m does not
    # dealias), but this runs for thousands of steps rather than a few hundred
    # and the mask costs nothing.
    keep = k <= (2.0 / 3.0) * k[-1]

    def nonlinear(v):
        u = np.fft.irfft(v, n=n)
        return deriv * np.fft.rfft(u * u) * keep

    # One timestep per row of pixels, so the vertical scale is fixed in time
    # units per pixel and the image looks the same on any panel. Sub-stepping
    # only kicks in when a row would exceed MAX_STEP.
    per_row = rate * length / w
    sub = max(1, int(np.ceil(per_row / MAX_STEP)))
    dt = per_row / sub
    e, e2, q, f1, f2, f3 = _coeffs(lin, dt)

    def step(v):
        nv = nonlinear(v)
        a = e2 * v + q * nv
        na = nonlinear(a)
        b = e2 * v + q * na
        nb = nonlinear(b)
        c = e2 * a + q * (2 * nb - nv)
        nc = nonlinear(c)
        return e * v + nv * f1 + 2 * (na + nb) * f2 + nc * f3

    # A sum of unstable-band cosines with random phase. The spatial mean of u
    # is conserved exactly -- every term of the equation is a derivative -- so
    # the initial condition must have mean zero or the whole solution rides on
    # a constant drift for ever. Omitting the j = 0 term is what guarantees it.
    rng = np.random.default_rng(seed)
    j = np.arange(1, 9)[:, None]
    amp = rng.normal(0.0, 1.0, (j.size, 1))
    phase = rng.uniform(0.0, 2 * np.pi, (j.size, 1))
    u = (amp * np.cos(2 * np.pi * j * x[None, :] / length + phase)).sum(0)

    v = np.fft.rfft(u)
    for _ in range(int(burn / dt)):
        v = step(v)

    # Keep the spectra, not the samples: the rows are wanted at the panel's
    # width, and the spectrum is what makes that a resize rather than a
    # resampling. Shape (h, n/2+1) complex is a few tens of MB at most.
    spec = np.empty((h, k.size), dtype=complex)
    for row in range(h):
        for _ in range(sub):
            v = step(v)
        spec[row] = v

    # Zero-pad to the panel width and transform back in one batched call. u is
    # band-limited by construction, so this is exact interpolation, not a
    # smoothing filter: the pixels are the solution evaluated at the pixel
    # centres. Gray-Scott repeats pixels because its fronts are near
    # discontinuities and interpolating them is a blur; here the opposite is
    # true and nearest-neighbour would put visible stairs on every ridge.
    m = min(k.size - 1, w // 2 + 1)
    pad = np.zeros((h, w // 2 + 1), dtype=complex)
    pad[:, :m] = spec[:, :m]
    field = np.fft.irfft(pad, n=w, axis=1) * (w / n)

    # The ramp is one-sided and climbs out of the desktop background, so a
    # signed field has no way to show its sign: shifting u up to be positive
    # would colour the troughs as strongly as the ridges and wash the panel to
    # a flat mid-tone with no background left anywhere. Rectifying instead puts
    # the troughs exactly on the background and leaves the ridges as the
    # structure.
    #
    # Squared because lib.normalise applies gamma 0.45, which is the right lift
    # for a histogram density -- where almost every cell is near the floor --
    # and far too much for a smooth field, where it flattens each ridge into a
    # single tone with a hard edge. The square very nearly cancels it and gives
    # back a ramp that runs from trough to crest.
    return np.maximum(field, 0.0) ** 2
