"""2-D Ising model at the critical temperature — equilibrium, not dynamics.

    H = -J sum_<ij> s_i s_j,   s_i = +/-1

on a square lattice with periodic boundaries, sampled at Onsager's exact
critical point T_c = 2J / ln(1 + sqrt(2)) = 2.26918... (Onsager 1944).

Everything else here is a trajectory or a pattern: a system going somewhere,
photographed on the way. This is a thermal ensemble -- one sample from the
Boltzmann distribution, with no time in the picture at all. That is the reason
to have it, and it is also why it looks like nothing else in the set.

What criticality buys visually is the absence of a length scale. Gray-Scott has
exactly one: the diffusion rates fix a stripe width and the whole image is that
width repeated. At T_c the correlation length diverges instead, so the domains
are scale-free: clusters of fractal dimension 187/96 (Stella & Vanderzande
1989) bounded by domain walls that are SLE(3) curves of dimension 11/8 (Beffara
2008). Islands inside islands inside islands, with no size that is the
characteristic one. Magnify any crop back to full size, rescale its contrast,
and it has the statistics of the whole -- which is exactly what lib.normalise
does to it anyway. Nothing else here makes that statement.

Updates are checkerboard heat-bath (Glauber 1963), not single-site Metropolis.
The square lattice is bipartite, so every site on one sublattice has all four
neighbours on the other: given one sublattice, the spins of the other are
conditionally independent and can all be resampled at once. A full sweep is
therefore two vectorised passes, and the per-site loop that makes a textbook
Metropolis implementation useless at this resolution never appears.
"""

import numpy as np

# Exactly half the panel lands on background, by construction below -- but the
# other half is solid, not filamentary, and a large contiguous patch of colour
# pulls the eye harder than the same ink spent on threads. So this sits between
# the attractors, which leave the panel nearly empty and can take 0.55, and
# Gray-Scott, which covers every pixel and has to whisper at 0.20. Checked
# against both at 1440x960 rather than guessed.
TITLE = "Ising model at criticality"
SUBTITLE = "T_c = 2 / ln(1 + sqrt 2)"

BLEND = 0.46

# Onsager's T_c, in units of J/k_B. Not a fitted or eyeballed number: it is the
# exact self-dual point of the 2-D square-lattice model.
TC = 2.0 / np.log1p(np.sqrt(2.0))

# Block-spin radius in lattice cells; the seed picks one, and also picks a
# different sample from the same ensemble.
#
# Every preset is at T_c exactly, and the temperature is deliberately not a
# knob. The coarse-to-fine construction below is only valid at the fixed point:
# doubling a lattice is an inverse RG step, and an inverse RG step preserves the
# configuration's statistics only where the correlation length is scale-free.
# A few percent off T_c, xi is some fixed number of cells, doubling multiplies
# it by two, and the carried-up structure is then at the wrong scale for the
# temperature it is supposed to be at. Off-critical Ising is a legitimate
# picture but it is not this algorithm's picture, and faking it would be worse
# than not having it.
#
# What is left to vary is the radius, which is the RG scale: it sets the
# smallest surviving feature, so changing it is literally zooming. That the
# four presets differ in magnification and still look like each other is the
# whole claim the critical point makes.
PRESETS = {
    "critical": 3,
    "grain":    2,
    "clusters": 4,
    "islands":  6,
}


def _sublattices(h, w):
    """The two checkerboard colours as boolean masks.

    Both lattice dimensions must be even or the periodic wrap joins a site to
    itself on the seam, the sublattices stop being independent, and the update
    silently stops sampling the right distribution. Every lattice built below
    is even by construction.
    """
    y, x = np.ogrid[:h, :w]
    black = ((y + x) & 1).astype(bool)
    return black, ~black


