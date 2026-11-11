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
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

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
  2. Raise the application-controller memory limit (the 2Gi default OOMs on this chart)
  3. Create labeled PoC namespaces
  4. Create cluster ConfigMap acs-ai-overwatch-cluster-config
  5. Create discovery ServiceAccount + script ConfigMap (unless --skip-discovery-prereqs)

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

# The default 2Gi limit OOM-kills the controller while it compares this chart.
# A dead controller leaves Application operations stuck in Running.
echo ""
echo "==> Raise openshift-gitops application-controller memory to 8Gi"
oc patch argocd openshift-gitops -n openshift-gitops --type merge -p '{"spec":{"controller":{"resources":{"requests":{"cpu":"500m","memory":"2Gi"},"limits":{"cpu":"2","memory":"8Gi"}}}}}'

# gp3-csi is WaitForFirstConsumer. A Pending PVC is healthy enough to let the
# next sync wave create the pod that binds it. Without this, the wave waits
# forever and never reaches Central.
# The sandbox SSO user is "admin" and is not a member of cluster-admins.
# Argo CD only looks at groups by default, so that login reaches the UI and then
# gets permission denied. Match the username claim as well.
echo "==> Grant the admin SSO user access to the Argo CD UI"
oc patch argocd openshift-gitops -n openshift-gitops --type merge -p '{"spec":{"rbac":{"policy":"g, system:cluster-admins, role:admin\ng, cluster-admins, role:admin\ng, admin, role:admin\n","scopes":"[groups, preferred_username, email]"}}}'

echo "==> Treat unbound PersistentVolumeClaims as healthy"
oc patch argocd openshift-gitops -n openshift-gitops --type merge -p "$(cat <<'EOF'
{"spec":{"resourceHealthChecks":[{"group":"","kind":"PersistentVolumeClaim","check":"hs = {}\nif obj.status ~= nil and obj.status.phase ~= nil then\n  if obj.status.phase == \"Bound\" or obj.status.phase == \"Pending\" then\n    hs.status = \"Healthy\"\n  else\n    hs.status = \"Degraded\"\n  end\n  hs.message = obj.status.phase\nelse\n  hs.status = \"Healthy\"\n  hs.message = \"PVC status is not set\"\nend\nreturn hs\n"}]}}
EOF
)"

run "${SCRIPT_DIR}/02-bootstrap-namespaces.sh"
cluster_admin_ensure_single_operatorgroup redhat-ods-operator redhat-ods-operator
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
  1. AWS GPU nodes, NFD instance, GPU node label, and Service Mesh 3 (skip cert-manager, ClusterPolicy, and DSC; Helm owns ClusterPolicy/DSC):
       ./scripts/cluster-admin/05-apply-platform-prep.sh
       # or: make platform-prep
  2. Confirm StorageClass: oc get storageclass (default gp3-csi in values.yaml)
  3. Set repoURL in gitops/argocd/application*.yaml to your fork
  4. oc apply -k gitops/argocd/
  5. Wait for sync-waves 0→1→2→4:
       acs-ai-overwatch-gitops-bootstrap
       acs-ai-overwatch-cluster-discovery
       acs-ai-overwatch
       acs-ai-overwatch-observability
  6. Hard-refresh the main app after the cluster ConfigMap exists
  7. After OpenShift Pipelines CSV Succeeded, create quay-build-robot in
     acs-agent-builder and oc create a PipelineRun (see README Quick Start)

Kueue is not required (DataScienceCluster kueue.managementState: Removed).

Cluster ConfigMap:
  oc get cm -n acs-ai-overwatch-system acs-ai-overwatch-cluster-config -o yaml
EOF
