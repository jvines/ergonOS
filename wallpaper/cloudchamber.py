"""Cloud chamber -- one event, as the droplet trails it leaves in a magnetic field.

A charged particle crossing supersaturated vapour leaves ions behind it, and
droplets condense on the ions. In a field B along the camera's line of sight
the track is a circle of radius

    r = p_perp / (q B)        (r in cm = p[MeV/c] / 3B[T] for unit charge)

so the picture is a momentum measurement. As the particle slows the circle
tightens. Everything here is that one statement, followed step by step:

  * collision energy loss from the Bethe formula (ICRU 37's form for
    electrons), which is roughly constant for a fast particle and rises as
    1/beta^2 as it stops -- the reason an electron's spiral closes into a
    tangled knot and a proton's track fattens at its end;
  * bremsstrahlung for electrons, from the complete-screening spectrum,
    sampled photon by photon, so a spiral occasionally steps inward where a
    hard photon left;
  * multiple Coulomb scattering, Highland's width, as a random kick per step:
    it is what makes the slow end of every electron wander;
  * delta rays: knock-on electrons from the 1/T^2 Rutherford spectrum, sent
    off at the angle two-body kinematics requires, each followed in turn --
    the little hooks along every fast track. All of them are electrons, so
    all of them curl the same way.

THE MEDIUM is argon at 100 atm in a 1.5 T field, the panel 80 cm tall, and
the pressure is not decoration. Two ratios decide whether an electron draws a
spiral at all. The fraction of its momentum lost per turn is 2 pi (dE/dx) /
0.3B -- independent of the chamber's size -- and in a 1 atm gas it is a
fraction of a percent: the same circle three hundred times. And against that
shrinkage, multiple scattering walks the circle's centre about by
r theta_0 per turn; the ratio of the two goes as 1 / sqrt(rho r), so a
sparse gas wanders further per turn than it shrinks and the spiral comes out
as a ball of yarn. That was measured, not guessed: at 20 atm the pair drew
exactly that. By 80-100 atm the loops nest. The density effect on dE/dx is
neglected: it trims the relativistic rise and changes nothing visible.

The EVENT is composed; the physics is not. A 4 GeV/c pi- comes in from the
top and hits an argon nucleus: a star of two slow protons (short, fat,
fattening further as they stop), a pi+ that sweeps out of the chamber, a
slow pi- that curls, stops, and is captured by another nucleus -- the small
three-pronged star at the end of its hook -- and a pi0, whose photon
converts some way off into the e+e- pair: the V that becomes the two
spirals, opening in opposite senses because the charges are opposite, and
pointing back at the star because the photon came from it. A cosmic muon
crosses unrelated, and two Compton electrons from stray gammas curl alone.
Every radius follows from the momentum given; every kink, hook and wander
from the seed. The beam is traced back from the vertex along its own
circle, so even at 4 GeV/c it arrives exactly where the star is.

DRAWN as droplets, not lines. Droplets are laid along each track at a density
proportional to the ionisation, so a fast track is a beaded string and a slow
one a continuous bar; each is a small anti-aliased disc (pen.py), and discs
combine by maximum, so where droplets crowd the trail closes up without
blowing out. Heavier ionisation also widens the trail, as the extra ions
diffuse sideways before the droplets form. Colour is the particle's remaining
kinetic energy on a log scale: cool where it is fast, warm where it is about
to stop -- so each spiral warms as it winds in.
"""

import math

import numpy as np

TITLE = "Cloud chamber"
SUBTITLE = ("a pion star, and the e+e- pair from its pi0;   r = p / qB,   "
            "B = 1.5 T,  argon at 100 atm")

# The field arrives already toned, 0..1 (see generate): droplet discs carry
# the colour of the energy they were made at.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
# No SOFTEN: every droplet is an analytic disc with a Gaussian edge at least
# two pixels across. HUE_SMOOTH keeps a beaded string one colour across its
# gaps, so the beading shows as opacity rather than as hue flicker.
SOFTEN = 0.0
HUE_SMOOTH = 3.0
# Band-limited already: nothing finer than the droplets' own soft edge.
SUPERSAMPLE = 1

