"""Orbital resonance -- the line between two planets, drawn every few days.

Join Earth and Venus with a straight line, wait two days, join them again,
and keep going for eight years. The lines envelop a five-petalled rose. The
five is not a choice: it is arithmetic in the periods.

    8 x 365.256 d  =  2922.0 d  ~  2921.1 d  =  13 x 224.701 d

Eight Earth years are thirteen Venus years to within a day, so after eight
years both planets are back where they started and the drawing closes on
itself. In that time Venus laps Earth 13 - 8 = 5 times: five inferior
conjunctions, 583.9 days apart, each 144 degrees round from the last -- the
five-fold cycle the Maya tabulated in the Venus table of the Dresden Codex.
Every chord is one moment of that synodic cycle, so the figure has one petal
per conjunction. In general a near p:q commensurability closes after q orbits
of the outer planet and draws p - q petals.

The second pair is Jupiter and Saturn, 5 x 11.86 y ~ 2 x 29.46 y: the near
5:2 commensurability behind the Great Inequality that Laplace explained in
1785. Five minus two is three. Their conjunctions step 243 degrees round the
sky, so every third one returns almost to the same place -- Kepler's trigon
of great conjunctions, drawn in De Stella Nova (1606) -- and the chords make a
three-fold rose. It is not exact: 5:2 is off by 0.4 years in 59, so each
rose is turned about 8 degrees from the last, and the triangle comes back
onto itself (a third of a turn) only after some 880 years. One cycle is
drawn, 2000 to 2060. A second cycle on top would be the same monthly fan of
chords turned by 8 degrees, and two fine gratings crossing at a small angle
beat into moire: ripples that belong to the drawing, not to the sky.

The third is an exoplanet system. TRAPPIST-1 b, c and d orbit an ultracool
dwarf at 1.51, 2.42 and 4.05 days, links in the longest resonant chain yet
found (Luger et al. 2017; periods from Agol et al. 2021): b:c is within 0.2
per cent of 8:5 and c:d within 0.4 per cent of 5:3, so b:d is near 8:3 and
the pair draws 8 - 3 = 5 petals -- the same count as Earth and Venus, from
twelve days of another star's planets instead of eight years of ours.

THE ORBITS ARE REAL. Solar-system positions come from Keplerian ellipses with
JPL's mean elements for J2000 (Standish's table, valid 1800-2050): semi-major
axis, eccentricity, inclination, mean longitude and its rate, the longitude of
perihelion and of the node, projected onto the ecliptic. So the rose carries
the orbits' eccentricity: it is not quite concentric and not quite
symmetric, which is the point of computing it rather than drawing two circles.
TRAPPIST-1's orbits are circular to within 0.01 and are taken as circles,
the two planets starting in conjunction; their real phases would only turn
the figure.

DRAWN AS A LINE DRAWING, not a density (see pen.py): every chord is an
anti-aliased stroke, and where chords cross the brighter is drawn over the
dimmer instead of adding up. The colour is the chord's length. A short chord
joins the planets near conjunction and lies in the ring between the orbits; a
long one spans the system near opposition, when the two are on opposite sides
of the star, and crosses its middle. Length is therefore the synodic phase
made visible: the ring cool, the heart of the rose warm, and the cusps --
where the fans of long chords fold over -- brightest of all.
"""

import numpy as np

TITLE = "Orbital resonance"
SUBTITLE = "the line joining two planets, drawn every few days until the pattern closes"

# The field arrives already coloured, 0..1 (see pen.py), and is taken as it is.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
SOFTEN = 0.0
HUE_SMOOTH = 3.0
# Analytic strokes: already band-limited, nothing for a supersample to add.
SUPERSAMPLE = 1

# Stroke edge and flat core, fractions of the panel height (1 px = 1/2400 at
# 4K).
SOFT = 1.0 / 2400
CORE = 0.3 / 2400
# Colour of the shortest chord: the bottom of the ramp, teal, and no lower.
V0 = 0.22

# JPL mean orbital elements at J2000, from E. M. Standish, "Keplerian Elements
# for Approximate Positions of the Major Planets" (Table 1, 1800-2050):
# a [AU], e, I [deg], L [deg], long. perihelion [deg], long. node [deg],
# dL/dt [deg per Julian century]. The rates of the other elements are left
# out: over a few centuries they move the picture by less than a line width.
ELEMENTS = {
    "Venus":   (0.72333566, 0.00677672, 3.39467605, 181.97909950,
                131.60246718, 76.67984255, 58517.81538729),
    "Earth":   (1.00000261, 0.01671123, -0.00001531, 100.46457166,
                102.93768193, 0.0, 35999.37244981),
    "Jupiter": (5.20288700, 0.04838624, 1.30439695, 34.39644051,
                14.72847983, 100.47390909, 3034.74612775),
    "Saturn":  (9.53667594, 0.05386179, 2.48599187, 49.95424423,
                92.59887831, 113.66242448, 1222.49362201),
}

# TRAPPIST-1: period [d] and semi-major axis [AU] (Agol et al. 2021).
TRAPPIST = {"b": (1.510826, 0.01154), "c": (2.421937, 0.01580),
            "d": (4.049219, 0.02227)}

