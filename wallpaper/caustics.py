"""Caustics -- sunlight through a rippled water surface, on the floor of a pool.

Every patch of a curved water surface is a weak lens. A crest bulging upward
converges the light that refracts through it, and with a focal length in
water of about n / ((n - 1) kappa) -- four times the radius of curvature --
a ripple a few millimetres high and a hand's width long focuses at about a
metre: the depth of a pool. Where neighbouring rays cross on the floor the
mapping from surface to floor folds over, its Jacobian vanishes, and the
intensity, which is the density of rays, becomes infinite along a line. Those
lines are the caustics: the bright net on the bottom of every sunny pool,
drawn around dark cells where the troughs have spread the light thin.

The surface is a sum of plane waves -- linear wave theory, a snapshot of a
random sea -- with wavelengths of a few centimetres to a few tens and a
power-law spectrum, directions spread about a breeze. It is scaled by one
number that says how hard it focuses, S = (1 - 1/n) depth rms(lap h): the
depth over the focal length of a typical crest (a cylindrical crest of
exactly rms curvature brings its light to a line on the floor at S = 1).
Below one the floor is a soft shimmer; just above it the net forms, one
line per crest; well above, every line has split into its two folds, the
bands between them cross, and the net turns into a tangle.

RAYS, NOT A FORMULA. Parallel sunlight lands on a fine grid on the surface --
nine rays per pixel of the panel, at every resolution -- and each ray is bent
by the exact vector form of Snell's law at the local normal (n = 1.333), run
to the floor, and deposited there bilinearly. The intensity is how many
arrive. The surface slope at each ray is a sum over the waves, which
separates into rows and columns and so is a matrix product per band of rays.

THE SUN IS NOT A POINT. Its disc, 0.53 degrees across and 0.40 inside the
water, blurs the floor pattern by a disc a few millimetres wide at a metre's
depth; that, and nothing else, sets how wide a caustic line is. The deposit is
convolved with the limb-darkened solar disc, which is also what makes the
lines smooth rather than a grid of ray hits.
"""

import numpy as np

import lib

TITLE = "Caustics"
SUBTITLE = "sunlight refracted through ripples, focused into a net on the floor of a pool"

# Lines on a dark ground: the net is the structure, the cells are empty, and
# the field's own floor -- the light the troughs still let through -- is
# subtracted in generate() so the cells land on the desktop colour. The house
# saturation and exposure for lines on empty ground.
#
# RAMP "duo", ground to sky to mauve: the lines are sky, the knots mauve, and
# the picture reads as light in water. The full ramp was rendered from the same
# field and is louder -- teal lines, blue edges, pink knots, three colours on
# every line -- which is its own case for choosing it.
SCALE = "unit"
GAMMA = 1.0
BLEND = 0.85
RAMP = "duo"
SOFTEN = 0.0          # the solar disc already band-limits every line
HUE_SMOOTH = 3.0
SUPERSAMPLE = 1       # nine rays a pixel and the sun's disc do the anti-aliasing

N_WATER = 1.333
SUN_RADIUS = np.radians(0.2665)   # angular radius of the solar disc, in air
LIMB = 0.6                        # linear limb darkening, I(mu) = 1 - LIMB (1 - mu)
RAYS = 3                          # rays per pixel, per axis

