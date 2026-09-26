"""Render a FITS image to a PNG thumbnail, for the file manager (ERGON-62).

yazi/plugins/fits.yazi shells out to this; see it and yazi.toml for why
yazi's own image previewer is not enough (its decoder does not read FITS).

Picks the first HDU that is_image and has NAXIS>=2 -- header-only checks, so
a table HDU is skipped without its rows being read, which is what makes
refusing a table-only file fast. A cube's extra axis is numpy index 0 (FITS
reverses axis order), so `_plane` just drops leading axes until 2-D.

Stretch is `numpy.nanpercentile`, not astropy's ZScaleInterval: zscale's
sampler compares raw values and a NaN (a dead pixel, a masked column --
ordinary in real data) breaks it, where dropping NaN first does not.

Colour is plain "gray", not the operator's usual `cool`: this is a
quick-look astronomical frame, ds9's own default is grey for the same
reason -- a diverging map invents a warm/cool reading a pixel value does
not have, and washes out the faint end a thumbnail is for judging.

Opened with memmap=True (as ergon_peek.py does), and downsampled toward the
output size BEFORE nanpercentile touches it, so a multi-gigapixel mosaic
pages in only what a thumbnail needs rather than loading fully into RAM.
"""
from __future__ import annotations

import sys

import numpy as np


def die(msg: str) -> None:
    print(f"ergon-fits-thumbnail: {msg}", file=sys.stderr)
    raise SystemExit(1)


def _first_image_hdu(hdul):
    for hdu in hdul:
        if getattr(hdu, "is_image", False) and hdu.header.get("NAXIS", 0) >= 2:
            return hdu
    return None


def _plane(data: np.ndarray) -> np.ndarray:
    while data.ndim > 2:
        data = data[0]
    return data


def _downsample(data: np.ndarray, target: int) -> np.ndarray:
    # A stride is a view, not a copy: only the sampled elements get paged in.
    step = max(1, max(data.shape) // max(1, target * 2))
    return data[::step, ::step] if step > 1 else data


def render(fits_path: str, out_path: str, size: int = 512) -> None:
    from astropy.io import fits

    with fits.open(fits_path, memmap=True) as hdul:
        hdu = _first_image_hdu(hdul)
        if hdu is None:
            die(f"{fits_path}: no image HDU (table-only FITS, nothing to thumbnail)")
        data = _plane(np.asarray(hdu.data))

    data = _downsample(data, size)
    finite = data[np.isfinite(data)]
    if finite.size == 0:
        die(f"{fits_path}: image HDU is all NaN/Inf, nothing to stretch")

    lo, hi = np.nanpercentile(finite, [1.0, 99.0])
    if hi <= lo:
        lo, hi = float(finite.min()), float(finite.max())
        if hi <= lo:
            hi = lo + 1.0  # a genuinely constant image; draw it as flat grey

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    dpi = 100
    fig = plt.figure(figsize=(size / dpi, size / dpi), dpi=dpi)
    ax = fig.add_axes((0, 0, 1, 1))
    ax.axis("off")
    # origin="lower": FITS pixel (1,1) is the bottom-left corner, same as ds9.
    ax.imshow(data, cmap="gray", vmin=lo, vmax=hi, origin="lower", interpolation="nearest")
    fig.savefig(out_path, dpi=dpi)
    plt.close(fig)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        die("usage: ergon_fits_thumbnail.py <fits> <out.png> [--size N]")

    size = 512
    if "--size" in argv:
        i = argv.index("--size")
        size = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]

    try:
        render(argv[0], argv[1], size)
    except SystemExit:
        raise
    except Exception as e:  # a corrupt/truncated FITS must fail clean, not traceback
        die(f"{argv[0]}: {e}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
