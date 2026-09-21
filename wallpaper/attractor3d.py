"""Shared drawing for the three-dimensional flows: chua, rossler, lorenzviews.

Not a generator -- it has no TITLE and render.py never loads it by name. It
holds the four things every continuous-time attractor in 3-D needs and none of
the physics: a fixed-step integrator, a camera, a frame, and a pen.

It exists because lorenz.py's recipe (few long orbits, path deposit, zscale,
gamma 0.4, defringe) carries over unchanged, but lorenz.py can only look along
a coordinate axis, and a double scroll or a folded band is a 3-D object whose
best view is oblique. It is a separate file rather than three copies because
the pen below departs from lib.deposit_path in one respect that matters, and a
fix to it should land once.

THE PEN. lib.deposit_path subdivides every segment of a trajectory by the
number the LONGEST one needs, and every sub-step is a bincount over the whole
83-megapixel grid at 4K x 3. That is correct and wasteful: a Rossler orbit
moves nine times faster through its fold than round its disc, so the disc --
most of the curve -- is cut nine times finer than it needs, and every one of
those passes pays for the full grid. Here each segment is cut into as many
pieces as ITS OWN length needs, and each piece is weighted 1/pieces, so
every step of the integrator still lays down exactly one unit of ink. The
picture is the same -- brightness is time spent in the pixel, as before --
and the cost is the drawn length of the curve rather than its length times
the worst case. Measured on lorenz.py's own orbits at 4K x 3: 190 s through
lib.deposit_path, 18 s here, the two fields equal to 5% (L1) once scaled.
"""

import numpy as np

import lib


def integrate(deriv, p, dt, steps, burn):
    """Classical RK4 at a fixed step, vectorised over an ensemble.

    p is (3, n): n orbits advanced together. Fixed step for the reason
    lorenz.py gives -- ink is laid per step, so an adaptive stepper would paint
    wherever it chose to slow down. Returns (steps, 3, n), burn-in discarded:
    the approach from an arbitrary start is not part of the attractor.
    """
    def step(p):
        k1 = deriv(p)
        k2 = deriv(p + dt / 2 * k1)
        k3 = deriv(p + dt / 2 * k2)
        k4 = deriv(p + dt * k3)
        return p + dt / 6 * (k1 + 2 * k2 + 2 * k3 + k4)

    for _ in range(burn):
        p = step(p)
    out = np.empty((steps,) + p.shape)
    for i in range(steps):
        p = step(p)
        out[i] = p
    return out


def view(pts, az, el, roll=0.0):
    """Orthographic camera. Returns screen-right and screen-UP coordinates.

    az turns the camera about the vertical axis, el raises it above the
    horizontal (90 looks straight down), roll turns the finished picture
    anticlockwise. Orthographic, not perspective: these are phase spaces, not
    scenes, and a vanishing point would invent a nearness that means nothing.
    The third return is depth, positive toward the camera.
    """
    a, e = np.radians(az), np.radians(el)
    right = np.array([-np.sin(a), np.cos(a), 0.0])
    up = np.array([-np.sin(e) * np.cos(a), -np.sin(e) * np.sin(a), np.cos(e)])
    sx = np.einsum("tkn,k->tn", pts, right)
    sy = np.einsum("tkn,k->tn", pts, up)
    toward = np.array([np.cos(e) * np.cos(a), np.cos(e) * np.sin(a), np.sin(e)])
    depth = np.einsum("tkn,k->tn", pts, toward)
    if roll:
        c, s = np.cos(np.radians(roll)), np.sin(np.radians(roll))
        sx, sy = c * sx - s * sy, s * sx + c * sy
    return sx, sy, depth


def frame(sx, sy, size, zoom=1.0, shift=(0.0, 0.0), clip=0.1):
    """The window, at the panel's aspect, that the drawing should fill.

    The box is taken between the clip and 100-clip percentiles rather than the
    extremes, so one orbit that strays furthest does not set the scale for all
    of them, and cover-fitted to the panel as lib.frame does. Then it is moved
    by `shift`, in fractions of that full-view window -- so a shift names the
    point of the whole picture that should sit at the centre -- and only then
    zoomed about that point.
    """
    lo_x, hi_x = np.percentile(sx[::7], [clip, 100 - clip])
    lo_y, hi_y = np.percentile(sy[::7], [clip, 100 - clip])
    x0, x1, y0, y1 = lib.frame(None, None, size, extent=(lo_x, hi_x, lo_y, hi_y),
                               fit="cover", zoom=1.0)
    cx = (x0 + x1) / 2 + shift[0] * (x1 - x0)
    cy = (y0 + y1) / 2 + shift[1] * (y1 - y0)
    hx, hy = (x1 - x0) / 2 / zoom, (y1 - y0) / 2 / zoom
    return cx - hx, cx + hx, cy - hy, cy + hy


