#!/usr/bin/env bash
# Container entrypoint for ACS PoC agents (FastAPI open harness + optional OTEL).
set -euo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-8000}"
export PYTHONPATH="${PYTHONPATH:-/opt/acs-agent}"

exec "$@"
