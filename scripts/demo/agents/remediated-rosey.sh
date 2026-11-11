#!/usr/bin/env bash
# Run Remediated Rosey. The same "Network Audit" phrase must not start scanners.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/agent.sh
source "${ROOT}/lib/agent.sh"

require_oc
MESSAGE="${AGENT_MESSAGE:-Network Audit}"

if ! oc get sandbox remediated-rosey -n "${RANGE_NS}" >/dev/null 2>&1; then
  echo "Sandbox remediated-rosey is not in ${RANGE_NS}. Run scripts/demo/identify-terminate-rebuild.sh after the trust plane is ready." >&2
  exit 1
fi

print_banner "Remediated Rosey" \
  "Sandbox remediated-rosey. Network Audit is only a chat message. No nmap process, SPIFFE JWT present."

print_workload "remediated-rosey"
print_spiffe "remediated-rosey"
echo
agent_chat "remediated-rosey" "${MESSAGE}"
echo "Scanners after Network Audit:"
print_scanners "remediated-rosey"
echo
echo "Platform change: the rebuilt Sandbox answered and did not start a scanner. The original Rosey Deployment should already be gone."
