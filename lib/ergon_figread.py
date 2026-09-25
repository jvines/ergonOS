"""Read provenance back out of a figure."""
import os
import sys

PREFIX = "ergon."


def from_png(path):
    from PIL import Image
    with Image.open(path) as im:
        return {k: v for k, v in (im.info or {}).items() if k.startswith(PREFIX)}


def from_pdf(path):
    # No pypdf in the base environment, and pulling one in for this would be a
    # poor trade. The Info dictionary is plain text in the trailer; find the
    # Keywords string the stamper wrote.
    import re
    raw = open(path, "rb").read()
    m = re.search(rb"/Keywords\s*\((.*?)\)", raw, re.S)
    if not m:
        return {}
    out = {}
    for tok in m.group(1).decode("latin-1", "replace").split():
        if tok.startswith(PREFIX) and "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    return out


def from_svg(path):
    # matplotlib writes Keywords into Dublin Core: one <rdf:li> per element,
    # inside <dc:subject><rdf:Bag>. This used to look for <ergon.script>-style
    # tags, which no SVG writer has ever produced -- the reader was written
    # against an output format that did not exist, matching the writer, which
    # could not save an SVG at all.
    import gzip
    import re
    opener = gzip.open if path.endswith(".svgz") else open
    with opener(path, "rt", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    out = {}
    for item in re.findall(r"<rdf:li[^>]*>([^<]*)</rdf:li>", text):
        tok = item.strip()
        if tok.startswith(PREFIX) and "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    return out


def main(path):
    ext = os.path.splitext(path)[1].lower()
    reader = {".png": from_png, ".pdf": from_pdf,
              ".svg": from_svg, ".svgz": from_svg}.get(ext)
    if reader is None:
        print(f"ergon-fig: {ext or 'this format'} carries no metadata channel", file=sys.stderr)
        return 1
    try:
        meta = reader(path)
    except Exception as e:
        print(f"ergon-fig: could not read {path}: {e}", file=sys.stderr)
        return 1
    if not meta:
        print(f"{path}\n  no ergon provenance — made before stamping, by another tool,\n"
              f"  or with ERGON_FIG_PROVENANCE=0")
        return 1
    print(path)
    for k in sorted(meta):
        print(f"  {k[len(PREFIX):]:<8} {meta[k]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1]))
