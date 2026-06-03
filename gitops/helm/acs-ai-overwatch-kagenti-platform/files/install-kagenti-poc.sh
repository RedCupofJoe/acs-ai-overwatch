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
EXTERNAL_OTEL_COLLECTOR="${EXTERNAL_OTEL_COLLECTOR:-}"
PHASE5_INTEGRATION="${PHASE5_INTEGRATION:-false}"

export PATH="/tools:${PATH}"

if ! command -v helm >/dev/null 2>&1 || ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: helm and oc must be available on PATH (/tools)" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required by setup-kagenti.sh" >&2
  exit 1
fi

if helm status kagenti -n "${KAGENTI_NS}" >/dev/null 2>&1; then
  echo "Helm release kagenti already installed in ${KAGENTI_NS} — skipping"
  exit 0
fi

_fetch_kagenti_source() {
  local dest="$1"
  local repo_path="${KAGENTI_GIT_URL#https://github.com/}"
  repo_path="${repo_path%.git}"
  local archive_url="https://github.com/${repo_path}/archive/refs/heads/${KAGENTI_GIT_REF}.tar.gz"
  local extract_dir="/tmp/kagenti-archive"

  rm -rf "${dest}" "${extract_dir}"
  mkdir -p "${extract_dir}"
  echo "Fetching Kagenti source from ${archive_url}"
  curl -fsSL "${archive_url}" | tar xz -C "${extract_dir}"
  mv "${extract_dir}/$(basename "${repo_path}")-${KAGENTI_GIT_REF}" "${dest}"
}

WORKDIR="/tmp/kagenti-src"
_fetch_kagenti_source "${WORKDIR}"

IFS=',' read -ra NS_ARR <<< "${AGENT_NAMESPACES}"
for ns in "${NS_ARR[@]}"; do
  ns="$(echo "${ns}" | xargs)"
  [ -z "${ns}" ] && continue
  # Upstream chart uses unindented list items ("- team1"), not "  - team1".
  if ! grep -qE "^- ${ns}$" "${WORKDIR}/charts/kagenti/values.yaml"; then
    sed -i "/^agentNamespaces:/a- ${ns}" "${WORKDIR}/charts/kagenti/values.yaml"
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
if [ "${PHASE5_INTEGRATION}" = "true" ] && [ -n "${EXTERNAL_OTEL_COLLECTOR}" ]; then
  echo "Phase 5 integration: Kagenti will use shared OTEL collector at ${EXTERNAL_OTEL_COLLECTOR}"
  export OTEL_EXPORTER_OTLP_ENDPOINT="${EXTERNAL_OTEL_COLLECTOR}"
fi

chmod +x "${WORKDIR}/scripts/ocp/setup-kagenti.sh"
"${WORKDIR}/scripts/ocp/setup-kagenti.sh" "${SETUP_ARGS[@]}"

echo "Kagenti platform install complete."