# Droplet geometry, as fractions of the panel height (4K: x 2400 = pixels).
# Wider than a hairline on purpose: under HUE_SMOOTH a line's colour is the
# mean over its profile, and a 1-px trail showed at 0.7 of its value, which
# pinned every track to the cool end of the ramp.
DROP_R = 0.85 / 2400      # flat core radius of one droplet
SOFT = 1.0 / 2400         # its Gaussian edge
SPACING = 1.7 / 2400      # mean droplet spacing on a minimum-ionising track
LATERAL = 0.5 / 2400      # sideways scatter of droplets on that track
MIN_SPACING = 0.3 / 2400  # dense tracks stop adding droplets here and widen

# Colour: log kinetic energy, T_HOT (and below) -> 1, T_COLD (and above) -> V0.
T_HOT, T_COLD, V0 = 2.0, 300.0, 0.28

# Physics constants, MeV and cm.
ME, MMU, MPI, MP = 0.51099895, 105.658, 139.570, 938.272
KBETHE = 0.307075                 # 4 pi N_A r_e^2 m_e c^2, MeV cm^2/mol
ZA, IEXC = 18.0 / 39.948, 188e-6  # argon: Z/A and mean excitation energy
RHO1, X0_GCM2 = 1.661e-3, 19.55   # argon density at 1 atm, 20 C; X0 in g/cm^2
TCUT = 0.2                        # delta rays followed above this energy
MASS = {"e": ME, "mu": MMU, "pi": MPI, "p": MP}

# Positions are in panel heights from the panel centre, x right and y up;
# angles in degrees; momenta in MeV/c. "cdip" is cos of the dip out of the
# plane: the projected radius is p cos(dip) / qB. ang="photon" starts a
# track along the line from the vertex, as a converted photon's pair must.
EVENTS = {
    "star": dict(
        B=1.5, atm=100.0, height_cm=80.0,
        vertex=(-0.40, 0.34),
        tracks=[
            # the incoming beam particle: it ARRIVES at the vertex heading `ang`,
            # having come `back` panel heights along its circle
            dict(kind="pi", q=-1, p=4000, to="vertex", ang=-120, back=0.44),
            # the star: two protons, two charged pions
            dict(kind="p", q=+1, p=360, at="vertex", ang=-98, cdip=0.97),
            dict(kind="p", q=+1, p=280, at="vertex", ang=150, cdip=0.9),
            dict(kind="pi", q=+1, p=320, at="vertex", ang=32, cdip=0.98),
            dict(kind="pi", q=-1, p=125, at="vertex", ang=-150, cdip=0.97,
                 # stops, and is captured: a small star of its own
                 capture=[dict(kind="p", q=+1, p=240, ang=110, cdip=0.9),
                          dict(kind="p", q=+1, p=185, ang=215, cdip=0.9),
                          dict(kind="p", q=+1, p=123, ang=-35, cdip=0.8)]),
            # a pi0 photon converts here into the pair (the V)
            dict(kind="e", q=-1, p=110, at=(0.12, -0.04), ang="photon", cdip=0.99),
            dict(kind="e", q=+1, p=75, at=(0.12, -0.04), ang="photon", cdip=0.99),
            # unrelated: a cosmic muon, and two Compton electrons
            dict(kind="mu", q=+1, p=1500, start=(0.66, 0.62), ang=-98),
            dict(kind="e", q=-1, p=4.0, at=(-0.68, -0.34), ang=60, cdip=0.9),
            dict(kind="e", q=-1, p=3.0, at=(0.62, 0.34), ang=200, cdip=0.9),
        ]),
}

# (event, random seed) per background. The seed is part of the picture: it
# decided every scattering kick, photon and knock-on electron.
VIEWS = [("star", 3), ("star", 2)]


def _stopping(T, m, rho):
    """Mean collision stopping power, MeV/cm."""
    k = KBETHE * ZA * rho
    if m == ME:
        # ICRU 37 for electrons (Moller scattering, identical particles).
        tau = T / ME
        b2 = tau * (tau + 2) / (tau + 1) ** 2
        f = 1 - b2 + (tau * tau / 8 - (2 * tau + 1) * math.log(2)) / (tau + 1) ** 2
        L = math.log(tau * tau * (tau + 2) / (2 * (IEXC / ME) ** 2)) + f
        return 0.5 * k / b2 * max(L, 1.0)
    g = 1 + T / m
    b2 = 1 - 1 / (g * g)
    tmax = 2 * ME * b2 * g * g / (1 + 2 * g * ME / m + (ME / m) ** 2)
    L = 0.5 * math.log(2 * ME * b2 * g * g * tmax / IEXC ** 2) - b2
    return k / b2 * max(L, 0.5)


