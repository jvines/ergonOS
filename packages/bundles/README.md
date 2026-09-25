# Bundles

Optional groups of packages, chosen at install time and changeable afterwards.

The base system is deliberately small: Arch, uv, and `packages/python` — enough
to check an order of magnitude and plot something. Everything a particular kind
of work needs lives in a bundle, so a machine carries the stack it is for and
nothing else.

    ergon-bundle list              what exists, what is installed, what it costs
    ergon-bundle info inference    what is in one
    ergon-bundle add inference     install it, and record it
    ergon-bundle remove inference  uninstall it, and un-record it

Bundles are recorded in `hosts/<host>/host.env` as `BUNDLES="..."`, so
reprovisioning a machine reproduces it. `ergon-bundle sync` installs exactly what
that line declares, and provisioning calls it.

Each install records what it actually added to this machine in
`~/.local/state/ergon/bundle-ledger`: packages that were not there before and
that the bundle names. `remove` uninstalls only those — never something the
machine already had — and never a package that `packages/pacman`,
`packages/aur`, `packages/python` or a hardware profile lists. A package another
enabled bundle also needs is kept, and its record moves to that bundle. With no
record (state wiped), `remove` uninstalls nothing and says so.

## Adding a bundle

One directory per bundle, each file optional, and nothing else in it:

    meta      DESCRIPTION, SIZE_MB, REQUIRES, NOTE
    pacman    official repo packages
    aur       AUR packages, built by makepkg
    python    PyPI requirements, installed into the pyfleet venv
    git       NAME @ git+https://...  or  NAME @ git+ssh://...

`meta` is **data, not shell**: `KEY=word` or `KEY="text"`, with no `$`, backtick
or backslash inside the quotes. It is never sourced, so `ergon-bundle list` runs
nothing from a bundle.

Lists are one entry per line, `#` starts a comment. Every line must match its
file's grammar — package names, PEP 508 names with extras and version specifiers,
no options, no markers, no URLs outside `git` — because these lines become
arguments to `sudo pacman` and uv. A bundle with one bad line is refused whole.

`git` exists because not everything is on PyPI, and because a name being on
PyPI does not mean it is the package you meant: `lachesis` there is a
closed-caption segmentation tool by someone else entirely. The `NAME` is the
distribution name from the project's `pyproject.toml`, which is not always the
repository's name (nereus-py installs as `astronereus`); remove drops by it. A
URL with no `@ref` follows the default branch.

`ergon-lint` holds `lib/` to these lists: every module it imports must be in
one, and every `ergon bundle add NAME` it prints must name a bundle that has
what the message is about. Drop a package here and the lint says who needed it.

`REQUIRES` is checked before installing and reports what it actually found —
see `gpu/meta`. It warns; it does not refuse. The machine is the user's.

## Bundles from elsewhere

A bundle can live in any git repository, as a directory in the format above:

    ergon-bundle info github:me/overlay//            what the repository holds
    ergon-bundle info github:me/overlay//fleet       what one bundle installs
    ergon-bundle add  github:me/overlay//fleet@v1    install it
    ergon-bundle update fleet                        fetch again, show the diff, ask

A source is `LOCATION//BUNDLE[@REF]`. LOCATION is `github:owner/repo`,
`codeberg:owner/repo`, `gitlab:group/repo`, an `https://` or `ssh://` URL (give a
port as `ssh://git@host:2222/me/overlay.git`), `user@host:path`, or a local git
repository. REF is a branch or a tag. `http://` and `git://` are refused: anyone
on the network path could change what installs as root.

`add` shows everything the bundle would install and asks. Without a terminal it
refuses unless given `--yes` — provisioning passes that for sources named in
`ERGON_BUNDLES`, because naming one there is the answer. `--as NAME` adds it
under another name; a bundle may not take a built-in's name.

The bundle's files are **copied** into `hosts/<host>/bundles/<name>/`, with a
`.source` recording the URL, bundle, ref and commit. After that it is local:
`sync`, `remove`, `list` and `info` never fetch, so reinstalling a machine needs
no access to the source. Commit the copy with `git add -f` (`hosts/*/` is
ignored upstream). `update` is the only command that goes back to the source; it
installs additions and leaves dropped packages installed for `remove` to take.

Fetches never prompt: ssh runs in BatchMode, so a private forge needs the key in
the agent and the host in `known_hosts` first.

**What this does not protect against.** The copy pins the list, not what the
lists resolve to: pacman, the AUR, PyPI and a git ref can all change later. AUR
PKGBUILDs and Python source builds run their own code. A private package named
bare in `python` resolves from public PyPI — use a `git` line for anything that
is not on PyPI. Read a third-party bundle before saying yes.
