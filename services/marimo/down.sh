#!/usr/bin/env bash
set -uo pipefail
# By executable and full command, never `pkill -f marimo`: that pattern matches
# the shell running this script and any editor with marimo in its title.
pkill -x marimo 2>/dev/null || pgrep -f "marimo edit --headless" | xargs -r kill 2>/dev/null || true
echo "   ok  marimo stopped"
