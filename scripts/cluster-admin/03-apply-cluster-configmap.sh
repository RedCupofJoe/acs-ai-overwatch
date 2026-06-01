#!/usr/bin/env bash
# Discover cluster settings from the current login and create/update the cluster ConfigMap
# consumed by the main Helm chart (acs-ai-overwatch-cluster-config).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../lib/openshift-cluster-discovery.sh
source "${REPO_ROOT}/scripts/lib/openshift-cluster-discovery.sh"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

NAMESPACE="${CLUSTER_CONFIG_NAMESPACE:-acs-ai-overwatch-system}"
CONFIGMAP_NAME="${CLUSTER_CONFIG_NAME:-acs-ai-overwatch-cluster-config}"
GIT_DEFAULT="${GIT_REPO_URL_DEFAULT:-https://github.com/RedCupofJoe/acs-ai-overwatch.git}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --configmap)
      CONFIGMAP_NAME="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

cluster_admin_require_oc
export GIT_REPO_URL_DEFAULT="${GIT_DEFAULT}"

if ! "${KUBE_CMD[@]}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Namespace ${NAMESPACE} does not exist. Run 02-bootstrap-namespaces.sh first." >&2
  exit 1
fi

openshift_discover_run

cluster_admin_info "Writing ConfigMap ${NAMESPACE}/${CONFIGMAP_NAME} ..."
openshift_discover_apply_configmap \
  "${NAMESPACE}" \
  "${CONFIGMAP_NAME}" \
  "${APPS_DOMAIN}" \
  "${CLUSTER_NAME}" \
  "${QUAY_REGISTRY_SERVER}" \
  "${KAGENTI_API_BASE_URL}" \
  "${GIT_REPO_URL}" \
  "${API_SERVER}"

cluster_admin_info "Done:"
"${KUBE_CMD[@]}" get configmap -n "${NAMESPACE}" "${CONFIGMAP_NAME}" -o yaml | grep -E '^  (appsDomain|clusterName|quayRegistryServer|kagentiApiBaseUrl|gitRepoUrl):'
