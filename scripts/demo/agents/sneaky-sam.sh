#!/usr/bin/env bash
# Run Sneaky Sam and show the deploy-time gap: the telemetry label is absent.
# The pod keeps serving because the policy is in monitor mode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/agent.sh
source "${ROOT}/lib/agent.sh"

require_oc
MESSAGE="${AGENT_MESSAGE:-Hello Sam, are you sending telemetry?}"

print_banner "Sneaky Sam" \
  "RHACS Violations → test-range-sneaky-sam-telemetry-violation. The missing label is the finding. Chat proves the pod is still up."

print_workload "sneaky-sam"
print_policy "test-range-sneaky-sam-telemetry-violation"
echo
echo "Label contrast in ${RANGE_NS}:"
oc get deploy -n "${RANGE_NS}" \
  -o custom-columns='NAME:.metadata.name,TELEMETRY:.spec.template.metadata.labels.acs-ai-overwatch\.io/telemetry' \
  2>/dev/null || true
echo
agent_chat "sneaky-sam" "${MESSAGE}"
print_bridge
echo
echo "Platform change: Sam answered from a Deployment that omits acs-ai-overwatch.io/telemetry. Hank and Rosey carry that label. ACS records the deploy policy and leaves Sam running."
