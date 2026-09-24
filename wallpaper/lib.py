"""Shared machinery for wallpaper generators.

A generator's job is to produce a 2-D float array of "how much is here" — a
density, a field, an occupancy count. This module turns that into an image in
the active palette. Splitting it that way means a generator contains only the
physics, and every generator gets identical colour handling for free.

Dependencies are numpy and matplotlib ONLY, both already in the base pyfleet
venv (see packages/python). Nothing here needs scipy, Pillow or a system
python, because a wallpaper generator that pulls a dependency tree is a
wallpaper generator that stops working.

Why generated at all: a photograph has a licence, a fixed resolution and a
fixed palette. A simulation has none of those. It renders at the panel's exact
size, it is coloured from whichever palette is active, it is reproducible from
a seed, and it is ours because we computed it.
"""

import numpy as np
from matplotlib.colors import LinearSegmentedColormap

# How far the empty ground is allowed to travel from BG0 toward BG1. Low: this
# is a background for a background, and anything stronger competes with the
# structure drawn on top of it.
GROUND_LIFT = 0.75

# House defaults for colour, chosen by looking at a blend x saturation grid on
# a real desktop rather than by taste in the abstract.
#
# 2.25 is high, and deliberately so: blending structure toward a dark ground
# desaturates it, and every earlier attempt to fix "washed" by raising blend
# only made the image louder without making it more colourful. Saturation is
# the knob that actually answers that complaint. Exposure lifts value slightly
# on top.
#
# These are DEFAULTS. A generator that wants to be quieter sets its own, and a
# user who disagrees passes --saturation / --exposure or edits one number.
DEFAULT_SATURATION = 2.25
DEFAULT_EXPOSURE = 1.1


def load_palette(path):
    """Read a theme/*.env into {COOL_BG0: '#1A1A2E', ...}.

    The same flat format ergon-theme reads. Values may carry a trailing
    comment, which is why this takes the first whitespace-delimited token and
    not the rest of the line.
    """
    out = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            val = val.split()[0].strip()
            if val.startswith("#") and len(val) == 7:
                out[key.strip()] = val
    return out


def is_light(palette):
    """Is this palette's ground light?

    The SAME test bin/ergon-theme makes (Rec. 709 relative luminance of
    COOL_BG0, gamma-encoded, against half of 255), and deliberately so: a
    palette that the desktop treats as light while the wallpaper treats it as
    dark would put a Papirus-Light icon theme over a wallpaper built for a dark
    ground, which is the mismatch this function exists to stop.
    """
    h = palette["COOL_BG0"].lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return (2126 * r + 7152 * g + 722 * b) / 10000 > 127


# How far a light palette's ramp is pulled toward its own ground.
#
# The dark palettes arrive pre-quietened: theme/cool.env is the `cool` colormap
# pastelised toward WHITE at 0.68, so its ramp is already soft against a dark
# ground. The light palettes are not -- they borrow a scheme's ACCENTS, which
# were chosen to carry small text on paper, so they are saturated mid-darks.
# Dropped into the same pipeline they produce a magenta nodal line on cream:
# every complaint the pastelisation was invented to answer, in reverse.
#
# So they get the mirror of that treatment, toward the ground instead of toward
# white. 0.55 is where solarized-light's #D33682 stops reading as a warning and
# starts reading as a wallpaper.
LIGHT_CALM = 0.55

# PNG encoder settings for every wallpaper this module writes.
#
# The encode, not the colour, is what a recolour spends its time on. Measured on
# a real 1280x800 wallpaper, the whole palette-dependent computation -- lookup,
# ground, blend, dither -- costs 0.17s, against 0.52s to write the file.
#
# compress_level 3 rather than Pillow's default 6, and the two save paths here
# pay differently for it:
#
#   uncaptioned (plt.imsave)   0.429s -> 0.110s   1256 KB -> 1162 KB
#   captioned   (fig.savefig)  0.523s -> 0.242s   1256 KB -> 1398 KB
#
# So it is free on the first and costs about 10% on disk on the second, which is
# the one nearly every generator takes. That is the right side of the trade for
# a file written once and read by a compositor: 0.28s per image per palette
# against 140 KB, on a set where switching palette re-writes every background.
PNG_KW = {"compress_level": 3}


