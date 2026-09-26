"""ERGON-62's FITS thumbnailer: the three shapes the card names -- a
table-only file and an all-NaN image refuse fast, a cube takes its first
plane, and a half-NaN frame still draws -- plus two regressions an
adversarial review found by actually running the render, not just checking a
PNG came out (`os.path.getsize(out) > 0` passed under a stretch that ignored
the file entirely): a BZERO/BSCALE frame, the ordinary raw-CCD layout, which
`memmap=True` refused outright, and yazi's own cache path, which has no
extension.

Astropy builds every fixture: a hand-rolled header is not what a real one
looks like. Measured during this card -- a minimal SIMPLE/END-only header,
no BITPIX/NAXIS, made `file`(1) call the file text/plain instead of FITS,
exactly the kind of gap a synthetic fixture would have hidden.
"""
from __future__ import annotations

import os
import sys

import matplotlib.image as mpimg
import numpy as np
import pytest
from astropy.io import fits

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
import ergon_fits_thumbnail as fth  # noqa: E402


def _write(tmp_path, hdul, name):
    p = str(tmp_path / name)
    hdul.writeto(p, overwrite=True)
    return p


def _distinct_levels(png_path):
    # A real stretch of real data has a broad, near-continuous spread of gray
    # levels. Rounding to 3dp and counting uniques catches what a size check
    # cannot: a stretch that clips everything to one or two flat levels
    # (NaN-poisoned percentiles, a hardcoded vmin/vmax, or ignoring the data
    # and drawing zeros all measured at 1-2 levels here; a real frame at 64px
    # measured >100) is a wrong-looking render even though it is a valid PNG.
    gray = mpimg.imread(png_path)[..., 0]
    return len(np.unique(np.round(gray, 3)))


@pytest.mark.parametrize("data", [
    np.random.default_rng(0).normal(100, 10, (64, 64)).astype("float32"),
    None,  # filled in below: half the frame NaN, as a dead-pixel mask would leave it
], ids=["plain", "nan-heavy"])
def test_image_renders(tmp_path, data):
    if data is None:
        data = np.random.default_rng(1).normal(0, 1, (64, 64)).astype("float32")
        data[::2] = np.nan
    path = _write(tmp_path, fits.HDUList([fits.PrimaryHDU(data)]), "img.fits")
    out = str(tmp_path / "out.png")
    fth.render(path, out, size=64)
    assert _distinct_levels(out) > 20  # a flat-clipped mutant measured 1-2


def test_bzero_scaled_image_renders(tmp_path):
    # ERGON-62 review: `fits.open(..., memmap=True)` makes astropy refuse ANY
    # scaled image ("Set memmap=False"), and this is not an edge case -- a
    # uint16 CCD frame is stored as int16+BZERO=32768 by convention. Measured
    # failing with astropy 8.0.1 before dropping the explicit memmap kwarg.
    raw = np.random.default_rng(2).integers(0, 60000, (64, 64), dtype=np.uint16)
    path = _write(tmp_path, fits.HDUList([fits.PrimaryHDU(raw)]), "u16.fits")
    assert fits.getheader(path)["BZERO"] == 32768  # sanity: this IS the scaled case
    out = str(tmp_path / "out.png")
    fth.render(path, out, size=64)
    assert _distinct_levels(out) > 20


def test_writes_extensionless_cache_path(tmp_path):
    # ERGON-62 review: yazi's cache key has no extension, and savefig() was
    # appending ".png" to it when format was left unset -- the file yazi
    # actually reads was never written. Measured: render('x.fits', cache)
    # left `cache` absent and `cache.png` present.
    data = np.random.default_rng(3).normal(100, 10, (32, 32)).astype("float32")
    path = _write(tmp_path, fits.HDUList([fits.PrimaryHDU(data)]), "img.fits")
    cache = str(tmp_path / "CACHEKEY")  # no suffix -- what ya.file_cache() hands the plugin
    fth.render(path, cache, size=32)
    assert os.path.exists(cache)
    assert not os.path.exists(cache + ".png")


def test_cube_takes_first_plane():
    cube = np.zeros((3, 32, 32), dtype="float32")
    cube[0] = 1.0
    cube[1:] = 99.0
    assert np.array_equal(fth._plane(cube), cube[0])


def test_cube_render_uses_first_plane(tmp_path):
    # The unit test above checks _plane() in isolation; this drives it
    # through render() end to end. Plane 0 carries real variance, the other
    # two are flat, so picking the wrong plane collapses to _distinct_levels
    # around 1-2 instead of >20 -- the same signal as a broken stretch.
    cube = np.full((3, 24, 24), 99.0, dtype="float32")
    cube[0] = np.random.default_rng(4).normal(100, 10, (24, 24))
    path = _write(tmp_path, fits.HDUList([fits.PrimaryHDU(cube)]), "cube.fits")
    out = str(tmp_path / "out.png")
    fth.render(path, out, size=24)
    assert _distinct_levels(out) > 20


@pytest.mark.parametrize("build", [
    lambda: fits.HDUList([fits.PrimaryHDU(), fits.BinTableHDU.from_columns(
        [fits.Column(name="a", format="D", array=np.arange(10.0))])]),
    lambda: fits.HDUList([fits.PrimaryHDU(np.full((16, 16), np.nan, dtype="float32"))]),
], ids=["table-only", "all-nan"])
def test_refuses_fast(tmp_path, build):
    path = _write(tmp_path, build(), "refuse.fits")
    out = str(tmp_path / "out.png")
    with pytest.raises(SystemExit):
        fth.render(path, out)
    assert not os.path.exists(out)
