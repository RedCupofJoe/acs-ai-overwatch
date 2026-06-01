#!/usr/bin/env bash
# AppProject required for cluster-scoped chart resources (DSC, ClusterPolicy, Namespaces).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO_ROOT="$(cluster_admin_repo_root)"
PROJECT_FILE="${REPO_ROOT}/gitops/argocd/appproject-acs-ai-overwatch.yaml"

cluster_admin_require_cluster_admin

if [[ ! -f "${PROJECT_FILE}" ]]; then
  echo "Missing ${PROJECT_FILE}" >&2
  exit 1
fi

cluster_admin_info "Applying AppProject acs-ai-overwatch ..."
"${KUBE_CMD[@]}" apply -f "${PROJECT_FILE}"
