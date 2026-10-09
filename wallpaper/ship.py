"""Make one shipped background field from its approved 8K master, and prove it.

    python ship.py --masters DIR --out DIR --work DIR --theme DIR FIELD...

FIELD is a master's stem, e.g. `julia-1`. For each one this writes
<out>/<FIELD>-3840x2400.npz and prints one tab-separated manifest row
(see shipped.tsv). Development only: it reads the NAS, and nothing on an
installed machine runs it (ERGON-74).

What ships is the APPROVED field, made smaller, never a fresh render. Seven
generators changed after their masters were made (ea29107, summation order),
so rendering a seed today would draw a sibling of the image that was approved,
up to 1/255 away. The master is the only copy of what was looked at.

Two checks gate a row, and a row that fails either is printed with the reason
and no file is kept:

  approved  the master field, coloured at 8K by today's code in the palette
            it was approved in, against the 8K PNG that was approved. Says
            whether colouring has drifted since, and settles which PNG a
            multi-seed generator's field belongs to. More than 1 pixel in
            100,000 off by more than 2/255, or any by more than 4, fails it:
            that background would ship as something nobody approved.
  shipped   the shipped file against the exact 2x2 average it was made from,
            coloured at four panel sizes in two palettes, one light and one
            dark. Within 1/255 everywhere but on the odd pixel that sits on an
            edge of the 512-entry colour lookup (at most 1 in 100,000, and
            never past 4/255), or the next wider dtype is tried: float16
            first, because it halves the download, then float32, then
            float64. normalise()'s rank equalisation is one reason this
            cannot be assumed: float16 ties values that were distinct, and
            ties reorder ranks.
"""

import argparse
import hashlib
import shutil
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import lib  # noqa: E402
import render  # noqa: E402

SIZE = "3840x2400"
# 16:10 at the field's own size, 16:10 at 1.5x (not a whole factor), 3:2 (the
# Framework's aspect, a crop) and 16:9 (a crop, then a whole factor).
PANELS = ("3840x2400", "2560x1600", "2256x1504", "1920x1080")
DTYPES = ("float16", "float32", "float64")

# The approved PNGs, by generator. Names were given by hand when each was
# approved, so a generator with several seeds has several candidates, and the
# colouring check decides which one a field is.
APPROVED = {
    "bifurcation": ["logistic"], "blackhole": ["blackhole-luminet"],
    "bogdanov": ["bogdanov-k1.6"], "bzreaction": ["bz-spiral"],
    "cardiac": ["heart-fibrillation"], "caustics": ["caustics-pool"],
    "chladni": ["chladni-0"], "clifford": ["clifford"],
    "cosmicweb": ["cosmicweb-fine"], "cyclicspecies": ["rps-pair"],
    "diffraction": ["diffraction-jwst", "diffraction-penrose", "diffraction-sierpinski"],
    "doublependulum": ["doublependulum"], "epithelium": ["tissue-growing"],
    "erosion": ["erosion-basins"], "flame": ["flame-silk"],
    "foldedtowel": ["towel-arch"], "fractaltree": ["tree-jacaranda"],
    "galaxycollision": ["galaxy-collision-loop"], "gaussbif": ["gauss-bubble"],
    "grayscott": ["grayscott-maze"], "henon": ["henon-basin", "henon-sheaf"],
    "hydrogen": ["hydrogen-10k-orbital", "hydrogen-stark-fan"],
    "ikeda": ["ikeda-zoom"], "instability": ["instability-billows", "instability-plumes"],
    "ising": ["ising-islands"],
    "julia": ["julia-dendrite", "julia-rabbit", "julia-spirals"],
    "koch": ["koch-vortex-offset"], "kuramoto": ["ks-thicket"],
    "leafvenation": ["leaf-blade"], "lensing": ["lensing-cluster", "lensing-ring"],
    "lichtenberg": ["lichtenberg-fan", "lichtenberg-forest"], "lorenz": ["lorenz"],
    "lorenzviews": ["lorenz-view-one-wing", "lorenz-view-top"],
    "mandelbrot": ["mandelbrot"],
    "mandelbrotdeep": ["mandelbrot-deep-minibrot", "mandelbrot-deep-seahorse"],
    "masscentre": ["masscentre-triangle"], "multifractal": ["multifractal-crossing"],
    "murmuration": ["murmuration-figure"], "pendulumphase": ["pendulumphase"],
    "perlin": ["perlin-flow-broad"], "perlinmap": ["perlinmap-contours"],
    "phyllotaxis": ["phyllotaxis-sunflower"], "phylogeny": ["tree-of-life-extinctions"],
    "physarum": ["slime-network"], "quantumscar": ["quantumscar-bowtie"],
    "resonance": ["resonance-earth-venus", "resonance-jupiter-saturn", "resonance-trappist1"],
    "rossler": ["rossler-lattice", "rossler-ring", "rossler-sail"],
    "snowflake": ["snowflake-plate"], "spiralgalaxy": ["spiral-galaxy"],
    "tentbif": ["tent-full"], "threebody": ["threebody"],
    "tipvortex": ["tipvortex-flap-pair", "tipvortex-wake"],
    "vortexstreet": ["vortex-near"],
}


def colour(field_path, gen, seed, palette, size, out):
    """render.py, exactly as a palette switch runs it, minus the subprocess."""
    sys.argv = ["render.py", "--generator", gen, "--palette", palette,
                "--size", size, "--seed", str(seed), "--from-field", field_path,
                "--out", out]
    render.main()
    return read_png(out)


