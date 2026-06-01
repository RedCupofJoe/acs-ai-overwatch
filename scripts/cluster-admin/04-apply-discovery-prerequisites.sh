#!/usr/bin/env bash
# Pre-create cluster-discovery ServiceAccount, RBAC, and script ConfigMap so the
# acs-ai-overwatch-cluster-discovery Argo Application can skip those resources or re-sync cleanly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO_ROOT="$(cluster_admin_repo_root)"
CHART="${REPO_ROOT}/gitops/helm/acs-ai-overwatch-cluster-discovery"
NAMESPACE="${DISCOVERY_NAMESPACE:-acs-ai-overwatch-system}"

cluster_admin_require_cluster_admin

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required" >&2
  exit 1
fi

if ! "${KUBE_CMD[@]}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Namespace ${NAMESPACE} does not exist. Run 02-bootstrap-namespaces.sh first." >&2
  exit 1
fi

cluster_admin_info "Applying discovery ServiceAccount, RBAC, and script ConfigMap ..."
helm template acs-ai-overwatch-cluster-discovery "${CHART}" \
  --show-only templates/rbac.yaml \
  --show-only templates/configmap-script.yaml \
  | "${KUBE_CMD[@]}" apply -f -

cluster_admin_info "Done:"
cluster_admin_info "  ${KUBE_CMD[*]} get sa,cm -n ${NAMESPACE} | grep cluster-discovery"
