"""The daily listing, filtered to what you actually care about.

    ergon arxiv                    today's new papers in your categories
    ergon arxiv --days 3
    ergon arxiv --save 4           save the 4th paper's PDF to the library
    ergon arxiv --cite 4           append its BibTeX to this project's .bib

NOT astro-only. arXiv carries most of physics, mathematics, computer science,
statistics, quantitative biology and economics, and the morning-listing ritual
is the same in all of them. Configure categories and keywords in
~/.config/ergon/arxiv.toml; the defaults are astro-ph.EP because that is who
wrote it, and they are three lines to change.

Scoring is deliberately dumb -- a keyword or a followed author, counted. A
clever relevance model would be wrong in ways you cannot see, and the point is
to not miss things, so unmatched papers are still listed, just below.
"""
from __future__ import annotations

import os
import re
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ATOM = "{http://www.w3.org/2005/Atom}"
CONF = os.path.join(os.environ.get("XDG_CONFIG_HOME",
                                   os.path.expanduser("~/.config")), "ergon", "arxiv.toml")
DEFAULT_CONF = """# What `ergon arxiv` sweeps. Categories are arXiv's own:
# astro-ph.EP, cs.LG, math.ST, q-bio.PE, econ.EM -- see arxiv.org/category_taxonomy
categories = ["astro-ph.EP", "astro-ph.SR"]

# Papers matching these rank first. Plain substrings, case-insensitive.
keywords = ["exoplanet", "radial velocity", "transit", "nested sampling",
            "bayesian", "atmospheric characterization"]

# Anyone here and it goes to the top regardless of keywords.
authors = []
"""


def load_conf():
    if not os.path.exists(CONF):
        os.makedirs(os.path.dirname(CONF), exist_ok=True)
        with open(CONF, "w") as fh:
            fh.write(DEFAULT_CONF)
        print(f"   ·   wrote {CONF} — edit it to follow your own field\n", file=sys.stderr)
    try:
        import tomllib
        with open(CONF, "rb") as fh:
            return tomllib.load(fh)
    except Exception as e:
        print(f"ergon-arxiv: {CONF} is not valid TOML: {e}", file=sys.stderr)
        raise SystemExit(1)


def fetch(categories, days, limit=200, ttl=3600):
    """Query arXiv, politely, and cache the answer.

    arXiv rate-limits hard and returns 429 with no body. Three things keep this
    from being rude, in order of how much they matter:

      A CACHE. The listing does not change within the hour, and running
      `ergon arxiv` four times in a morning should cost one request. It also
      means the command works on a plane, which for this audience is a real
      scheduled condition rather than an edge case.

      A DESCRIPTIVE User-Agent with contact details, which the API terms ask
      for and which is how they tell a tool from a scraper.

      BACKOFF, and a sentence rather than a traceback when it still fails.
    """
    import hashlib, time
    cat = " OR ".join(f"cat:{c}" for c in categories)
    q = urllib.parse.urlencode({
        "search_query": f"({cat})",
        "sortBy": "submittedDate", "sortOrder": "descending",
        "max_results": str(limit),
    })
    url = f"https://export.arxiv.org/api/query?{q}"

    cdir = os.path.join(os.environ.get("XDG_CACHE_HOME",
                        os.path.expanduser("~/.cache")), "ergon")
    os.makedirs(cdir, exist_ok=True)
    cache = os.path.join(cdir, "arxiv-" + hashlib.sha256(url.encode()).hexdigest()[:16] + ".xml")
    if os.path.exists(cache) and time.time() - os.path.getmtime(cache) < ttl:
        return ET.fromstring(open(cache, "rb").read())

    req = urllib.request.Request(url, headers={
        "User-Agent": "ergon-arxiv/1.0 (+https://github.com/jvines; mailto:jose.vines.l@gmail.com)"})
    last = None
    for attempt in range(3):
        try:
            body = urllib.request.urlopen(req, timeout=40).read()
            with open(cache, "wb") as fh:
                fh.write(body)
            return ET.fromstring(body)
        except Exception as e:
            last = e
            code = getattr(e, "code", None)
            if code == 429:
                time.sleep(5 * (attempt + 1))
                continue
            if attempt < 2:
                time.sleep(3)
                continue
            break

    # A stale cache beats nothing: yesterday's listing is still a listing, and
    # saying so is more useful than a traceback about a socket.
    if os.path.exists(cache):
        age = int((time.time() - os.path.getmtime(cache)) / 3600)
        print(f"   !!   arXiv is not answering ({last}); showing a cached listing "
              f"from {age}h ago", file=sys.stderr)
        return ET.fromstring(open(cache, "rb").read())
    raise SystemExit(
        f"ergon-arxiv: arXiv is not answering ({last}).\n"
        "             429 means rate-limited -- wait a few minutes. The listing "
        "is cached for an hour once it succeeds.")