def ramp_cmap(palette, reverse=False, ramp="full"):
    """A colormap from the palette's five-step ramp, grounded in BG0.

    BG0 is the first stop rather than the ramp's own dark end, so that empty
    regions of the field land exactly on the desktop background and the image
    has no edge. A wallpaper whose corners are a slightly different dark from
    the compositor's is worse than one with no structure at all.

    On a LIGHT palette the same construction inverts: the ground is the bright
    end and the ramp runs downward into saturated accents, so sparse structure
    disappears into the paper while dense structure becomes a hard coloured
    line. See LIGHT_CALM.
    """
    # How many of the palette's colours the image may use.
    #
    # "full" -- all five ramp stops -- suits sparse structure: lines on an empty
    # ground, where each colour covers a small area and the ramp reads as depth.
    # On a SCREEN-FILLING field with fine filaments it is a disaster: every
    # colour appears everywhere at once and the result is rainbow noise. Those
    # want one hue ("mono": ground to the palette's accent) or two ("duo").
    if ramp == "mono":
        stops = [palette["COOL_BG0"], palette["COOL_ACCENT"]]
    elif ramp == "duo":
        stops = [palette["COOL_BG0"], palette["COOL_1"], palette["COOL_3"]]
    elif ramp == "warm":
        stops = [palette["COOL_BG0"], palette["COOL_3"], palette["COOL_4"]]
    else:
        stops = [palette["COOL_BG0"]] + [palette[f"COOL_{i}"] for i in range(5)]
    if reverse:
        stops = [stops[0]] + stops[1:][::-1]

    # Calm a light palette's ramp toward its own ground. See LIGHT_CALM.
    #
    # Applied to the ramp stops only, never to stops[0]: that one IS the ground
    # and blending it toward itself is a no-op that would only obscure the
    # intent. Done here rather than in the palette files because it is a
    # property of putting a scheme's accents on a wallpaper, not a correction to
    # the scheme -- theme/solarized-light.env still reproduces Solarized's
    # published values exactly, which theme/LICENSES.md commits us to.
    if is_light(palette):
        ground = stops[0].lstrip("#")
        g_rgb = [int(ground[i:i + 2], 16) for i in (0, 2, 4)]
        calmed = []
        for s in stops[1:]:
            c = s.lstrip("#")
            v = [int(c[i:i + 2], 16) for i in (0, 2, 4)]
            calmed.append("#%02X%02X%02X" % tuple(
                int(round(x + (gx - x) * LIGHT_CALM)) for x, gx in zip(v, g_rgb)))
        stops = [stops[0]] + calmed

    # Interpolated in LINEAR LIGHT, not in sRGB.
    #
    # Blending sRGB values directly is the usual cause of a gradient that
    # looks harsh: sRGB is perceptually encoded, so a straight lerp between
    # two stops moves quickly through some of the range and slowly through
    # the rest, and the joins between stops show as creases. Undoing the
    # transfer function, interpolating in the linear space where light
    # actually adds, and re-encoding gives even steps and no visible seams.
    rgb = np.array([
        [int(s.lstrip("#")[i:i + 2], 16) / 255 for i in (0, 2, 4)]
        for s in stops
    ])
    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)

    n = 512
    t = np.linspace(0, 1, n)
    src = np.linspace(0, 1, len(stops))
    out = np.stack([np.interp(t, src, lin[:, c]) for c in range(3)], axis=1)
    out = np.where(out <= 0.0031308, out * 12.92,
                   1.055 * np.maximum(out, 0) ** (1 / 2.4) - 0.055)
    return LinearSegmentedColormap.from_list("ergon", np.clip(out, 0, 1), N=n)


