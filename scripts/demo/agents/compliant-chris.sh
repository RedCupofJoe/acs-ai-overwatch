#!/usr/bin/env bash
# Run Compliant Chris and show the approved shape: Sandbox, SPIFFE JWT, no scanners.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/agent.sh
source "${ROOT}/lib/agent.sh"

require_oc
MESSAGE="${AGENT_MESSAGE:-What share of students were placed?}"

if ! oc get sandbox compliant-chris -n "${RANGE_NS}" >/dev/null 2>&1; then
  echo "Sandbox compliant-chris is not in ${RANGE_NS}. Apply the trust-plane and approved Applications first." >&2
  exit 1
fi

print_banner "Compliant Chris" \
  "The Sandbox, the SPIFFE JWT file, and a CSV answer. RHACS should stay quiet for this workload."

print_workload "compliant-chris"
print_spiffe "compliant-chris"
echo
echo "Scanners in the image:"
print_scanners "compliant-chris"
echo
agent_chat "compliant-chris" "${MESSAGE}"
echo "Platform change: Chris answered from an Agent Sandbox with a SPIFFE JWT-SVID and no recon tools. This is the control case."
