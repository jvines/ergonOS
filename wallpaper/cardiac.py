"""Heart tissue, spiral waves -- a rotor breaking up into fibrillation.

    du/dt = lap(u) + u (1 - u) (u - (v + b) / a) / eps
    dv/dt = f(u) - v,     f(u) = 0 below u = 1/3, 1 above u = 1,
                          1 - 6.75 u (u - 1)^2 between

Barkley's excitable medium (Physica D 49, 61, 1991) with the delayed recovery
of Bar and Eiswirth (Phys. Rev. E 48, R1635, 1993). u is the excitation -- the
membrane voltage of a cartoon heart cell -- and v the recovery that ends each
beat and keeps the tissue refractory after it. A wave is a travelling region
of excitation: tissue ahead of it at rest, tissue behind it refractory, which
is why an excitable wave cannot pass back through where it has just been, and
why a broken one curls around its free end into a rotor.

Barkley's own model keeps that rotor forever: one clean spiral, the picture a
Belousov-Zhabotinsky dish makes. What f(u) adds is a delay -- no recovery is
produced until the excitation is a third of the way up -- and with it each
wave's duration and speed come to depend steeply on how far the tissue ahead
has recovered, the excitable-media counterpart of the steep restitution that
breaks up spirals in cardiac models (Fenton et al., Chaos 12, 852, 2002). Past
eps ~ 0.07 the rotor's waves can no longer follow one another stably. They
tear, every torn end curls into a new rotor, those tear in turn, and the
single spiral becomes a shifting population of short-lived wavelets. In a
ventricle that is fibrillation: a heart whose every cell is still firing, and
which has stopped pumping because no two regions fire together. Moe's
"multiple wavelets" (Am. Heart J. 67, 200, 1964) is the same picture drawn
from the other end.

The two views are one simulation of one medium: the rotor while it tears --
one spiral still turning, torn wavefronts curling around it, the outer rings
it launched earlier still whole -- and the same tissue five times later, when
nothing of the first rotor is left.

Rendering. The field shown is not u but the time since the tissue last fired,
and that can be read straight off the model: during a beat v climbs as
1 - e^-t, afterwards it decays from a - b = 0.77 as e^-t. Brightness is then
a chosen function of that time -- a flat-topped crest for the first fifth of
a recovery time, which draws every wavefront as a line of fixed width, and
under it a long exponential glow for the refractory tail, floored so that
recovered tissue lands exactly on the desktop colour. The ramp is reversed:
the crest takes the top colour and the tail the middle one, so the
anti-aliased leading edge passes through the tail's own colour and draws no
fringe.

Simulated on a fixed grid of cells whatever the panel size and upscaled
(Catmull-Rom); the wavefront is then re-sharpened at panel resolution from
its distance to the u = 1/2 contour, as the domain walls are in ising.py, so
it is crisp at 4K and at 8K alike. The update loop uses only +, -, *, / and
clip: no transcendental function whose last bit could differ between CPUs, so
the same run on any machine lands on the same turbulent state.
"""

import numpy as np

TITLE = "Heart tissue, spiral waves"
SUBTITLE = "an electrical rotor in excitable tissue breaking up -- the onset of fibrillation"

# Chosen against warm (pink crest on mauve) and the full ramp (a rainbow down
# every tail): sky wavefronts on a mauve afterglow. GAMMA above 1 because the
# ramp is interpolated in linear light, where a faint tail reads brighter
# than its value; at 1 the afterglow swallowed the fronts.
SCALE = "unit"
GAMMA = 1.5
BLEND = 0.85
RAMP = "duo"
REVERSE = True
SATURATION = 2.0
EXPOSURE = 1.0
SOFTEN = 0.7
# The field is built at panel resolution from a smooth simulation: nothing
# for supersampling to add.
SUPERSAMPLE = 1

A, B = 0.84, 0.07
DX, DT = 0.25, 0.018
# Grid rows, fixed: the simulation is the same at every render size, and the
# columns follow the panel's aspect.
ROWS = 250
# Half-width of the re-sharpened wavefront, as a fraction of panel height.
CRISP = 1.4 / 2400
# Brightness against time since firing, in recovery times: the crest's share,
# duration and flatness (exp(-(t/T)^P), P = 4 is flat-topped), the decay of
# the glow behind it, and the time after which tissue is drawn as ground.
CREST, CREST_T, CREST_P, TAIL_T, REST = 0.6, 0.2, 4.0, 1.4, 4.0

# (eps, simulated time). One medium, two moments of one run. The breakup
# moment was chosen from snapshots every six time units: at 48 the core had
# only just torn, by 66 the tearing had reached the outer rings.
# Only the view chosen on a real desktop is offered: the run carried on to
# multiple-wavelet fibrillation. The same run at t = 60, the first rotor still
# tearing ("breakup"), was shown and pruned.
PRESETS = {
    "fibrillation": (0.072, 300.0),
}


def caption(seed):
    name = list(PRESETS)[seed % len(PRESETS)]
    eps, t = PRESETS[name]
    if name == "breakup":
        return TITLE, ("a rotor of electrical excitation tearing into wavelets -- the onset"
                       f" of fibrillation  (Barkley-Bar-Eiswirth medium, eps = {eps})")
    return TITLE, ("the same tissue later: rotors born and dying everywhere, no two regions"
                   f" beating together -- fibrillation  (eps = {eps})")


