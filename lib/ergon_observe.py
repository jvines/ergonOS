"""Is the target up, from where, and when.

    ergon observe TOI-700 --site paranal
    ergon observe "HD 209458" --site lasilla --date 2026-10-14

Airmass through the night, the observable window, and the moon. astroplan
underneath. Weekly during proposal season and nightly on a run, and the
alternative is a notebook you rewrite every time.
"""
from __future__ import annotations

import sys
import warnings

# astropy warns that an ICRS->GCRS separation depends on transformation
# direction. True, and irrelevant at the degree-level precision of "is the moon
# near my target" -- but it prints a five-line paragraph above the answer, and
# a tool whose output is mostly a warning is one people stop running.
warnings.filterwarnings("ignore", message=".*NonRotationTransformation.*")
warnings.filterwarnings("ignore", category=UserWarning, module="astropy.*")

# The sites people actually type, mapped to the names astropy knows. Aliases
# because "paranal" is what you say and "Paranal Observatory" is what the
# registry calls it, and being told "unknown site" for a site you are standing
# on is a poor experience.
ALIASES = {
    "paranal": "Paranal Observatory", "vlt": "Paranal Observatory",
    "lasilla": "La Silla Observatory", "la silla": "La Silla Observatory",
    "lco": "Las Campanas Observatory", "lascampanas": "Las Campanas Observatory",
    "keck": "Keck Observatory", "gemini-south": "Gemini South",
    "gemini-north": "Gemini North", "ctio": "Cerro Tololo",
    "apo": "Apache Point Observatory", "lapalma": "Roque de los Muchachos",
    "subaru": "Subaru Telescope", "mauna kea": "Mauna Kea",
}


def main(argv) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        print("\nsites:", ", ".join(sorted(ALIASES)))
        return 0

    site = "paranal"
    date = None
    names = []
    i = 0
    while i < len(argv):
        if argv[i] == "--site":
            site = argv[i + 1]; i += 2
        elif argv[i] == "--date":
            date = argv[i + 1]; i += 2
        else:
            names.append(argv[i]); i += 1
    target_name = " ".join(names)
    if not target_name:
        print("ergon-observe: which target?", file=sys.stderr)
        return 2

    try:
        import numpy as np
        from astropy.coordinates import EarthLocation, get_body
        from astropy.time import Time
        import astropy.units as u
        from astroplan import Observer, FixedTarget
    except ImportError as e:
        raise SystemExit(f"ergon-observe: needs astroplan ({e}).\n"
                         "               ergon bundle add astronomy")

    loc_name = ALIASES.get(site.lower(), site)
    try:
        loc = EarthLocation.of_site(loc_name)
    except Exception:
        raise SystemExit(f"ergon-observe: unknown site '{site}'.\n"
                         f"               known aliases: {', '.join(sorted(ALIASES))}\n"
                         "               or any name from astropy's site registry")
    obs = Observer(location=loc, name=loc_name)

    try:
        target = FixedTarget.from_name(target_name)
    except Exception as e:
        raise SystemExit(f"ergon-observe: cannot resolve '{target_name}': {e}")

    when = Time(date) if date else Time.now()
    # Midnight at the SITE, not wherever you are sitting. Getting this wrong
    # silently shifts the whole night and is the classic way these plots lie.
    midnight = obs.midnight(when, which="nearest")

    try:
        dusk = obs.twilight_evening_astronomical(midnight, which="previous")
        dawn = obs.twilight_morning_astronomical(midnight, which="next")
    except Exception:
        raise SystemExit("ergon-observe: no astronomical night at this site on this date "
                         "(polar summer, or a bad date)")

    print(f"\n  {target_name}  from  {loc_name}")
    print(f"  night of {midnight.datetime:%Y-%m-%d} (UTC)")
    print(f"  astronomical night  {dusk.datetime:%H:%M} -> {dawn.datetime:%H:%M}")

    moon_illum = obs.moon_illumination(midnight)
    moon = get_body("moon", midnight, location=loc)
    sep = moon.separation(target.coord).deg
    print(f"  moon                {moon_illum * 100:.0f}% illuminated, {sep:.0f} deg away")

    times = dusk + (dawn - dusk) * np.linspace(0, 1, 25)
    alt = obs.altaz(times, target).alt.deg
    airmass = obs.altaz(times, target).secz

    up = alt > 30
    if not up.any():
        print("\n  never above 30 deg — not observable from here on this date\n")
        return 0
    print(f"  above 30 deg        {times[up][0].datetime:%H:%M} -> {times[up][-1].datetime:%H:%M}"
          f"  ({(times[up][-1] - times[up][0]).to(u.hour).value:.1f} h)")
    print(f"  best airmass        {min(a for a, u_ in zip(airmass, up) if u_):.2f}\n")

    # A plot is the wrong answer in a terminal for something you check in ten
    # seconds between exposures.
    for t, a, am in zip(times[::2], alt[::2], airmass[::2]):
        if a < 0:
            bar = ""
        else:
            bar = "#" * int(a / 3)
        flag = " " if a > 30 else "."
        print(f"  {t.datetime:%H:%M} {a:5.1f} {flag} {bar}")
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
