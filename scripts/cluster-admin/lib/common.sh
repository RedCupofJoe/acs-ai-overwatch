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