def read_png(path):
    import matplotlib.image as mpimg
    a = mpimg.imread(path)
    if a.dtype != np.uint8:
        a = np.round(a * 255).astype(np.uint8)
    return a[..., :3].astype(np.int16)


def palettes(theme):
    out = []
    for name in sorted(os.listdir(theme)):
        if name.endswith(".env") and name != "type.env":
            p = os.path.join(theme, name)
            if "COOL_BG0" in lib.load_palette(p):
                out.append(p)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--masters", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--theme", required=True)
    # Every 8K master was coloured in catppuccin: one script made them all
    # (verify8k.sh, 2026-09-21) and it named that palette. Known, so not
    # guessed. Guessing went wrong: colouring a 960x600 copy in every palette
    # and taking the nearest matched masscentre-0 to kanagawa, because line art
    # thickens when it is shrunk, and 23 approved backgrounds were held as
    # drifted that coloured into their PNGs exactly once the palette was right.
    ap.add_argument("--palette", default=None, help="default: <theme>/catppuccin.env")
    ap.add_argument("fields", nargs="+")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    pals = palettes(args.theme)
    pal = args.palette or os.path.join(args.theme, "catppuccin.env")

    for stem in args.fields:
        gen, seed = stem.rsplit("-", 1)
        work = os.path.join(args.work, stem)
        os.makedirs(work, exist_ok=True)
        master = os.path.join(args.masters, f"{stem}-7680x4800.npy")
        m = np.asarray(np.load(master), dtype=np.float64)

        # WHICH PNG, and how far today's colouring is from it: the master at
        # 8K, against every candidate at full size. The right one is 0-3/255
        # off; a wrong one differs wherever the two images do (8% and 22% of
        # julia-1's pixels, most of a Julia set being shared empty ground).
        mine = colour(master, gen, seed, pal, "7680x4800", os.path.join(work, "8k.png"))
        scores = []
        for cand in APPROVED[gen]:
            png = read_png(os.path.join(args.masters, f"{cand}-8k.png"))
            if png.shape != mine.shape:
                scores.append((1.0, 255, cand))
                continue
            d = np.abs(mine - png).max(axis=-1)
            scores.append((float((d > 2).mean()), int(d.max()), cand))
            del png, d
        del mine
        scores.sort()
        a_frac, a_max, approved = scores[0]
        # One clear match, or the mapping is a guess -- and a guessed
        # provenance is the thing PROVENANCE.md exists to refuse.
        if len(scores) > 1 and scores[1][0] <= 2 * a_frac + 0.001:
            print(f"{stem}\tFAIL\tambiguous: {scores}", flush=True)
            continue
        if a_max > 4 or a_frac > 1e-5:
            print(f"{stem}\tFAIL\tdraws something else than {approved}-8k.png: "
                  f"{a_frac:.1%} of pixels more than 2/255 off, at most {a_max}", flush=True)
            continue

        # SHIPPED: the exact 4K average, then the narrowest dtype that colours
        # the same image in the approved palette AND in one of the other
        # lightness -- every palette is one keypress away, and a light ramp
        # spends its levels differently from a dark one.
        light = lib.is_light(lib.load_palette(pal))
        other = next(p for p in pals if lib.is_light(lib.load_palette(p)) != light)
        ref = lib.downsample(m, 2)
        del m
        ref_path = os.path.join(work, "ref.npy")
        np.save(ref_path, ref)
        cases = [(p, s) for p in (pal, other) for s in PANELS]
        want = {c: colour(ref_path, gen, seed, c[0], c[1], os.path.join(work, "ref.png"))
                for c in cases}
        result = None
        for dt in DTYPES:
            cand_path = os.path.join(work, f"{stem}-{SIZE}.npz")
            np.savez_compressed(cand_path, **lib.pack_field(ref.astype(dt)))
            # Measured on cardiac-0: float32 was 0/255 off everywhere but ONE
            # pixel of 3.4M, 3/255 off where its value sat on a lookup edge, and
            # "1/255 anywhere" sent it to float64 at 60 MB. float16 was 3-4/255
            # off on 0.02% of pixels -- the drift render.py already refused for
            # the prepared cache -- and is still refused here.
            b_max, b_frac = 0, 0.0
            for c in cases:
                d = np.abs(colour(cand_path, gen, seed, c[0], c[1],
                                  os.path.join(work, "got.png")) - want[c]).max(axis=-1)
                b_max, b_frac = max(b_max, int(d.max())), max(b_frac, float((d > 1).mean()))
            if b_max <= 4 and b_frac <= 1e-5:
                result = (dt, cand_path, b_max, b_frac)
                break
        if result is None:
            print(f"{stem}\tFAIL\tno dtype colours the same image", flush=True)
            continue
        dt, cand_path, b_max, b_frac = result
        final = os.path.join(args.out, os.path.basename(cand_path))
        shutil.move(cand_path, final)
        with open(final, "rb") as f:
            sha = hashlib.sha256(f.read()).hexdigest()
        print("\t".join([os.path.basename(final), sha, str(os.path.getsize(final)), dt,
                         f"{approved}-8k.png", os.path.basename(pal)[:-4],
                         str(a_max), f"{a_frac:.6f}", str(b_max), f"{b_frac:.2e}"]), flush=True)
        for f in os.listdir(work):
            os.remove(os.path.join(work, f))


if __name__ == "__main__":
    main()