def zscale_limits(field, nsamples=20000, contrast=0.25, max_reject=0.5,
                  min_npixels=5, krej=2.5, max_iterations=5):
    """IRAF zscale: the display limits, from a fit to the sorted samples.

    The algorithm DS9 and IRAF use on astronomical frames, and it is here for
    the same reason it exists there: these fields have the same shape as a
    star field. A few cells hold the core and carry orders of magnitude more
    signal than anything else, and the structure worth seeing is in the faint
    tail. A percentile clip throws away the top and still stretches across the
    whole remaining range; zscale instead fits a line through the sorted pixel
    values, iteratively rejecting the points that deviate, and takes the slope
    of the SURVIVING bulk as the range to display. The core saturates, which
    is correct -- it is one cell in a thousand -- and the faint structure gets
    the contrast.

    contrast=0.25 is the IRAF default: the fitted slope is divided by it, so
    the displayed range is four times the bulk's spread. Lower shows more.
    """
    v = np.asarray(field, dtype=float).ravel()
    v = v[np.isfinite(v)]
    if v.size == 0:
        return 0.0, 1.0

    # Sample on a stride rather than randomly: reproducible, and no shuffling
    # of a large array.
    stride = max(1, v.size // nsamples)
    samples = np.sort(v[::stride])
    npx = samples.size
    if npx < min_npixels:
        return float(samples[0]), float(samples[-1])

    midpoint = (npx - 1) // 2
    med = samples[midpoint]

    x = np.arange(npx, dtype=float) - midpoint
    y = samples.astype(float)
    good = np.ones(npx, dtype=bool)
    slope = 0.0
    for _ in range(max_iterations):
        n = int(good.sum())
        if n < min_npixels or n < npx * (1 - max_reject):
            break
        slope, intercept = np.polyfit(x[good], y[good], 1)
        resid = y - (slope * x + intercept)
        sigma = resid[good].std()
        if sigma == 0:
            break
        new = good & (np.abs(resid) < krej * sigma)
        if new.sum() == good.sum():
            break
        good = new

    if slope == 0:
        return float(samples[0]), float(samples[-1])

    z1 = med + (slope / contrast) * (0 - midpoint)
    z2 = med + (slope / contrast) * ((npx - 1) - midpoint)
    return float(max(z1, samples[0])), float(min(z2, samples[-1]))


def normalise(field, gamma=0.45, clip=99.5, scale="linear"):
    """Field -> 0..1, with the long tail of a density compressed.

    Attractor densities are extremely peaked: a few cells collect orders of
    magnitude more visits than the rest, so a linear scale shows one bright
    smear on black and loses the structure that makes the thing worth looking
    at. The percentile clip drops the outliers and gamma lifts the floor.

    scale="log" goes further and is the right choice when the density spans
    orders of magnitude rather than a factor of a few. Lorenz is the case that
    forced this: linear-with-clip rendered the butterfly as a solid blob,
    because the two lobes are so much denser than the connecting sheet that
    clipping at the 99.5th percentile still left everything interesting in the
    top few percent of the range. Under log the lobes, the sheet and the
    unstable fixed points at the lobe centres are all visible at once.
    """
    field = np.asarray(field, dtype=float)
    if scale == "unit":
        # Already in 0..1: the generator did its own stretch, because the
        # image needed more than one (see bifurcation.py).
        return np.clip(field, 0.0, 1.0) ** gamma
    if scale == "equalize":
        # HISTOGRAM EQUALISATION: colour by rank, not by value.
        #
        # For a field whose values bunch up -- most pendulums in the phase map
        # flip quickly, so most pixels share nearly the same value -- any
        # value-based stretch hands most of the colour range to that bulk and
        # squeezes the interesting structure into a sliver at one end. Ranking
        # instead gives every colour an equal share of the lit pixels, so the
        # detail spreads across the whole ramp and no single colour floods the
        # screen. Empty pixels (0) are left out of the ranking and stay exactly
        # on the ground colour. gamma still applies after, to bias the share.
        out = np.zeros_like(field)
        lit = field > 0
        if lit.any():
            vals = field[lit]
            ranks = np.argsort(np.argsort(vals, kind="stable"), kind="stable")
            out[lit] = (ranks + 1) / vals.size
        return np.clip(out, 0.0, 1.0) ** gamma
    if scale == "zscale":
        # Empty cells must stay at exactly 0 so they land on the desktop
        # background; zscale's z1 is usually above zero, which would lift the
        # whole panel off the ground colour and put a visible rectangle on the
        # desktop. So the floor is forced to 0 and only z2 is taken from the
        # fit.
        #
        # Fitted on the LIT pixels only. The empty ground is not data: it is
        # where nothing was drawn. Including it made the fit resolution-
        # dependent -- at 8K the lines are thinner relative to the frame, ~75%
        # of pixels are empty, the sorted sample is dominated by zeros and the
        # ceiling collapsed BELOW the typical line pixel. Measured: Lorenz's z2
        # fell from 2.26 at 4K to 0.80 at 8K, pinning 71% of its lines to the
        # top of the ramp -- one solid colour -- while the same field at 4K
        # spread across it.
        lit = field[field > 0]
        _, z2 = zscale_limits(lit) if lit.size else (0.0, 0.0)
        if z2 <= 0:
            z2 = float(field.max()) or 1.0
        return np.clip(field / z2, 0.0, 1.0) ** gamma
    if scale == "log":
        # +1 so empty cells stay exactly 0 and land on the background.
        field = np.log1p(field)
    hi = np.percentile(field[field > 0], clip) if np.any(field > 0) else 1.0
    if hi <= 0:
        hi = 1.0
    return np.clip(field / hi, 0.0, 1.0) ** gamma


def prepare(field, gamma=0.45, scale="linear", soften=0.0, hue_smooth=0.0):
    """The half of a render that the palette has nothing to do with.

    Returns (v, hue, alpha). `alpha` is None when hue_smooth is off, which is
    the signal to colour straight from `v`.

    THIS IS THE EXPENSIVE HALF, and it is the reason this function exists
    separately from the colouring. It holds the field (295 MB at 4K), its
    downsample, SOFTEN's Gaussian and HUE_SMOOTH's two more -- and 47 of the 61
    generators ask for hue_smooth, 46 for soften, so that is the normal case
    rather than a corner of it. None of it depends on a single palette value.

    Re-deriving it per palette is what made `ergon theme <name>` re-render every
    background from scratch: measured at 1.9s per image per palette, against
    0.4s to do this once and about half a second to colour it afterwards. Cache
    this, colour on demand, and a palette switch stops being a render at all.
    """
    if soften > 0:
        field = smooth(np.asarray(field, dtype=np.float32), soften)
    v = normalise(field, gamma=gamma, scale=scale)
    if hue_smooth <= 0:
        return v, v, None
    # DEFRINGE: hue from the neighbourhood, opacity from the pixel.
    #
    # The colormap reads one number as both brightness and hue, so the soft
    # edge of a line -- lower in value than its core -- came out a different
    # COLOUR as well as dimmer: pink core, blue edge, cyan rim. Here the hue is
    # the value-weighted mean over a few pixels, which is the same across a
    # line's width and along its length, and the pixel's own value only sets
    # how far it is laid over the ground. An edge is then the line's colour
    # fading out, not another colour. In a uniform region the two agree and
    # nothing changes.
    vv = v.astype(np.float32)
    den = smooth(vv, hue_smooth)
    num = smooth(vv * vv, hue_smooth)
    hue = np.where(den > 1e-6, num / np.maximum(den, 1e-6), 0.0)
    alpha = np.where(hue > 1e-6, np.clip(v / np.maximum(hue, 1e-6), 0, 1), 0.0)
    return v, hue, alpha


def render(field, palette, out, blend=0.55, reverse=False, gamma=0.45,
           scale="linear", title=None, subtitle=None,
           saturation=1.0, exposure=1.0, ramp="full", soften=0.0,
           hue_smooth=0.0):
    """Write `field` as a wallpaper PNG in the palette's colours.

    Thin on purpose: it is prepare() then colourise(), and it exists so that
    generating a wallpaper for the first time and re-colouring a cached one
    cannot drift apart. A recolour calls the second half alone.
    """
    # SOFTEN: band-limit the field before any nonlinearity touches it.
    #
    # A line one pixel wide is not equally bright wherever it lies: centred on
    # a pixel it is one pixel at full value, straddling two it is two at half.
    # The stretch below is strongly nonlinear -- gamma 0.4 turns those halves
    # into 0.76 each -- so a straddling line carries half as much light again,
    # and a slightly tilted one alternates between the two along its length.
    # That is beading, and hundreds of near-parallel beaded lines are a moire
    # that no downsampling can remove, because it is in the image rather than
    # in the resampling. A Gaussian of ~0.8 px makes every line wide enough
    # that where it falls between pixels no longer changes its profile.
    v, hue, alpha = prepare(field, gamma=gamma, scale=scale, soften=soften,
                            hue_smooth=hue_smooth)
    return colourise(v, hue, alpha, palette, out, blend=blend, reverse=reverse,
                     ramp=ramp, saturation=saturation, exposure=exposure,
                     title=title, subtitle=subtitle)


def colourise(v, hue, alpha, palette, out, blend=0.55, reverse=False,
              ramp="full", title=None, subtitle=None,
              saturation=1.0, exposure=1.0):
    """The half of a render that IS the palette: a lookup, a ground, a caption.

    Takes prepare()'s output rather than a field, so a palette switch never
    touches the field, the downsample or any Gaussian. Everything here is a
    per-pixel operation on the panel-sized arrays.

    `blend` is how far toward full colour the structure is taken. It is well
    below 1 on purpose: this is a surface that windows sit on top of all day,
    and it has to stay quiet. The existing gradient uses 18%; structure carries
    more visual weight than a gradient, so it gets less headroom than the
    number alone suggests.
    """
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    cmap = ramp_cmap(palette, reverse=reverse, ramp=ramp)
    if alpha is not None:
        g0 = np.asarray(cmap(0.0)[:3])
        rgb = g0 + (cmap(hue)[..., :3] - g0) * alpha[..., None]
    else:
        rgb = cmap(v)[..., :3]
    del hue, alpha

    # The ground is a GRADIENT, not a flat fill.
    #
    # Flat BG0 everywhere makes the empty regions read as dead space, and on a
    # large panel a single unbroken colour across two thirds of the screen
    # looks like a missing image rather than a background. A slow diagonal lift
    # from BG0 toward BG1 -- the palette's own next surface tone, so it cannot
    # clash -- gives the emptiness somewhere to go. It is the same move the
    # original ergon-wallpaper gradient makes, which also keeps the generated
    # art and the no-image default looking like the same family.
    h_i, w_i = rgb.shape[:2]
    c0 = np.array([int(palette["COOL_BG0"][i:i + 2], 16) / 255 for i in (1, 3, 5)])
    c1 = np.array([int(palette.get("COOL_BG1", palette["COOL_BG0"])[i:i + 2], 16) / 255
                   for i in (1, 3, 5)])
    gy, gx = np.mgrid[0:h_i, 0:w_i]
    t = ((gx / max(1, w_i - 1)) + (gy / max(1, h_i - 1))) / 2.0
    # Eased, so there is no visible linear seam running corner to corner.
    t = (t * t * (3 - 2 * t))[..., None]
    bg = c0 + (c1 - c0) * t * GROUND_LIFT
    rgb = bg + (rgb - bg) * blend

    # SATURATION and EXPOSURE, after the blend.
    #
    # Blending toward BG0 is what keeps a wallpaper from competing with the
    # windows on it, but mixing a colour toward a dark grey desaturates as well
    # as darkens -- so everything came out looking washed, which is a different
    # complaint from "too bright" and needs a different knob. Raising blend
    # instead would just make it louder, not more colourful.
    #
    # Done in HSV so hue is untouched: the palette decides hue and nothing here
    # is entitled to move it. Saturation multiplies S, exposure multiplies V,
    # both clipped.
    #
    # Weighted by the STRUCTURE, so the empty ground is left alone. Applied
    # uniformly, a 2.25x saturation turned catppuccin's muted grey-blue base
    # into saturated navy: the wallpaper's background stopped matching the
    # desktop's, which is the one thing BG0 as the colormap's first stop exists
    # to guarantee -- and it made the whole image read as more extreme than the
    # structure alone ever was. At v = 0 the factor is exactly 1.
    if saturation != 1.0 or exposure != 1.0:
        from matplotlib.colors import rgb_to_hsv, hsv_to_rgb
        hsv = rgb_to_hsv(np.clip(rgb, 0, 1))
        wgt = np.clip(v, 0, 1)
        hsv[..., 1] = np.clip(hsv[..., 1] * (1 + (saturation - 1) * wgt), 0, 1)
        hsv[..., 2] = np.clip(hsv[..., 2] * (1 + (exposure - 1) * wgt), 0, 1)
        rgb = hsv_to_rgb(hsv)

    # Dither, for the same reason ergon-wallpaper dithers: a low-contrast image
    # spans few 8-bit levels and bands visibly on a large panel. One level of
    # noise breaks the steps without measurably costing file size.
    rng = np.random.default_rng(0)
    rgb = np.clip(rgb + (rng.random(rgb.shape) - 0.5) / 255.0 * 2.0, 0, 1)

    if not title:
        plt.imsave(out, rgb, pil_kwargs=PNG_KW)
        return out

    # Caption, bottom left.
    #
    # A wallpaper computed from a named system should say which one. Without
    # it these are abstract patterns; with it the desktop tells you it is
    # showing the Sun-Jupiter co-orbital region, which is the entire point of
    # a science OS generating its own backgrounds.
    #
    # Drawn through a figure rather than imsave because imsave writes an array
    # and cannot draw text. figsize * dpi is set to the exact pixel size and
    # the axes fill the canvas, so the output is pixel-for-pixel what imsave
    # would have written, plus the text.
    dpi = 100.0
    h_px, w_px = rgb.shape[:2]
    fig = plt.figure(figsize=(w_px / dpi, h_px / dpi), dpi=dpi)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.imshow(rgb, interpolation="nearest", aspect="auto")
    ax.set_axis_off()

    # DIM, not FG0: this is a label on a wallpaper, not a heading. It should be
    # legible when looked for and invisible when not.
    # FG1, not DIM, and at high alpha. The first version used DIM at 0.62 and
    # was unreadable on a busy background -- a label you have to hunt for is
    # not a label. It is still small and still bottom-left, which is enough to
    # keep it out of the way.
    # OUTLINED, not just coloured. Alpha and colour alone cannot make a label
    # readable over an unknown background: wherever the structure is bright the
    # text sits light-on-light and disappears, which is what happened at DIM,
    # then again at FG1. A stroke in the palette's own ground colour gives
    # every glyph its own dark edge, so it reads over the attractor and over
    # the empty corners alike -- the same trick a subtitle burned into video
    # uses, and for the same reason.
    import matplotlib.patheffects as pe
    col = palette.get("COOL_FG0", "#EEEEEE")
    ground = palette.get("COOL_BG0", "#000000")
    stroke = [pe.withStroke(linewidth=max(2.5, w_px / 380.0), foreground=ground,
                            alpha=0.85)]
    pad = max(22, int(w_px * 0.022))
    size = max(11.0, w_px / 110.0)

    # Title on top, subtitle beneath it. Written the other way round first,
    # which put the equation above the name and read as two unrelated labels.
    if subtitle:
        ax.text(pad, h_px - pad, subtitle, color=col, alpha=0.88,
                family="monospace", fontsize=size * 0.82, va="bottom",
                ha="left", path_effects=stroke)
        ax.text(pad, h_px - pad - size * 1.45, title, color=col, alpha=1.0,
                family="monospace", fontsize=size, va="bottom", ha="left",
                weight="bold", path_effects=stroke)
    else:
        ax.text(pad, h_px - pad, title, color=col, alpha=1.0,
                family="monospace", fontsize=size, va="bottom", ha="left",
                weight="bold", path_effects=stroke)

    fig.savefig(out, dpi=dpi, pad_inches=0, pil_kwargs=PNG_KW)
    plt.close(fig)
    return out


def frame(xs, ys, size, extent=None, pad=0.0, fit="cover", zoom=1.18):
    """The (x0, x1, y0, y1) window this trajectory should be drawn in.

    Split out from histogram2d so a generator can compute the window ONCE from
    a small sample and then accumulate billions of points into it in bounded
    memory. Holding the points first does not scale: 220 million points is
    3.5 GB of float64 before anything is binned.
    """
    w, h = size
    if extent is None:
        xr = xs.max() - xs.min()
        yr = ys.max() - ys.min()
        extent = (
            xs.min() - xr * pad, xs.max() + xr * pad,
            ys.min() - yr * pad, ys.max() + yr * pad,
        )
    x0, x1, y0, y1 = extent

    agot = (x1 - x0) / (y1 - y0)
    awant = w / h
    contain = fit == "contain"
    if (agot < awant) == contain:
        cx, half = (x0 + x1) / 2, (y1 - y0) * awant / 2
        x0, x1 = cx - half, cx + half
    else:
        cy, half = (y0 + y1) / 2, (x1 - x0) / awant / 2
        y0, y1 = cy - half, cy + half

    if zoom != 1.0:
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        hx, hy = (x1 - x0) / 2 / zoom, (y1 - y0) / 2 / zoom
        x0, x1, y0, y1 = cx - hx, cx + hx, cy - hy, cy + hy

    return x0, x1, y0, y1


def deposit(xs, ys, size, extent, out=None):
    """Accumulate points with BILINEAR weights. Antialiased by construction.

    Each point contributes to the four cells around it in proportion to how
    close it is to each -- a point halfway between two pixels lights both at
    half strength. Nothing lands wholly in one cell, so there is no aliasing
    to remove afterwards.

    This replaces np.histogram2d, which deposits into the NEAREST cell only.
    That is the correct thing for a histogram and the wrong thing for drawing:
    it quantises every sample to a pixel centre, which is exactly what made
    sparse regions render as a scatter of hard dots. The fix for that was
    supersampling plus a Gaussian blur -- three times the memory and a
    convolution, to undo damage caused by the accumulator. Depositing properly
    in the first place is cheaper AND better, and it is what every renderer
    that draws these systems smoothly actually does.

    Implemented with np.bincount rather than np.add.at: add.at is a scatter
    with correct duplicate handling and is roughly an order of magnitude
    slower, and bincount does the same job for a flattened index array.
    """
    w, h = size
    x0, x1, y0, y1 = extent
    field = np.zeros(h * w, dtype=np.float64) if out is None else out

    # -0.5 puts sample coordinates on pixel CENTRES, so a point at the centre
    # of a pixel deposits entirely into it rather than splitting across two.
    fx = (np.asarray(xs) - x0) / (x1 - x0) * w - 0.5
    fy = (np.asarray(ys) - y0) / (y1 - y0) * h - 0.5

    ix = np.floor(fx).astype(np.int64)
    iy = np.floor(fy).astype(np.int64)
    tx = fx - ix
    ty = fy - iy

    for dx, dy, wt in (
        (0, 0, (1 - tx) * (1 - ty)),
        (1, 0, tx * (1 - ty)),
        (0, 1, (1 - tx) * ty),
        (1, 1, tx * ty),
    ):
        cx, cy = ix + dx, iy + dy
        m = (cx >= 0) & (cx < w) & (cy >= 0) & (cy < h)
        if not m.any():
            continue
        field += np.bincount(cy[m] * w + cx[m], weights=wt[m],
                             minlength=h * w)
    return field.reshape(h, w) if out is None else field


def deposit_path(xs, ys, size, extent, out=None, max_step=0.7,
                 max_subdiv=6000):
    """Deposit a CONTINUOUS trajectory, subdividing so it never gaps.

    A solution of an ODE is a curve, not a cloud. Sampling it at the
    integrator's steps and depositing those samples draws a dotted line
    wherever the state is moving fast -- and the state is moving fastest
    exactly where the picture is most interesting. Lorenz shows this plainly:
    the outer sweep of each lobe is where the trajectory covers the most
    distance per step, so it is where the dots are most visible.

    Consecutive samples are joined and the segment subdivided until no piece
    is longer than max_step pixels, so the drawn curve is continuous whatever
    the timestep. That is the honest fix for "the steps are too coarse": the
    integrator's step is chosen for the dynamics, and the drawing step should
    be chosen for the raster.
    """
    w, h = size
    x0, x1, y0, y1 = extent
    xs = np.asarray(xs); ys = np.asarray(ys)

    # Segment lengths in PIXELS, so the subdivision is set by the raster.
    px = (xs - x0) / (x1 - x0) * w
    py = (ys - y0) / (y1 - y0) * h
    # axis=0, so a 2-D (steps, n_trajectories) array is treated as one path
    # PER COLUMN. Ravelling an ensemble first would join the end of one
    # trajectory to the start of the next and draw a line across the picture
    # between two unrelated orbits.
    d = np.hypot(np.diff(px, axis=0), np.diff(py, axis=0))
    # The MAXIMUM segment, not a percentile.
    #
    # 99.5 was used first, to stop one freak jump forcing thousands of
    # subdivisions. The cost is that the longest half percent of segments stay
    # under-resolved, and at 8K those are precisely the fast sweeps around the
    # outside of a lobe -- so the picture came out continuous everywhere except
    # the places the eye follows, which read as dashes. For an ODE at fixed dt
    # the segment length is bounded anyway, so the maximum is the honest
    # choice; the cap below is what protects against a genuine discontinuity.
    n = int(np.ceil(max(1.0, float(np.nanmax(d)) / max_step)))
    n = min(n, max_subdiv)

    if n <= 1:
        return deposit(xs, ys, size, extent, out=out)

    # One interpolated pass per sub-step, vectorised over every segment at
    # once. n is set from the 99.5th percentile rather than the maximum so a
    # single huge jump -- a map's discontinuity, or a close encounter -- does
    # not force thousands of subdivisions for the whole trajectory.
    field = np.zeros(h * w, dtype=np.float64) if out is None else out
    for i in range(n):
        t = i / n
        deposit(xs[:-1] + (xs[1:] - xs[:-1]) * t,
                ys[:-1] + (ys[1:] - ys[:-1]) * t,
                size, extent, out=field)
    return field.reshape(h, w) if out is None else field


def _gauss1d(sigma):
    r = max(1, int(round(3 * sigma)))
    x = np.arange(-r, r + 1, dtype=np.float32)
    k = np.exp(-0.5 * (x / sigma) ** 2)
    return k / k.sum()


def smooth(field, sigma):
    """Separable Gaussian blur, numpy only.

    This is what actually removes the dots, and no amount of extra sampling
    would. A hard-binned histogram is Poisson in every cell: where the orbit
    visits a pixel once or twice, the result is a speck, and the gamma applied
    later amplifies exactly those cells. Convolving before the downsample
    turns each sample into a small smooth contribution instead of a hit in one
    cell -- the cheap equivalent of splatting a kernel per point, which is how
    the smooth renders of these systems are actually made.

    Done at the SUPERSAMPLED resolution, so sigma is in subpixels and the
    structure is not softened at the scale anyone looks at it.
    """
    if sigma <= 0:
        return field
    k = _gauss1d(sigma)
    pad = len(k) // 2
    a = np.pad(field.astype(np.float32), pad, mode="edge")
    # Two 1-D passes rather than a 2-D kernel: separable, so it is O(2r) per
    # pixel instead of O(r^2), which at these resolutions is the difference
    # between seconds and minutes.
    out = np.empty_like(a)
    np.copyto(out, 0)
    for i, kv in enumerate(k):
        out[pad:-pad or None, :] += kv * a[i:i + field.shape[0], :]
    a2 = out
    out = np.zeros_like(a2)
    for i, kv in enumerate(k):
        out[:, pad:-pad or None] += kv * a2[:, i:i + field.shape[1]]
    return out[pad:-pad or None, pad:-pad or None]


def downsample(field, ss):
    """Area-average ss x ss blocks. The correct downsampling filter for this.

    A box average over the exact block is what an ideal sensor pixel does:
    every supersample inside the output pixel contributes equally and nothing
    outside it contributes at all. Point-sampling or bilinear resizing would
    reintroduce the aliasing the supersampling was done to remove.
    """
    h, w = field.shape[0] // ss, field.shape[1] // ss
    return field[:h * ss, :w * ss].reshape(h, ss, w, ss).mean(axis=(1, 3))


def histogram2d(xs, ys, size, extent=None, pad=0.0, fit="cover", zoom=1.18,
                ss=1, sigma=0.0, path=False):
    """Bin a trajectory into a (h, w) density, filling the panel.

    A trajectory is a list of points; the wallpaper is a raster. Binning rather
    than drawing lines is what makes the density -- where the system spends its
    time -- the thing you see, which is the interesting statement an attractor
    makes.

    fit="cover" CROPS to fill the frame. The first version fitted the whole
    attractor inside it instead, which is correct for a figure and wrong for a
    wallpaper: an attractor is rarely 16:10, so containing it left wide empty
    bands down both sides and the structure sat in a box in the middle of the
    screen. A wallpaper should reach the edges. Losing the outermost wisps of a
    lobe costs nothing -- they are the least-visited cells and the faintest
    pixels -- while the middle of the structure gets the whole panel.

    zoom > 1 pushes further in, past the bounding box, so the densest part of
    the structure is what fills the screen rather than its full extent.
    fit="contain" keeps the old behaviour for anything that genuinely needs its
    whole extent visible.
    """
    w, h = size
    if extent is None:
        xr = xs.max() - xs.min()
        yr = ys.max() - ys.min()
        extent = (
            xs.min() - xr * pad, xs.max() + xr * pad,
            ys.min() - yr * pad, ys.max() + yr * pad,
        )
    x0, x1, y0, y1 = extent

    agot = (x1 - x0) / (y1 - y0)
    awant = w / h
    contain = fit == "contain"
    # cover shrinks the axis with room to spare; contain widens the other one.
    if (agot < awant) == contain:
        cx, half = (x0 + x1) / 2, (y1 - y0) * awant / 2
        x0, x1 = cx - half, cx + half
    else:
        cy, half = (y0 + y1) / 2, (x1 - x0) / awant / 2
        y0, y1 = cy - half, cy + half

    if zoom != 1.0:
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        hx, hy = (x1 - x0) / 2 / zoom, (y1 - y0) / 2 / zoom
        x0, x1, y0, y1 = cx - hx, cx + hx, cy - hy, cy + hy

    # SUPERSAMPLE, then box-average down.
    #
    # A histogram binned straight to the panel is shot-noise limited: each
    # pixel holds a Poisson count, so even a well-sampled attractor renders
    # visibly grainy and the faint outer filaments break into speckle. Binning
    # at ss times the resolution and averaging blocks of ss*ss gives each
    # output pixel ss^2 times the counts and anti-aliases the filament edges in
    # the same pass, which is the difference between this and the smooth
    # renders these systems are usually shown in.
    #
    # ss=2 costs four times the histogram memory and almost no time -- the
    # expense here is generating the points, not binning them.
    # ss=3 where the panel is small enough to afford it. The supersampled
    # histogram is (h*ss)*(w*ss) float64, so 3 costs 2.25x the memory of 2 and
    # buys noticeably smoother filaments; above about 2.5 megapixels that is
    # hundreds of MB for a wallpaper and 2 is the sensible ceiling.
    if ss == 2 and w * h <= 2_500_000:
        ss = 3
    # Bilinear deposit, NOT np.histogram2d. See deposit() -- binning to the
    # nearest cell is what produced the dots that supersampling and blurring
    # were then added to hide. Depositing properly needs neither, so ss and
    # sigma default to 1 and 0: they remain only for a generator that wants
    # extra softening for its own reasons.
    hh, ww = h * ss, w * ss
    fn = deposit_path if path else deposit
    field = fn(xs, ys, (ww, hh), (x0, x1, y0, y1))

    # ANTIALIAS before downsampling. This is the whole difference between a
    # continuous-looking curve and a trail of dots.
    #
    # A box-average of a hard-binned histogram is not antialiasing: every
    # sample still lands wholly in one subpixel, so a sparse trajectory is a
    # string of isolated hits and the gamma applied at render time makes each
    # one a visible speck. Convolving at the supersampled resolution spreads
    # each sample over a small neighbourhood -- the cheap equivalent of
    # splatting a kernel per point -- and the curve closes up.
    #
    # This lives HERE, not in a generator, because every generator that bins a
    # trajectory needs it. It was first written inside clifford.py, which left
    # the other eight aliased and is exactly the bug this comment exists to
    # stop recurring.
    if sigma > 0:
        field = smooth(field, sigma)
    if ss > 1:
        field = downsample(field, ss)
    return field
