#!/usr/bin/env bash
# ERGON-67 real run, in a throwaway container (needs docker and network): scaffold a
# project, uv sync, and prove marimo and the project package import in the
# project env and the starter notebook exports. Not part of the fast gate.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
docker run --rm --label cl.jvines.owner=ergon-67 -v "$REPO":/repo:ro \
  ghcr.io/astral-sh/uv:python3.13-bookworm bash -ec '
    export HOME=/tmp/h; mkdir -p $HOME/.local/bin; ln -sf "$(command -v uv)" $HOME/.local/bin/uv
    cd /tmp && /repo/bin/ergon-new demo-proj >/dev/null && cd demo-proj
    grep -q "\"marimo\"" uv.lock
    uv run python -c "import marimo, demo_proj"
    grep -q "import demo_proj" <<<"$(uv run marimo export script notebooks/starter.py)"
  ' && echo "   ok   ergon new project: locked marimo imports, starter notebook exports" \
    || { echo "   FAIL ergon new + marimo" >&2; exit 1; }
