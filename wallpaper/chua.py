"""Chua's circuit -- the double scroll.

    dx/dt = alpha (y - x - f(x))
    dy/dt = x - y + z
    dz/dt = -beta y
    f(x)  = m1 x + (m0 - m1) (|x + 1| - |x - 1|) / 2

Among the simplest electronic circuits that are chaotic, and one whose chaos
has been shown on the bench, in simulation and by proof: two capacitors, an
inductor, a resistor and one nonlinear element, the "Chua diode", whose
current is the piecewise-linear f above. x and y are the two
capacitor voltages and z the inductor current, all made dimensionless.
alpha = 15.6, beta = 28, m0 = -1.143, m1 = -0.714 are the textbook values for
the double scroll.

Because f is piecewise LINEAR, the flow is linear in each of three slabs,
x < -1, |x| < 1 and x > 1. The outer two each hold a saddle-focus, at
x = +-1.5: an orbit spirals outward around one of them, a scroll, until it
crosses into the middle slab, where the equilibrium at the origin decides
which scroll it enters next. Two spiral sheets stitched through a middle
band, visited in an order that no finite record of the past predicts.

AXES. The attractor is thin in y -- about 0.8 wide against 4.5 in x and 7 in z
-- so an honest isotropic view sees it nearly edge-on from almost everywhere,
and the scrolls collapse into two smeared ellipses. Each coordinate is
therefore drawn in units of its own spread (standard deviation), which is what
any plot of these three quantities does anyway: they are two voltages and a
current, and there is no common unit to be faithful to. In those units the
object is round enough that a camera angle can be chosen for the picture.

Drawn the lorenz.py way, which was approved: three orbits followed a long way
rather than an ensemble -- about five hundred turns of scroll in all -- so
that each turn is a line you can follow rather than part of a haze. See
attractor3d.py for the camera and the pen, and for the depth cue below.
"""

import numpy as np

import attractor3d as a3

TITLE = "Chua's circuit"
SUBTITLE = ("double scroll,  alpha=15.6, beta=28, m0=-1.143, m1=-0.714"
            "   (Matsumoto 1984)")

# The approved Lorenz look, unchanged; lorenz.py explains each number.
SCALE = "zscale"
GAMMA = 0.4
SOFTEN = 0.8
HUE_SMOOTH = 3.0
BLEND = 0.85

# Depth cue (attractor3d.depth_weight): ink from 8% at the back of the object
# to 100% at the front. The two scrolls overlap in every view that shows both,
# and this is what says which is in front; with this palette it also turns the
# far one teal and the near one violet. 0.08 rather than 0.3, which gamma 0.4
# compresses to a brightness ratio of 0.62 and nobody can see.
DEPTH = 0.08

ALPHA, BETA, M0, M1 = 15.6, 28.0, -1.143, -0.714

# Seeds are camera positions, in the axis-normalised space described above.
# (azimuth, elevation, roll, zoom, shift): roll lays the long axis of the
# projection along the panel so that a 16:10 frame holds both scrolls;
# zoom > 1 crops into the outer turns rather than leaving the corners empty.
VIEWS = [
    # From above and to one side, looking into both spiral sheets: two
    # whirlpools, and the middle band as a lattice of strands between them.
    (45.0, 60.0, -50.0, 1.05, (0.0, 0.0)),
    # From low down: the scrolls as two tilted discs, one over the other, and
    # the band an S of strands joining them.
    (160.0, 15.0, -15.0, 1.15, (0.0, 0.0)),
    # Lower and more side-on than the first: the whirlpools edge-on enough to
    # read as coils.
    (70.0, 35.0, -60.0, 1.05, (0.0, 0.0)),
]


def _deriv(p):
    x, y, z = p
    fx = M1 * x + 0.5 * (M0 - M1) * (np.abs(x + 1.0) - np.abs(x - 1.0))
    return np.stack([ALPHA * (y - x - fx), x - y + z, -BETA * y])


def generate(size, seed=0, orbits=3, steps=60_000, dt=0.004, burn=5_000):
    rng = np.random.default_rng(seed)
    # Started in the basin of the double scroll, near one scroll's plane. The
    # burn-in brings them onto it and decorrelates them.
    p = np.stack([0.7 + rng.uniform(-0.2, 0.2, orbits),
                  rng.uniform(-0.1, 0.1, orbits),
                  rng.uniform(-0.1, 0.1, orbits)])
    # dt = 0.004 is ~370 steps per turn of scroll, and alpha * dt = 0.06 keeps
    # the fastest rate in the system far inside RK4's stability region. The
    # kinks in f cost RK4 some formal order without costing it the picture.
    pts = a3.integrate(_deriv, p, dt, steps, burn)
    pts = (pts - pts.mean(axis=(0, 2))[None, :, None]) \
        / pts.std(axis=(0, 2))[None, :, None]

    az, el, roll, zoom, shift = VIEWS[seed % len(VIEWS)]
    sx, sy, depth = a3.view(pts, az, el, roll)
    extent = a3.frame(sx, sy, size, zoom=zoom, shift=shift)
    wgt = None if DEPTH is None else a3.depth_weight(depth, DEPTH)
    return a3.draw(sx, sy, size, extent, weight=wgt)
