"""Physarum polycephalum -- a slime mould's transport network, grown by agents.

The plasmodium of Physarum is a single cell that forages by spreading a web
of tubes, then thickening the ones that carry the most flow and abandoning
the rest. Given oat flakes on a plate it joins them with a network whose
length and fault tolerance rival an engineer's (Nakagaki et al. 2000; Tero et
al. 2010, the Tokyo rail system).

The model is Jones's (2010, Artificial Life 16:127). No tube is put in by
hand: the network emerges from a population of particles and a
chemoattractant field.

  * the TRAIL is a scalar field on a periodic lattice; every step it diffuses
    (a 3x3 mean) and decays by a fixed fraction;
  * every AGENT has a position and a heading, and three sensors SO cells
    ahead, at 0 and +/-SA. It keeps straight when the front sensor reads
    most, turns by RA toward the stronger side otherwise, and turns at random
    when both sides beat the front; then it steps forward one cell and
    deposits onto the trail.

Agents follow trail and trail is where agents went: a positive feedback that
condenses the population into tubes. Jones also forbids two agents to
share a cell; with that rule the network is a fine, nearly uniform foam of small
polygons (the "reticulum" preset). Without it -- as in most later
implementations -- agents crowd into the busiest tubes, the tubes compete
for them, and the network coarsens as the real one does, into trunks and
side veins. The first two presets are that, stopped part way.

RENDERING. What is drawn is where the agents ARE, over the last few hundred
steps -- the flux in each tube -- not the trail, which is blurred by its own
diffusion (drawn, it glowed and flooded). Positions are continuous, deposited
bilinearly at panel resolution and softened by a Gaussian a fixed fraction of
the panel height wide, so veins are the same width at 4K and 8K. Colour is
flux, on the house zscale: a side vein lands on teal, a trunk that carries
the population goes pink. The fine strands inside a tube are real: agents
keep to lanes as they stream along it.

Tried and pruned: food sources projecting attractant (at every population
tried they changed nothing visible), and inoculating the plate at one point
(it grew pseudopods along the lattice axes, an artefact of the grid).
"""

import numpy as np

import lib

TITLE = "Slime mould network"

# Lines on empty ground: the house treatment.
SCALE = "zscale"
GAMMA = 0.5
BLEND = 0.85
SOFTEN = 0.0
HUE_SMOOTH = 3.0
# The field is a deposit smoothed at a fixed fraction of the panel height:
# already band-limited, so it is rendered at the panel's own resolution.
SUPERSAMPLE = 1

# Simulation lattice: cells per panel height. Fixed, so the network is the
# same at any render size; the lengths below are in these cells.
GRID = 720
# Width of the drawn vein profile, as a fraction of the panel height.
BLUR = 1.2 / 2400

# Jones's parameters: sa, ra in degrees; so in cells; decay per step; agents
# per lattice cell; steps; the last `avg` of them are drawn; exclude, his
# one-agent-per-cell rule; and the seed of the starting positions and
# headings -- part of the picture, so pinned with it.
#
# Only "network" was chosen on a real desktop. "wide" (so 25) and "reticulum"
# (sa 22.5, so 9, density 0.10, steps 3500, avg 600, exclude, blur 2/2400)
# were shown and pruned. A later revision drawing each tube in one colour
# across its width was shown beside this one, and this one was kept.
PRESETS = [
    dict(name="network", sa=30.0, ra=45.0, so=18.0, decay=0.1, density=0.5,
         steps=2000, avg=200, exclude=False, seed=1),
]


def _diffuse(t):
    """3x3 mean on the periodic lattice, as two separable passes."""
    t = t + np.roll(t, 1, 0) + np.roll(t, -1, 0)
    t = t + np.roll(t, 1, 1) + np.roll(t, -1, 1)
    return t * np.float32(1 / 9)