# Per view: panel height and depth in metres, sun elevation and azimuth in
# degrees, the wave band (shortest, peak, longest wavelength in m), the
# spectral slope of amplitude with wavenumber, the breeze direction (deg) and
# its spreading exponent (cos^2s; 0 = isotropic), the number of waves, S the
# focusing strength, and draw, the random seed of the waves -- part of the
# picture, so pinned with the view.
#
# S was tried from 1.15 to 3.2. At 2.4 and above every line of the net has
# split into two folds with a bright band between, the bands cross, and the
# floor is a tangle of glassy tubes with pink clots where they meet; 1.25 is a
# net of single lines, the way a pool floor looks with the sun high.
# "pool" is a metre of floor under you; "floor" twice that, deeper, so the
# lines -- whose width is the sun's disc, fixed in metres -- come out finer
# against a net twice as dense. A sun 32 degrees up was tried and shears the
# net into ribbons, which reads as something other than a pool.
#
# Only "pool" was chosen on a real desktop; "floor" (panel 2.2, depth 1.5,
# sun (55, 200), wind 40, draw 7) was shown and pruned.
VIEWS = [
    dict(name="pool", panel=1.1, depth=1.2, sun=(62, 20), band=(0.06, 0.16, 0.45),
         slope=-3.0, wind=15.0, spread=1.0, waves=160, S=1.25, draw=11),
]

# Tone, in units of the mean intensity on the floor: the FLOOR_Q quantile --
# the light the cells still get -- goes to the ground colour, TOP to the top
# of the ramp, linearly. The knots where lines cross run to ~15x the mean:
# TOP 4 to 6 clipped them into flat blots; 15 with the faint bands between
# paired folds lifted (gamma 0.8) turned the net to glass tubes; 10, linear,
# keeps the lines, and the knots as small hot points.
FLOOR_Q = 0.5
TOP = 10.0
TONE_GAMMA = 1.0


def caption(seed):
    v = VIEWS[seed % len(VIEWS)]
    _, _, A = _waves(v, v["panel"])
    rms = np.sqrt(np.sum(np.abs(A) ** 2) / 2) * v["panel"] * 1000
    return (TITLE, f"sunlight through ripples of {rms:.1f} mm rms, focused on a pool floor"
                   f" {v['depth']:.1f} m down;  sun {v['sun'][0]} degrees up")


def _waves(v, unit):
    """(kx, ky, complex amplitude) of each wave, lengths in panel heights,
    amplitudes scaled so the focusing strength is S."""
    rng = np.random.default_rng(v["draw"])
    lo, pk, hi = (b / unit for b in v["band"])
    # Wavenumbers log-uniform over the band, weighted by the power law above
    # the peak and rising to it from below, so the peak wavelength dominates.
    k = 2 * np.pi / np.exp(rng.uniform(np.log(lo), np.log(hi), v["waves"]))
    kp = 2 * np.pi / pk
    amp = (k / kp) ** np.where(k > kp, v["slope"], 2.0)
    # Directions about the breeze, cos^(2s) spreading, drawn by rejection.
    th = np.empty(0)
    while th.size < v["waves"]:
        t = rng.uniform(-np.pi, np.pi, 4 * v["waves"])
        keep = rng.uniform(0, 1, t.size) < np.abs(np.cos(t / 2)) ** (2 * v["spread"])
        th = np.concatenate([th, t[keep]])
    th = th[:v["waves"]] + np.radians(v["wind"])
    A = amp * np.exp(2j * np.pi * rng.uniform(0, 1, v["waves"]))
    kx, ky = k * np.cos(th), k * np.sin(th)
    # rms Laplacian of the surface; the threshold focal depth is n/((n-1) kappa).
    lap = np.sqrt(np.sum(np.abs(A) ** 2 * k ** 4) / 2)
    depth = v["depth"] / unit
    A *= v["S"] / (depth * (1 - 1 / N_WATER) * lap)
    return kx, ky, A


def _sun_kernel(shape, radius):
    """The limb-darkened solar disc as a convolution kernel, centred at [0, 0]
    of a periodic grid, anti-aliased at the rim, unit sum."""
    h, w = shape
    y = np.fft.fftfreq(h, 1 / h)[:, None]
    x = np.fft.fftfreq(w, 1 / w)[None, :]
    r = np.hypot(x, y) / radius
    mu = np.sqrt(np.clip(1 - r * r, 0, 1))
    k = (1 - LIMB * (1 - mu)) * np.clip((1 - r) * radius + 0.5, 0, 1)
    return k / k.sum()


