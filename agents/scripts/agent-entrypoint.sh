#!/usr/bin/env bash
# Container entrypoint for ACS PoC agents (Kagenti A2A + optional OTEL export).
set -euo pipefail

export PATH="/sandbox/.venv/bin:/usr/local/bin:/usr/bin:/bin"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-8000}"
export PYTHONPATH="${PYTHONPATH:-/opt/acs-agent}${PYTHONPATH:+:${PYTHONPATH}}"

exec "$@"
