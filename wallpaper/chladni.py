"""Chladni figures -- a standing wave on a square plate, drawn at its nodes.

Chladni (1787) bowed the edge of a sand-strewn brass plate and found the sand
collecting along the lines where the plate was not moving. The honest theory of
the free-edge square plate is Ritz's (Ann. Phys. 28, 737, 1909) and it is built
out of free-free beam functions. What is used here is the classical stand-in --
the Neumann modes of a square, superposed:

    cos(n pi x) cos(m pi y)

which is what nearly every reproduction of a Chladni figure is actually
drawing. It gets the topology right -- how many lines, where they cross, what
symmetry they have -- and the exact curvature wrong, and for a surface to put
windows on that is the correct half to keep.

The figure is the zero set of the sum: the nodal lines, where the amplitude
vanishes and the sand shaken off everywhere else has nowhere further to go. So
the field here is not an amplitude. It is nearness to a node.

There is nothing to integrate. The mode and its gradient are closed form,
evaluated once per pixel from outer products of two 1-D cosine tables, which
makes this the fastest generator in the set by a wide margin -- the cost is a
dozen passes over the raster and nothing else. Everything else here has a knob
for how long you are willing to wait for it to converge; this one does not.

What it contributes is rigidity. The attractors are haze and Gray-Scott is a
texture; between them they do not contain a straight line, a right angle or a
repeat. Every figure here is exactly symmetric about two axes -- which two
depends on the mode, and the presets below are split between the pair that
holds the diagonals and the pair that holds the horizontal and vertical -- and
it is in the set because a wallpaper set needs one image that is obviously
constructed rather than grown.
"""

import numpy as np

# Nodal lines are curves, so most of the panel stays at background -- that puts
# this in the attractors' band and not with the space-filling fields. It sits
# at the bottom of that band because it is the only generator here that draws
# continuous geometry: the eye follows a line it can trace in a way it never
# follows attractor haze, and a lattice of straight segments competes with
# window edges in a way that noise does not.
TITLE = "Chladni figures"
SUBTITLE = "nodal lines of a vibrating square plate"

BLEND = 0.78

# Hue from the neighbourhood, so a line's soft edge fades in the line's own
# colour instead of stepping down the ramp into a different one (see
# lib.render). No SOFTEN: the lines are an analytic Gaussian several pixels
# wide already, so there is nothing to band-limit.
HUE_SMOOTH = 3.0

# How much of the plate's motion shows between the lines (see generate). It
# has to be tiny: the house stretch lifts faint values hard, and 0.06 to 0.6
# all flooded the panel with colour and took the top of the ramp away from the
# lines. 0.004 reads as a dark, pillowed tint. Chosen on a real desktop against
# the plain figures and a stronger 0.012.
GLOW = 0.004
GLOW_POWER = 2.0

# Each preset is a set of (n, m, weight) terms summing to the mode, written out
# term by term rather than hiding the classical pairing in code, because the
# pairing is a choice and the last preset breaks it.
#
# Two terms with opposite sign is the textbook figure. cos(n)cos(m) and its
# transpose are distinct solutions at the same frequency, so every mixture of
# the two is a solution as well and the plate picks one according to where it
# is damped. The antisymmetric mixture is the one that is always drawn, because
# it is the one that lays a nodal line down the diagonal.
#
# Within such a pair n and m have to be coprime: (kn, km) is the figure of
# (n, m) tiled k times, not a new figure, so (2,1), (4,2) and (6,3) are one
# pattern at three zooms. The first version of this table had all three in it
# and looked like a bug. The ratio picks the figure; n picks how densely it
# repeats across the panel.
#
# "cross" mixes across mode numbers instead. Frequency depends on n and m only
# through n^2 + m^2 -- squared for a plate, square-rooted for a membrane,
# monotone either way -- so (7,1) and (5,5) are degenerate at 49+1 = 25+25 = 50
# and the entire plane they span answers to one driving tone. That degeneracy
# is why Chladni could shake several different patterns out of a single note;
# 1.4 is a point in that plane, not a fitted constant, and on a real plate it
# is chosen by where you hold it. It is also the only preset here whose figure
# is not built from a coprime pair, which is why (5,5) can appear at all.
#
# Range: below (3,1) the panel holds four lines and reads as a minimal poster
# rather than a figure, and past (8,5) the lines pack closer than a few pixels
# at 4K and the whole thing turns into moire.
PRESETS = {
    "star":    ((3, 1, 1.0), (1, 3, -1.0)),                 # n^2+m^2 = 10
    "lens":    ((5, 2, 1.0), (2, 5, -1.0)),                 # 29
    "rosette": ((7, 3, 1.0), (3, 7, -1.0)),                 # 58
    "mesh":    ((8, 5, 1.0), (5, 8, -1.0)),                 # 89
    "cross":   ((7, 1, 1.0), (1, 7, -1.0), (5, 5, 1.4)),    # 50, degenerate
}


