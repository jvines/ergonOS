"""Lissajous figures -- two perpendicular oscillations, drawn as one curve.

    x = sin(a t + delta),   y = sin(b t)

Lissajous (1857) reflected a light beam off mirrors on two tuning forks at
right angles and threw the figure on a wall; Bowditch had the same curves from
a compound pendulum two decades earlier. For integer a and b the curve closes
after t = 2 pi, with a lobes touching each side edge and b touching the top
and bottom, and its topology is fixed by the ratio a : b -- which is how the
figures were used, to tune one fork against another by eye.

Drawn here as what the figure literally is: the SHADOW of a curve on a
cylinder. x = sin(a t + delta) is the projection of a point going round a
circle a times, whose depth out of the screen is z = cos(a t + delta), while y
climbs and falls b times. So every Lissajous figure is a closed wire wound on
a vertical cylinder and seen side-on, and the crossings in the flat drawing
are not crossings at all: one strand passes in front of the other. Here they
are drawn that way. Depth is the colour and the weight of the line -- the
near side of the cylinder warm and heavy, the far side cool and fine -- and
because strokes combine by maximum and the near side carries the higher
value, the near strand is always drawn over the far one. A flat textbook
figure becomes a lathe-turned object, from the same two sines.

The cylinder is stretched to the panel, because the two amplitudes are free:
an oscilloscope with its gains set to fill the screen.
"""

import numpy as np

TITLE = "Lissajous figure"
SUBTITLE = "x = sin(a t + δ),  y = sin(b t):  violet strands pass in front, teal behind"

# The field arrives already coloured, 0..1 (see pen.py), and is taken as it is.
# Strokes are analytic and band-limited, so no SOFTEN; HUE_SMOOTH keeps a
# line's soft edge in the line's own colour (see fractaltree.py).
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
SOFTEN = 0.0
HUE_SMOOTH = 3.0

# Stroke edge, and the flat core of the nearest strands, fractions of panel
# height (1 px = 1 / 2400 at 4K). The far side has no core at all.
SOFT = 1.0 / 2400
CORE = 0.8 / 2400

# (a, b, traces, spread). a and b coprime, or the figure is a smaller one
# traced several times. Fewer lobes take wider ribbons: with room between them,
# more traces read as a woven band rather than a blur.
PRESETS = {
    "5:8":   (5, 8, 14, 0.5),
    "3:13":  (3, 13, 9, 0.35),
    "7:9":   (7, 9, 9, 0.35),
    "11:13": (11, 13, 5, 0.25),
}


def phase(a, b):
    """The delta that keeps every lobe as far from its neighbours as it gets.

    Along the top edge the figure touches at the b points where sin(b t) = 1,
    at x = sin(phi0 + 2 pi a k / b), and two of those coincide -- the curve
    doubles back on itself -- when their phases are mirror images about
    pi/2. That happens at a lattice of delta spaced pi/b apart; midway between
    two of them the b touch points are evenly spread, and (working the same
    condition along the side edges) so are the a points there. Any other
    delta pairs the lobes up into near-doubled strands, which is what the
    first attempt here drew by picking delta by hand.
    """
    return np.pi / 2 - (a - 1) * np.pi / (2 * b)

# Colour of the far side of the cylinder, and how fast it warms toward the
# near side.
V0 = 0.16
VPOW = 1.3

# Inset from the panel edge, fraction of each axis, so the turning lobes are
# seen whole instead of cut.
MARGIN = 0.035
# The bottom gets its own, deeper inset: the caption lives there. At 0.035 the
# figure's lower turning points -- its brightest, where the near strands turn
# -- landed exactly on the subtitle's baseline, and the glyphs' dark outlines
# chopped them up. 0.09 lifts the figure's bottom edge to about y = 2185 at 4K,
# just above the top of the title.
MARGIN_BOTTOM = 0.09


def _preset(seed):
    names = list(PRESETS)
    return PRESETS[names[seed % len(names)]]


def caption(seed):
    # From the seed alone, which is all render.py ever varies: it passes no
    # preset and no overrides, so this is the figure generate() draws. Set
    # inside generate(), the subtitle reverted to the module's on every
    # palette switch, which re-colours the saved field without calling it.
    a, b, copies, _ = _preset(seed)
    return TITLE, (f"x = sin({a}t + δ),  y = sin({b}t):  {copies} traces as the phase δ slips;"
                   "  violet strands pass in front, teal behind")


def generate(size, seed=0, jobs=None, preset=None, **over):
    import pen

    a, b, copies, spread = PRESETS[preset] if preset else _preset(seed)
    copies = over.get("copies", copies)
    w, h = size
    # Vertical half-amplitude and centre, fractions of the height, between the
    # top margin and the deeper bottom one.
    ay = 0.5 * (1.0 - MARGIN - MARGIN_BOTTOM)
    cy = MARGIN + ay

    # Sampled finely enough that each chord sits within a hundredth of a
    # pixel of the curve: the path is at most (a W + b H) pi long in pixels,
    # and chords of ~3 px keep the sag at the tightest lobe negligible.
    n = int(np.pi * (a * w + b * h) / 3) + 1
    t = np.linspace(0.0, 2 * np.pi, n + 1)

    # THE FIGURE AS AN OSCILLOSCOPE SHOWS IT: not one trace but several, the
    # phase stepping a little between sweeps, as it does when the two
    # frequencies are a hair off the exact ratio. Each strand of the figure
    # becomes a ribbon of parallel traces. The step is a fraction SPREAD of
    # pi/b, the distance between two phases at which the figure folds onto
    # itself, so however many traces there are the ribbons never touch.
    step = over.get("spread", spread) * np.pi / b
    deltas = phase(a, b) + step * (np.linspace(-0.5, 0.5, copies) if copies > 1 else [0.0])

    xa, ya, xb, yb, c0, c1, val = [], [], [], [], [], [], []
    for delta in deltas:
        th = a * t + delta
        px = (0.5 + (0.5 - MARGIN) * np.sin(th)) * w
        py = (cy - ay * np.sin(b * t)) * h
        # Depth, 0 at the back of the cylinder and 1 at the front, sets the
        # colour and the weight. Weight per vertex, so consecutive chords
        # share their end widths exactly; colour per chord.
        z = 0.5 + 0.5 * np.cos(th)
        core = over.get("core", CORE) * h * z ** 2
        d = 0.5 * (z[:-1] + z[1:])
        xa.append(px[:-1]); ya.append(py[:-1]); xb.append(px[1:]); yb.append(py[1:])
        c0.append(core[:-1]); c1.append(core[1:])
        val.append(V0 + (1 - V0) * d ** VPOW)
    cat = np.concatenate
    return pen.draw(cat(xa), cat(ya), cat(xb), cat(yb), cat(c0), cat(c1),
                    cat(val), size, soft=SOFT * h, jobs=jobs)