def parse(root, days):
    import datetime
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    out = []
    for e in root.findall(f"{ATOM}entry"):
        pub = e.findtext(f"{ATOM}published", "")
        try:
            when = datetime.datetime.fromisoformat(pub.replace("Z", "+00:00"))
        except ValueError:
            continue
        if when < cutoff:
            continue
        out.append({
            "id": e.findtext(f"{ATOM}id", "").rsplit("/", 1)[-1],
            "title": " ".join(e.findtext(f"{ATOM}title", "").split()),
            "authors": [a.findtext(f"{ATOM}name", "") for a in e.findall(f"{ATOM}author")],
            "summary": " ".join(e.findtext(f"{ATOM}summary", "").split()),
            "published": when,
            "pdf": next((l.get("href") for l in e.findall(f"{ATOM}link")
                         if l.get("title") == "pdf"), ""),
        })
    return out


def score(p, keywords, authors):
    text = (p["title"] + " " + p["summary"]).lower()
    s = sum(2 for k in keywords if k.lower() in text)
    names = " ".join(p["authors"]).lower()
    s += sum(10 for a in authors if a.lower() in names)
    return s


def main(argv) -> int:
    days, save, cite = 1, None, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            print(__doc__.strip()); return 0
        if a == "--days":
            days = int(argv[i + 1]); i += 2; continue
        if a == "--save":
            save = int(argv[i + 1]); i += 2; continue
        if a == "--cite":
            cite = int(argv[i + 1]); i += 2; continue
        print(f"ergon-arxiv: unknown argument {a}", file=sys.stderr); return 2

    conf = load_conf()
    cats = conf.get("categories", ["astro-ph.EP"])
    kw = conf.get("keywords", [])
    au = conf.get("authors", [])

    papers = parse(fetch(cats, days), days)
    if not papers:
        print(f"   nothing new in {', '.join(cats)} in the last {days} day(s)")
        return 0
    for p in papers:
        p["score"] = score(p, kw, au)
    # Unmatched papers are still shown, below the matches. The point is not to
    # miss things; a filter that hides is a filter that costs you a scoop.
    papers.sort(key=lambda p: (-p["score"], p["published"]))

    if save is not None or cite is not None:
        n = (save if save is not None else cite) - 1
        if not 0 <= n < len(papers):
            print(f"ergon-arxiv: no paper {n + 1} in this listing", file=sys.stderr)
            return 1
        p = papers[n]
        if save is not None:
            lib = os.path.join(os.environ.get("XDG_DATA_HOME",
                               os.path.expanduser("~/.local/share")), "ergon", "library")
            os.makedirs(lib, exist_ok=True)
            safe = re.sub(r"[^A-Za-z0-9]+", "-", p["title"])[:60].strip("-")
            dest = os.path.join(lib, f"{p['id']}-{safe}.pdf")
            urllib.request.urlretrieve(p["pdf"], dest)
            print(f"   ok  {dest}")
        else:
            os.execvp("ergon-cite", ["ergon-cite", f"arXiv:{p['id'].split('v')[0]}"])
        return 0

    print()
    for i, p in enumerate(papers, 1):
        mark = "*" if p["score"] >= 10 else ("+" if p["score"] > 0 else " ")
        first = p["authors"][0].split()[-1] if p["authors"] else "?"
        etal = " et al." if len(p["authors"]) > 1 else ""
        print(f"  {i:>3}{mark} {p['title'][:88]}")
        print(f"       {first}{etal}  ·  {p['id']}  ·  {p['published']:%b %d}")
    print(f"\n  {len(papers)} papers  ·  * followed author  + keyword match")
    print( "  ergon arxiv --save N   ergon arxiv --cite N\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