def _fly(tr, ev, box, rng, out, depth=0):
    """Follow one charged particle; append its path to `out`, recursing into
    the delta rays it knocks out. Path arrays: x, y (cm), T (MeV), and the
    energy it deposits per cm of PROJECTED path."""
    m, z, cdip = MASS[tr["kind"]], tr["q"], tr.get("cdip", 1.0)
    B, rho = ev["B"], RHO1 * ev["atm"]
    x0 = X0_GCM2 / rho
    x, y, th = tr["x"], tr["y"], math.radians(tr["ang"])
    p = tr["p"]
    T = math.sqrt(p * p + m * m) - m
    tstop = 0.012 if m == ME else 0.3
    xs, ys, Ts, qs = [], [], [], []
    x_lo, x_hi, y_lo, y_hi = box
    # Tracks may start outside the panel (the beam, the muon) and fly in, so
    # only LEAVING it ends one: once inside, then outside.
    inside, run, smax = False, 0.0, tr.get("smax", 1e9)
    while T > tstop and run < smax:
        now = x_lo < x < x_hi and y_lo < y < y_hi
        if inside and not now:
            break
        inside = inside or now
        if run > 3 * (x_hi - x_lo) and not inside:
            break
        p = math.sqrt(T * (T + 2 * m))
        E = T + m
        beta = p / E
        # Signed curvature of the projection, 1/cm: B out of the page turns a
        # positive charge clockwise.
        kap = -z * 3.0 * B / (p * cdip)
        ds = min(0.1, 0.03 / abs(kap))          # projected step: ~200 a turn
        dl = ds / cdip                          # true path length
        dedx = _stopping(T, m, rho)
        xs.append(x); ys.append(y); Ts.append(T); qs.append(dedx / cdip)

        dE = dedx * dl
        if m == ME and T > 1.0:
            # Bremsstrahlung, complete screening: dN/dy = (4/3 (1-y) + y^2)/y
            # per radiation length. Photons below y = 0.02 as a continuum,
            # harder ones one at a time (4.41 per X0 above that).
            dE += E * dl / x0 * 0.0264
            if rng.random() < 4.41 * dl / x0:
                while True:
                    yb = 0.02 ** rng.random()           # log-uniform proposal
                    if rng.random() < (1 - yb) + 0.75 * yb * yb:
                        break
                dE += yb * E
        # Multiple scattering: Highland's projected width for this step.
        th0 = 13.6 / (beta * p) * abs(z) * math.sqrt(dl / x0)
        th += kap * ds + th0 * rng.standard_normal()
        x += ds * math.cos(th)
        y += ds * math.sin(th)
        run += ds

        # Delta rays above TCUT: Rutherford 1/T^2 up to the kinematic limit.
        if depth == 0:
            tmx = T / 2 if m == ME else \
                2 * ME * p * p / (ME * ME + m * m + 2 * ME * E)
            if tmx > TCUT:
                rate = 0.5 * KBETHE * ZA * rho / beta ** 2 * (1 / TCUT - 1 / tmx)
                if rng.random() < rate * dl:
                    td = 1 / (1 / TCUT - rng.random() * (1 / TCUT - 1 / tmx))
                    pd = math.sqrt(td * (td + 2 * ME))
                    ct = min(1.0, td * (E + ME) / (pd * p))
                    st = math.sqrt(1 - ct * ct)
                    cp = math.cos(2 * math.pi * rng.random())
                    _fly(dict(kind="e", q=-1, p=pd, x=x, y=y,
                              ang=math.degrees(th + math.atan2(st * cp, ct)),
                              cdip=max(0.2, math.hypot(ct, st * cp))),
                         ev, box, rng, out, depth + 1)
        T -= dE
    # A particle that STOPS inside may leave something behind: a pi- at rest
    # is captured by a nucleus, which breaks up into short, dense prongs.
    if T <= tstop and inside:
        for spec in tr.get("capture", ()):
            _fly(dict(spec, x=x, y=y), ev, box, rng, out, depth)
    if len(xs) > 1:
        out.append(tuple(np.array(a) for a in (xs, ys, Ts, qs)))


