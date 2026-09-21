"""Julia sets -- one map, every starting point.

    z -> z^2 + c,   c fixed,   z0 = the pixel

The Mandelbrot set varies c and starts every orbit at 0; a Julia set fixes c
and varies the start. The filled Julia set is the starts that stay bounded,
and its boundary J_c is where the dynamics is chaotic -- repelling cycles are
dense in it, and any neighbourhood of a point of J_c is spread over the
whole plane by iteration (Fatou, Julia, 1918-19). The two pictures are tied
together by one theorem: J_c is connected exactly when c is in the Mandelbrot
set, and a dust (a Cantor set) when it is not.

The four classics:
  * Douady's rabbit, c = -0.123 + 0.745i, inside the period-3 bulb: an
    attracting 3-cycle, so the interior is three families of ears, each
    meeting the next at a point where three of them touch.
  * the dendrite, c = i, on the boundary: no interior at all. The critical
    orbit lands on a repelling cycle (i -> -1+i -> -i -> -1+i), so J_c is a
    tree, and the picture is all branches.
  * the basilica, c = -1, centre of the period-2 bulb: an attracting 2-cycle
    through the critical point, a string of pinched lobes along the axis.
  * c = -0.8 + 0.156i, just outside the set above the period-2 bulb: J_c is
    a dust, but a dust arranged as double spirals, because c sits in the
    spiralling part of the set's boundary.

Everything else -- the escape count, the distance estimate, the look -- is
mandelbrot.py's, with the derivative taken with respect to z0 rather than c.
"""

import mandelbrot as M

TITLE = "Julia set"
# The per-preset caption comes from caption(seed) below; this is the fallback.
SUBTITLE = "z -> z^2 + c from every starting point"

SCALE = "unit"
SOFTEN = 0.8
HUE_SMOOTH = 3.0
BLEND = 0.85
# REVERSED ramp: the fast-escaping tips come out pink and mauve, the deep
# junctions and dense cores blue and aqua. Chosen by looking at the rabbit,
# the basilica and the dendrite both ways: in the forward ramp a thin Julia
# set is teal and blue from end to end and reads cold and faint; reversed,
# its extremities carry the warm colour and the drawing has somewhere to go.
# It also sets the Julia sets apart from the Mandelbrot pictures, which keep
# the forward ramp and put pink in their depths. The spirals are the
# exception that works both ways -- forward (render.py has no flag to undo
# REVERSE, so recolour the saved field) gives pink starburst hubs and sky
# tips; the rabbit forward came out aqua-tipped and violet, and worse.
REVERSE = True
# Between the whole set's 0.6 (thin lines, see mandelbrot.py) and the deep
# views' 0.8 (dense filaments): these presets are some of each.
GAMMA = 0.7

# (name, c, rotation, frame width, maxiter, line core, line pen). Every J_c is
# symmetric under z -> -z, so the frame is centred on 0. Rotation lays the
# long axis along the panel; upright, the rabbit and the dendrite sit in a
# square with two thirds of the panel empty. Widths fill a 16:10 panel,
# trimming at most the tips.
#
# The dendrite is a Z: a trunk between two three-way junctions, each sending
# two arms out at ~115-135 degrees to it. Laid along the diagonal (the first
# version), both junctions' arms fold toward the same two corners and the
# other two quarters of the panel are empty whatever the zoom. Turned so the
# trunk runs nearly across the panel, the four arms splay toward the four
# corners. -0.95 rather than the fully level -1.12, which ran the lower-left
# arm through the caption.
#
# The line (core + Gaussian pen, in 4K pixels, see mandelbrot.compose) is
# set per set, because the two kinds want opposite things:
#   * the rabbit and the dendrite are thin curves on empty ground, and at
#     core 1.0 they were the dimmest pictures of the lot. 1.8 + 0.9 gives
#     them weight; at 2.4 the rabbit's small ear loops close into blobs.
#   * the spirals are a dust whose points, in the arms and the spoke hubs,
#     lie closer together than a pixel. ANY flat core there paints every
#     pixel of those regions at full value and the hubs came out as solid
#     aqua discs (core 0.4) or solid spokes (core 0.15). With no core and a
#     0.2 px shoulder only the sub-pixel samples that nearly touch the dust
#     light up, so a hub's spokes stay separate right into its centre and the
#     arms keep their inner structure as tone rather than a slab.
#   * a basilica (c = -1, core 1.0 with mandelbrot's default pen) was built
#     and never shown; it is not in the table. Only views chosen on a real
#     desktop are.
PRESETS = [
    ("spirals", complex(-0.8, 0.156), 0.0, 3.10, 5000, 0.0, 0.2),
    ("dendrite", complex(0.0, 1.0), -0.95, 2.80, 3000, 1.8, 0.9),
    ("Douady rabbit", complex(-0.123, 0.745), -0.40, 3.00, 3000, 1.8, 0.9),
]


def caption(seed):
    """(title, subtitle) from the preset alone, so a re-colour from a saved
    field -- which never calls generate() -- gets the same caption."""
    name, c = PRESETS[seed % len(PRESETS)][:2]
    return TITLE, f"{name},  z -> z^2 + c,  c = {M.cstr(c, 4)}"


def generate(size, seed=0, **kw):
    name, c, rot, width, maxiter, core, pen = PRESETS[seed % len(PRESETS)]
    nu, de = M.escape_field(size, 0j, width, rot, maxiter=maxiter, julia=c)
    return M.compose(nu, de, width, pen=pen, core=core)