def generate(size, seed=0, rays=RAYS, floor_q=FLOOR_Q, top=TOP, tone_gamma=TONE_GAMMA, **kw):
    v = dict(VIEWS[seed % len(VIEWS)], **kw)
    w, h = size
    unit = v["panel"]                       # metres per panel height
    depth = v["depth"] / unit               # everything below in panel heights
    kx, ky, A = _waves(v, unit)

    # The sun: its direction of travel, down into the water.
    el, az = np.radians(v["sun"][0]), np.radians(v["sun"][1])
    d = np.array([np.cos(el) * np.cos(az), np.cos(el) * np.sin(az), -np.sin(el)])
    eta = 1 / N_WATER

    def refract(nx, ny):
        """Vector Snell's law at the upward normal (-hx, -hy, 1)/|.|."""
        nz = 1 / np.sqrt(1 + nx * nx + ny * ny)
        nx, ny = nx * nz, ny * nz
        ci = -(nx * d[0] + ny * d[1] + nz * d[2])
        ct = np.sqrt(1 - eta * eta * (1 - ci * ci))
        f = eta * ci - ct
        return eta * d[0] + f * nx, eta * d[1] + f * ny, eta * d[2] + f * nz

    # Where a flat surface would send the light: the pattern is drawn relative
    # to that, so the panel shows the floor under the panel.
    t0 = refract(np.zeros(1), np.zeros(1))
    shift = np.array([t0[0][0], t0[1][0]]) * depth / -t0[2][0]

    # Rays that can land on the panel start within a margin of it: five rms
    # displacements, plus the sun's blur.
    rms_tilt = np.sqrt(np.sum(np.abs(A) ** 2 * (kx ** 2 + ky ** 2)) / 2)
    blur = depth * np.tan(SUN_RADIUS / N_WATER)
    margin = 5 * rms_tilt * (1 - eta) * depth + 2 * blur
    aspect = w / h
    pad = int(np.ceil(2 * blur * h)) + 2      # deposit border, pixels
    W, H = w + 2 * pad, h + 2 * pad
    ext = (-aspect / 2 - pad / h, aspect / 2 + pad / h, -0.5 - pad / h, 0.5 + pad / h)

    step = 1.0 / (h * rays)                   # ray spacing, panel heights
    xs = np.arange(-aspect / 2 - margin, aspect / 2 + margin, step)
    ys = np.arange(-0.5 - margin, 0.5 + margin, step)
    Ex = np.exp(1j * np.outer(kx, xs))        # (M, nx)
    field = np.zeros(H * W)
    for j in range(0, ys.size, 192):
        yy = ys[j:j + 192]
        Ey = np.exp(1j * np.outer(yy, ky))    # (ny, M)
        # Slopes of h = Re sum A e^{i k.x}: dh/dx = Re sum i kx A e^{i k.x}.
        hx = -((Ey * (A * kx)) @ Ex).imag
        hy = -((Ey * (A * ky)) @ Ex).imag
        tx, ty, tz = refract(hx, hy)
        s = depth / -tz
        X = xs[None, :] + tx * s - shift[0]
        Y = yy[:, None] + ty * s - shift[1]
        lib.deposit(X.ravel(), Y.ravel(), (W, H), ext, out=field)
    field = field.reshape(H, W) / rays ** 2

    # Convolve with the sun's disc (periodic; the border pad absorbs the wrap).
    ker = _sun_kernel((H, W), max(blur * h, 0.6))
    field = np.fft.irfft2(np.fft.rfft2(field) * np.fft.rfft2(ker), s=(H, W))
    I = field[pad:pad + h, pad:pad + w]
    I = I / I.mean()

    # The light between the lines goes to the ground colour; the net keeps the ramp.
    lo = np.quantile(I[::7, ::7], floor_q)
    return np.clip((I - lo) / (top - lo), 0.0, 1.0) ** tone_gamma
