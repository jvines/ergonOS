"""Mandelbrot set, deep zoom -- four places a long way down.

Magnified a million times and more, the set stops looking like itself. Near a
boundary point c it looks like the Julia set of that same c (Tan Lei, 1990,
for Misiurewicz points), which is why a spiral in seahorse valley has the
arms of a Julia set; and every so often the zoom lands on a small copy of the
whole set, a "minibrot", ringed with decorations that record the path taken
to reach it (Douady-Hubbard tuning). The escape-time machinery and the look
are mandelbrot.py's; this module only knows where to stand.

HOW THE PLACES WERE FOUND, not guessed. A minibrot is the solution of
z_p(c) = 0 for its period p -- its nucleus -- so it can be located exactly:
the period of the smallest-period copy near a point is the first p at which
a small disc of c, iterated with its radius carried along, covers 0; Newton
on z_p(c) then gives the nucleus to machine precision. Its size and
orientation come from the renormalisation estimate used by deep-zoom
software (Heiland-Allen):

    lambda = prod_{i<p} 2 z_i,    beta = 1 + sum_{k<p} 1/lambda_k,
    s = 1 / (beta lambda^2)

The copy is then approximately nucleus + s * M, with M the whole set in its
usual coordinates -- so framing it is a matter of choosing a window in M's
coordinates and mapping it through s. The rotation is arg s, which is why
every copy below stands upright with its needle to the left, as the whole
set is always drawn. It also means a copy's OWN valleys can be visited: the
elephants below are the elephant valley of a period-17 copy, reached at the
same coordinates (0.285, 0) as the main set's elephant valley.

Precision: plain float64, no perturbation theory. At the deepest frame here,
2.5e-9 wide, one supersampled pixel is 2e-13, about two thousand units in
the last place of c; iteration round-off stays well below that for the few
thousand steps these views need.
"""

import cmath

import mandelbrot as M

TITLE = "Mandelbrot set, deep zoom"
# The per-view caption comes from caption(seed) below; this is the fallback.
SUBTITLE = "z -> z^2 + c, magnified a million times and more"

SCALE = "unit"
# Line settings for DENSE pictures. The whole-set look (full-brightness core
# 1.0 px, gamma 0.6; see mandelbrot.py) turned every region where filaments
# are closer than a pixel -- the band along a minibrot, the elephants' heads
# -- into a flat pink fog. A narrow core and a gentler gamma keep the
# texture there; these pictures have almost no isolated thin lines, which
# are what the wide core was for.
GAMMA = 0.8
CORE = 0.4
SOFTEN = 0.8
HUE_SMOOTH = 3.0
BLEND = 0.85

# Two kinds of view. A plain one is a centre and a width. A minibrot one is a
# nucleus and period plus a window in the copy's own coordinates: `local` is
# its centre (-0.75 centres the copy itself) and `span` its width, both in
# units where the whole set is 2.5 wide. maxiter from the fraction of pixels
# still running at 90% of the limit, measured: 0 for the spiral, 4e-5 for
# the two copies, and 5e-4 for the elephants even at 20000 -- escape past a
# cusp is parabolic and has a long tail. Those pixels sit on the copy's edge
# and draw as part of it; tripling maxiter to chase them would triple the
# six minutes that view already takes.
#
# Only the views chosen on a real desktop are here. Elephant valley (a
# period-17 copy, nucleus 0.29373677602754694 - 0.014975229760356331i,
# local 0.285, span 0.05, maxiter 20000) was good but pruned for space; a
# period-31 copy by the 1/3 limb's branch point was built and never shown.
VIEWS = [
    dict(name="minibrot", what="a period-30 copy of the set in seahorse valley",
         nucleus=complex(-0.77468025307807331, -0.13742327527435791), period=30,
         local=-0.75, span=10.0, maxiter=6000),
    dict(name="seahorse", what="seahorse valley, a spiral arm",
         centre=complex(-0.7746806106269039, -0.1374168856037867),
         width=3e-6, maxiter=5000),
]


def size_estimate(nucleus, period):
    """Complex size of the minibrot at `nucleus`: |s| scale, arg s rotation."""
    z, lam, beta = 0j, 1 + 0j, 1 + 0j
    for _ in range(1, period):
        z = z * z + nucleus
        lam = 2 * z * lam
        beta = beta + 1 / lam
    return 1 / (beta * lam * lam)


def frame(view):
    """(centre, width, rotation) of a view."""
    if "centre" in view:
        return view["centre"], view["width"], 0.0
    s = size_estimate(view["nucleus"], view["period"])
    return view["nucleus"] + s * view["local"], abs(s) * view["span"], cmath.phase(s)


def caption(seed):
    """(title, subtitle) for a view -- from the frame alone, no escape field,
    so a re-colour from a saved field gets the same caption as the render."""
    view = VIEWS[seed % len(VIEWS)]
    centre, width, _ = frame(view)
    # Magnification against the whole set, which is about 3 wide.
    mag = f"{3.0 / width:.1e}".replace("e+0", "e").replace("e+", "e")
    return TITLE, (f"{view['what']},  c = {M.cstr(centre, 12)},  "
                   f"magnified {mag}")


def generate(size, seed=0, **kw):
    view = VIEWS[seed % len(VIEWS)]
    centre, width, rot = frame(view)
    nu, de = M.escape_field(size, centre, width, rot, maxiter=view["maxiter"])
    return M.compose(nu, de, width, core=CORE)
