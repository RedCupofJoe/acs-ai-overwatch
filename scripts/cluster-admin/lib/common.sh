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

cluster_admin_require_cluster_admin() {
  cluster_admin_require_oc || return 1
  local user
  user="$("${KUBE_CMD[@]}" whoami)"
  if ! "${KUBE_CMD[@]}" auth can-i create clusterrolebindings --all-namespaces \
    --as="${user}" 2>/dev/null | grep -qE '^(yes|true)$'; then
    echo "This script requires cluster-admin (or equivalent) privileges." >&2
    echo "Current user: ${user}" >&2
    return 1
  fi
}

cluster_admin_info() {
  printf '%s\n' "$*"
}
