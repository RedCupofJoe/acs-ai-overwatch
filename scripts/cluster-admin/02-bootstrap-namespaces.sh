#!/usr/bin/env bash
# Create PoC namespaces with argocd.argoproj.io/managed-by so Argo CD can manage them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO_ROOT="$(cluster_admin_repo_root)"
CHART="${REPO_ROOT}/gitops/helm/acs-ai-overwatch-gitops-bootstrap"

cluster_admin_require_cluster_admin

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required to render namespace manifests" >&2
  exit 1
fi

cluster_admin_info "Applying namespaces from ${CHART} ..."
helm template acs-ai-overwatch-gitops-bootstrap "${CHART}" \
  | "${KUBE_CMD[@]}" apply -f -

cluster_admin_info "Done. Example label check:"
cluster_admin_info "  ${KUBE_CMD[*]} get ns acs-ai-overwatch-system -o jsonpath='{.metadata.labels.argocd\\.argoproj\\.io/managed-by}{\"\\n\"}'"
