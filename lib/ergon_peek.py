"""Look at a data file without caring what it is.

One command for parquet, CSV/TSV, FITS, npy/npz and JSON, because the
alternative is four half-remembered incantations and a collaborator's file you
cannot open. Detection is by magic bytes first and extension second: files
arrive misnamed, and `.dat` means nothing at all.

Dependencies are checked per format and reported precisely. The base python is
deliberately small (see packages/python), so parquet needs a bundle -- and
being told WHICH is the difference between a tool that is honest and a
traceback. HDF5 and netCDF are recognised and refused by name.
"""
from __future__ import annotations

import io
import os
import sys

MAGIC = [
    (b"PAR1", "parquet"),
    (b"\x89HDF\r\n\x1a\n", "hdf5"),
    (b"\x93NUMPY", "npy"),
    (b"PK\x03\x04", "npz"),
    (b"CDF\x01", "netcdf"),
    (b"CDF\x02", "netcdf"),
    (b"\x89\x48\x44\x46", "hdf5"),
    (b"SIMPLE  =", "fits"),
]
EXT = {
    ".parquet": "parquet", ".pq": "parquet",
    ".csv": "csv", ".tsv": "csv", ".txt": "csv", ".dat": "csv",
    ".fits": "fits", ".fit": "fits", ".fts": "fits",
    ".h5": "hdf5", ".hdf5": "hdf5", ".he5": "hdf5",
    ".npy": "npy", ".npz": "npz",
    ".nc": "netcdf", ".cdf": "netcdf",
    ".json": "json", ".jsonl": "jsonl", ".ndjson": "jsonl",
}
# Which list provides the reader, for the message when it is missing.
# bin/ergon-lint holds each hint to the list it names (ERGON-59): astropy's
# used to send people to the astronomy bundle, which does not contain it.
PROVIDER = {
    "pyarrow": "pip install pyarrow, or: ergon bundle add ml",
    "astropy": "the base python should have this — run: pyfleet sync",
    "pandas": "the base python should have this — run: pyfleet sync",
}


def die(msg: str, hint: str = "") -> None:
    print(f"ergon-peek: {msg}", file=sys.stderr)
    if hint:
        print(f"            {hint}", file=sys.stderr)
    raise SystemExit(1)


def need(mod: str):
    """Import or explain. importlib, not __import__: the latter returns the TOP
    package for a dotted name, so `__import__("astropy").io.fits` raises
    AttributeError because the submodule was never imported."""
    import importlib
    try:
        return importlib.import_module(mod)
    except ImportError:
        root = mod.split(".")[0]
        die(f"{mod} is not installed", PROVIDER.get(root, f"pip install {root}"))


def sniff(path: str, head: bytes) -> str:
    for sig, kind in MAGIC:
        if head.startswith(sig):
            return kind
    # FITS keyword can be padded; check the first card properly.
    if head[:6] == b"SIMPLE":
        return "fits"
    ext = os.path.splitext(path)[1].lower()
    if ext in EXT:
        return EXT[ext]
    # Fall back on "does it look like text with delimiters".
    try:
        text = head.decode("utf-8")
    except UnicodeDecodeError:
        return "unknown"
    if text.lstrip()[:1] in "[{":
        return "json"
    return "csv" if any(d in text for d in ",\t;|") else "unknown"


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def describe_frame(df, name: str, kind: str, size: int | None) -> None:
    rows, cols = df.shape
    meta = f"{kind} · {rows:,} rows × {cols} columns"
    if size is not None:
        meta = f"{kind} · {human(size)} · {rows:,} rows × {cols} columns"
    print(f"\n{name}\n{meta}\n")

    width = max((len(str(c)) for c in df.columns), default=6)
    width = min(max(width, 6), 28)
    print(f"  {'column'.ljust(width)}  {'type'.ljust(10)}  {'nulls'.rjust(6)}  summary")
    print(f"  {'-' * width}  {'-' * 10}  {'-' * 6}  {'-' * 34}")

    for c in df.columns:
        s = df[c]
        nulls = int(s.isna().sum())
        dt = str(s.dtype)[:10]
        try:
            if s.dtype.kind in "ifu":
                d = s.dropna()
                summary = (f"{d.min():.4g} … {d.max():.4g}  (mean {d.mean():.4g})"
                           if len(d) else "all null")
            elif s.dtype.kind in "M":
                d = s.dropna()
                summary = f"{d.min()} … {d.max()}" if len(d) else "all null"
            else:
                u = s.dropna().unique()
                shown = ", ".join(str(x)[:12] for x in u[:4])
                summary = f"{len(u)} unique: {shown}" + (" …" if len(u) > 4 else "")
        except Exception:
            summary = "(not summarisable)"
        print(f"  {str(c)[:width].ljust(width)}  {dt.ljust(10)}  {nulls:>6}  {summary[:34]}")

    print("\n  first rows")
    with_opts = getattr(df, "to_string", None)
    body = with_opts(max_rows=8, max_cols=10) if with_opts else str(df.head(8))
    for line in body.splitlines()[:12]:
        print(f"    {line}")
    print()


