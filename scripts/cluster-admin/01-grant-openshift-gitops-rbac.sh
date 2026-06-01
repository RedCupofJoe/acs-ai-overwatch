#!/usr/bin/env bash
# Grant the OpenShift GitOps application controller permission to deploy the PoC chart.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO_ROOT="$(cluster_admin_repo_root)"
RBAC_FILE="${REPO_ROOT}/gitops/argocd/bootstrap/openshift-gitops-controller-rbac.yaml"

cluster_admin_require_cluster_admin

if [[ ! -f "${RBAC_FILE}" ]]; then
  echo "Missing ${RBAC_FILE}" >&2
  exit 1
fi

cluster_admin_info "Applying ClusterRoleBinding for openshift-gitops-argocd-application-controller ..."
"${KUBE_CMD[@]}" apply -f "${RBAC_FILE}"

cluster_admin_info "Done. Verify:"
cluster_admin_info "  ${KUBE_CMD[*]} auth can-i create serviceaccounts -n acs-ai-overwatch-system --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller"