def simulate(p, gw, gh, record):
    """Run preset p on a (gh, gw) periodic lattice; record(x, y) gets the
    agents' positions on each of the last p['avg'] steps. Loops over time
    only: every agent moves at once. The randomness -- starting state, the
    tie-break turn, a blocked agent's new heading -- all comes from one
    generator seeded by the preset, so the run is the same on any machine."""
    rng = np.random.default_rng(p["seed"])
    n = int(p["density"] * gw * gh)
    f32 = np.float32
    # Distinct starting cells (the exclusion rule needs it), anywhere in each.
    here = rng.choice(gw * gh, n, replace=False).astype(np.int64)
    x = (here % gw + rng.random(n)).astype(f32)
    y = (here // gw + rng.random(n)).astype(f32)
    th = rng.uniform(0, 2 * np.pi, n)
    # Heading as a unit vector: turning by a fixed angle is then a rotation by
    # precomputed cos/sin, with no trigonometry per agent per step.
    c, s = np.cos(th).astype(f32), np.sin(th).astype(f32)
    csa, ssa = f32(np.cos(np.radians(p["sa"]))), f32(np.sin(np.radians(p["sa"])))
    cra, sra = f32(np.cos(np.radians(p["ra"]))), f32(np.sin(np.radians(p["ra"])))
    so, keep = f32(p["so"]), f32(1 - p["decay"])
    occ = np.zeros(gw * gh, bool)
    occ[here] = True
    ids, claim = np.arange(n), np.zeros(gw * gh, np.int64)
    trail = np.zeros((gh, gw), f32)

    def sense(dc, ds):
        # The integer modulo after the cast: in float32, a tiny negative
        # coordinate modulo gw rounds to gw itself.
        ix = ((x + so * dc) % gw).astype(np.int32) % gw
        iy = ((y + so * ds) % gh).astype(np.int32) % gh
        return trail.ravel()[iy * gw + ix]

    for step in range(p["steps"]):
        F = sense(c, s)
        L = sense(c * csa + s * ssa, s * csa - c * ssa)     # rotated by -SA
        R = sense(c * csa - s * ssa, s * csa + c * ssa)     # rotated by +SA
        # -1 turn left, +1 right, 0 keep straight.
        k = np.where(R > L, f32(1), np.where(L > R, f32(-1), f32(0)))
        k = np.where((F > L) & (F > R), f32(0), k)
        both = (F < L) & (F < R)
        k = np.where(both, np.where(rng.random(n, dtype=f32) < 0.5, f32(-1), f32(1)), k)
        cr, sr = np.where(k == 0, f32(1), cra), k * sra
        c, s = c * cr - s * sr, s * cr + c * sr
        if step % 64 == 63:                   # keep the heading a unit vector
            nrm = np.sqrt(c * c + s * s)
            c, s = c / nrm, s / nrm
        nx, ny = (x + c) % gw, (y + s) % gh
        tgt = (ny.astype(np.int32) % gh).astype(np.int64) * gw + nx.astype(np.int32) % gw
        if p["exclude"]:
            # A step inside the agent's own cell always succeeds; one into
            # another cell only if that cell was empty, and of several agents
            # bidding for it one wins -- the last written by the scatter, an
            # arbitrary but fixed choice among agents in random order. A
            # blocked agent stays, turns to a random heading and deposits
            # nothing (Jones 2010).
            stay = tgt == here
            claim[tgt] = ids
            win = stay | (~occ[tgt] & (claim[tgt] == ids))
            moved = win & ~stay
            occ[here[moved]] = False
            occ[tgt[moved]] = True
            here = np.where(win, tgt, here)
            x, y = np.where(win, nx, x), np.where(win, ny, y)
            lost = np.flatnonzero(~win)
            th = rng.uniform(0, 2 * np.pi, lost.size)
            c[lost], s[lost] = np.cos(th), np.sin(th)
            dep = tgt[win]
        else:
            x, y, dep = nx, ny, tgt
        trail.ravel()[:] += np.bincount(dep, minlength=gw * gh).astype(f32)
        trail = _diffuse(trail) * keep
        if step >= p["steps"] - p["avg"]:
            record(x, y)


def _splat(px, py, shape, acc):
    """Bilinear deposit in pixel coordinates, periodic, one bincount."""
    h, w = shape
    fx, fy = px - 0.5, py - 0.5
    ix, iy = np.floor(fx).astype(np.int64), np.floor(fy).astype(np.int64)
    tx, ty = (fx - ix).astype(np.float32), (fy - iy).astype(np.float32)
    x0, x1 = ix % w, (ix + 1) % w
    y0, y1 = iy % h, (iy + 1) % h
    acc += np.bincount(np.concatenate([y0 * w + x0, y0 * w + x1, y1 * w + x0, y1 * w + x1]),
                       np.concatenate([(1 - tx) * (1 - ty), tx * (1 - ty),
                                       (1 - tx) * ty, tx * ty]),
                       minlength=h * w)


def density(p, size, grid=None):
    """The drawn field: agent positions over the last steps, at `size`."""
    w, h = size
    gh = grid or GRID
    gw = int(round(gh * w / h))
    acc = np.zeros(h * w, np.float64)
    sx, sy = w / gw, h / gh

    def record(x, y):
        _splat(x.astype(np.float64) * sx, y.astype(np.float64) * sy, (h, w), acc)

    simulate(p, gw, gh, record)
    field = acc.reshape(h, w).astype(np.float32)
    return lib.smooth(field, p.get("blur", BLUR) * h) / p["avg"]


def caption(seed):
    p = PRESETS[seed % len(PRESETS)]
    # The population on a 16:10 panel, to the nearest thousand.
    n = round(p["density"] * GRID * round(GRID * 1.6), -3)
    rule = "one agent to a cell" if p["exclude"] else "agents free to crowd"
    return TITLE, (f"Jones's Physarum model: {n:,.0f} agents follow and lay a chemical"
                   f" trail; sensors {p['so']:.0f} cells ahead at +/-{p['sa']:g} deg,"
                   f" {rule}")


def generate(size, seed=0):
    return density(PRESETS[seed % len(PRESETS)], size)
