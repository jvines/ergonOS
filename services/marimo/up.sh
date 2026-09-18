#!/usr/bin/env bash
# marimo as a running server rather than a launch.
#
# Cold start is slow enough to break the "back of the envelope" feel the whole
# base python exists for -- by the time it is up you have lost the thought. So
# it runs, and the keybind opens a notebook against it.
set -euo pipefail
VENV="${PYFLEET_VENV:-${XDG_DATA_HOME:-$HOME/.local/share}/pyfleet}"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/ergon/marimo.log"
NOTEBOOKS="$HOME/notebooks"
mkdir -p "$(dirname "$LOG")" "$NOTEBOOKS"
[ -x "$VENV/bin/marimo" ] || { echo "marimo is not installed — ergon bundle add notebooks" >&2; exit 1; }
# --headless because the browser is opened by the keybind, not by the daemon;
# a service that spawns a browser window when systemd starts it is a service
# that opens a browser window at login.
setsid "$VENV/bin/marimo" edit --headless --no-token \
  --port "${PORT:-2718}" "$NOTEBOOKS" >>"$LOG" 2>&1 &
echo "   ok  marimo on http://localhost:${PORT:-2718}  (notebooks in $NOTEBOOKS)"
