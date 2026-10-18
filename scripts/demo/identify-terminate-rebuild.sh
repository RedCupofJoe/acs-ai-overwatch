#!/usr/bin/env bash
# Identify (ACS already recorded monitor-mode violations), terminate, then rebuild.
# Refuses to start until the trust-plane operators are installed.
# If the misbehavior Application was never created, there is nothing to terminate.
set -euo pipefail

GITOPS_NS="${GITOPS_NS:-openshift-gitops}"
MISBEHAVIOR_APP="${MISBEHAVIOR_APP:-acs-ai-overwatch-misbehavior}"
RANGE_NS="${RANGE_NS:-test-range}"
BUILDER_NS="${BUILDER_NS:-acs-agent-builder}"
BUILDER_DEPLOY="${BUILDER_DEPLOY:-acs-agent-builder}"

if ! command -v oc >/dev/null 2>&1; then
  echo "oc is required" >&2
  exit 1
fi

csv_succeeded() {
  local namespace="$1"
  local phase
  phase="$(oc get csv -n "${namespace}" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || true)"
  grep -q Succeeded <<<"${phase}"
}

echo "Checking the trust plane before identify/terminate/rebuild..."
for ns in zero-trust-workload-identity-manager trusted-profile-analyzer agent-sandbox-system keycloak; do
  if ! csv_succeeded "${ns}"; then
    echo "Operator CSV in ${ns} is not Succeeded. Apply the trust-plane Application and wait." >&2
    exit 1
  fi
done

oc get zerotustworkloadidentitymanager.operator.openshift.io cluster -n zero-trust-workload-identity-manager >/dev/null
oc get keycloak.k8s.keycloak.org rhtpa -n keycloak >/dev/null
oc get deploy rhtpa-postgres rhtpa-minio -n trusted-profile-analyzer >/dev/null
echo "Trust plane operators are installed."

if ! oc get application "${MISBEHAVIOR_APP}" -n "${GITOPS_NS}" >/dev/null 2>&1; then
  echo "Misbehavior Application is not installed. Nothing to terminate."
  exit 0
fi

echo "Switching ${MISBEHAVIOR_APP} from monitor to enforce..."
oc patch application "${MISBEHAVIOR_APP}" -n "${GITOPS_NS}" --type merge -p '{"spec":{"source":{"helm":{"parameters":[{"name":"enforcement.mode","value":"enforce"}]}},"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
oc annotate application "${MISBEHAVIOR_APP}" -n "${GITOPS_NS}" argocd.argoproj.io/refresh=hard --overwrite

echo "Waiting for ACS to terminate Hank, Rosey, and Sam..."
gone=0
for _ in $(seq 1 60); do
  left="$(oc get pods -n "${RANGE_NS}" --no-headers 2>/dev/null | awk '$1 ~ /^(helpful-hank|rosey-regrets|sneaky-sam)-/ {print $1}' || true)"
  if [[ -z "${left}" ]]; then
    echo "Shadow agent pods are gone."
    gone=1
    break
  fi
  echo "still running: ${left}"
  sleep 10
done
if [[ "${gone}" != "1" ]]; then
  echo "Timed out waiting for ACS to terminate the shadow agents." >&2
  exit 1
fi

echo "Asking the builder to rebuild Rosey and Sam through the TPA package gate..."
oc exec -n "${BUILDER_NS}" "deploy/${BUILDER_DEPLOY}" -c builder -- python -c '
import json, urllib.request
body = json.dumps({"targets":[
  {"from":"rosey-regrets","to":"remediated-rosey"},
  {"from":"sneaky-sam","to":"remediated-sam"}
]}).encode()
req = urllib.request.Request("http://127.0.0.1:8000/rebuild", data=body, headers={"Content-Type":"application/json"})
print(urllib.request.urlopen(req, timeout=30).read().decode())
'

for _ in $(seq 1 120); do
  status="$(oc exec -n "${BUILDER_NS}" "deploy/${BUILDER_DEPLOY}" -c builder -- python -c '
import json, urllib.request
data = json.load(urllib.request.urlopen("http://127.0.0.1:8000/rebuild/status", timeout=15))
jobs = list((data.get("jobs") or {}).values())
print(jobs[-1].get("status", "pending") if jobs else "pending")
')"
  echo "builder status: ${status}"
  if [[ "${status}" == "rolled-out" ]]; then
    echo "Rebuild finished. Remediated agents are Sandbox CRs."
    exit 0
  fi
  if [[ "${status}" == "failed" ]]; then
    echo "Rebuild failed the TPA package gate or the Sandbox apply." >&2
    exit 1
  fi
  sleep 15
done

echo "Timed out waiting for the builder." >&2
exit 1
