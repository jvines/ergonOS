# Third-party colour schemes

Six of the palettes in this directory are not ours. They reproduce the published
colour values of established schemes, each under its own licence, and each of
those licences is MIT — which permits redistribution and **requires that the
copyright and permission notice travel with the values**. That is what this file
is. It is not a courtesy.

Only the hex values are upstream's. The *mapping* — which upstream colour fills
which of Ergon's 22 roles — is ours, and is documented in the header of each
`.env` file. Where a scheme does not publish a colour for a role, the `.env`
says so rather than inventing one.

| palette | scheme | upstream | licence |
|---|---|---|---|
| `catppuccin.env` | Catppuccin Mocha | <https://github.com/catppuccin/palette> | MIT, © 2021 Catppuccin |
| `gruvbox.env` | Gruvbox dark, medium | <https://github.com/morhetz/gruvbox> | MIT/X11 (see note) |
| `nord.env` | Nord | <https://github.com/nordtheme/nord> | MIT |
| `everforest.env` | Everforest dark, medium | <https://github.com/sainnhe/everforest> | MIT |
| `rose-pine.env` | Rosé Pine (main) | <https://github.com/rose-pine/rose-pine-theme> | MIT, © 2023 Rosé Pine |
| `tokyo-night.env` | Tokyo Night (Storm) | <https://github.com/enkia/tokyo-night-vscode-theme> | MIT, © 2018-present Enkia |

The remaining palettes — `cool`, `winter`, `spring`, `summer`, `autumn`,
`plasma` — are generated from matplotlib colormaps and are ours; see the header
of `cool.env` for the derivation.

**Gruvbox note.** The repository declares MIT/X11 in its README and MIT in its
`package.json`, and ships **no `LICENSE` file**. The declaration is clear and
consistent, but there is no licence text in-tree to quote, which is why the
verbatim notice below is absent for that one entry. If upstream adds one, quote
it here.

**Naming.** Catppuccin asks that ports carrying its name follow its style guide.
That is a convention rather than a licence condition, but the palette here is
named for the scheme it reproduces and credits upstream, which is both the
honest and the low-friction reading of it.

---

## MIT License

The following notice applies to the Catppuccin, Nord, Everforest, Rosé Pine and
Tokyo Night colour values reproduced in this directory, each with its own
copyright line as listed in the table above.

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## If you add a palette

A palette that reproduces someone else's published colours is a redistribution.
Before adding one:

1. Find the actual `LICENSE` file, not a badge or a README line, and confirm it
   permits redistribution.
2. Add a row above, with the exact copyright line.
3. Put the upstream URL and the licence in the `.env` header too, so the file is
   self-describing when it is copied somewhere else — which is exactly what
   people do with palettes.

If provenance cannot be established, the palette does not ship. The same applies
to wallpapers, and more sharply: an image's licence is rarely the repository's.
