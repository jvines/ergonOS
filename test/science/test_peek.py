"""ergon peek refuses HDF5 and netCDF by name, and is honest about the
astronomy paths that were half-built (ERGON-58): vector columns, .fits.gz,
multi-HDU files and FITS string columns.

The HDF5/netCDF branches that claimed to read them were fiction (removed under
ERGON-59): pd.read_hdf needs PyTables and reads only pandas' own HDFStore,
xarray was in no package list, and a netCDF-4 file never reached its branch
because netCDF-4 IS HDF5. What replaced them has to say so without pandas --
the refusal tests below block it via monkeypatch (astropy too), rather than
rely on the surrounding suite's own env happening to lack it, which is exactly
the machine where "pandas is not installed" would send someone to fix the
wrong thing. bin/test-science.sh's env grew pandas and astropy for the FITS
tests further down this file (ERGON-58); without the monkeypatch, adding them
there would have silently disarmed this exact guard -- a review caught it
passing against a mutant that imports pandas ahead of the refusal.

COVERS: HDF5/netCDF refusal; vector FITS columns (must be described, never
silently dropped); .fits.gz, misnamed, truncated, or none of those; --hdu by
index and by EXTNAME, on a table or an image extension; FITS string columns
(must be decoded, not printed as numpy.bytes_); image-only FITS (must point at
fitsheader/fitsinfo rather than grow a second one).
DOES NOT COVER: parquet/CSV/JSON/npy, which have no astronomy-specific traps.
"""
from __future__ import annotations

import gzip
import os
import sys

import numpy as np
import pytest
from astropy.io import fits

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
import ergon_peek  # noqa: E402


@pytest.mark.parametrize("name, magic, says", [
    ("run.h5", b"\x89HDF\r\n\x1a\n", "is HDF5"),
    ("era5.nc", b"\x89HDF\r\n\x1a\n", "is HDF5"),    # netCDF-4
    ("old.nc", b"CDF\x01", "is netCDF"),             # classic netCDF
], ids=["hdf5", "netcdf4", "netcdf-classic"])
def test_refused_by_name(tmp_path, capsys, monkeypatch, name, magic, says):
    # Block both regardless of what this env actually has installed -- this
    # must prove the refusal happens before either import, not merely that it
    # happens to on today's env (see module docstring).
    monkeypatch.setitem(sys.modules, "pandas", None)
    monkeypatch.setitem(sys.modules, "astropy", None)
    p = tmp_path / name
    p.write_bytes(magic + b"\0" * 64)
    with pytest.raises(SystemExit) as e:
        ergon_peek.main([str(p)])
    err = capsys.readouterr().err
    assert e.value.code == 1
    assert says in err and "does not read" in err, err


def _write_fits(path, hdus):
    fits.HDUList(hdus).writeto(path, overwrite=True)


def _catalog_hdu(extname="CAT", n=3):
    """A table HDU carrying a scalar int column, a scalar float column, a
    5-element-per-row vector column (a toy flux array) and a padded ASCII
    string column -- the four things ERGON-58 says peek gets wrong about
    real light-curve/spectral/catalog FITS."""
    cols = [
        fits.Column(name="ID", format="J", array=np.arange(n, dtype=np.int32)),
        fits.Column(name="RA", format="D", array=np.linspace(10.0, 20.0, n)),
        fits.Column(name="FLUX", format="5E",
                    array=np.arange(n * 5, dtype=np.float32).reshape(n, 5)),
        fits.Column(name="NAME", format="8A",
                    array=np.array(["CD-38", "V* AB", "HD 1"][:n])),
    ]
    return fits.BinTableHDU.from_columns(cols, name=extname)


def test_vector_column_described_not_dropped(tmp_path, capsys):
    p = tmp_path / "catalog.fits"
    _write_fits(p, [fits.PrimaryHDU(), _catalog_hdu()])
    ergon_peek.main([str(p)])
    out = capsys.readouterr().out
    # Old behaviour: `if arr[c.name].ndim == 1` left FLUX out of the
    # DataFrame dict comprehension and printed nothing about it at all.
    assert "FLUX" in out, out
    assert "vector columns" in out, out
    assert "(5,)" in out, out            # per-row shape
    assert "ID" in out and "RA" in out   # scalar columns still described


def test_string_column_decoded_and_stripped(tmp_path, capsys):
    p = tmp_path / "catalog.fits"
    _write_fits(p, [fits.PrimaryHDU(), _catalog_hdu()])
    ergon_peek.main([str(p)])
    out = capsys.readouterr().out
    assert "CD-38" in out, out
    assert "b'" not in out, out          # numpy.bytes_ repr, padding and all


