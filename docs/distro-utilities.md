# Utilities for the distro

Running list. Nothing here is built yet except the bundle system.

The distro is for anyone doing data science, not only astronomers, and **must
not hardcode anything about this fleet**. Where a utility needs a machine to
talk to, it gets pluggable backends and the fleet is a backend that lives in a
private overlay — not two forks of the distro.

---

## Confirmed

| command | what it does | why it matters |
|---|---|---|
| `ergon-peek FILE` | schema, head, summary stats for parquet, CSV, FITS, npy, JSON | one incantation instead of four half-remembered ones. A collaborator sends you a file and you look at it without caring what it is. Columna's core is the parquet backend; astropy does FITS |
| `ergon-fig` | stamps git SHA, script path, date and environment hash into figure metadata at save time; `ergon-fig whence plot.png` reads it back | six months later nobody can tell which script or commit made a figure. Costs nothing at write time, invisible until needed, and is the reproducibility thesis made concrete |
| `ergon-cite ID` | bibcode / DOI / arXiv → BibTeX appended to the project `.bib`, via ADS, Crossref, arXiv | daily papercut with no Linux answer |
| `ergon-cite --software` | correct BibTeX for numpy/scipy/astropy/emcee **at the installed versions** | journals increasingly require it and everyone fakes it |
| `ergon-doctor` | is OMP_NUM_THREADS sane, what BLAS is numpy linked to, uv present, bundles consistent with host.env, disk, swap | also the bug-report format for a public distro: "paste ergon-doctor" beats twenty questions |
| `ergon-new` | project scaffold: pyproject, lockfile, gitignored `data/`, `figures/`, a `.bib`, git init | the twenty minutes between an idea and running code |
| `ergon-kernel` | register the current uv env as a named Jupyter kernel (marimo uses none) | uv envs are invisible to Jupyter; everyone hits this in week one |
| `ergon-watch` | supervise a long run, notify on finish or death | start a 6-hour chain, close the lid, find out what happened |
| `ergon-archive` | find stale multi-GB outputs (old chains, intermediate FITS) and push them to NAS or S3 | computational scientists accumulate hundreds of GB they never open and notice when the disk fills mid-run |
| `ergon-ship HOST` | reproduce this project's locked environment elsewhere, run, bring results back | what makes "cluster frontend" mean something |

### `ergon-ship` backends

- **default / public** — spin up a container somewhere, or plain ssh with the
  lockfile. No assumption of a scheduler.
- **slurm** — for people who have one.
- **fleet** — the coordinator claim, the elastic nodes, WoL. Lives in the
  private overlay, because `coordinator.jvines.cl` means nothing to anyone else.

The backend is a plugin, not a fork. One distro.

---

## Astronomy (the astronomy bundle)

- **Archive queries.** ESO — both the raw archive and **P2**, which nothing
  wraps well. VizieR. **ExoFOP TESS**, which returns clean JSON. `eso-query`
  already exists (github.com/jvines/eso-query) and should be the backend rather
  than a rewrite.
- **TAC proposal templates.** ESO, CNTAC, and the rest. The formats change, so
  the design is: carry a bundled template AND check upstream for a newer one at
  use time, warning if the bundled copy is stale rather than silently producing
  last cycle's format.

---

## Services

Services are not tools. The rule, taken from `bin/llama-server.sh`: **explicit
up/down with an idle reaper, nothing autostarted.** A distro that idles at 4 GB
because it started six daemons is a distro people uninstall. `ergon-svc up <name>`.

| service | verdict |
|---|---|
| **Postgres** | in, with the extensions configurable at install: `pgvector`, `postgis`, **`q3c`**, **`pgsphere`**. Q3C/pgSphere give cone search and catalogue crossmatch in SQL and nobody ships them preconfigured |
| **DuckDB** | in, as an option. No server, reads parquet in place. Probably matters more day to day than Postgres |
| **LanceDB** | in — embedded, columnar, no daemon. The vector store that is a file rather than a service |
| **MLflow** | maybe. Good idea, unproven for samplers. Weigh **Aim** against it: lighter and local-first |
| **Langfuse** | **no**. Wants Postgres + ClickHouse + Redis + MinIO for LLM tracing on a laptop |
| **Qdrant / Pinecone** | no. A daemon for something that should be a file; Pinecone is hosted |

## Also in

- **Quarto** — `.qmd` to PDF/HTML with citations and executable code. The
  notebook-to-paper path. Single binary
- **DVC** — git for big files. The data half of reproducibility; pairs with
  `ergon-archive` and `ergon-fig`
- **dbt-core**
- **TOPCAT** — already in the astronomy bundle
- **Snakemake** — *to evaluate.* Declarative resumable DAG with real traction in
  science rather than in data engineering. Gives per-output provenance for free,
  which is most of what `ergon-fig` does by hand
- **`llm`** (simonw) if there is an LLM story — one pip install, SQLite-logs
  every prompt

---

## Round two

**In.**

- **Snapshot before every `pacman -Syu`.** A pacman pre-transaction hook into
  snapper. btrfs subvolumes, snapper and `bin/ergon-rollback` already work; this is
  the missing piece. It is the whole of openSUSE's pitch and arguably the
  headline feature: you cannot break this with an update
- **`ergon-target ID`** — TOI/TIC/HD/Gaia/2MASS to one terminal card: coordinates,
  magnitudes, parallax and distance, TESS sectors, known planets, finding chart
