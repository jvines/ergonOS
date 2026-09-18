#!/usr/bin/env bash
# IDLE_MIN=0: a database is not reaped. Something is probably connected to it,
# and pulling it out from under a session to save memory is a worse outcome
# than the memory.
set -euo pipefail
command -v pg_ctl >/dev/null || { echo "postgres is not installed" >&2; exit 1; }
sudo systemctl start postgresql
echo "   ok  postgres on :${PORT:-5432}"