def draw(sx, sy, size, extent, max_step=0.7, chunk=24_000_000, ink="time",
         weight=None):
    """Deposit continuous orbits, time-weighted, with UP at the top.

    sx, sy are (steps, orbits); each column is one orbit and is never joined
    to the next. Every segment is cut into ceil(length / max_step) pieces --
    0.7 px, as lib.deposit_path uses -- and each piece deposits 1/pieces with
    bilinear weights (lib.deposit's scheme), so the field is the time density
    whatever the local speed.

    ink="length" instead lays ink per unit of DRAWN length, so every strand is
    equally bright however fast it was traversed. For a flow whose speed
    varies by an order of magnitude round the attractor -- Rossler crawls on
    its disc and races up the fold -- time density leaves the fast part as a
    ghost, and the fast part is often the one the picture is about.

    Rows are filled from the TOP of the window down, so physical up is up.
    lib.histogram2d puts the lowest y in row 0 and so draws everything upside
    down unless the caller flips it.
    """
    w, h = size
    x0, x1, y0, y1 = extent
    px = (np.asarray(sx) - x0) / (x1 - x0) * w - 0.5
    py = (y1 - np.asarray(sy)) / (y1 - y0) * h - 0.5
    field = np.zeros(h * w)
    if px.size < 2:
        return field.reshape(h, w)

    ax, ay = px[:-1].T.ravel(), py[:-1].T.ravel()
    bx, by = px[1:].T.ravel(), py[1:].T.ravel()
    seglen = np.hypot(bx - ax, by - ay)
    n = np.maximum(1, np.ceil(seglen / max_step)).astype(np.int64)
    # A segment with neither end inside the window (plus one segment length of
    # margin) cannot touch it. Dropped before subdividing: cropping to fill
    # the panel throws away a good part of every projection, and those parts
    # would otherwise cost as much to draw as the parts that are shown.
    reach = n * max_step
    keep = ~(((ax < -reach) & (bx < -reach)) | ((ax > w + reach) & (bx > w + reach))
             | ((ay < -reach) & (by < -reach)) | ((ay > h + reach) & (by > h + reach)))
    ax, ay, bx, by, n = ax[keep], ay[keep], bx[keep], by[keep], n[keep]
    per = (1.0 if ink == "time" else seglen[keep]) / n
    if weight is not None:
        wv = np.asarray(weight)
        per = per * (0.5 * (wv[:-1] + wv[1:])).T.ravel()[keep]
    if n.size == 0:
        return field.reshape(h, w)

    # Chunked by sub-point count so memory is bounded however long the orbit.
    ends = np.cumsum(n)
    cuts = np.searchsorted(ends, np.arange(chunk, ends[-1], chunk))
    for s0, s1 in zip(np.r_[0, cuts], np.r_[cuts, n.size]):
        nn = n[s0:s1]
        seg = np.repeat(np.arange(s0, s1), nn)
        k = np.arange(nn.sum()) - np.repeat(np.cumsum(nn) - nn, nn)
        t = k / n[seg]
        fx = ax[seg] + (bx[seg] - ax[seg]) * t
        fy = ay[seg] + (by[seg] - ay[seg]) * t
        wt = per[seg]
        del seg, k, t
        ix = np.floor(fx).astype(np.int64)
        iy = np.floor(fy).astype(np.int64)
        tx, ty = fx - ix, fy - iy
        del fx, fy
        for dx, dy, ww in ((0, 0, (1 - tx) * (1 - ty)), (1, 0, tx * (1 - ty)),
                           (0, 1, (1 - tx) * ty), (1, 1, tx * ty)):
            cx, cy = ix + dx, iy + dy
            m = (cx >= 0) & (cx < w) & (cy >= 0) & (cy < h)
            field += np.bincount(cy[m] * w + cx[m], weights=(wt * ww)[m],
                                 minlength=h * w)
    return field.reshape(h, w)


def depth_weight(depth, floor):
    """Ink from `floor` at the back of the object to 1 at the front.

    A projection flattens the object, and where a near strand crosses a far
    one nothing says which is in front. Weighting ink by depth makes the near
    strands brighter, and because the palette runs from teal at low values to
    pink at high ones it also makes them WARMER -- the same cue as atmospheric
    perspective, from the ramp that is already there.
    """
    lo, hi = np.percentile(depth[::7], [0.5, 99.5])
    return floor + (1.0 - floor) * np.clip((depth - lo) / (hi - lo), 0.0, 1.0)
