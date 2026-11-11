#!/usr/bin/env bash
# Run Helpful Hank and show that the platform stays quiet.
# Telemetry is on, no recon tools start, and the runtime policy does not fire.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/agent.sh
source "${ROOT}/lib/agent.sh"

require_oc
MESSAGE="${AGENT_MESSAGE:-Hello Hank, who are you?}"

print_banner "Helpful Hank" \
  "Inventory in test-range. Telemetry label stays enabled. No scanner process and no new runtime violation."

print_workload "helpful-hank"
echo
echo "Scanners before the message:"
print_scanners "helpful-hank"
echo
agent_chat "helpful-hank" "${MESSAGE}"
echo "Scanners after the message:"
print_scanners "helpful-hank"
echo
echo "Platform change: Hank answered. The pod is still a plain Deployment with telemetry enabled, and no recon process started."
