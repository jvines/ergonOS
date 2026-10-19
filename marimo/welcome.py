# ERGON-55. The welcome notebook (`ergon welcome --gui`, and first login when
# marimo and a browser exist). It types no fact about this machine: every cell
# runs a command and shows what it printed, so it cannot drift from the system
# (AGENTS.md: ground truth is queryable). test-welcome.sh fails if a keybind or
# a bundle name is ever typed in here.
#
# Edit a copy, not this file: `ergon welcome --edit` puts one in ~/notebooks.
import marimo

app = marimo.App(width="medium")


@app.cell
def _():
    import os
    import shutil
    import subprocess

    import marimo as mo

    ergon = shutil.which("ergon") or os.path.join(
        os.environ.get("ERGON", ""), "bin", "ergon"
    )

    def run(*args, limit=20):
        # stdin closed and a timeout: a command that waits on a person, or
        # hangs, becomes one line saying so instead of a frozen notebook.
        try:
            p = subprocess.run(
                [ergon, *args],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=limit,
            )
        except (OSError, subprocess.TimeoutExpired) as e:
            return f"(could not run: {e})"
        text = (p.stdout or "").rstrip()
        if p.returncode != 0:
            text += f"\n(exit {p.returncode}) {(p.stderr or '').strip()}"
        return text or "(it printed nothing)"

    def show(*args):
        return mo.md(f"```\n{run(*args)}\n```")

    return mo, run, show


@app.cell
def _(mo, run):
    mo.md(run("explain", "welcome"))
    return


@app.cell
def _(mo, show):
    # (title, command) pairs: names of commands, not facts about the machine.
    sections = {
        "Commands: ergon --help": ("--help",),
        "Keys: ergon keys": ("keys", "--print"),
        "Bundles: ergon bundle list": ("bundle", "list"),
        "Topics: ergon explain --list": ("explain", "--list"),
        "Health: ergon doctor": ("doctor",),
    }
    mo.accordion({title: show(*cmd) for title, cmd in sections.items()})
    return


if __name__ == "__main__":
    app.run()