def _droplets(path, h_cm, qmin, rng):
    """Droplet centres, radii and values along one path, in cm."""
    xs, ys, Ts, qs = path
    seg = np.hypot(np.diff(xs), np.diff(ys))
    ratio = qs[:-1] / qmin                          # ionisation / minimum
    sp = SPACING * h_cm
    dens = np.minimum(ratio / sp, 1.0 / (MIN_SPACING * h_cm))
    lam = np.concatenate([[0.0], np.cumsum(dens * seg)])
    # Gamma(3) gaps: droplets less regular than a lattice and less clumped
    # than a Poisson string, which read as noise rather than condensation.
    gaps = rng.gamma(3.0, 1 / 3.0, int(lam[-1] * 1.3) + 16)
    t = np.cumsum(gaps)
    t = t[t < lam[-1]]
    if t.size == 0:
        return None
    i = np.clip(np.searchsorted(lam, t, side="right") - 1, 0, seg.size - 1)
    f = (t - lam[i]) / np.maximum(lam[i + 1] - lam[i], 1e-12)
    x = xs[i] + f * (xs[i + 1] - xs[i])
    y = ys[i] + f * (ys[i + 1] - ys[i])
    T = Ts[i] * np.exp(f * np.log(Ts[i + 1] / Ts[i]))
    # Heavier ionisation: more ions diffusing sideways before condensation.
    wide = np.minimum(ratio[i], 40.0) ** 0.33
    nx, ny = -(ys[i + 1] - ys[i]) / seg[i], (xs[i + 1] - xs[i]) / seg[i]
    off = rng.standard_normal(t.size) * LATERAL * h_cm * wide
    r = DROP_R * h_cm * np.exp(0.25 * rng.standard_normal(t.size)) * wide ** 0.5
    v = V0 + (1 - V0) * np.clip(np.log(T_COLD / T) / np.log(T_COLD / T_HOT), 0, 1)
    return x + off * nx, y + off * ny, r, v


def caption(seed):
    return TITLE, SUBTITLE


def generate(size, seed=0, jobs=None, view=None):
    import pen

    name, rng_seed = view or VIEWS[seed % len(VIEWS)]
    ev = EVENTS[name]
    w, h = size
    H = ev["height_cm"]
    A = w / h
    box = (-0.5 * A * H * 1.03, 0.5 * A * H * 1.03, -0.515 * H, 0.515 * H)
    vx, vy = (c * H for c in ev["vertex"])
    qmin = 1.52 * RHO1 * ev["atm"]          # minimum ionisation, MeV/cm
    drops = []
    for i, spec in enumerate(ev["tracks"]):
        tr = dict(spec)
        if "start" in tr:
            tr["x"], tr["y"] = (c * H for c in tr["start"])
        elif tr.get("to") == "vertex":
            # The beam ends where it interacts. It is not aimed along a
            # straight line -- even at 4 GeV/c it bends by several pixels
            # over the panel -- but traced BACK along its own circle from the
            # vertex, so it arrives there exactly. (Energy lost on the way
            # changes its radius by a fraction of a percent.)
            kap = -tr["q"] * 3.0 * ev["B"] / (tr["p"] * tr.get("cdip", 1.0))
            L = tr["back"] * H
            th1 = math.radians(tr["ang"])
            th0 = th1 - kap * L
            tr["x"] = vx - (math.sin(th1) - math.sin(th0)) / kap
            tr["y"] = vy + (math.cos(th1) - math.cos(th0)) / kap
            tr["ang"], tr["smax"] = math.degrees(th0), L
        else:
            at = tr["at"]
            tr["x"], tr["y"] = (vx, vy) if at == "vertex" else (at[0] * H, at[1] * H)
        if tr.get("ang") == "photon":
            # A converted photon travelled in a straight line from the vertex.
            tr["ang"] = math.degrees(math.atan2(tr["y"] - vy, tr["x"] - vx))
        # Each track draws from its OWN stream, keyed by the view's seed and
        # its place in the list, so re-aiming one prong cannot reshuffle the
        # kicks and photons that shaped another's spiral.
        paths = []
        _fly(tr, ev, box, np.random.default_rng([rng_seed, i]), paths)
        rd = np.random.default_rng([rng_seed, i, 1])
        drops += [d for d in (_droplets(pth, H, qmin, rd) for pth in paths) if d]
    x, y, r, v = (np.concatenate(c) for c in zip(*drops))

    # cm about the centre -> pixels, y down.
    s = h / H
    px = (x + 0.5 * A * H) * s
    py = (0.5 * H - y) * s
    return pen.draw(px, py, px, py, r * s, r * s, v, size, soft=SOFT * h,
                    jobs=jobs).astype(np.float64)
