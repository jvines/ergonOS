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

import gzip
import io
import os
import sys
import zlib

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
GZIP_MAGIC = b"\x1f\x8b"
EXT = {
    ".parquet": "parquet", ".pq": "parquet",
    ".csv": "csv", ".tsv": "csv", ".txt": "csv", ".dat": "csv",
    # .fz (CFITSIO tile-compression) is a normal FITS file by magic -- its
    # primary header starts with a plain SIMPLE card, so sniff() already
    # returns "fits" from the MAGIC table above before this extension entry is
    # ever consulted. It only fires on a misnamed or truncated file whose first
    # 4KB doesn't contain SIMPLE (review, ERGON-58) -- it is not, itself, what
    # lets astropy read tile-compressed data.
    ".fits": "fits", ".fit": "fits", ".fts": "fits", ".fz": "fits",
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


def _gunzip_prefix(data: bytes, n: int) -> bytes:
    """Decompress up to the first `n` output bytes of a gzip stream from a
    possibly-truncated prefix of it. zlib's decompressobj runs incrementally,
    so a partial compressed prefix still yields whatever complete DEFLATE
    output it already contains -- `head` (the file's first 4KB) is enough to
    see a FITS primary header's opening card without reading the whole file."""
    try:
        return zlib.decompressobj(zlib.MAX_WBITS | 16).decompress(data, n)
    except zlib.error:
        return b""


def sniff(path: str, head: bytes) -> str:
    for sig, kind in MAGIC:
        if head.startswith(sig):
            return kind
    # FITS keyword can be padded; check the first card properly.
    if head[:6] == b"SIMPLE":
        return "fits"
    if head[:2] == GZIP_MAGIC:
        # ESO and MAST ship FITS gzipped as a matter of course, and astropy
        # opens it transparently -- but the magic that says "this is FITS" is
        # now buried inside the compressed stream.
        if _gunzip_prefix(head, 6) == b"SIMPLE":
            return "fits"
        # `_gunzip_prefix` returns b"" only when it cannot decompress at all --
        # a corrupt gzip stream, not merely a truncated one: zlib's incremental
        # decompressor still yields SIMPLE from a truncated stream, since the
        # header cards are the first bytes out (measured against 64MB streams
        # of zeros and of random data at gzip levels 0/1/9 -- all six sniffed
        # correctly; review, ERGON-58). Fall back to the name ESO/MAST actually
        # use rather than call a real FITS file "unknown" over a decompressor
        # edge case too narrow to enumerate here.
        stem = path[:-len(".gz")] if path.lower().endswith(".gz") else path
        if os.path.splitext(stem)[1].lower() in (".fits", ".fit", ".fts"):
            return "fits"
        return "unknown"
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


def _fits_column(col):
    """FITS integers/floats are big-endian and pandas refuses that. FITS
    fixed-width ASCII columns come back as `numpy.bytes_`, so left alone they
    print as e.g. b'CD-38   ' -- the decode-me prefix and the FITS padding
    both -- in every row of the summary (ERGON-58)."""
    if col.dtype.kind == "S":
        return [v.decode("ascii", "replace").rstrip(" \x00") for v in col]
    if col.dtype.byteorder == ">":
        return col.byteswap().view(col.dtype.newbyteorder())
    return col


def describe_vector_columns(arr, cols) -> None:
    """Per-row array columns (a flux or wavelength array, one per spectrum or
    light-curve row) have no single-value cell, so they cannot become a
    DataFrame column -- `if arr[c.name].ndim == 1` used to drop them with no
    warning, which is real data loss for most spectral and light-curve FITS
    (ERGON-58). Describe them instead: shape, dtype, and a cheap sanity check
    over every element rather than materialising them by hand."""
    np = need("numpy")
    print("  vector columns (one array per row -- not shown in the table above)")
    # `default=` only feeds max() when `cols` is empty -- describe_vector_columns
    # is never called with an empty list, so it was doing nothing, and every
    # name under 6 chars (FLUX, WAVE, IVAR) narrowed the column below the
    # header's own width and misaligned every row under it (review, ERGON-58).
    width = min(max(max((len(c.name) for c in cols), default=0), 6), 28)
    print(f"  {'column'.ljust(width)}  {'per-row shape'.ljust(14)}  {'dtype'.ljust(9)}  summary")
    print(f"  {'-' * width}  {'-' * 14}  {'-' * 9}  {'-' * 34}")
    for c in cols:
        data = arr[c.name]
        try:
            flat = np.asarray(data, dtype=float).reshape(-1)
            finite = np.isfinite(flat)
            frac = finite.sum() / flat.size if flat.size else 0.0
            summary = (f"finite {frac:.0%}  {flat[finite].min():.4g} … {flat[finite].max():.4g}"
                       if finite.any() else "no finite values")
        except (TypeError, ValueError):
            summary = "(not summarisable)"
        shape = str(data.shape[1:])
        print(f"  {c.name[:width].ljust(width)}  {shape:<14}  {str(data.dtype)[:9].ljust(9)}  {summary[:34]}")
    print()


def resolve_hdu(hdul, spec: str):
    """--hdu takes either the index the layout table prints or an EXTNAME,
    compared case-insensitively -- FITS convention is upper case and nobody
    types SPECTRUM at a shell prompt."""
    try:
        i = int(spec)
    except ValueError:
        i = None
    if i is not None:
        if not (-len(hdul) <= i < len(hdul)):
            die(f"--hdu {spec}: this file has {len(hdul)} HDU(s), indices 0..{len(hdul) - 1}")
        return hdul[i]
    for h in hdul:
        if str(h.name).upper() == spec.upper():
            return h
    die(f"--hdu {spec}: no HDU named {spec!r}", "names and indices are in the layout table above")


def describe_hdu(h, path: str) -> None:
    if getattr(h, "is_image", False):
        if h.data is None:
            print(f"  HDU '{h.name}' is an image extension with no data (header only)\n")
        else:
            print(f"  HDU '{h.name}'  image · {h.data.shape} {h.data.dtype}\n")
        # Not in scope (ERGON-58): astropy already ships fitsheader/fitsinfo
        # for header and pixel inspection, and they are already installed.
        print("  pixel data and WCS are not peek's job -- see fitsheader / fitsinfo\n")
        return
    if not (hasattr(h, "columns") and h.columns is not None):
        print(f"  HDU '{h.name}' is neither image nor table -- nothing to describe\n")
        return
    pd = need("pandas")
    arr = h.data
    scalar = [c for c in h.columns if arr[c.name].ndim == 1]
    vector = [c for c in h.columns if arr[c.name].ndim > 1]
    if scalar:
        df = pd.DataFrame({c.name: _fits_column(arr[c.name]) for c in scalar})
        describe_frame(df, f"{path}  (HDU '{h.name}')", "fits table", None)
    else:
        print(f"\n{path}  (HDU '{h.name}')\nfits table · {len(arr):,} rows · only vector columns\n")
    if vector:
        describe_vector_columns(arr, vector)


def _hdu_dims(h) -> str:
    """The layout table's dims column, from the header alone. Touching
    `.data` here (the original code checked `h.data is not None` and read
    `.data.shape`/`len(h.data)` for every HDU) is free on a memmapped plain
    FITS file, but on .gz/.fz it is a real decompression of pixels nobody
    asked to see yet -- measured on 16x2048^2 float32 image HDUs: 48MB RSS
    through a plain .fits, 337MB through the same file gzipped, entirely from
    this loop (review, ERGON-58). NAXIS2 and NAXIS/BITPIX are mandatory FITS
    table/image header keywords, so this needs nothing `.data` would add."""
    if getattr(h, "is_image", False):
        if h.header.get("NAXIS", 0) == 0:
            return "—"
        bitpix = h.header.get("ZBITPIX", h.header.get("BITPIX"))
        return f"{h.shape} bitpix {bitpix}"
    if hasattr(h, "columns") and h.columns is not None:
        return f"{h.header.get('NAXIS2', 0):,} rows × {len(h.columns)} cols"
    return "—"


def peek_fits(path: str, hdu_spec: str | None) -> None:
    fits = need("astropy.io.fits")
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        gz = fh.read(2) == GZIP_MAGIC
    print(f"\n{path}\n{'fits.gz' if gz else 'fits'} · {human(size)}\n")
    # memmap needs a real mmap-able file; a GzipFile is a decompressing
    # stream, not one, so mapping is off exactly when it would do nothing.
    source = gzip.open(path, "rb") if gz else path
    try:
        with fits.open(source, memmap=not gz) as hdul:
            print(f"  {'#':>2}  {'name'.ljust(12)}  {'type'.ljust(12)}  dimensions")
            print(f"  {'-' * 2}  {'-' * 12}  {'-' * 12}  {'-' * 24}")
            for i, h in enumerate(hdul):
                kind = type(h).__name__.replace("HDU", "")
                print(f"  {i:>2}  {str(h.name)[:12].ljust(12)}  {kind[:12].ljust(12)}  {_hdu_dims(h)}")
            print()

            if gz:
                # A GzipFile treats a truncated stream (an interrupted
                # MAST/ESO download, say) as a clean EOF unless it is actually
                # drained -- and the layout loop above no longer touches
                # `.data` (previous fix), so by this point nothing has forced
                # that read. Without this, a catalog cut off mid-transfer
                # looked like a complete, boring, header-only file at exit 0:
                # the card's own "silent data loss is worse than refusing",
                # reproduced (review, ERGON-58). Reading is cheap either way
                # once you're past the header, and this is the only way to
                # know the pixels and rows behind it are actually all there.
                try:
                    while source.read(1 << 20):
                        pass
                except EOFError:
                    die(f"{path}: gzip stream is truncated -- the file is incomplete")

            if hdu_spec is not None:
                describe_hdu(resolve_hdu(hdul, hdu_spec), path)
                return

            # Default: the first table HDU, which is almost always what you
            # opened the file for -- but say so, and say what was skipped,
            # rather than silently hide a catalog-plus-metadata file's other
            # half (ERGON-58).
            tables = [h for h in hdul if hasattr(h, "columns") and h.columns is not None]
            if not tables:
                print("  no table HDU here -- header and pixel data are not peek's job,")
                print("  see fitsheader / fitsinfo\n")
                return
            describe_hdu(tables[0], path)
            if len(tables) > 1:
                print(f"  {len(tables) - 1} more table HDU(s) not shown -- pass --hdu <#|EXTNAME>\n")
    finally:
        if gz:
            source.close()


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        print("\nusage: ergon peek <file>|-   (- reads stdin, e.g. a table on the clipboard)")
        print("       ergon peek survey.fits --hdu 1        (index, from the layout table)")
        print("       ergon peek survey.fits --hdu SPECTRUM (or an EXTNAME, either case)")
        return 0

    # --hdu is FITS-only; pull it out before the file argument is looked at,
    # since it can come before or after it on the command line.
    hdu_spec = None
    rest = []
    args = iter(argv)
    for a in args:
        if a == "--hdu":
            try:
                hdu_spec = next(args)
            except StopIteration:
                die("--hdu needs a value: an HDU index or an EXTNAME")
        elif a.startswith("--hdu="):
            hdu_spec = a.split("=", 1)[1]
        else:
            rest.append(a)
    if not rest:
        die("no file given", "usage: ergon peek <file>|- [--hdu <#|EXTNAME>]")
    path = rest[0]

    if path == "-":
        if hdu_spec is not None:
            die("--hdu does not apply to stdin")
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
        peek_fits(path, hdu_spec)
        return 0

    if hdu_spec is not None:
        die(f"--hdu only applies to FITS files (this looks like {kind})")

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
