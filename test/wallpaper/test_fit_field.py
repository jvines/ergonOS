"""A stored field reaches the panel at the panel's size, cut and averaged exactly.

The approved backgrounds ship as 16:10 fields at 3840x2400 (ERGON-74), and
render.py used to downsample a field only by a whole factor at the same aspect.
Anything else -- 2560x1600 is 1.5x, the Framework is 3:2, most monitors are
16:9 -- was coloured at the field's full 9.2M pixels: about fifteen seconds an
image, sixty-nine images per palette switch, for the compositor to crop away.

COVERS: lib.fit_field crops to the panel's aspect around the centre, area-
averages at fractional factors without losing or inventing signal, and is
exactly downsample() at whole ones; it never enlarges; load_field reads the
shipped .npz and widens it; and render.py, handed a shipped .npz, writes an
image at the panel's size.

DOES NOT COVER: that a shipped field colours the image that was approved. That
needs the 8K masters, which live on the NAS, and wallpaper/ship.py checks it
when a field is made.
"""
from __future__ import annotations

import os
import subprocess
import sys

import numpy as np
import pytest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "wallpaper"))

import lib  # noqa: E402


@pytest.fixture
def field():
    return np.random.default_rng(1).random((240, 384)) * 100.0


def test_whole_factor_is_downsample_exactly(field):
    assert np.array_equal(lib.fit_field(field, 192, 120), lib.downsample(field, 2))


def test_fractional_factor_keeps_the_signal(field):
    out = lib.fit_field(field, 256, 160)            # 1.5x
    assert out.shape == (160, 256)
    assert out.mean() == pytest.approx(field.mean(), rel=1e-12)
    flat = lib.fit_field(np.full((240, 384), 7.25), 256, 160)
    assert np.ptp(flat) == 0 and flat[0, 0] == pytest.approx(7.25)


def test_box_average_by_hand():
    # Three pixels into two: each output covers one and a half of them.
    out = lib._area_axis(np.array([[1.0, 2.0, 3.0]]), 2, 1)
    assert out == pytest.approx(np.array([[4 / 3, 8 / 3]]))


@pytest.mark.parametrize("w,h", [(192, 108), (188, 125)])  # 16:9 and 3:2
def test_crops_to_the_panel_aspect_around_the_centre(w, h):
    f = np.zeros((240, 384))
    f[100:140, 172:212] = 1.0                        # a block at the centre
    out = lib.fit_field(f, w, h)
    assert out.shape == (h, w)
    ys, xs = np.nonzero(out > 0.5)
    assert abs(xs.mean() - (w - 1) / 2) < 1.0 and abs(ys.mean() - (h - 1) / 2) < 1.0


def test_never_enlarges(field):
    assert lib.fit_field(field, 768, 480).shape == (240, 384)


def test_load_field_widens_a_shipped_npz(tmp_path, field):
    p = tmp_path / "julia-0-384x240.npz"
    np.savez_compressed(p, field=field.astype(np.float16))
    got = lib.load_field(str(p))
    assert got.dtype == np.float64
    assert np.array_equal(got, field.astype(np.float16).astype(np.float64))


@pytest.mark.parametrize("dt", ["float16", "float32", "float64"])
def test_byte_planes_come_back_bit_for_bit(tmp_path, field, dt):
    p = tmp_path / "f.npz"
    f = field.astype(dt)
    np.savez_compressed(p, **lib.pack_field(f))
    got = lib.load_field(str(p))
    assert np.array_equal(got, f.astype(np.float64))


def test_render_writes_the_panel_size_from_a_shipped_field(tmp_path, field):
    p = tmp_path / "julia-0-384x240.npz"
    np.savez_compressed(p, **lib.pack_field(field.astype(np.float32)))
    out = tmp_path / "out.png"
    subprocess.run([sys.executable, os.path.join(REPO, "wallpaper", "render.py"),
                    "--generator", "julia", "--palette", os.path.join(REPO, "theme", "cool.env"),
                    "--size", "256x160", "--seed", "0", "--from-field", str(p),
                    "--out", str(out), "--no-title"], check=True, capture_output=True)
    import matplotlib.image as mpimg
    assert mpimg.imread(out).shape[:2] == (160, 256)
