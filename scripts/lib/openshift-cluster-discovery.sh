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

# Default StorageClass (cluster annotation, then common ROSA/OCP names).
openshift_discover_default_storage_class() {
  local sc
  sc="$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1 || true)"
  if [[ -z "${sc}" ]]; then
    for candidate in gp3-csi gp3 gp2-csi gp2; do
      if oc get storageclass "${candidate}" >/dev/null 2>&1; then
        printf '%s' "${candidate}"
        return 0
      fi
    done
    printf '%s' "gp3-csi"
    return 0
  fi
  printf '%s' "${sc}"
}

# Pick the newest OpenShift AI channel for a target minor (e.g. 3.4).
openshift_discover_rhoai_channel() {
  local channels="$1"
  local target="${RHOAI_TARGET_VERSION:-3.4}"
  local pref channel fallback

  for pref in "stable-${target}" "fast-${target}" "eus-${target}"; do
    if echo "${channels}" | grep -qxF "${pref}"; then
      printf '%s' "${pref}"
      return 0
    fi
  done
  fallback="$(echo "${channels}" | grep -E "${target}" | sort -V | tail -n1 || true)"
  if [[ -n "${fallback}" ]]; then
    printf '%s' "${fallback}"
    return 0
  fi
  return 1
}

# Resolve OLM Subscription channel from packagemanifest (oc jsonpath; no jq required).
# strategy: default | latest-stable-3 | rhoai-target
openshift_discover_package_channel() {
  local package="$1"
  local fallback="${2:-stable}"
  local strategy="${3:-default}"
  local channels default_ch channel

  if ! channels="$(oc get packagemanifest "${package}" -n openshift-marketplace -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}' 2>/dev/null)"; then
    echo "WARN: packagemanifest ${package} not found; using fallback channel ${fallback}" >&2
    printf '%s' "${fallback}"
    return 0
  fi

  default_ch="$(oc get packagemanifest "${package}" -n openshift-marketplace -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true)"

  case "${strategy}" in
    latest-stable-3)
      channel="$(echo "${channels}" | grep -E '^stable-3\.[0-9]+$' | sort -V | tail -n1 || true)"
      channel="${channel:-${default_ch:-${fallback}}}"
      ;;
    rhoai-target)
      if channel="$(openshift_discover_rhoai_channel "${channels}")"; then
        :
      else
        channel="${default_ch:-${fallback}}"
      fi
      ;;
    default|*)
      channel="${default_ch:-${fallback}}"
      ;;
  esac
  printf '%s' "${channel}"
}

# Discover OLM channels for operators used by acs-ai-overwatch (exported globals).
openshift_discover_operator_channels() {
  DEFAULT_STORAGE_CLASS="$(openshift_discover_default_storage_class)"
  QUAY_OPERATOR_CHANNEL="$(openshift_discover_package_channel quay-operator stable-3.15 latest-stable-3)"
  RHOAI_OPERATOR_CHANNEL="$(openshift_discover_package_channel rhods-operator stable-3.4 rhoai-target)"
  RHACS_OPERATOR_CHANNEL="$(openshift_discover_package_channel rhacs-operator stable default)"
  NFD_OPERATOR_CHANNEL="$(openshift_discover_package_channel nfd stable default)"
  GPU_OPERATOR_CHANNEL="$(openshift_discover_package_channel gpu-operator-certified stable default)"
  export DEFAULT_STORAGE_CLASS QUAY_OPERATOR_CHANNEL RHOAI_OPERATOR_CHANNEL RHACS_OPERATOR_CHANNEL NFD_OPERATOR_CHANNEL GPU_OPERATOR_CHANNEL
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

storage:
  defaultStorageClass: ${DEFAULT_STORAGE_CLASS}

mattermost:
  siteUrl: ""
  route:
    host: ""

quayStorage:
  quayOperator:
    subscription:
      channel: ${QUAY_OPERATOR_CHANNEL}
  registryCredentials:
    server: ${quay_host}
${password_line}

rhoai:
  operator:
    subscription:
      channel: ${RHOAI_OPERATOR_CHANNEL}

acs:
  operator:
    subscription:
      channel: ${RHACS_OPERATOR_CHANNEL}

accelerators:
  nfd:
    subscription:
      channel: ${NFD_OPERATOR_CHANNEL}
  gpuOperator:
    subscription:
      channel: ${GPU_OPERATOR_CHANNEL}

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
  local default_storage_class="${11:-gp3-csi}"
  local quay_operator_channel="${12:-stable-3.15}"
  local rhoai_operator_channel="${13:-stable-3.4}"
  local rhacs_operator_channel="${14:-stable}"
  local nfd_operator_channel="${15:-stable}"
  local gpu_operator_channel="${16:-stable}"
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
    --from-literal=defaultStorageClass="${default_storage_class}" \
    --from-literal=quayOperatorChannel="${quay_operator_channel}" \
    --from-literal=rhoaiOperatorChannel="${rhoai_operator_channel}" \
    --from-literal=rhacsOperatorChannel="${rhacs_operator_channel}" \
    --from-literal=nfdOperatorChannel="${nfd_operator_channel}" \
    --from-literal=gpuOperatorChannel="${gpu_operator_channel}" \
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
  openshift_discover_operator_channels

  APPS_DOMAIN="${apps_domain}"
  CLUSTER_NAME="${cluster_name}"
  QUAY_REGISTRY_SERVER="${quay_host}"
  KAGENTI_API_BASE_URL="${kagenti_base}"
  GIT_REPO_URL="${git_url}"
  API_SERVER="${api_server}"
  MATTERMOST_ROUTE_HOST="${mm_route_host}"
  MATTERMOST_SITE_URL="${mm_site_url}"
  export APPS_DOMAIN CLUSTER_NAME QUAY_REGISTRY_SERVER KAGENTI_API_BASE_URL GIT_REPO_URL API_SERVER MATTERMOST_ROUTE_HOST MATTERMOST_SITE_URL \
    DEFAULT_STORAGE_CLASS QUAY_OPERATOR_CHANNEL RHOAI_OPERATOR_CHANNEL RHACS_OPERATOR_CHANNEL NFD_OPERATOR_CHANNEL GPU_OPERATOR_CHANNEL
}
