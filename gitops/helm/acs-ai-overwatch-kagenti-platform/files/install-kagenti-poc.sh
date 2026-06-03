#!/usr/bin/env bash
# Idempotent PoC install of the Kagenti platform using upstream setup-kagenti.sh.
set -euo pipefail

KAGENTI_GIT_URL="${KAGENTI_GIT_URL:?}"
KAGENTI_GIT_REF="${KAGENTI_GIT_REF:-main}"
KAGENTI_NS="${KAGENTI_NS:-kagenti-system}"
KC_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KC_REALM="${KEYCLOAK_REALM:-kagenti}"
SKIP_MLFLOW="${SKIP_MLFLOW:-true}"
SKIP_OVN="${SKIP_OVN_PATCH:-true}"
SKIP_UI="${SKIP_UI:-false}"
AGENT_NAMESPACES="${AGENT_NAMESPACES:-test-range}"

export PATH="/tools:${PATH}"

if helm status kagenti -n "${KAGENTI_NS}" >/dev/null 2>&1; then
  echo "Helm release kagenti already installed in ${KAGENTI_NS} — skipping"
  exit 0
fi

WORKDIR="/tmp/kagenti-src"
rm -rf "${WORKDIR}"
git clone --depth 1 --branch "${KAGENTI_GIT_REF}" "${KAGENTI_GIT_URL}" "${WORKDIR}" \
  || git clone --depth 1 "${KAGENTI_GIT_URL}" "${WORKDIR}"

IFS=',' read -ra NS_ARR <<< "${AGENT_NAMESPACES}"
for ns in "${NS_ARR[@]}"; do
  ns="$(echo "${ns}" | xargs)"
  [ -z "${ns}" ] && continue
  if ! grep -q "  - ${ns}" "${WORKDIR}/charts/kagenti/values.yaml"; then
    sed -i "/^agentNamespaces:/a\\  - ${ns}" "${WORKDIR}/charts/kagenti/values.yaml"
  fi
done

SETUP_ARGS=(--kagenti-repo "${WORKDIR}" --realm "${KC_REALM}" --keycloak-namespace "${KC_NAMESPACE}")
if [ "${SKIP_MLFLOW}" = "true" ]; then
  SETUP_ARGS+=(--skip-mlflow)
fi
if [ "${SKIP_OVN}" = "true" ]; then
  SETUP_ARGS+=(--skip-ovn-patch)
fi
if [ "${SKIP_UI}" = "true" ]; then
  SETUP_ARGS+=(--skip-ui)
fi

chmod +x "${WORKDIR}/scripts/ocp/setup-kagenti.sh"
"${WORKDIR}/scripts/ocp/setup-kagenti.sh" "${SETUP_ARGS[@]}"

echo "Kagenti platform install complete."
