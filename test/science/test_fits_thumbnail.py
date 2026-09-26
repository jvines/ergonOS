"""ERGON-62's FITS thumbnailer: the three shapes the card names -- a
table-only file and an all-NaN image refuse fast, a cube takes its first
plane, and a half-NaN frame still draws.

Astropy builds every fixture: a hand-rolled header is not what a real one
looks like. Measured during this card -- a minimal SIMPLE/END-only header,
no BITPIX/NAXIS, made `file`(1) call the file text/plain instead of FITS,
exactly the kind of gap a synthetic fixture would have hidden.
"""
from __future__ import annotations

import os
import sys

import numpy as np
import pytest
from astropy.io import fits

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
import ergon_fits_thumbnail as fth  # noqa: E402


def _write(tmp_path, hdul, name):
    p = str(tmp_path / name)
    hdul.writeto(p, overwrite=True)
    return p


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
    assert os.path.getsize(out) > 0


def test_cube_takes_first_plane():
    cube = np.zeros((3, 32, 32), dtype="float32")
    cube[0] = 1.0
    cube[1:] = 99.0
    assert np.array_equal(fth._plane(cube), cube[0])


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
