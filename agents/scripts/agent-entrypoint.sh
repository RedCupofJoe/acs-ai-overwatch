#!/usr/bin/env bash
# Container entrypoint for ACS PoC agents (FastAPI open harness + optional OTEL).
set -euo pipefail

# Prefer the OpenShell sandbox venv when present; otherwise UBI python-312
# (/opt/app-root) ahead of platform /usr/bin/python3.
export PATH="/sandbox/.venv/bin:/opt/app-root/bin:/usr/local/bin:/usr/bin:/bin"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-8000}"
export PYTHONPATH="${PYTHONPATH:-/opt/acs-agent}"

exec "$@"
