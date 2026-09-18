"""Everything about a target, from any identifier, in one card.

    ergon target TOI-5205
    ergon target "HD 209458"
    ergon target TIC 307210830

Every piece of this exists in astroquery. What does not exist is not having to
write ten lines to get it, which is why nobody does and everybody re-derives
the same coordinates from a paper instead.

Resolution order is deliberate: SIMBAD knows names, the TIC knows TESS, and
ExoFOP knows what the community currently believes about a TOI -- including
dispositions that have changed since the last paper.
"""
from __future__ import annotations

import json
import sys
import urllib.parse
import urllib.request

# ExoFOP's download_toi.php ignores a toi= parameter -- it silently returns an
# empty body rather than an error -- so the only working query is the whole
# table. It is a few MB, it changes daily at most, and caching it means the
# second lookup is instant and the tool works at an observatory with no network.
def need_astroquery():
    try:
        import astroquery  # noqa: F401
    except ImportError:
        raise SystemExit(
            "ergon-target: needs astroquery.\n"
            "              ergon bundle add astronomy")


EXOFOP_CSV = "https://exofop.ipac.caltech.edu/tess/download_toi.php?sort=toi&output=csv"


def exofop_table(ttl=86400):
    import csv, io, os, time
    cdir = os.path.join(os.environ.get("XDG_CACHE_HOME",
                        os.path.expanduser("~/.cache")), "ergon")
    os.makedirs(cdir, exist_ok=True)
    cache = os.path.join(cdir, "exofop-toi.csv")
    if not (os.path.exists(cache) and time.time() - os.path.getmtime(cache) < ttl):
        try:
            body = urllib.request.urlopen(EXOFOP_CSV, timeout=60).read()
            if b"TIC ID" not in body[:200]:
                raise ValueError("ExoFOP returned something that is not the TOI table")
            with open(cache, "wb") as fh:
                fh.write(body)
        except Exception as e:
            if not os.path.exists(cache):
                print(f"   !!   ExoFOP is not answering ({e}); TOI details unavailable",
                      file=sys.stderr)
                return None
            print(f"   !!   ExoFOP is not answering; using a cached table",
                  file=sys.stderr)
    with open(cache, newline="", encoding="utf-8", errors="replace") as fh:
        return list(csv.DictReader(fh))


def from_exofop(toi: str):
    """The only source that knows a TOI's CURRENT disposition -- the thing most
    likely to have changed since whatever paper you are reading."""
    num = toi.upper().replace("TOI-", "").replace("TOI", "").strip()
    rows = exofop_table()
    if rows is None:
        return None
    # "TOI-700" means every planet of TOI 700; match on the integer part.
    want = num.split(".")[0]
    hits = [r for r in rows if str(r.get("TOI", "")).split(".")[0] == want]
    if not hits:
        print(f"   !!   ExoFOP has no TOI {want}", file=sys.stderr)
        return None
    return hits


def fmt(label, value, unit=""):
    if value in (None, "", "nan"):
        return
    print(f"  {label:<16} {value}{(' ' + unit) if unit else ''}")


def main(argv) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    name = " ".join(argv)
    need_astroquery()

    from astroquery.simbad import Simbad
    import astropy.units as u
    from astropy.coordinates import SkyCoord

    sim = Simbad()
    # The default SIMBAD fields are a name and a position. Everything that makes
    # the card worth reading has to be asked for.
    for f in ("sp_type", "plx_value", "rvz_radvel", "V", "G", "J", "K", "otype"):
        try:
            sim.add_votable_fields(f)
        except Exception:
            pass

    try:
        r = sim.query_object(name)
    except Exception as e:
        raise SystemExit(f"ergon-target: SIMBAD failed: {e}")
    if r is None or len(r) == 0:
        print(f"ergon-target: SIMBAD does not know '{name}'", file=sys.stderr)
        r = None

    print(f"\n  {name}")
    print("  " + "-" * (len(name) + 2))

    if r is not None:
        row = r[0]
        def col(*names):
            for n in names:
                if n in r.colnames and row[n] is not None:
                    v = row[n]
                    return None if hasattr(v, "mask") and v.mask else v
            return None

        ra, dec = col("ra", "RA"), col("dec", "DEC")
        if ra is not None and dec is not None:
            try:
                c = SkyCoord(float(ra) * u.deg, float(dec) * u.deg)
                fmt("coordinates", c.to_string("hmsdms", precision=2))
                fmt("", f"{float(ra):.6f} {float(dec):+.6f} deg")
            except Exception:
                fmt("coordinates", f"{ra} {dec}")
        fmt("type", col("otype", "OTYPE"))
        fmt("spectral type", col("sp_type", "SP_TYPE"))
        plx = col("plx_value", "PLX_VALUE")
        if plx:
            try:
                fmt("parallax", f"{float(plx):.3f}", "mas")
                fmt("distance", f"{1000.0 / float(plx):.1f}", "pc")
            except Exception:
                pass
        for band, label in (("V", "V"), ("G", "G"), ("J", "J"), ("K", "K")):
            v = col(band, f"FLUX_{band}")
            if v is not None:
                try:
                    fmt(f"{label} mag", f"{float(v):.2f}")
                except Exception:
                    pass

    if "toi" in name.lower():
        hits = from_exofop(name)
        if hits:
            fmt("", "")
            print(f"\n  ExoFOP — {len(hits)} planet candidate(s)")
            fmt("TIC", hits[0].get("TIC ID"))
            sec = [x for x in str(hits[0].get("Sectors", "")).split(",") if x.strip()]
            fmt("sectors", f"{len(sec)} ({sec[0]}-{sec[-1]})" if sec else None)
            print()
            print(f"  {'TOI':<10} {'disposition':<12} {'period/d':>10} {'depth/ppm':>10} {'R/Rearth':>9}")
            # ExoFOP stores full float precision. Sixteen significant figures
            # on a period known to four is not information, it is noise that
            # makes the table unreadable.
            def num(v, places):
                try:
                    return f"{float(v):.{places}f}"
                except (TypeError, ValueError):
                    return "-"
            for h in sorted(hits, key=lambda r: r.get("TOI", "")):
                print(f"  {h.get('TOI',''):<10} "
                      f"{(h.get('TFOPWG Disposition') or h.get('TESS Disposition') or '-'):<12} "
                      f"{num(h.get('Period (days)'), 4):>10} "
                      f"{num(h.get('Depth (ppm)'), 0):>10} "
                      f"{num(h.get('Planet Radius (R_Earth)'), 2):>9}")
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
