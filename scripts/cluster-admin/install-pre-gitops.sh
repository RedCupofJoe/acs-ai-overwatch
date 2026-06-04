#!/usr/bin/env bash
# Run all cluster-admin steps before registering/syncing Argo CD Applications.
#
# Usage:
#   ./scripts/cluster-admin/install-pre-gitops.sh
#   ./scripts/cluster-admin/install-pre-gitops.sh --skip-rbac
#   ./scripts/cluster-admin/install-pre-gitops.sh --with-values-file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SKIP_RBAC=false
WITH_VALUES_FILE=false
SKIP_DISCOVERY_PREREQS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-rbac)
      SKIP_RBAC=true
      shift
      ;;
    --skip-discovery-prereqs)
      SKIP_DISCOVERY_PREREQS=true
      shift
      ;;
    --with-values-file)
      WITH_VALUES_FILE=true
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: install-pre-gitops.sh [options]

Runs cluster-admin bootstrap before oc apply -k gitops/argocd/:

  0. Create AppProject acs-ai-overwatch (cluster-scoped CR permissions)
  1. Grant OpenShift GitOps application-controller RBAC (unless --skip-rbac)
  2. Create labeled PoC namespaces
  3. Create cluster ConfigMap acs-ai-overwatch-cluster-config
  4. Create discovery ServiceAccount + script ConfigMap (unless --skip-discovery-prereqs)

Options:
  --skip-rbac                 Skip ClusterRoleBinding (if managed-by namespaces are enough)
  --skip-discovery-prereqs    Let Argo CD create discovery SA/ConfigMap
  --with-values-file          Also run discover-cluster-values.sh (optional values-cluster.yaml)

Requires: oc login as cluster-admin, helm on PATH.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

run() {
  echo ""
  echo "==> $*"
  "$@"
}

run "${SCRIPT_DIR}/00-apply-appproject.sh"

if [[ "${SKIP_RBAC}" != true ]]; then
  run "${SCRIPT_DIR}/01-grant-openshift-gitops-rbac.sh"
else
  echo "Skipping 01-grant-openshift-gitops-rbac.sh (--skip-rbac)"
fi

run "${SCRIPT_DIR}/02-bootstrap-namespaces.sh"
run "${SCRIPT_DIR}/03-apply-cluster-configmap.sh"

if [[ "${SKIP_DISCOVERY_PREREQS}" != true ]]; then
  run "${SCRIPT_DIR}/04-apply-discovery-prerequisites.sh"
else
  echo "Skipping 04-apply-discovery-prerequisites.sh (--skip-discovery-prereqs)"
fi

if [[ "${WITH_VALUES_FILE}" == true ]]; then
  run "${REPO_ROOT}/scripts/discover-cluster-values.sh"
fi

cat <<EOF

Pre-GitOps bootstrap complete.

Next:
  1. Confirm StorageClass: oc get storageclass (default gp3-csi in values.yaml)
  2. Set repoURL in gitops/argocd/application*.yaml to your fork
  3. oc apply -k gitops/argocd/
  4. Sync Applications in order (or wait for sync-waves 0→1→2):
       acs-ai-overwatch-gitops-bootstrap
       acs-ai-overwatch-cluster-discovery
       acs-ai-overwatch
  4. Install [Red Hat Kueue Operator](README.md#red-hat-kueue-operator-prerequisite) manually before default-dsc syncs
  5. (Optional, for agent builds) Install OpenShift Pipelines — see README Prerequisites

Cluster ConfigMap:
  oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config -o yaml
EOF