- **`ergon-observe TARGET --site --date`** — airmass, visibility window, moon
  separation. astroplan underneath
- **First-run tour.** Most of why omarchy sticks. A new user shown the keybinds
  and the bundles in two minutes stays; one dropped into an unfamiliar tiling WM
  reinstalls Ubuntu
- **Referee response scaffolding** — pair each comment with a response, track
  what is addressed, emit the response letter and a change-marked manuscript.
  Optionally LLM-assisted, against a local server or a key the user supplies
- **Backup, preconfigured** — restic or borg with excludes that understand a
  scientist's tree: skip `.venv`, caches and regenerable outputs; keep code,
  notes, `.bib`, figures, lockfiles
- **Waybar module for running jobs**, local and remote
- **Clipboard to dataframe** — a table copied out of a PDF is one `ergon-peek -` away
- **`scratch/` convention** — excluded from backup, auto-archived after N days,
  because the alternative is what everyone does, which is never deleting anything
- **`ergon-repro`** — lockfile, data hashes, scripts, container recipe. Low
  priority; wanted more by journals than by us

**Out.** Figure compliance checking against journal specs — not useful enough.

**Done, as `ergon watch`** (ERGON-19). The parked `ergon-run --mem` — a systemd
scope plus oomd, so a runaway sampler does not take the session down — is now
what every `ergon watch` does: a scope of its own under `app.slice`, with
`--mem` for the limit. What made it work in practice rather than in theory was
the part the proposal did not have: a shared wezterm process means one cgroup
for every terminal, so the scope, not the slice drop-in, is what contains a run.
zram is still parked — it changes what hibernation resumes from, and that needs
`test-hibernate.sh` in a VM before it goes anywhere near a machine.

## Round three

**In.**

- **Plots in the terminal.** wezterm speaks the iTerm image protocol, so a
  matplotlib backend can render inline in the shell — no GUI window, and it
  works identically over ssh to a compute node. The payoff for the terminal
  choice that `tmux -CC` already justified
- **`ergon-arxiv`** — new listings filtered by keywords and followed authors, in a
  TUI. One key to save the PDF to the librarian, one to `ergon-cite` it into the
  current project. **Not astro-only**: arXiv carries most of physics, maths, CS,
  stats, quantitative biology and economics, and the daily-listing ritual is the
  same in all of them. Highest-engagement thing on the list
- **Encrypted project data.** fscrypt or gocryptfs on `data/`, unlocked by the
  login session through the keyring that autostart.lua already runs. Embargoed
  observations in plaintext on a laptop that travels is not paranoia, it is the
  terms you agreed to when you got the time. Reads as a bigger win in other
  fields — medical, human-subjects — than in ours
- **Automatic rollback on failed boot.** If the session fails to come up twice,
  boot the previous snapshot rather than dumping the user at a TTY. What turns
  "you can roll back" into "you do not have to know how to roll back"
- **Presentation profile** — one keybind: bigger fonts, notifications off, bar
  cleaned up, neutral wallpaper
- **Night profile** — half built already: `media.lua` steps hyprsunset warm and
  the comment says "useful at a telescope for the obvious reason". Make it a
  profile: deep red shift, brightness floor, notifications suppressed
- **`ergon-sync`** — your config follows you to a new machine. This repo,
  productised: point a fresh install at your git remote and it is *your*
  machine, bundles included, because host.env already records them

**Out.** visidata — Columna is baked in instead.

- **LSP wired to the project venv.** `ergon-new` writes the config pointing the
  language server at `.venv`, so imports resolve and go-to-definition works
  without per-project, per-editor fiddling. Editor-agnostic by design
- **Editor choice at install.** emacs, neovim, and whatever else, chosen like a
  bundle — and it sets `$EDITOR`/`$VISUAL` too, not just the package

## Round four — structural

**In.**

- **Weekly known-good validation in CI.** Arch is rolling; some Tuesday
  something breaks. The Forgejo runner plus `bin/test-arch-vm.sh` +
  `bin/test-hypr-session.sh` already install from the real ISO and assert that
  the desktop works down to a synthetic click. Run it weekly against current
  Arch and publish the manifest that passed. This is the line between "Arch with
  good scripts" and a distro, and the harness already exists
- **Install by `curl | bash` from the stock Arch ISO**, not a custom ISO built
  with archiso. Lower maintenance, never ships a stale kernel, honest about what
  it is. Revisit only if it is ever what holds adoption back
- **Hardware quirks by DMI match** — `hardware/<vendor>-<model>/` drop-ins
  applied at provision time, the same shape as `hosts/<host>/`. The Framework is
  the reference machine; the first ThinkPad with Nvidia is the whole support
  burden. Cheap now, near-impossible to retrofit
- **MIME associations and thumbnailers** — `.parquet` opens Columna, `.fits`
  opens theia, and the file manager previews a FITS image instead of a generic
  icon. Most of what makes a system feel finished rather than assembled
- **`ergon-bench`** — matmul, FFT, a small sampler, timed next to the thread
  config. The diagnosis lives in `ergon-doctor`'s BLAS rows instead: bench has
  no process pool, so it cannot observe the oversubscription this used to claim
  to catch (ERGON-63)
- **`ergon-calc '3 Rjup in Rearth'`** — astropy units from the shell, no REPL
- **Locale and keyboard asked at install**, like every other installer

**Deferred.** The name. It will follow the Greek scheme; brainstorm separately.
Note that every command is `ergon-*` and the rename gets more expensive per
utility added.
