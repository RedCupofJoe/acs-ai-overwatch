#!/usr/bin/env bash
# In-cluster entrypoint (Job). Requires DISCOVERY_NAMESPACE and DISCOVERY_CONFIGMAP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=openshift-cluster-discovery.sh
source "${SCRIPT_DIR}/openshift-cluster-discovery.sh"

GIT_REPO_URL="${GIT_REPO_URL:-${GIT_REPO_URL_DEFAULT:-https://github.com/RedCupofJoe/acs-ai-overwatch.git}}"
export GIT_REPO_URL

openshift_discover_run
openshift_discover_apply_configmap \
  "${DISCOVERY_NAMESPACE}" \
  "${DISCOVERY_CONFIGMAP}" \
  "${APPS_DOMAIN}" \
  "${CLUSTER_NAME}" \
  "${QUAY_REGISTRY_SERVER}" \
  "${KAGENTI_API_BASE_URL}" \
  "${GIT_REPO_URL}" \
  "${API_SERVER}"

echo "Updated ConfigMap ${DISCOVERY_NAMESPACE}/${DISCOVERY_CONFIGMAP}"