# Each view: the pair, how long and how often a chord is drawn, and the frame.
#
# span  -- days drawn, from J2000 (2000 Jan 1.5), one whole commensurability
#          cycle, so the figure closes (Jupiter-Saturn nearly: see above).
# step  -- days between chords. What decides the look is chords per SYNODIC
#          period, ~250-300 here: fewer and the chords of one sweep stop
#          reading as a smooth fan and tangle; more and the fans fill solid.
#          Earth and Venus also need the fraction. At exactly 2 days the five
#          synodic cycles laid their chords almost on top of one another
#          (583.92 d is 291.96 steps), and the orbits' eccentricity -- a shift
#          of about one chord spacing -- turned the near-misses into clumps
#          and gaps: a tangled net. At 292.2 steps a cycle each one lands a
#          fifth of a step past the last, and the five interleave evenly.
# zoom  -- the outer orbit's radius over the panel's half-width. At 1 it
#          grazes the left and right edges and the top and bottom of the rose
#          are cropped, which is what fills a 16:10 panel.
# turn  -- degrees. 0 keeps the solar-system figures in the ecliptic frame
#          they were computed in: vernal equinox to the right, north up.
# upow  -- colour = rank of the chord's length, raised to this. Above 1 the
#          middling chords sink toward blue and only the longest, which cross
#          the heart of the figure, reach mauve and pink.
VIEWS = [
    dict(name="venus", inner="Venus", outer="Earth", span=8 * 365.25,
         step=583.922 / 292.2, zoom=1.0, turn=0.0, upow=1.6),
    dict(name="jupiter", inner="Jupiter", outer="Saturn",
         span=59.6 * 365.25, step=30.0, zoom=1.0, turn=0.0, upow=1.6),
    dict(name="trappist", inner="b", outer="d", span=3 * 4.049219,
         step=0.01, zoom=1.0, turn=0.0, upow=1.6),
]

CAPTIONS = {
    "venus": ("Orbital resonance: Earth and Venus",
              "the line between them every 2 days, 2000 to 2008:"
              "  8 Earth years = 13 Venus years, five petals"),
    "jupiter": ("Orbital resonance: Jupiter and Saturn",
                "the line between them every month, 2000 to 2060:"
                "  near 5:2, three petals -- Kepler's trigon"),
    "trappist": ("Orbital resonance: TRAPPIST-1 b and d",
                 "the line between them every 15 minutes for 12 days:"
                 "  8:5 x 5:3 = 8:3, five petals"),
}


def caption(seed):
    return CAPTIONS[VIEWS[seed % len(VIEWS)]["name"]]


def position(name, t):
    """Heliocentric ecliptic (x, y) in AU at t days from J2000."""
    if name in TRAPPIST:
        p, a = TRAPPIST[name]
        th = 2 * np.pi * t / p
        return a * np.cos(th), a * np.sin(th)
    a, e, inc, L0, varpi, node, Ldot = ELEMENTS[name]
    inc, varpi, node = np.radians([inc, varpi, node])
    L = np.radians(L0 + Ldot * t / 36525.0)
    M = np.mod(L - varpi + np.pi, 2 * np.pi) - np.pi
    # Kepler's equation by Newton's method from E = M; e < 0.06 here, so a
    # handful of steps reaches machine precision.
    E = M + e * np.sin(M)
    for _ in range(6):
        E = E - (E - e * np.sin(E) - M) / (1 - e * np.cos(E))
    xp = a * (np.cos(E) - e)
    yp = a * np.sqrt(1 - e * e) * np.sin(E)
    w = varpi - node
    cw, sw, cn, sn, ci = np.cos(w), np.sin(w), np.cos(node), np.sin(node), np.cos(inc)
    x = (cw * cn - sw * sn * ci) * xp + (-sw * cn - cw * sn * ci) * yp
    y = (cw * sn + sw * cn * ci) * xp + (-sw * sn + cw * cn * ci) * yp
    return x, y


def generate(size, seed=0, jobs=None, **over):
    import pen

    v = dict(VIEWS[seed % len(VIEWS)], **over)
    w, h = size

    t = np.arange(0.0, v["span"], v["step"])
    x1, y1 = position(v["inner"], t)
    x2, y2 = position(v["outer"], t)

    # Turn, then scale: pixels per AU such that the outer orbit's greatest
    # radius is `zoom` panel half-widths. The star sits at the centre.
    c, s = np.cos(np.radians(v["turn"])), np.sin(np.radians(v["turn"]))
    x1, y1 = c * x1 - s * y1, s * x1 + c * y1
    x2, y2 = c * x2 - s * y2, s * x2 + c * y2
    k = v["zoom"] * (w / 2) / float(np.max(np.hypot(x2, y2)))
    X1, Y1 = w / 2 + k * x1, h / 2 - k * y1
    X2, Y2 = w / 2 + k * x2, h / 2 - k * y2

    # Colour from the chord's length, by RANK rather than by value. Lengths
    # bunch toward the long end -- the planets spend more of the synodic
    # cycle far apart than close -- so a linear map gave nearly every chord
    # the same mauve. Ranked, each part of the ramp gets an equal share of
    # the chords, and the ring, the fans and the heart separate by colour.
    # The floor keeps the shortest chords a colour, not a shade of ground.
    L = np.hypot(x2 - x1, y2 - y1)
    u = np.argsort(np.argsort(L, kind="stable"), kind="stable") / max(1, L.size - 1)
    val = V0 + (1 - V0) * u ** v["upow"]
    core = v.get("core", CORE) * h
    return pen.draw(X1, Y1, X2, Y2, core, core, val, size,
                    soft=v.get("soft", SOFT) * h, jobs=jobs)
