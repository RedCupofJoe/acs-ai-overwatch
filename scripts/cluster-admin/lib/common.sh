# shellcheck shell=bash
# Shared helpers for cluster-admin pre-GitOps scripts.

cluster_admin_repo_root() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  printf '%s' "${root}"
}

cluster_admin_require_oc() {
  if command -v oc >/dev/null 2>&1; then
    KUBE_CMD=(oc)
  elif command -v kubectl >/dev/null 2>&1; then
    KUBE_CMD=(kubectl)
  else
    echo "Required: oc or kubectl" >&2
    return 1
  fi
  if ! "${KUBE_CMD[@]}" whoami >/dev/null 2>&1; then
    echo "Not logged in. Run: oc login ..." >&2
    return 1
  fi
}

cluster_admin_can() {
  local result
  result="$("${KUBE_CMD[@]}" auth can-i "$@" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [[ "${result}" == "yes" || "${result}" == "true" ]]
}

cluster_admin_require_cluster_admin() {
  cluster_admin_require_oc || return 1
  local user
  user="$("${KUBE_CMD[@]}" whoami)"

  # OpenShift/Kubernetes break-glass admins (do not use --as= here; self-impersonation can return "no").
  case "${user}" in
    kube:admin|system:admin|admin) return 0 ;;
  esac

  if cluster_admin_can create clusterrolebindings --all-namespaces \
    || cluster_admin_can create namespaces --all-namespaces \
    || cluster_admin_can '*' '*' --all-namespaces; then
    return 0
  fi

  echo "This script requires cluster-admin (or equivalent) privileges." >&2
  echo "Current user: ${user}" >&2
  echo "Checks failed: create clusterrolebindings, create namespaces, or * * cluster-wide." >&2
  return 1
}

# Lighter gate for namespace-only scripts (02-bootstrap-namespaces).
cluster_admin_require_namespace_create() {
  cluster_admin_require_oc || return 1
  cluster_admin_require_cluster_admin && return 0
  if cluster_admin_can create namespaces; then
    return 0
  fi
  local user
  user="$("${KUBE_CMD[@]}" whoami)"
  echo "Cannot create namespaces. Current user: ${user}" >&2
  return 1
}

cluster_admin_info() {
  printf '%s\n' "$*"
}

# One OperatorGroup per namespace. OpenShift AI fails the CSV with
# TooManyOperatorGroups when a console install leaves a second group beside
# the chart's redhat-ods-operator group. Keep the chart name and delete the rest.
cluster_admin_ensure_single_operatorgroup() {
  local ns="${1:-redhat-ods-operator}"
  local keep="${2:-redhat-ods-operator}"
  local -a cmd=(oc)
  if [[ -n "${KUBE_CMD[*]:-}" ]]; then
    cmd=("${KUBE_CMD[@]}")
  fi
  if ! "${cmd[@]}" get namespace "${ns}" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${DRY_RUN:-false}" == true ]]; then
    cluster_admin_info "dry-run: would keep a single OperatorGroup ${keep} in ${ns}"
    return 0
  fi
  if ! "${cmd[@]}" get operatorgroup "${keep}" -n "${ns}" >/dev/null 2>&1; then
    cluster_admin_info "Creating OperatorGroup ${keep} in ${ns}"
    "${cmd[@]}" apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${keep}
  namespace: ${ns}
spec: {}
EOF
  fi
  local name
  while IFS= read -r name; do
    [[ -z "${name}" || "${name}" == "${keep}" ]] && continue
    cluster_admin_info "Removing extra OperatorGroup ${name} in ${ns}"
    "${cmd[@]}" delete operatorgroup "${name}" -n "${ns}" --wait=false
  done < <("${cmd[@]}" get operatorgroup -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
}
