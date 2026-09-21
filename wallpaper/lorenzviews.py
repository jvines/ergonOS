"""Lorenz attractor from other sides -- the same orbits, turned in 3-D.

lorenz.py draws the butterfly the way it is always drawn, looking along y at
the (x, z) plane. That view is canonical because it is the one where the two
wings separate, but it hides most of what the object is: a pair of nearly flat
spiral sheets, each tilted, meeting along a seam where the orbit decides which
wing to visit next. Seeds here are other camera positions on the same system:

  0  top, looking down the z axis. The wings lie almost in the plane of the
     screen, so the spirals are seen open, and the seam is the S-shaped lane
     through the middle. Turned 45 degrees about z so that the two fixed
     points, which sit on the line x = y, lie across the panel, then rolled
     25 degrees onto its diagonal: seen from above the object is about
     three times as long as it is wide, and laid flat a 16:10 panel either
     cuts both wings through their eyes or leaves half the panel empty.
  1  oblique, down the plane of one wing: it collapses into a bright blade
     while the other opens full face, which shows how thin a sheet each wing
     really is.

The physics and the look are lorenz.py's, unchanged and imported from it --
three orbits, t = 120, Lorenz's 1963 parameters; zscale, gamma 0.4, defringe
-- so any change to the approved look carries over. The only differences are
the camera and the frame, both in attractor3d.py, and that physical up is up:
z points up the screen in every view that shows it (the oblique view is
rolled a few degrees off it, to fill the panel). lorenz.py itself draws z
downward, because lib.histogram2d puts the lowest value in the top row.
"""

import numpy as np

import attractor3d as a3
from lorenz import SCALE, GAMMA, SOFTEN, HUE_SMOOTH, BLEND  # noqa: F401

# Depth cue (see attractor3d.depth_weight): ink from DEPTH at the back to 1 at
# the front. None draws every strand alike.
DEPTH = None

TITLE = "Lorenz attractor"
_PHYS = "3 orbits, t=120,  sigma=10, rho=28, beta=8/3"
# The fallback; the per-view caption comes from caption(seed).
SUBTITLE = f"different views,  {_PHYS}"


def caption(seed):
    """(title, subtitle) for one view, from the table alone -- so a re-colour
    from a saved field, which never calls generate(), is captioned the same."""
    return TITLE, f"{VIEWS[seed % len(VIEWS)][0]},  {_PHYS}"


# (caption, azimuth, elevation, roll, zoom, shift, orbit seed). Azimuth is
# measured from +x toward +y and is where the camera stands; elevation 90
# looks straight down. Zoom and shift are chosen per view by eye: each
# projection has a different outline, and cropping it to 16:10 wants a
# different compromise between losing the outermost loops and leaving the
# corners empty. The orbit seed picks the three starting points, and is part
# of the picture: it is pinned so that pruning a view never changes another.
#
# Only views chosen on a real desktop are here. Pruned: a side view along x
# (0, 0, 0, zoom 1.0) and a classic oblique (-30, 40, -8, zoom 1.05, shift
# 0.03, 0.03) that was built and never shown.
VIEWS = [
    ("top view, looking down z", -45.0, 90.0, 25.0, 0.83, (0.0, 0.0), 0),
    ("oblique view, down one wing", -60.0, 60.0, -12.0, 1.05, (0.0, 0.0), 3),
]


def _deriv(p, s=10.0, r=28.0, b=8.0 / 3.0):
    x, y, z = p
    return np.stack([s * (y - x), x * (r - z) - y, x * y - b * z])


def generate(size, seed=0, ensemble=3, steps=48_000, dt=0.0025, burn=3000):
    _, az, el, roll, zoom, shift, orbit_seed = VIEWS[seed % len(VIEWS)]
    # Same start as lorenz.py, so orbit seed 0 here and seed 0 there share
    # orbits.
    rng = np.random.default_rng(orbit_seed)
    p = np.stack([rng.uniform(-15, 15, ensemble),
                  rng.uniform(-20, 20, ensemble),
                  rng.uniform(5, 40, ensemble)])
    pts = a3.integrate(_deriv, p, dt, steps, burn)
    # Centred on the attractor's own middle, so every camera turns about it
    # rather than about the origin, which is at the bottom of the seam.
    pts -= pts.mean(axis=(0, 2))[None, :, None]

    sx, sy, depth = a3.view(pts, az, el, roll)
    extent = a3.frame(sx, sy, size, zoom=zoom, shift=shift)
    wgt = None if DEPTH is None else a3.depth_weight(depth, DEPTH)
    return a3.draw(sx, sy, size, extent, weight=wgt)
