"""Stamp provenance into every figure, without anyone remembering to.

Six months after the fact, nobody can tell which script or which commit produced
a figure. The information exists at save time and is thrown away; this keeps it,
in the file's own metadata, where it travels with the image.

WHY IT IS AUTOMATIC
-------------------
A `save_with_provenance()` helper would be correct and unused. The value is in
never thinking about it, so this patches `Figure.savefig` for the whole
environment: a `.pth` file in the pyfleet venv imports this module at
interpreter start, and every plot made by that python carries its origin.

It is deliberately cheap when matplotlib is never imported -- which is most
runs. The import hook unhooks itself the moment it has done its job.

READ IT BACK
------------
    ergon fig whence plot.png

PNG carries it in tEXt chunks, PDF and SVG in their metadata dictionaries.
Formats without a metadata channel (JPEG) are left alone rather than being
silently not-stamped-but-looking-stamped.
"""
from __future__ import annotations

import builtins
import os
import subprocess
import sys

PREFIX = "ergon"
_state = {"patched": False}


def _run(cmd, cwd):
    try:
        out = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=2)
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


def _git(start: str) -> str:
    """Commit of the repo the SCRIPT lives in, not the cwd.

    The cwd is wherever you happened to launch from and is frequently not a
    repo at all; the script's directory is the thing whose history explains the
    figure. The -dirty suffix matters more than the hash: a figure made from
    uncommitted code cannot be reproduced from the hash alone, and that is
    exactly what you need to know six months later.
    """
    if not start or not os.path.isdir(start):
        return ""
    sha = _run(["git", "rev-parse", "--short", "HEAD"], start)
    if not sha:
        return ""
    dirty = _run(["git", "status", "--porcelain"], start)
    return f"{sha}-dirty" if dirty else sha


def provenance() -> dict:
    import datetime
    script = os.path.abspath(sys.argv[0]) if sys.argv and sys.argv[0] else ""
    meta = {
        f"{PREFIX}.date": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        f"{PREFIX}.host": os.uname().nodename,
        f"{PREFIX}.python": sys.version.split()[0],
    }
    if script:
        meta[f"{PREFIX}.script"] = script
        sha = _git(os.path.dirname(script))
        if sha:
            meta[f"{PREFIX}.git"] = sha
    # The environment, identified by the thing that actually determines results.
    venv = os.environ.get("VIRTUAL_ENV") or sys.prefix
    if venv:
        meta[f"{PREFIX}.env"] = venv
    try:
        import numpy
        meta[f"{PREFIX}.numpy"] = numpy.__version__
    except Exception:
        pass
    return meta


# PNG and SVG take arbitrary key/value pairs. PDF's Info dictionary does NOT:
# it has a fixed set of keys, and matplotlib raises on anything else. So the
# whole record goes into Keywords as one string rather than being dropped.
_ARBITRARY = {"png", "svg", "svgz"}
_FIXED_PDF = {"pdf"}


def _merge(fname, fmt, user_meta):
    fmt = (fmt or (os.path.splitext(str(fname))[1].lstrip(".") or "png")).lower()
    p = provenance()
    if fmt in _ARBITRARY:
        out = dict(p)
        out.update(user_meta or {})
        return out
    if fmt in _FIXED_PDF:
        out = dict(user_meta or {})
        flat = " ".join(f"{k}={v}" for k, v in p.items())
        out["Keywords"] = (out.get("Keywords", "") + " " + flat).strip()
        return out
    return user_meta  # JPEG and friends: no metadata channel, leave it alone


def _patch(figure_module) -> None:
    import functools

    Figure = figure_module.Figure
    original = Figure.savefig

    # functools.wraps is not cosmetic here. pyplot builds its module-level
    # savefig with @_copy_docstring_and_deprecators(Figure.savefig), which
    # inspects __qualname__ and raises
    #     RuntimeError: Wrapped method from unexpected class: _patch.<locals>.savefig
    # for anything that does not look like it came from Figure. Without the
    # copied metadata, importing pyplot fails outright.
    @functools.wraps(original)
    def savefig(self, fname, *args, **kwargs):
        try:
            kwargs["metadata"] = _merge(fname, kwargs.get("format"), kwargs.get("metadata"))
        except Exception:
            # Never let provenance break a save. A lost stamp is a nuisance; a
            # lost figure at the end of a long run is not.
            pass
        return original(self, fname, *args, **kwargs)

    # An explicit marker, because functools.wraps deliberately makes the
    # wrapper indistinguishable from the original by every other means.
    savefig._ergon_provenance = True
    Figure.savefig = savefig
    _state["patched"] = True


def install() -> None:
    if os.environ.get("ERGON_FIG_PROVENANCE", "1") == "0":
        return
    real_import = builtins.__import__

    def hooked(name, *a, **kw):
        mod = real_import(name, *a, **kw)
        if not _state["patched"] and name.split(".")[0] == "matplotlib":
            fm = sys.modules.get("matplotlib.figure")
            # `is not None` is not enough. figure.py's own `import matplotlib`
            # re-enters this hook while figure.py is still executing, so the
            # module object exists in sys.modules with no Figure class on it
            # yet -- reading it raises "partially initialized module ... most
            # likely due to a circular import". Wait for the class itself.
            if fm is not None and getattr(fm, "Figure", None) is not None:
                try:
                    _patch(fm)
                except Exception:
                    pass
                if _state["patched"]:
                    # Unhook only on success, and only then: past this point the
                    # cost is zero, and a permanent __import__ wrapper in every
                    # interpreter is a rude thing for a distro to leave behind.
                    builtins.__import__ = real_import
        return mod

    builtins.__import__ = hooked


install()