def simulate(rows, cols, eps, t_end):
    """Explicit Euler, isotropic nine-point Laplacian, no-flux edges."""
    U = np.zeros((rows + 2, cols + 2), np.float32)
    u = U[1:-1, 1:-1]
    v = np.zeros((rows, cols), np.float32)
    y, x = np.mgrid[0:rows, 0:cols]
    # A wave along a half-line from the left edge to the centre, refractory
    # tissue on one side of it. Its free end at the centre curls up into the
    # rotor; the no-flux edge holds the other end, so there is one rotor, not
    # the pair a periodic box would force.
    cy, cx = rows // 2, cols // 2
    u[(x < cx) & (y >= cy) & (y < cy + int(2.0 / DX))] = 1.0
    v[(x < cx) & (y < cy) & (y >= cy - int(6.0 / DX))] = 0.75
    c = np.float32(DT / (6 * DX * DX))
    k = np.float32(DT / eps)
    for _ in range(int(round(t_end / DT))):
        # Mirror halo: zero flux through the tissue's edge.
        U[0, 1:-1] = u[1]; U[-1, 1:-1] = u[-2]
        U[:, 0] = U[:, 2]; U[:, -1] = U[:, -3]
        # Isotropic nine-point stencil: the five-point one lets a spiral feel
        # the grid axes, and a rotor this coarse would come out square.
        lap = 4 * (U[:-2, 1:-1] + U[2:, 1:-1] + U[1:-1, :-2] + U[1:-1, 2:]) \
            + U[:-2, :-2] + U[:-2, 2:] + U[2:, :-2] + U[2:, 2:] - 20 * u
        w = np.clip(u, np.float32(1 / 3), np.float32(1))
        f = 1 - np.float32(6.75) * w * (w - 1) ** 2
        du = k * u * (1 - u) * (u - (v + B) / A) + c * lap
        v += np.float32(DT) * (f - v)
        u += du
    return u.astype(np.float64), v.astype(np.float64)


def _cubic(a, h, w):
    """Catmull-Rom upscale of a grid to (h, w), edges clamped. Bilinear
    leaves a crease along every cell edge in a smooth gradient, and at ten
    pixels a cell the refractory tails are nothing but smooth gradient."""
    def weights(n_out, n_in):
        s = (np.arange(n_out) + 0.5) * n_in / n_out - 0.5
        i = np.floor(s).astype(int)
        t = s - i
        wt = [((-t + 2) * t - 1) * t / 2, ((3 * t - 5) * t * t + 2) / 2,
              ((-3 * t + 4) * t + 1) * t / 2, (t - 1) * t * t / 2]
        idx = [np.clip(i + k, 0, n_in - 1) for k in (-1, 0, 1, 2)]
        return idx, wt
    iy, wy = weights(h, a.shape[0])
    rows = sum(wk[:, None] * a[ik] for ik, wk in zip(iy, wy))
    ix, wx = weights(w, a.shape[1])
    return sum(wk[None, :] * rows[:, ik] for ik, wk in zip(ix, wx))


def field(u, v, size, crisp=None):
    w, h = size
    u = _cubic(u, h, w)
    v = np.clip(_cubic(v, h, w), 0.0, 1.0)
    # Excitation, re-sharpened: the signed distance in pixels to the u = 1/2
    # contour, ramped over a pixel or two. Only at a wavefront, where v is
    # still low; the back of a beat keeps the simulation's own soft edge,
    # because the brightness is continuous across it anyway.
    gy, gx = np.gradient(u)
    d = (u - 0.5) / (np.hypot(gx, gy) + 1e-9)
    half = max(0.7, (CRISP if crisp is None else crisp) * h)
    sharp = np.clip(0.5 + d / (2 * half), 0.0, 1.0)
    soft = np.clip((u - 0.25) / 0.5, 0.0, 1.0)
    m = np.clip((0.35 - v) / 0.2, 0.0, 1.0)
    e = m * sharp + (1 - m) * soft
    # Time since the tissue fired, in recovery times, read off v: during a
    # beat v = 1 - e^-t, after it v decays from a - b as e^-t.
    vb = A - B
    t_in = -np.log(np.clip(1 - v, 1e-3, 1.0))
    t_out = -np.log(1 - vb) + np.log(vb / np.maximum(v, 1e-4))
    tau = e * t_in + (1 - e) * t_out
    # A sharp crest and a longer glow behind it, lowered so that tissue which
    # has recovered sits exactly on the ground colour.
    g = CREST * np.exp(-(tau / CREST_T) ** CREST_P) + (1 - CREST) * np.exp(-tau / TAIL_T)
    floor = CREST * np.exp(-(REST / CREST_T) ** CREST_P) + (1 - CREST) * np.exp(-REST / TAIL_T)
    return np.clip((g - floor) / (1 - floor), 0.0, 1.0)


def generate(size, seed=0, **kw):
    w, h = size
    eps, t_end = PRESETS[list(PRESETS)[seed % len(PRESETS)]]
    cols = int(round(ROWS * w / h))
    u, v = simulate(ROWS, cols, eps, t_end)
    return field(u, v, size)
