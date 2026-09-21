"""Double pendulum, phase space: every pixel is a pendulum.

x is the upper arm's starting angle and y the lower arm's, both over
[-pi, pi], released from rest. The colour is how long that pendulum takes
to flip an arm over the top. Low-energy starts near the centre never flip
and stay on the ground colour; around them the map breaks into filaments at
every scale, because neighbouring starting positions end up doing
completely different things.

The field comes from doublependulum.generate_flip; this module exists so the
phase space is its own background with its own look, separate from the
path picture of the same system.

The look was chosen on a real desktop, and each part answers a specific
complaint:

  * computed at 2x per axis and averaged down, because at one pendulum per
    pixel every filament edge is a hard staircase;
  * HISTOGRAM-EQUALISED, because most starting positions flip quickly and a
    value-based stretch hands most of the colour to that bulk -- one colour
    flooded the screen while the filaments were crushed into a sliver;
  * a two-colour ramp, not all five: on a screen-filling field of fine
    filaments the full ramp puts every colour everywhere at once;
  * gamma 1.8 with the ramp in its normal direction, which gives the slow,
    detailed flips the larger share of the ramp;
  * saturation 1.5 and exposure 0.95 -- well below the trajectory
    generators' 2.25 / 1.1, which suit thin lines on an empty ground and
    overwhelm a picture that fills the screen.
"""

import doublependulum as dp

TITLE = "Double pendulum, phase space"
SUBTITLE = "how long each starting position takes to flip an arm over the top"

SCALE = "equalize"
RAMP = "duo"
REVERSE = False
GAMMA = 1.8
SATURATION = 1.5
EXPOSURE = 0.95
BLEND = 0.85

# Every pixel is an independent pendulum, so this is by far the most
# expensive generator: ~194 s per million pendulums on one core, and an 8K
# frame is 37 million of them. It is computed in bands across machines; see
# the rows= argument of doublependulum.generate_flip.


def generate(size, seed=0, rows=None, **kw):
    return dp.generate_flip(size, seed=seed, rows=rows, t_max=20.0, dt=0.01)
