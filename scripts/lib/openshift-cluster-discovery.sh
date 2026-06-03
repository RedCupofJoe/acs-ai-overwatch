# shellcheck shell=bash
# Shared OpenShift cluster discovery (used by discover-cluster-values.sh and the in-cluster Job).
# Expects kubectl or oc with a current cluster context. Sources cleanly; does not set -e.

openshift_discover_apps_domain() {
  local domain
  domain="$(kubectl get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  if [[ -z "${domain}" ]]; then
    domain="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  fi
  printf '%s' "${domain}"
}

openshift_discover_cluster_name() {
  local name
  name="$(kubectl get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || true)"
  if [[ -z "${name}" ]]; then
    name="$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || true)"
  fi
  if [[ -z "${name}" ]]; then
    name="openshift-cluster"
  fi
  printf '%s' "${name}"
}

openshift_discover_api_server() {
  kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null \
    || oc whoami --show-server 2>/dev/null \
    || true
}

# Hostname only (no scheme) for container registry / Route host.
openshift_discover_quay_registry_server() {
  local apps_domain="$1"
  local host=""
  if kubectl get namespace quay >/dev/null 2>&1; then
    host="$(kubectl get route -n quay -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "${host}" ]]; then
    if [[ "${apps_domain}" == apps.* ]]; then
      host="quay-quay.${apps_domain}"
    else
      host="quay-quay.apps.${apps_domain}"
    fi
  fi
  printf '%s' "${host}"
}

# External Route host for Mattermost (prefers live Route when already deployed).
openshift_discover_mattermost_route_host() {
  local apps_domain="$1"
  local mm_namespace="${2:-monitoring}"
  local host=""
  if kubectl get route mattermost -n "${mm_namespace}" >/dev/null 2>&1; then
    host="$(kubectl get route mattermost -n "${mm_namespace}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  fi
  if [[ -z "${host}" ]]; then
    host="mattermost-${mm_namespace}.${apps_domain}"
  fi
  printf '%s' "${host}"
}

openshift_discover_mattermost_site_url() {
  local route_host
  route_host="$(openshift_discover_mattermost_route_host "$1" "$2")"
  printf 'https://%s' "${route_host}"
}

openshift_discover_kagenti_api_base_url() {
  local apps_domain="$1"
  local base="${KAGENTI_API_BASE_URL:-}"
  local ns host
  if [[ -n "${base}" ]]; then
    printf '%s' "${base}"
    return
  fi
  for ns in kagenti-system kagenti default; do
    host="$(kubectl get route -n "${ns}" -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | grep -i kagenti | head -n1 || true)"
    if [[ -n "${host}" ]]; then
      printf 'https://%s' "${host}"
      return
    fi
  done
  if [[ "${apps_domain}" == apps.* ]]; then
    printf 'https://kagenti-api.%s' "${apps_domain}"
  else
    printf 'https://kagenti-api.apps.%s' "${apps_domain}"
  fi
}

openshift_discover_git_repo_url() {
  local default_url="${1:-https://github.com/RedCupofJoe/acs-ai-overwatch.git}"
  local raw="${GIT_REPO_URL:-}"
  if [[ -z "${raw}" ]] && command -v git >/dev/null 2>&1 && [[ -n "${REPO_ROOT:-}" ]]; then
    raw="$(git -C "${REPO_ROOT}" config --get remote.origin.url 2>/dev/null || true)"
  fi
  case "${raw}" in
    git@*:*/*)
      raw="https://${raw#git@}"
      raw="${raw/:/\/}"
      raw="${raw%.git}.git"
      ;;
  esac
  if [[ -z "${raw}" ]]; then
    raw="${default_url}"
  fi
  printf '%s' "${raw}"
}

# Emit a Helm values fragment to stdout.
openshift_discover_write_helm_values() {
  local apps_domain="$1"
  local cluster_name="$2"
  local quay_host="$3"
  local kagenti_base="$4"
  local git_url="$5"
  local password_line="${6:-}"
  cat <<EOF
cluster:
  name: ${cluster_name}
  appsDomain: ${apps_domain}

mattermost:
  siteUrl: ""
  route:
    host: ""

quayStorage:
  registryCredentials:
    server: ${quay_host}
${password_line}
kagenti:
  api:
    baseUrl: ${kagenti_base}
  appSource:
    repoUrl: ${git_url}
EOF
}

# Apply or update the in-cluster ConfigMap used by Helm / Argo CD.
openshift_discover_apply_configmap() {
  local namespace="$1"
  local name="$2"
  local apps_domain="$3"
  local cluster_name="$4"
  local quay_host="$5"
  local kagenti_base="$6"
  local git_url="$7"
  local api_server="${8:-}"
  local mattermost_route_host="${9:-}"
  local mattermost_site_url="${10:-}"
  local discovered_at
  discovered_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  kubectl create configmap "${name}" \
    --namespace="${namespace}" \
    --from-literal=appsDomain="${apps_domain}" \
    --from-literal=clusterName="${cluster_name}" \
    --from-literal=quayRegistryServer="${quay_host}" \
    --from-literal=kagentiApiBaseUrl="${kagenti_base}" \
    --from-literal=gitRepoUrl="${git_url}" \
    --from-literal=apiServer="${api_server}" \
    --from-literal=mattermostRouteHost="${mattermost_route_host}" \
    --from-literal=mattermostSiteUrl="${mattermost_site_url}" \
    --from-literal=discoveredAt="${discovered_at}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

openshift_discover_run() {
  local apps_domain cluster_name quay_host kagenti_base git_url api_server mm_namespace mm_route_host mm_site_url
  apps_domain="$(openshift_discover_apps_domain)"
  if [[ -z "${apps_domain}" ]]; then
    echo "Could not read ingresses.config/cluster spec.domain" >&2
    return 1
  fi
  mm_namespace="${MATTERMOST_NAMESPACE:-monitoring}"
  cluster_name="$(openshift_discover_cluster_name)"
  quay_host="$(openshift_discover_quay_registry_server "${apps_domain}")"
  kagenti_base="$(openshift_discover_kagenti_api_base_url "${apps_domain}")"
  git_url="$(openshift_discover_git_repo_url "${GIT_REPO_URL_DEFAULT:-}")"
  api_server="$(openshift_discover_api_server)"
  mm_route_host="$(openshift_discover_mattermost_route_host "${apps_domain}" "${mm_namespace}")"
  mm_site_url="$(openshift_discover_mattermost_site_url "${apps_domain}" "${mm_namespace}")"

  APPS_DOMAIN="${apps_domain}"
  CLUSTER_NAME="${cluster_name}"
  QUAY_REGISTRY_SERVER="${quay_host}"
  KAGENTI_API_BASE_URL="${kagenti_base}"
  GIT_REPO_URL="${git_url}"
  API_SERVER="${api_server}"
  MATTERMOST_ROUTE_HOST="${mm_route_host}"
  MATTERMOST_SITE_URL="${mm_site_url}"
  export APPS_DOMAIN CLUSTER_NAME QUAY_REGISTRY_SERVER KAGENTI_API_BASE_URL GIT_REPO_URL API_SERVER MATTERMOST_ROUTE_HOST MATTERMOST_SITE_URL
}
