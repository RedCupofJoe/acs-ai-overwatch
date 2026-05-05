#!/usr/bin/env bash
set -euo pipefail

# Triggers a "Network Audit" command for the Rosey Regrets agent through Kagenti API.
#
# Required:
#   export KAGENTI_API_BASE="https://kagenti-api.apps.example.com"
#   export KAGENTI_API_TOKEN="<bearer-token>"
#
# Optional:
#   export ROSEY_AGENT_NAME="rosey-regrets"
#   export NETWORK_AUDIT_COMMAND="Network Audit"
#   export KAGENTI_COMMANDS_PATH_TEMPLATE="/api/v1/agents/{agent}/commands"
#   export KAGENTI_TLS_INSECURE="false"

KAGENTI_API_BASE="${KAGENTI_API_BASE:?set KAGENTI_API_BASE}"
KAGENTI_API_TOKEN="${KAGENTI_API_TOKEN:?set KAGENTI_API_TOKEN}"
ROSEY_AGENT_NAME="${ROSEY_AGENT_NAME:-rosey-regrets}"
NETWORK_AUDIT_COMMAND="${NETWORK_AUDIT_COMMAND:-Network Audit}"
KAGENTI_COMMANDS_PATH_TEMPLATE="${KAGENTI_COMMANDS_PATH_TEMPLATE:-/api/v1/agents/{agent}/commands}"
KAGENTI_TLS_INSECURE="${KAGENTI_TLS_INSECURE:-false}"

command_path="${KAGENTI_COMMANDS_PATH_TEMPLATE/\{agent\}/${ROSEY_AGENT_NAME}}"
command_url="${KAGENTI_API_BASE%/}${command_path}"

curl_flags=(-sS -X POST "$command_url" \
  -H "Authorization: Bearer ${KAGENTI_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"command\":\"${NETWORK_AUDIT_COMMAND}\",\"source\":\"acs-violation-loop\"}")

if [[ "${KAGENTI_TLS_INSECURE}" == "true" ]]; then
  curl_flags=(-k "${curl_flags[@]}")
fi

echo "Triggering '${NETWORK_AUDIT_COMMAND}' for agent '${ROSEY_AGENT_NAME}'..."
response="$(curl "${curl_flags[@]}")"
echo "${response}"
