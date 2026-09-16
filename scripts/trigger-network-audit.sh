#!/usr/bin/env bash
set -euo pipefail

# Triggers a "Network Audit" command for the Rosey Regrets agent HTTP API.
#
# Required:
#   export ROSEY_URL="http://rosey-regrets.test-range.svc.cluster.local"
#
# Optional:
#   export NETWORK_AUDIT_COMMAND="Network Audit"

ROSEY_URL="${ROSEY_URL:-http://rosey-regrets.test-range.svc.cluster.local}"
NETWORK_AUDIT_COMMAND="${NETWORK_AUDIT_COMMAND:-Network Audit}"

echo "Triggering '${NETWORK_AUDIT_COMMAND}' for rosey-regrets at ${ROSEY_URL}..."
curl -sS -X POST "${ROSEY_URL%/}/chat" \
  -H "Content-Type: application/json" \
  -d "{\"message\":\"${NETWORK_AUDIT_COMMAND}\"}"
echo