def _equilibrate(s, sweeps, table, rng):
    """Heat-bath sweeps in place. Loops over time only; never over sites."""
    black, white = _sublattices(*s.shape)
    for _ in range(sweeps):
        for mask in (black, white):
            # Neighbour sum on the periodic lattice. Four int8 spins sum to an
            # even integer in [-4, 4], so this cannot overflow and the heat-bath
            # probability has only five possible values -- a five-entry table
            # instead of an exp() over half a million sites, twice per sweep.
            n = (np.roll(s, 1, 0) + np.roll(s, -1, 0)
                 + np.roll(s, 1, 1) + np.roll(s, -1, 1))
            p = table[(n + 4) // 2]
            u = rng.random(s.shape, dtype=np.float32)
            new = np.where(u < p, np.int8(1), np.int8(-1)).astype(np.int8)
            # Only this sublattice is resampled; the other is what the
            # probabilities were conditioned on.
            np.copyto(s, new, where=mask)


def _lattice_side(pixels, scale, unit=64):
    """Cells along one axis: pixels/scale, rounded up to a multiple of `unit`."""
    cells = (pixels + scale - 1) // scale
    return max(unit, ((cells + unit - 1) // unit) * unit)


def _box(a, r):
    """Separable box blur with periodic wrap, O(pixels) whatever r is.

    Prefix sums rather than a convolution because the radius is large and the
    cost must not grow with it. Periodic to match the lattice's own boundaries:
    a zero-padded blur would darken the panel edges into a visible frame.
    """
    for axis in (0, 1):
        n = a.shape[axis]
        k = min(r, n // 2)
        if k < 1:
            continue
        pad = np.concatenate(
            (np.take(a, np.arange(n - k, n), axis=axis),
             a,
             np.take(a, np.arange(k), axis=axis)),
            axis=axis,
        )
        c = np.cumsum(pad, axis=axis)
        c = np.concatenate((np.zeros_like(np.take(c, [0], axis=axis)), c), axis=axis)
        a = (np.take(c, np.arange(2 * k + 1, n + 2 * k + 1), axis=axis)
             - np.take(c, np.arange(n), axis=axis)) / (2 * k + 1)
    return a


def generate(size, seed=0, scale=3, relax=200, radius=None):
    if radius is None:
        radius = PRESETS[list(PRESETS)[seed % len(PRESETS)]]

    # Simulated below panel resolution, for a different reason than Gray-Scott:
    # that pattern has an intrinsic wavelength, this one has none. What sets the
    # smallest visible feature here is the coarse-graining radius, so simulating
    # finer than a few cells per smoothing kernel buys detail that the smoothing
    # then destroys, at nine times the cost.
    #
    # The lattice is rounded UP on both counts: up to the panel, so the upscaled
    # field always covers it and only ever needs cropping; and up to a multiple
    # of 64, so that halving it five times still lands on an even lattice, which
    # the checkerboard requires at every level.
    w, h = size
    gw, gh = _lattice_side(w, scale), _lattice_side(h, scale)

    # Critical slowing down is the whole difficulty. Local spin flips relax a
    # mode of wavelength L in ~L^2.17 sweeps (z = 2.1665, Nightingale & Blote
    # 1996), so equilibrating a 960x640 lattice from random would take millions
    # of sweeps and no amount of vectorising saves it. Instead equilibrate a
    # small lattice properly and double it repeatedly, replicating each spin
    # into a 2x2 block. The long-wavelength structure -- the expensive part --
    # is carried up intact, and at T_c it is still correct after rescaling,
    # because that is what a renormalisation-group fixed point means. Only the
    # short-wavelength modes are wrong at each new level, and those relax in
    # tens of sweeps. This is the coarse-to-fine half of multigrid Monte Carlo
    # (Goodman & Sokal 1986) and it is what makes this affordable at all.
    bw, bh, levels = gw, gh, 0
    while levels < 5 and bw % 2 == 0 and bh % 2 == 0 and min(bw, bh) >= 40:
        bw, bh, levels = bw // 2, bh // 2, levels + 1

    # P(s = +1 | neighbours) for each of the five possible local fields.
    local_field = np.array([-4.0, -2.0, 0.0, 2.0, 4.0])
    table = (1.0 / (1.0 + np.exp(-2.0 * local_field / TC))).astype(np.float32)

    rng = np.random.default_rng(seed)
    s = np.where(rng.random((bh, bw)) < 0.5, np.int8(1), np.int8(-1)).astype(np.int8)

    # Six autocorrelation times at the coarsest level, which is the only level
    # that starts from an infinite-temperature configuration and so the only one
    # that has to pay the full L^z. The cap is there for small panels, where the
    # doubling loop bottoms out on a larger base lattice than 2880x1920's 30x20
    # and 6 L^z would run into the tens of thousands of sweeps for a smoke test.
    _equilibrate(s, min(20000, int(6 * max(bw, bh) ** 2.17)), table, rng)
    for _ in range(levels):
        s = np.repeat(np.repeat(s, 2, 0), 2, 1)
        _equilibrate(s, relax, table, rng)

    # Raw +/-1 spins are pixel noise on a panel; the physically meaningful
    # object is the block-spin magnetisation (Kadanoff 1966), the local average
    # that the RG itself works with. Three box passes approximate a Gaussian of
    # that radius by the central limit theorem, at three linear passes instead
    # of a real convolution. A critical field survives this: smoothing removes
    # the scales below the radius and leaves every scale above it, which is
    # exactly the structure worth showing.
    m = s.astype(np.float32)
    for _ in range(3):
        m = _box(m, radius)

    field = np.repeat(np.repeat(m, scale, 0), scale, 1)
    # One more blur at panel resolution, radius equal to the upscale factor, to
    # dissolve the block edges the repeat introduced. Nearest-neighbour is right
    # for Gray-Scott, whose fronts are genuinely sharp; here the sharpness would
    # be an artefact of the lattice, which is not a thing the model has.
    field = _box(field, scale)[:h, :w]

    # What gets plotted is the FLUCTUATION about the mean, not the order
    # parameter. A finite critical lattice is almost always lopsided -- the
    # magnetisation distribution at T_c is bimodal at +/- L^(-1/8), which is
    # still 0.4 at L = 960 -- and that offset is the box, not the physics: it
    # vanishes in the thermodynamic limit. The scale-free object is the
    # fluctuation m - <m>, whose correlations are the ones that diverge.
    # The median rather than the mean, and taken after the crop rather than
    # before, so the centring is exact on the pixels actually shown: half the
    # panel is structure and half is ground whatever phase this seed fell into.
    # It also disposes of the Z2 ambiguity -- flipping every spin swaps which
    # half is lit, and the two are the same picture.
    field -= np.median(field)

    # The below-median half sits at zero, which the ramp grounds in the desktop
    # background, so the zero contour becomes the edge of the visible structure.
    # That contour is the fractal object: the same curve at every magnification,
    # which is the only reason this system is here.
    #
    # Squared, because lib.normalise applies gamma 0.45 and that gamma exists
    # for attractor densities, which are heavy-tailed and need their floor
    # lifted hard. A smoothed field has no tail: run through the same gamma raw,
    # every domain interior saturates at the top of the ramp and the image
    # posterises into two flat tones. Squaring first makes the effective
    # exponent 0.9, so the rendered colour tracks the magnetisation nearly
    # linearly and the interiors keep their gradient.
    return np.maximum(field, 0.0) ** 2
