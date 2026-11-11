#!/usr/bin/env bash
# Run Remediated Sam and show the telemetry label and SPIFFE JWT that Sneaky Sam lacked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/agent.sh
source "${ROOT}/lib/agent.sh"

require_oc
MESSAGE="${AGENT_MESSAGE:-Are you emitting telemetry, and which model do you use?}"

if ! oc get sandbox remediated-sam -n "${RANGE_NS}" >/dev/null 2>&1; then
  echo "Sandbox remediated-sam is not in ${RANGE_NS}. Run scripts/demo/identify-terminate-rebuild.sh after the trust plane is ready." >&2
  exit 1
fi

print_banner "Remediated Sam" \
  "Sandbox remediated-sam. Telemetry and approved labels are set, and a SPIFFE JWT-SVID is mounted."

print_workload "remediated-sam"
print_spiffe "remediated-sam"
echo
agent_chat "remediated-sam" "${MESSAGE}"
echo
echo "Platform change: Sam now answers from an approved Sandbox with telemetry enabled. The original Deployment that omitted the label should already be gone."
