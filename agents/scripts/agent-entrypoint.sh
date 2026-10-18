#!/usr/bin/env bash
# Container entrypoint for ACS PoC agents (FastAPI open harness + optional OTEL).
set -euo pipefail

# Prefer the OpenShell sandbox venv when present; otherwise UBI python-312
# (/opt/app-root) ahead of platform /usr/bin/python3.
export PATH="/sandbox/.venv/bin:/opt/app-root/bin:/usr/local/bin:/usr/bin:/bin"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-8000}"
export PYTHONPATH="${PYTHONPATH:-/opt/acs-agent}"

if [[ "${AGENT_HARNESS:-}" == "openclaw" ]] && command -v openclaw >/dev/null 2>&1; then
  mkdir -p /sandbox/.openclaw
  if [[ ! -f /sandbox/.openclaw/openclaw.json ]]; then
    cat > /sandbox/.openclaw/openclaw.json <<EOF
{
  "gateway": {"mode": "local", "bind": "loopback", "port": ${OPENCLAW_PORT:-18789}},
  "agents": {"defaults": {"workspace": "/sandbox"}},
  "models": {
    "providers": {
      "maas": {
        "baseUrl": "${LLM_API_BASE:-}",
        "api": "openai-completions",
        "models": [{"id": "${LLM_MODEL:-granite-3.1-8b-instruct-fp8}", "name": "MaaS Granite"}]
      }
    }
  }
}
EOF
  fi
  # The HTTP adapter on PORT stays the demo control plane. OpenClaw is the harness.
  if [[ "${OPENCLAW_GATEWAY:-true}" == "true" ]]; then
    openclaw gateway run --bind 127.0.0.1 --port "${OPENCLAW_PORT:-18789}" >/tmp/openclaw-gateway.log 2>&1 &
  fi
fi

exec "$@"
