#!/usr/bin/env bash
# Run Rosey Regrets' Network Audit and show the scanners ACS is about to record.
# The reply returns immediately. nmap, masscan, rustscan, and naabu start in the background.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/agent.sh
source "${ROOT}/lib/agent.sh"

require_oc
MESSAGE="${AGENT_MESSAGE:-Network Audit}"

print_banner "Rosey Regrets" \
  "RHACS Violations → test-range-runtime-guardrails, then Mattermost Town Square. Monitor mode leaves the pod running."

print_workload "rosey-regrets"
print_policy "test-range-runtime-guardrails"
echo
echo "Scanners before the message:"
print_scanners "rosey-regrets"
echo
agent_chat "rosey-regrets" "${MESSAGE}"
wait_for_scanner "rosey-regrets"
print_transcripts "rosey-regrets"
echo
echo "Giving the sensor a moment to report the process..."
sleep 8
print_bridge
echo
echo "Platform change: recon processes are running inside the Rosey pod and transcripts are on the output volume. The runtime policy records that in monitor mode."
