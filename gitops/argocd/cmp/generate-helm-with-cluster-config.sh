#!/usr/bin/env bash
# Argo CD Config Management Plugin helper: render the main chart using cluster ConfigMap
# acs-ai-overwatch-system/acs-ai-overwatch-cluster-config (optional values-cluster.yaml override).
#
# Install as a CMP on the GitOps instance; point Application acs-ai-overwatch at the plugin
# when Helm lookup from the repo-server is unavailable. See gitops/argocd/cmp/README.md
set -euo pipefail

CHART_PATH="${CHART_PATH:-gitops/helm/acs-ai-overwatch}"
CM_NS="${CLUSTER_CONFIG_NAMESPACE:-acs-ai-overwatch-system}"
CM_NAME="${CLUSTER_CONFIG_NAME:-acs-ai-overwatch-cluster-config}"
VALUES_FROM_CM="/tmp/values-from-cluster-configmap.yaml"

cat >"${VALUES_FROM_CM}" <<EOF
cluster:
  appsDomain: ""
EOF

if command -v kubectl >/dev/null 2>&1 && kubectl get configmap -n "${CM_NS}" "${CM_NAME}" >/dev/null 2>&1; then
  appsDomain="$(kubectl get configmap -n "${CM_NS}" "${CM_NAME}" -o jsonpath='{.data.appsDomain}')"
  clusterName="$(kubectl get configmap -n "${CM_NS}" "${CM_NAME}" -o jsonpath='{.data.clusterName}')"
  quayServer="$(kubectl get configmap -n "${CM_NS}" "${CM_NAME}" -o jsonpath='{.data.quayRegistryServer}')"
  kagentiBase="$(kubectl get configmap -n "${CM_NS}" "${CM_NAME}" -o jsonpath='{.data.kagentiApiBaseUrl}')"
  gitUrl="$(kubectl get configmap -n "${CM_NS}" "${CM_NAME}" -o jsonpath='{.data.gitRepoUrl}')"
  cat >"${VALUES_FROM_CM}" <<EOF
cluster:
  name: ${clusterName}
  appsDomain: ${appsDomain}
quayStorage:
  registryCredentials:
    server: ${quayServer}
kagenti:
  api:
    baseUrl: ${kagentiBase}
  appSource:
    repoUrl: ${gitUrl}
EOF
elif [[ -z "${ALLOW_MISSING_CLUSTER_CONFIG:-}" ]]; then
  echo "ConfigMap ${CM_NS}/${CM_NAME} not found. Sync Application acs-ai-overwatch-cluster-discovery first." >&2
  exit 1
fi

helm template "${ARGOCD_APP_NAME:-acs-ai-overwatch}" "${CHART_PATH}" \
  -f "${CHART_PATH}/values.yaml" \
  -f "${CHART_PATH}/values-poc.yaml" \
  -f "${VALUES_FROM_CM}" \
  ${HELM_EXTRA_ARGS:-}
