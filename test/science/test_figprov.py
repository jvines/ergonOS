"""A figure saved by the shared python carries its origin, in every format.

This file exists because that was false for months and nothing noticed.

lib/ergon_figprov.py listed svg and svgz alongside png as formats that "take
arbitrary key/value pairs". PNG does; SVG does not. matplotlib's SVG writer pops
the Dublin Core keys it knows and raises ValueError on whatever is left, so
every ergon.* field went into that raise and `savefig("x.svg")` did not write a
figure at all. The reader agreed: from_svg matched <ergon.script>...</ergon.script>
tags, which no SVG writer has ever emitted.

Writer and reader were consistent with each other and with nothing else. That is
precisely the shape a test catches and a review does not, and there was no test:
nothing in this repo saved a figure and read it back. Fixed in 92a3b4d.

COVERS: that a stamped figure can be SAVED at all, in png, pdf, svg and svgz;
that what comes back out is what went in; that the git field tracks the repo the
script lives in, including -dirty; that a format with no metadata channel is
left alone; and that a stamp the backend rejects costs the stamp rather than the
figure.

DOES NOT COVER: that the values are meaningful to a human six months later, or
that the .pth hook installs itself in a venv -- that is `ergon fig status`, and
it needs a venv this suite deliberately does not build.
"""
from __future__ import annotations

import os
import subprocess
import sys

import matplotlib
import pytest

matplotlib.use("Agg")
import matplotlib.figure as mfigure  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
import ergon_figprov  # noqa: E402
import ergon_figread  # noqa: E402

READERS = {
    "png": ergon_figread.from_png,
    "pdf": ergon_figread.from_pdf,
    "svg": ergon_figread.from_svg,
    "svgz": ergon_figread.from_svg,
}
FORMATS = tuple(READERS)


def _figure():
    fig = mfigure.Figure()
    fig.subplots().plot([0, 1], [0, 1])
    return fig


def _save(tmp_path, ext, **kw):
    p = os.path.join(str(tmp_path), f"plot.{ext}")
    _figure().savefig(p, **kw)
    return p


def _stamped():
    """The patch is global and idempotent; install it once, on demand."""
    if not getattr(mfigure.Figure.savefig, "_ergon_provenance", False):
        ergon_figprov._patch(mfigure)
    return mfigure.Figure.savefig


# --- the round trip ---------------------------------------------------------

def test_every_format_saves_and_reads_back(tmp_path):
    """The assertion that would have caught the shipped crash on day one."""
    _stamped()
    seen = {}
    for ext in FORMATS:
        p = _save(tmp_path, ext)
        assert os.path.getsize(p) > 0, f"{ext}: nothing was written"
        meta = READERS[ext](p)
        assert meta, f"{ext}: saved, but carries no ergon provenance"
        seen[ext] = {k[len("ergon."):]: v for k, v in meta.items()}

    for key in ("date", "host", "python", "env"):
        for ext in FORMATS:
            assert key in seen[ext], f"{ext} lost the {key} field"

    # Identical content through four different metadata channels. Anything that
    # survives one encoding and not another is the bug this file is about.
    for key in ("host", "python", "env"):
        values = {seen[ext][key] for ext in FORMATS}
        assert len(values) == 1, f"{key} differs across formats: {values}"


def test_git_field_tracks_the_scripts_repo(tmp_path, monkeypatch):
    """The -dirty suffix is the point: a hash alone cannot reproduce a figure."""
    repo = tmp_path / "repo"
    repo.mkdir()
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@e",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@e"}
    run = lambda *a: subprocess.run(a, cwd=str(repo), env=env, check=True,
                                    capture_output=True)
    run("git", "init", "-q")
    (repo / "plot.py").write_text("# a script that makes a figure\n")
    run("git", "add", "plot.py")
    run("git", "commit", "-qm", "one")

    _stamped()
    monkeypatch.setattr(sys, "argv", [str(repo / "plot.py")])

    clean = ergon_figprov.provenance()
    assert "ergon.git" in clean, "a script inside a repo got no commit"
    assert not clean["ergon.git"].endswith("-dirty")

    (repo / "plot.py").write_text("# edited, not committed\n")
    dirty = ergon_figprov.provenance()
    assert dirty["ergon.git"].endswith("-dirty"), \
        "an uncommitted tree was recorded as if it were reproducible"


def test_a_format_with_no_metadata_channel_is_left_alone(tmp_path):
    """Better an unstamped JPEG than one that looks stamped and is not."""
    _stamped()
    assert ergon_figprov._merge("x.jpg", None, None) is None
    user = {"Some": "value"}
    assert ergon_figprov._merge("x.jpg", None, user) is user


def test_a_rejected_stamp_costs_the_stamp_not_the_figure(tmp_path, monkeypatch):
    """The module's own promise, against the half that actually failed."""
    _stamped()
    monkeypatch.setattr(ergon_figprov, "_merge",
                        lambda fn, fmt, um: {"ergon.bogus": "x", **(um or {})})
    p = _save(tmp_path, "svg")
    assert os.path.exists(p) and os.path.getsize(p) > 0, \
        "a stamp the backend refused took the figure with it"


# --- negative control -------------------------------------------------------
# Everything above compares a dict against a file. A bug in the readers would
# make every one of them compare {} with {} and pass, and the original defect
# would sail through. Prove the suite can still see it.

def test_the_original_defect_would_still_be_caught(tmp_path):
    """Hand the SVG writer an ergon.* key directly, the way the bug did.

    Through __wrapped__, which functools.wraps points at the unpatched savefig,
    so this reaches the backend without the retry guard in front of it. If this
    ever stops raising, matplotlib has changed and the fix above is free to be
    reverted -- which is a thing worth being told.
    """
    _stamped()
    unpatched = mfigure.Figure.savefig.__wrapped__
    with pytest.raises(ValueError, match="Unknown metadata key"):
        unpatched(_figure(), os.path.join(str(tmp_path), "raw.svg"),
                  metadata={"ergon.script": "x.py"})


def test_the_readers_can_return_nothing(tmp_path):
    """And that an unstamped file reads back empty rather than inventing fields."""
    orig = ergon_figprov._merge
    try:
        ergon_figprov._merge = lambda fn, fmt, um: um
        for ext in FORMATS:
            p = _save(tmp_path, ext)
            assert READERS[ext](p) == {}, f"{ext}: found provenance in a file with none"
    finally:
        ergon_figprov._merge = orig
