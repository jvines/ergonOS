"""Rossler attractor -- stretch and fold, with nothing else in the way.

    dx/dt = -y - z
    dy/dt =  x + a y
    dz/dt =  b + z (x - c)

a = b = 0.2, c = 5.7: Rossler's own 1976 values. He built the system to be
the simplest flow that could be chaotic, with a single nonlinear term, and it
shows the mechanism of chaos more plainly than Lorenz does. The (x, y) part is
an unstable spiral: an orbit near the z = 0 plane winds outward, which
STRETCHES a strip of neighbouring orbits into a band. Once x passes c the
z (x - c) term switches on, and the band's outer edge is flung upward, bent
back over and dropped onto the INNER edge of the disc. Stretch, fold,
reinject, every turn -- Smale's horseshoe, drawn by an ODE. After enough turns
the band is a book of leaves, a Cantor set in cross-section, and the gaps
between the leaves are what the picture is made of.

THE VIEW is chosen to show that fold. From straight above (x, y) the fold is a
place where the spiral crosses itself; from the side (x, z) it is the only
thing visible and the disc is a line. From above and to one side the disc is
an ellipse, the fold stands out of it as a sail, and you can follow the
leaves up the sail, over, and back down across the disc.

z is drawn at HALF scale. The fold rises about as high (z = 23) as the disc is
wide, so in an oblique view at true scale the object is taller than it is
wide, and a 16:10 panel either crops the sail off the top or shrinks the disc
to a strip along the bottom. Squashing z keeps the geometry -- which strand
lies over which -- and gives both the screen. The caption says so.

INK BY LENGTH, not by time. The orbit moves up to nine times faster through
the fold than round the disc, so time density -- what lorenz.py draws -- dims
the sail to teal and piles the pink into the slow inner edge of the disc:
the colour lands on the least interesting part. Here every strand carries
the same ink per unit of drawn length, so brightness means overlapping
strands and the fold is as bright as the band it came from. (INK = "time"
brings the other behaviour back; both were rendered and compared.)

DEPTH CUE. Seen obliquely the fold and the disc overlap, and nothing in a
projection says which strand is in front. Ink is therefore scaled from 8% at
the back of the object to 100% at the front, which with this palette also
moves the far side toward teal and the near side toward violet and pink.
See attractor3d.py for the camera, the pen and the cue.
"""

import numpy as np

import attractor3d as a3

TITLE = "Rössler attractor"
SUBTITLE = ("stretch and fold, z at half scale,  a=0.2, b=0.2, c=5.7"
            "   (Rössler 1976)")

# The approved Lorenz look; lorenz.py explains each number.
SCALE = "zscale"
GAMMA = 0.4
SOFTEN = 0.8
HUE_SMOOTH = 3.0
BLEND = 0.85

# See above. DEPTH 0.08, chosen against 0.3 and none side by side: gamma 0.4
# turns an ink ratio of 0.3 into a brightness ratio of 0.62, too little to
# read, where 0.08 becomes 0.36.
INK = "length"
DEPTH = 0.08

A, B, C = 0.2, 0.2, 5.7

# (azimuth, elevation, roll, z-scale, zoom, shift). Azimuth is where the
# camera stands, measured from +x toward +y; roll turns the picture
# anticlockwise; shift is in fractions of the full view (attractor3d.frame).
# (azimuth, elevation, roll, z scale, zoom, shift). Every zoom carries a
# factor 0.7: the builder framed each view to fill the panel edge to edge,
# and on a real desktop all three read better pulled back -- 0.85 was tried
# too, and the full 0.7 chosen for each.
VIEWS = [
    # The whole sail, crest included, laid on its side: z points to the
    # LEFT. Upright, the sail is taller than a 16:10 panel at any zoom that
    # fills it -- the crest ran off the top edge and the left third was
    # empty. Rolled 75 degrees it lies along the panel: the crest is the
    # rounded tip at the left, the leaves fan out from it to the disc on
    # the right, and the only empty ground is the wedge under the caption.
    (-150.0, 20.0, 75.0, 0.5, 0.9 * 0.7, (0.0, 0.0)),
    # From behind the fold: the folded band lies back across the disc, and
    # where its leaves cross the disc's they make a lattice.
    (120.0, 35.0, 0.0, 0.5, 1.0 * 0.7, (0.0, 0.0)),
    # From higher and further round: the disc an open ring, and the fold
    # landing on its far side at the top as a triangle of crossing leaves.
    # Chosen for the ANGLE of that crossing. From az -90, el 30 the landing
    # band met the disc band at about 10 degrees, and two sets of strands
    # that nearly parallel beat into a diamond moire; the pattern is in the
    # geometry, so no amount of supersampling removes it. Here they cross
    # steeply enough to read as a fine lattice instead.
    (-60.0, 40.0, 10.0, 0.5, 1.0 * 0.7, (0.0, 0.0)),
]


def _deriv(p):
    x, y, z = p
    return np.stack([-y - z, x + A * y, B + z * (x - C)])


def generate(size, seed=0, orbits=3, steps=60_000, dt=0.01, burn=5_000):
    rng = np.random.default_rng(seed)
    p = np.stack([rng.uniform(-1, 1, orbits),
                  rng.uniform(-6, -4, orbits),
                  rng.uniform(0.0, 0.5, orbits)])
    # dt = 0.01 is ~590 steps a turn round the disc, and a trip through the
    # fold -- z up to 23 and back -- still takes over a hundred of them.
    pts = a3.integrate(_deriv, p, dt, steps, burn)
    pts -= pts.mean(axis=(0, 2))[None, :, None]

    az, el, roll, zs, zoom, shift = VIEWS[seed % len(VIEWS)]
    pts[:, 2] *= zs
    sx, sy, depth = a3.view(pts, az, el, roll)
    extent = a3.frame(sx, sy, size, zoom=zoom, shift=shift)
    wgt = None if DEPTH is None else a3.depth_weight(depth, DEPTH)
    return a3.draw(sx, sy, size, extent, ink=INK, weight=wgt)