@pytest.mark.parametrize("padded, want", [
    (b"CD-38   ", "CD-38"),          # FITS pads ASCII columns with spaces
    (b"CD-38\x00\x00\x00", "CD-38"),  # some writers pad with NUL instead
], ids=["space-padded", "nul-padded"])
def test_fits_column_decodes_and_strips_padded_bytes(padded, want):
    # Unit-level, not through astropy: astropy 8.0.1 (the version this suite
    # resolved -- test-science.sh is deliberately unpinned) already decodes
    # 'A'-format columns to native str on read, so a round trip through a
    # real file no longer exercises this path. The bug ERGON-58 reports --
    # numpy.bytes_ printing as a byte repr with FITS padding -- is a fact
    # about the array shape this function must handle regardless of which
    # astropy version hands it that shape.
    col = np.array([padded], dtype=f"S{len(padded)}")
    assert ergon_peek._fits_column(col) == [want]


@pytest.mark.parametrize("name", ["survey.fits.gz", "survey.gz"],
                         ids=["named-right", "misnamed"])
def test_gzip_fits_is_read(tmp_path, capsys, name):
    plain = tmp_path / "plain.fits"
    _write_fits(plain, [fits.PrimaryHDU(), _catalog_hdu()])
    p = tmp_path / name
    with open(plain, "rb") as src, gzip.open(p, "wb") as dst:
        dst.write(src.read())
    ergon_peek.main([str(p)])
    out = capsys.readouterr().out
    assert "unrecognised format" not in out
    assert "ID" in out and "RA" in out, out


def test_truncated_gzip_fits_is_refused(tmp_path, capsys):
    # An interrupted MAST/ESO download, modelled directly: cut a valid gzip
    # stream in half. Before the truncation check, this read as a complete,
    # boring, header-only file at exit 0 -- the catalog rows were gone with no
    # word about it (review, ERGON-58; the card's own "silent data loss is
    # worse than refusing").
    plain = tmp_path / "plain.fits"
    _write_fits(plain, [fits.PrimaryHDU(), _catalog_hdu(n=50)])
    full = gzip.compress(plain.read_bytes())
    p = tmp_path / "cut.fits.gz"
    p.write_bytes(full[: len(full) // 2])
    with pytest.raises(SystemExit) as e:
        ergon_peek.main([str(p)])
    assert e.value.code == 1
    err = capsys.readouterr().err
    assert "truncated" in err, err


def test_hdu_layout_default_shows_first_table_and_names_the_rest(tmp_path, capsys):
    p = tmp_path / "multi.fits"
    _write_fits(p, [fits.PrimaryHDU(), _catalog_hdu("CAT"), _catalog_hdu("META", n=2)])
    ergon_peek.main([str(p)])
    out = capsys.readouterr().out
    assert "CAT" in out and "META" in out   # both named in the layout table
    assert "1 more table HDU" in out and "--hdu" in out


@pytest.mark.parametrize("spec", ["META", "meta", "2"], ids=["extname", "lowercase", "index"])
def test_hdu_flag_selects_by_name_or_index(tmp_path, capsys, spec):
    p = tmp_path / "multi.fits"
    _write_fits(p, [fits.PrimaryHDU(), _catalog_hdu("CAT"), _catalog_hdu("META", n=2)])
    ergon_peek.main([str(p), "--hdu", spec])
    out = capsys.readouterr().out
    # Both HDUs share a schema, so the layout table always names both and
    # always shows "2 rows" for META regardless of what --hdu did -- that
    # string alone passes whether or not --hdu is even parsed (review,
    # ERGON-58: it was still true with --hdu resolved and then discarded).
    # The description header is the only thing that says which one was
    # actually described.
    assert "(HDU 'META')" in out, out
    assert "(HDU 'CAT')" not in out, out


def test_hdu_flag_selects_image_extension(tmp_path, capsys):
    # Left untested by the first pass (its own report said so): --hdu on an
    # image extension that isn't the primary, e.g. a thumbnail cutout next to
    # a catalog.
    p = tmp_path / "mixed.fits"
    img = fits.ImageHDU(data=np.zeros((3, 3), dtype=np.float32), name="THUMB")
    _write_fits(p, [fits.PrimaryHDU(), _catalog_hdu("CAT"), img])
    ergon_peek.main([str(p), "--hdu", "THUMB"])
    out = capsys.readouterr().out
    assert "THUMB" in out and "(3, 3)" in out, out
    assert "fitsheader" in out and "fitsinfo" in out, out


def test_hdu_flag_bad_name_dies(tmp_path, capsys):
    p = tmp_path / "multi.fits"
    _write_fits(p, [fits.PrimaryHDU(), _catalog_hdu("CAT")])
    with pytest.raises(SystemExit) as e:
        ergon_peek.main([str(p), "--hdu", "NOPE"])
    assert e.value.code == 1
    assert "no HDU named" in capsys.readouterr().err


def test_image_only_fits_points_at_fitsheader(tmp_path, capsys):
    p = tmp_path / "image.fits"
    _write_fits(p, [fits.PrimaryHDU(data=np.zeros((4, 4), dtype=np.float32))])
    ergon_peek.main([str(p)])
    out = capsys.readouterr().out
    assert "fitsheader" in out and "fitsinfo" in out, out
