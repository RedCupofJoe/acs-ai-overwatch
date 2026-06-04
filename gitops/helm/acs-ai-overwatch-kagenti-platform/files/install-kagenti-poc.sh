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

# Istio ambient on kagenti-system breaks kubelet HTTP liveness/readiness probes
# (1s timeout) for backend, UI, and operator — exclude control-plane Deployments.
_exclude_control_plane_from_ambient() {
  local dep
  for dep in kagenti-backend kagenti-ui kagenti-controller-manager; do
    if ! oc get deployment "${dep}" -n "${KAGENTI_NS}" >/dev/null 2>&1; then
      continue
    fi
    echo "Excluding ${dep} from Istio ambient mesh (probe compatibility)"
    oc patch deployment "${dep}" -n "${KAGENTI_NS}" --type merge -p \
      '{"spec":{"template":{"metadata":{"labels":{"istio.io/dataplane-mode":"none"}}}}}'
  done
}

if helm status kagenti -n "${KAGENTI_NS}" >/dev/null 2>&1; then
  echo "Helm release kagenti already installed in ${KAGENTI_NS} — skipping platform install"
  _exclude_control_plane_from_ambient
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
_patch_agent_namespaces() {
  local values_file="$1"
  shift
  python3 - "$values_file" "$@" <<'PY'
import re
import sys

path = sys.argv[1]
extra = [ns.strip() for ns in sys.argv[2:] if ns.strip()]
text = open(path, encoding="utf-8").read()
match = re.search(r"^agentNamespaces:\n((?:- .+\n)*)", text, flags=re.M)
existing: list[str] = []
if match:
    existing = [
        line[2:].strip()
        for line in match.group(1).splitlines()
        if line.startswith("- ")
    ]
for ns in extra:
    if ns not in existing:
        existing.append(ns)
block = "agentNamespaces:\n" + "".join(f"- {ns}\n" for ns in existing)
text, count = re.subn(
    r"^agentNamespaces:\n(?:- .+\n)*",
    block,
    text,
    count=1,
    flags=re.M,
)
if count != 1:
    sys.exit(f"agentNamespaces block not found in {path}")
open(path, "w", encoding="utf-8").write(text)
PY
}
_patch_agent_namespaces "${WORKDIR}/charts/kagenti/values.yaml" "${NS_ARR[@]}"

# Agent namespaces are pre-created by acs-ai-overwatch-gitops-bootstrap; adopt them
# so `helm upgrade --install kagenti` can manage RBAC/network policies in Step 4.
_adopt_agent_namespaces_for_helm() {
  for ns in "$@"; do
    ns="$(echo "${ns}" | xargs)"
    [ -z "${ns}" ] && continue
    if ! oc get namespace "${ns}" >/dev/null 2>&1; then
      continue
    fi
    echo "Adopting existing namespace ${ns} for Helm release kagenti"
    oc label namespace "${ns}" app.kubernetes.io/managed-by=Helm --overwrite
    oc annotate namespace "${ns}" \
      meta.helm.sh/release-name=kagenti \
      meta.helm.sh/release-namespace="${KAGENTI_NS}" \
      --overwrite
  done
}
_adopt_agent_namespaces_for_helm "${NS_ARR[@]}"

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

_exclude_control_plane_from_ambient

echo "Kagenti platform install complete."
