#!/usr/bin/env bash
# Container entrypoint for ACS PoC agents (FastAPI open harness + optional OTEL).
set -euo pipefail

# UBI python-312 installs packages into /opt/app-root; keep that ahead of
# platform /usr/bin/python3 (3.9 on UBI9), which does not have httpx/fastapi.
export PATH="/opt/app-root/bin:/usr/local/bin:/usr/bin:/bin"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-8000}"
export PYTHONPATH="${PYTHONPATH:-/opt/acs-agent}"

exec "$@"
