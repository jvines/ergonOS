"""ergon peek refuses HDF5 and netCDF by name, and before it asks for pandas.

The branches that claimed to read them were fiction (ERGON-58, removed under
ERGON-59): pd.read_hdf needs PyTables and reads only pandas' own HDFStore, xarray
was in no package list, and a netCDF-4 file never reached its branch because
netCDF-4 IS HDF5. What replaced them has to say so without pandas -- this suite
has none, which is exactly the machine where "pandas is not installed" would
send someone to fix the wrong thing.

COVERS: HDF5, netCDF-4 under a .nc name, and classic netCDF, detected by magic.
DOES NOT COVER: any format peek does read; those need pandas.
"""
from __future__ import annotations

import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
import ergon_peek  # noqa: E402


@pytest.mark.parametrize("name, magic, says", [
    ("run.h5", b"\x89HDF\r\n\x1a\n", "is HDF5"),
    ("era5.nc", b"\x89HDF\r\n\x1a\n", "is HDF5"),    # netCDF-4
    ("old.nc", b"CDF\x01", "is netCDF"),             # classic netCDF
], ids=["hdf5", "netcdf4", "netcdf-classic"])
def test_refused_by_name(tmp_path, capsys, name, magic, says):
    p = tmp_path / name
    p.write_bytes(magic + b"\0" * 64)
    with pytest.raises(SystemExit) as e:
        ergon_peek.main([str(p)])
    err = capsys.readouterr().err
    assert e.value.code == 1
    assert says in err and "does not read" in err, err
