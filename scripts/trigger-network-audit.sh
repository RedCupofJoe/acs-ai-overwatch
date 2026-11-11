#!/usr/bin/env bash
# Compatibility wrapper. The Rosey demo script is scripts/demo/agents/rosey-regrets.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${ROSEY_URL:-}" ]]; then
  export AGENT_URL="${ROSEY_URL}"
fi
if [[ -n "${NETWORK_AUDIT_COMMAND:-}" ]]; then
  export AGENT_MESSAGE="${NETWORK_AUDIT_COMMAND}"
fi

exec "${ROOT}/demo/agents/rosey-regrets.sh"