def peek_fits(path: str) -> None:
    fits = need("astropy.io.fits")
    size = os.path.getsize(path)
    print(f"\n{path}\nfits · {human(size)}\n")
    with fits.open(path, memmap=True) as hdul:
        print(f"  {'#':>2}  {'name'.ljust(12)}  {'type'.ljust(12)}  dimensions")
        print(f"  {'-' * 2}  {'-' * 12}  {'-' * 12}  {'-' * 24}")
        for i, h in enumerate(hdul):
            kind = type(h).__name__.replace("HDU", "")
            if getattr(h, "is_image", False) and h.data is not None:
                dims = f"{h.data.shape} {h.data.dtype}"
            elif hasattr(h, "columns") and h.columns is not None:
                dims = f"{len(h.data):,} rows × {len(h.columns)} cols"
            else:
                dims = "—"
            print(f"  {i:>2}  {str(h.name)[:12].ljust(12)}  {kind[:12].ljust(12)}  {dims}")
        # The first table HDU is almost always what you opened the file for.
        for h in hdul:
            if hasattr(h, "columns") and h.columns is not None:
                pd = need("pandas")
                # byteswap: FITS is big-endian and pandas will not take that.
                arr = h.data
                df = pd.DataFrame({
                    c.name: arr[c.name].byteswap().view(arr[c.name].dtype.newbyteorder())
                    if arr[c.name].dtype.byteorder == ">" else arr[c.name]
                    for c in h.columns if arr[c.name].ndim == 1
                })
                describe_frame(df, f"{path}  (HDU '{h.name}')", "fits table", None)
                break
        else:
            print()


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        print("\nusage: ergon peek <file>|-   (- reads stdin, e.g. a table on the clipboard)")
        return 0

    path = argv[0]
    if path == "-":
        raw = sys.stdin.buffer.read()
        if not raw.strip():
            die("nothing on stdin")
        pd = need("pandas")
        try:
            df = pd.read_csv(io.BytesIO(raw), sep=None, engine="python")
        except Exception as e:
            die(f"could not parse stdin as a table: {e}")
        describe_frame(df, "(stdin)", "table", len(raw))
        return 0

    if not os.path.exists(path):
        die(f"no such file: {path}")

    with open(path, "rb") as fh:
        head = fh.read(4096)
    kind = sniff(path, head)
    size = os.path.getsize(path)

    # Recognised so they can be refused by name, ahead of the pandas check --
    # "pandas is not installed" would send someone to fix the wrong thing. The
    # branches that claimed to read these were fiction (ERGON-58): HDF5 checked
    # for h5py and then called pd.read_hdf, which needs PyTables and reads only
    # pandas' own HDFStore layout; netCDF needed xarray, which no package list
    # names, and a netCDF-4 file never reached that branch, because netCDF-4 IS
    # HDF5 and that magic is tested first. peek has no reader for either --
    # that is a fact about peek, not about the machine: scipy (packages/python)
    # reads classic netCDF, and the astronomy bundle's own dependencies pull in
    # h5py, tables and xarray, so the hint must not claim the system can't.
    if kind in ("hdf5", "netcdf"):
        fmt = "HDF5" if kind == "hdf5" else "netCDF"
        # The netCDF-4 aside is only true of THIS file when it is what set off
        # the HDF5 branch under a .nc/.cdf name -- printing it for a plain .h5
        # or for classic netCDF (the CDF magic, kind == "netcdf") would be a
        # fact about a different file.
        ext = os.path.splitext(path)[1].lower()
        note = "netCDF-4 is HDF5 inside; " if kind == "hdf5" and ext in (".nc", ".cdf") else ""
        die(f"{path} is {fmt}, which ergon peek does not read",
            f"{note}ergon peek has no HDF5 or netCDF reader")

    if kind == "fits":
        peek_fits(path)
        return 0

    pd = need("pandas")
    if kind == "parquet":
        need("pyarrow")
        df = pd.read_parquet(path)
    elif kind == "csv":
        df = pd.read_csv(path, sep=None, engine="python")
    elif kind == "json":
        df = pd.read_json(path)
    elif kind == "jsonl":
        df = pd.read_json(path, lines=True)
    elif kind in ("npy", "npz"):
        np = need("numpy")
        a = np.load(path, allow_pickle=False)
        if kind == "npz":
            print(f"\n{path}\nnpz · {human(size)} · {len(a.files)} array(s)\n")
            for k in a.files:
                print(f"  {k:<24} {str(a[k].shape):<18} {a[k].dtype}")
            print()
            return 0
        if a.ndim <= 2:
            # Fall through to the frame summary, which prints its own header --
            # printing one here too gave every .npy two headers.
            df = pd.DataFrame(a if a.ndim == 2 else a.reshape(-1, 1))
        else:
            print(f"\n{path}\nnpy · {human(size)} · shape {a.shape} · {a.dtype}\n")
            print(f"  {a.ndim}-d array; showing a slice\n")
            print(a[(0,) * (a.ndim - 2)])
            return 0
    else:
        die(f"unrecognised format for {path}",
            "magic bytes and extension both inconclusive")
        return 1

    describe_frame(df, path, kind, size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
