"""Back-of-the-envelope with units, from the shell.

    ergon calc '3 Rjup in Rearth'
    ergon calc '1 AU / c in minutes'
    ergon calc 'sqrt(G * Msun / AU) in km/s'

astropy.units underneath, which is why dimensional mistakes fail loudly instead
of producing a number that looks fine. That is the whole reason astropy is in
the base python -- catching a factor of 1000 before it reaches a plot.
"""
from __future__ import annotations

import math
import re
import sys


def build_namespace():
    import astropy.constants as const
    import astropy.units as u
    import numpy as np

    ns = {}
    # Every unit astropy knows, by its own name and its aliases.
    for name in dir(u):
        obj = getattr(u, name)
        if isinstance(obj, (u.UnitBase, u.Quantity)):
            ns[name] = obj
    # Constants by their short names: c, G, M_sun. Plus the spellings people
    # actually type, which astropy does not define.
    for name in dir(const):
        obj = getattr(const, name)
        if hasattr(obj, "unit"):
            ns[name] = obj
    # Plurals, because that is how the question is asked: "in minutes", not
    # "in minute". astropy defines the singular and the abbreviation only.
    for sing in ("second", "minute", "hour", "day", "year", "meter", "metre",
                 "gram", "kelvin", "radian", "degree", "arcsec", "arcmin",
                 "parsec", "lightyear", "angstrom", "electronvolt", "jansky"):
        if hasattr(u, sing):
            ns[sing + "s"] = getattr(u, sing)
    ns.update({
        "Msun": const.M_sun, "Rsun": const.R_sun, "Lsun": const.L_sun,
        "Mearth": const.M_earth, "Rearth": const.R_earth,
        "Mjup": const.M_jup, "Rjup": const.R_jup,
        "np": np, "pi": math.pi, "e": math.e,
        "sqrt": np.sqrt, "log": np.log, "log10": np.log10, "exp": np.exp,
        "sin": np.sin, "cos": np.cos, "tan": np.tan, "abs": abs,
    })
    return ns, u


def main(argv) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    expr = " ".join(argv)

    ns, u = build_namespace()

    # "X in Y" is how a person says it and is not Python. Split on the LAST
    # ` in `, because the left side can contain one ("1 AU in km" is fine, but
    # so is "sin(x)" -- the spaces are what disambiguate).
    target = None
    m = re.search(r"\s+in\s+(?!.*\s+in\s+)(.+)$", expr)
    if m:
        target, expr = m.group(1).strip(), expr[:m.start()].strip()

    # ^ reads as exponent to everyone outside Python.
    expr = expr.replace("^", "**")

    # "3 Rjup" is how physics is written and is a syntax error in Python:
    # juxtaposition means multiplication everywhere except here. Insert the
    # operator between a number (or a closing paren) and a following name.
    #
    # The \s+ is load-bearing -- without it "1e5" would become "1*e*5", since
    # the exponent is a bare identifier as far as a regex is concerned.
    expr = re.sub(r"([\d.)])\s+([A-Za-z_])", r"\1*\2", expr)

    try:
        value = eval(expr, {"__builtins__": {}}, ns)  # noqa: S307
    except Exception as e:
        print(f"ergon-calc: cannot evaluate {expr!r}: {e}", file=sys.stderr)
        return 1

    if target:
        try:
            unit = eval(target, {"__builtins__": {}}, ns)  # noqa: S307
        except Exception as e:
            print(f"ergon-calc: cannot convert to {target!r}: {e}", file=sys.stderr)
            return 1
        try:
            if isinstance(unit, u.UnitBase):
                value = value.to(unit)
            else:
                # The target is a CONSTANT, not a unit -- Rearth, Msun, c.
                # `.to()` on one of those produces nonsense ("33.6 6.378e+06 m")
                # because a Quantity is not a unit. The question "how many
                # Earth radii" is a ratio, so answer it as one and label it
                # with what was actually asked for.
                ratio = (value / unit).decompose()
                print(f"{float(ratio):.6g} {target}")
                return 0
        except Exception as e:
            print(f"ergon-calc: cannot convert to {target!r}: {e}", file=sys.stderr)
            return 1

    try:
        print(f"{value.value:.6g} {value.unit}")
    except AttributeError:
        print(f"{value:.6g}" if isinstance(value, float) else value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