def generate(size, seed=0, width=0.0012, glow=None, glow_power=None):
    names = sorted(PRESETS)
    terms = PRESETS[names[seed % len(PRESETS)]]

    w, h = size

    # Equal scale on both axes. The plate is square, the panel is not, and
    # something has to give: stretching the plate destroys the diagonal
    # symmetry that is the entire content of a Chladni figure, and fitting it
    # whole leaves two dead bars down the sides. So the domain simply runs past
    # the plate edge on the long axis. The mode functions are cosines defined
    # on all of R^2 -- the plate is a boundary condition on them, not their
    # domain -- so the pattern continues across x=0 and x=1 with no seam, and
    # reads as a larger plate driven at the same wavelength.
    unit = min(w, h)  # pixels per plate width
    x = 0.5 + (np.arange(w) - (w - 1) / 2) / unit
    y = 0.5 + (np.arange(h) - (h - 1) / 2) / unit

    s = np.zeros((h, w))
    sx = np.zeros((h, w))
    sy = np.zeros((h, w))
    for n, m, c in terms:
        cx, cy = np.cos(n * np.pi * x), np.cos(m * np.pi * y)
        dcx = -n * np.pi * np.sin(n * np.pi * x)
        dcy = -m * np.pi * np.sin(m * np.pi * y)
        # Every term is separable, so the raster costs three outer products and
        # the trigonometry is evaluated w + h times, not w * h times.
        s += (c * cy)[:, None] * cx[None, :]
        sx += (c * cy)[:, None] * dcx[None, :]
        sy += (c * dcy)[:, None] * cx[None, :]

    # Thresholding |s| does not draw a line of constant width. The amplitude
    # climbs away from a node at a rate set by the local gradient, so a fixed
    # cut on |s| gives a hairline where the plate is steep and a broad smear
    # where it is nearly flat -- the figure ends up weighted by something that
    # has nothing to do with its shape. |s| / |grad s| is the first-order
    # distance to the nodal set, and is uniform width by construction. Where
    # two nodal lines cross both terms vanish together, |s| quadratically and
    # |grad s| linearly, so the ratio still tends to zero; eps is only there to
    # keep the exact critical point out of 0/0.
    d = np.abs(s) / (np.hypot(sx, sy) + 1e-9)

    # Width is a fraction of the panel so the picture is the same picture at
    # any resolution, with a floor of just over a pixel: a line thinner than
    # the sample spacing falls between pixels and the figure disappears, and
    # this file has to render a 2880x1920 panel and a 320-wide thumbnail.
    # The Gaussian profile is what anti-aliases the line -- d is a real
    # distance, so the falloff is smooth without supersampling anything.
    lw = max(1.2, width * unit) / unit
    line = np.exp(-(d / lw) ** 2)
    glow = GLOW if glow is None else glow
    glow_power = GLOW_POWER if glow_power is None else glow_power
    if glow <= 0:
        return line

    # The plate's own motion between the lines, as a glow under them: how hard
    # each point vibrates, |s|, brightest at the antinodes -- exactly where the
    # sand is thrown from. It falls to zero at every node, so it never touches
    # a line and leaves a dark margin along each one, and it sits in the lower
    # part of the ramp so the lines keep the top of it.
    a = np.abs(s)
    a /= a.max() or 1.0
    return line + glow * a ** glow_power
