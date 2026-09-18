"""Turn an identifier into BibTeX in this project's .bib.

    ergon cite 10.1086/670067          DOI
    ergon cite 2013PASP..125..306F     ADS bibcode
    ergon cite arXiv:1202.3665         arXiv
    ergon cite --software              the stack you actually ran

The daily papercut with no Linux answer: you have a bibcode and you want the
entry in your paper's .bib, and instead you open a browser.

Sources, in the order they are tried, and all of them free except ADS:
  Crossref   for DOIs. Returns BibTeX directly; no key, no account.
  arXiv      Atom API. If the preprint has since been published, its DOI is in
             the feed and Crossref's entry for the PUBLISHED version is used --
             citing the preprint of a paper that exists is a small error that
             propagates.
  ADS        needs a token, because ADS needs a token. $ADS_DEV_KEY or
             ~/.ads/dev_key, the same place the `ads` package looks.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

UA = "ergon-cite (https://github.com/jvines; mailto:jose.vines.l@gmail.com)"
TIMEOUT = 25

# Curated, and honest about being curated. There is no machine-readable "how do
# I cite this" for most of PyPI -- CITATION.cff exists but almost nothing ships
# it -- so this is the set that actually turns up in a methods section, mapped
# to the paper its authors ask you to cite.
SOFTWARE_DOI = {
    "numpy":        "10.1038/s41586-020-2649-2",
    "scipy":        "10.1038/s41592-019-0686-2",
    "matplotlib":   "10.1109/MCSE.2007.55",
    "pandas":       "10.5281/zenodo.3509134",
    "astropy":      "10.3847/1538-4357/ac7c74",
    "emcee":        "10.1086/670067",
    "dynesty":      "10.1093/mnras/staa278",
    "ultranest":    "10.21105/joss.03001",
    "corner":       "10.21105/joss.00024",
    "arviz":        "10.21105/joss.01143",
    "lightkurve":   "10.3847/1538-3881/aae8dd",
    "astroquery":   "10.3847/1538-3881/aafc33",
    "photutils":    "10.5281/zenodo.596036",
    "batman-package": "10.1086/683602",
    "numpyro":      "10.48550/arXiv.1912.11554",
    "scikit-learn": "10.48550/arXiv.1201.0490",
    "h5py":         "10.5281/zenodo.594310",
}

DOI_RE = re.compile(r"\b(10\.\d{4,9}/[^\s\"<>]+)", re.I)
ARXIV_RE = re.compile(r"(?:arxiv[:/ ]\s*)?(\d{4}\.\d{4,5})(v\d+)?", re.I)
BIBCODE_RE = re.compile(r"^\d{4}[A-Za-z&.]{5}[\w.&]{4}[A-Z.][\d.]{4}[A-Z]$")


def get(url, headers=None, data=None):
    req = urllib.request.Request(url, data=data,
                                 headers={"User-Agent": UA, **(headers or {})})
    return urllib.request.urlopen(req, timeout=TIMEOUT).read().decode("utf-8", "replace")


def classify(ident: str) -> tuple[str, str]:
    s = ident.strip().rstrip("/")
    s = re.sub(r"^https?://(dx\.)?doi\.org/", "", s, flags=re.I)
    s = re.sub(r"^https?://arxiv\.org/abs/", "arXiv:", s, flags=re.I)
    if BIBCODE_RE.match(s):
        return "bibcode", s
    m = DOI_RE.search(s)
    if m:
        return "doi", m.group(1)
    m = ARXIV_RE.search(s)
    if m:
        return "arxiv", m.group(1)
    raise SystemExit(f"ergon-cite: cannot tell what '{ident}' is "
                     "(expected a DOI, an arXiv id, or an ADS bibcode)")


def from_doi(doi: str) -> str:
    """doi.org content negotiation, not Crossref's own endpoint.

    doi.org routes to whichever registry actually owns the DOI. The Crossref
    endpoint only knows Crossref DOIs, so every Zenodo record -- which is how
    pandas, photutils and most software archives are cited -- came back 404
    from a service that had simply never heard of them.
    """
    url = "https://doi.org/" + urllib.parse.quote(doi, safe="/:")
    try:
        return get(url, {"Accept": "application/x-bibtex"}).strip()
    except urllib.error.HTTPError as e:
        if e.code in (404, 204):
            raise SystemExit(f"ergon-cite: no registry has a record of {doi}")
        raise


def from_arxiv(aid: str) -> str:
    feed = get(f"https://export.arxiv.org/api/query?id_list={aid}&max_results=1")
    # Prefer the published version when there is one: citing the preprint of a
    # paper that exists is a small error that propagates into everyone who
    # copies your .bib.
    m = re.search(r"<arxiv:doi[^>]*>([^<]+)</arxiv:doi>", feed)
    if m:
        return from_doi(m.group(1).strip())
    title = re.search(r"<title>(.*?)</title>", feed, re.S)
    if not title:
        raise SystemExit(f"ergon-cite: arXiv has no record of {aid}")
    # Skip the feed's own <title>, which is the query string.
    titles = re.findall(r"<title>(.*?)</title>", feed, re.S)
    title = " ".join(titles[-1].split())
    authors = re.findall(r"<name>([^<]+)</name>", feed)
    year = (re.search(r"<published>(\d{4})", feed) or [None, "????"])[1]
    first = authors[0].split()[-1] if authors else "unknown"
    key = f"{first}{year}"
    auth = " and ".join(authors)
    return (f"@article{{{key},\n"
            f"  title         = {{{title}}},\n"
            f"  author        = {{{auth}}},\n"
            f"  year          = {{{year}}},\n"
            f"  eprint        = {{{aid}}},\n"
            f"  archivePrefix = {{arXiv}},\n"
            f"  primaryClass  = {{astro-ph}}\n"
            f"}}")


def ads_token() -> str | None:
    tok = os.environ.get("ADS_DEV_KEY")
    if tok:
        return tok.strip()
    p = os.path.expanduser("~/.ads/dev_key")
    if os.path.exists(p):
        return open(p).read().strip()
    return None


def from_bibcode(bibcode: str) -> str:
    tok = ads_token()
    if not tok:
        raise SystemExit(
            "ergon-cite: a bibcode needs an ADS token.\n"
            "            Get one at https://ui.adsabs.harvard.edu/user/settings/token\n"
            "            then: mkdir -p ~/.ads && echo YOUR_TOKEN > ~/.ads/dev_key\n"
            "            (or pass the DOI instead, which needs nothing)")
    body = json.dumps({"bibcode": [bibcode]}).encode()
    out = get("https://api.adsabs.harvard.edu/v1/export/bibtex", data=body,
              headers={"Authorization": f"Bearer {tok}",
                       "Content-Type": "application/json"})
    return json.loads(out)["export"].strip()


def fetch(ident: str) -> str:
    kind, value = classify(ident)
    return tidy({"doi": from_doi, "arxiv": from_arxiv, "bibcode": from_bibcode}[kind](value))


def tidy(bib: str, prefer_key: str | None = None) -> str:
    """Reformat an entry into something a human will edit.

    Crossref returns one very long line, with HTML in the title -- emcee's is
    literally "<tt>emcee</tt>: The MCMC Hammer" -- and typographic dashes in
    the page range. That compiles, and it makes a .bib unreadable and unmergeable:
    every edit is a whole-line diff.
    """
    m = re.match(r"\s*@(\w+)\s*\{\s*([^,]+),(.*)\}\s*$", bib, re.S)
    if not m:
        return bib.strip()
    kind, key, body = m.group(1), m.group(2).strip(), m.group(3)

    # DataCite returns the DOI URL as the key -- @misc{https://doi.org/10.5281/
    # zenodo.3509134, ...} -- which you cannot type into a \cite{} without
    # escaping and would not want to. Build one from author and year instead.
    if "/" in key or ":" in key:
        au = re.search(r"author\s*=\s*\{([^},]+)", body)
        yr = re.search(r"year\s*=\s*\{?(\d{4})", body)
        surname = re.sub(r"[^A-Za-z]", "", (au.group(1).split(" and ")[0].split(",")[0].split()[-1]
                                            if au else "anon"))
        key = f"{surname or 'anon'}{yr.group(1) if yr else ''}"
    # Software archives are authored by "The pandas development team" and such,
    # so a surname-derived key reads \cite{team2026}. When the caller knows the
    # package, that is the better name.
    if prefer_key:
        yr = re.search(r"year\s*=\s*\{?(\d{4})", body)
        key = f"{re.sub(r'[^A-Za-z0-9]', '', prefer_key)}{yr.group(1) if yr else ''}"

    # Split on commas at brace depth zero; values contain commas freely.
    fields, buf, depth = [], "", 0
    for ch in body:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        if ch == "," and depth == 0:
            fields.append(buf); buf = ""
        else:
            buf += ch
    fields.append(buf)

    out = []
    for f in fields:
        if "=" not in f:
            continue
        name, _, value = f.partition("=")
        name = name.strip()
        value = " ".join(value.split())
        value = re.sub(r"</?[a-z]+>", "", value)          # <tt>, <i>, <sub>
        # Stripping a tag can leave the space that separated it from the
        # punctuation: "<tt>emcee</tt>\n : The MCMC Hammer" becomes
        # "emcee : The MCMC Hammer".
        value = re.sub(r"\s+([:;,.])", r"\1", value)
        value = value.replace("\u2013", "--").replace("\u2014", "---")
        if not value:
            continue
        if not (value.startswith("{") or value.isdigit()):
            value = "{" + value.strip('"') + "}"
        out.append(f"  {name:<13} = {value}")
    return f"@{kind}{{{key},\n" + ",\n".join(out) + "\n}"


def entry_key(bib: str) -> str:
    m = re.search(r"@\w+\s*\{\s*([^,\s]+)", bib)
    return m.group(1) if m else ""


def find_bib(explicit: str | None) -> str:
    if explicit:
        return explicit
    # One .bib in the obvious places, or refs.bib. Guessing between several is
    # worse than asking.
    cands = []
    for d in (".", "paper", "ms", "manuscript", "tex"):
        if os.path.isdir(d):
            cands += [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith(".bib")]
    if len(cands) == 1:
        return cands[0]
    if len(cands) > 1:
        raise SystemExit("ergon-cite: several .bib files here; pass --bib <file>\n  "
                         + "\n  ".join(cands))
    return "refs.bib"


def append(bib_path: str, entry: str, stdout: bool) -> int:
    key = entry_key(entry)
    if stdout:
        print(entry)
        return 0
    existing = open(bib_path).read() if os.path.exists(bib_path) else ""
    if key and re.search(r"@\w+\s*\{\s*" + re.escape(key) + r"\s*,", existing):
        print(f"   ·   {key} is already in {bib_path}")
        return 0
    with open(bib_path, "a") as fh:
        if existing and not existing.endswith("\n\n"):
            fh.write("\n")
        fh.write(entry.rstrip() + "\n")
    print(f"   ok  {key} -> {bib_path}")
    return 0


def installed_version(pkg: str) -> str | None:
    from importlib.metadata import version, PackageNotFoundError
    try:
        return version(pkg)
    except PackageNotFoundError:
        return None


def software(names, bib_path, stdout) -> int:
    wanted = names or sorted(SOFTWARE_DOI)
    rc = 0
    for pkg in wanted:
        ver = installed_version(pkg)
        if ver is None:
            if names:            # explicitly asked for: say so
                print(f"   ·   {pkg} is not installed")
            continue
        doi = SOFTWARE_DOI.get(pkg)
        if not doi:
            print(f"   !!  {pkg} {ver}: no citation recorded — add it to "
                  "lib/ergon_cite.py if the authors ask for one")
            rc = 1
            continue
        try:
            entry = tidy(from_doi(doi), prefer_key=pkg)
        except SystemExit as e:
            # One unresolvable DOI aborted the entire --software run, leaving a
            # half-written .bib and no indication which packages were skipped.
            print(f"   !!  {pkg} {ver}: {str(e).replace('ergon-cite: ', '')}")
            rc = 1
            continue
        # The VERSION is the point. A methods section that cites the numpy
        # paper without saying which numpy is not reproducible, and the paper
        # is the same for every version.
        entry = re.sub(r"\n\}\s*$", f",\n  note          = {{version {ver}}}\n}}", entry)
        append(bib_path, entry, stdout)
    return rc


def main(argv) -> int:
    stdout = "--stdout" in argv
    argv = [a for a in argv if a != "--stdout"]
    bib = None
    if "--bib" in argv:
        i = argv.index("--bib")
        bib = argv[i + 1]
        del argv[i:i + 2]

    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0

    bib_path = find_bib(bib)
    if argv[0] == "--software":
        return software(argv[1:], bib_path, stdout)
    rc = 0
    for ident in argv:
        try:
            append(bib_path, fetch(ident), stdout)
        except SystemExit as e:
            print(e, file=sys.stderr)
            rc = 1
        except Exception as e:
            print(f"ergon-cite: {ident}: {type(e).__name__}: {e}", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
