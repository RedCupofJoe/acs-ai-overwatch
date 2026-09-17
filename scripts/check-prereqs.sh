#!/usr/bin/env bash
# Check ACS AI Overwatch prerequisites against the current oc login.
#
# Usage:
#   ./scripts/check-prereqs.sh
#
# Exit 0 when every required check passes. Warnings do not fail the script.
set -uo pipefail

PASS=0
FAIL=0
WARN=0

pass() {
  printf 'PASS  %s\n' "$*"
  PASS=$((PASS + 1))
}

fail() {
  printf 'FAIL  %s\n' "$*"
  FAIL=$((FAIL + 1))
}

warn() {
  printf 'WARN  %s\n' "$*"
  WARN=$((WARN + 1))
}

section() {
  printf '\n== %s ==\n' "$*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

oc_ok() {
  oc "$@" >/dev/null 2>&1
}

csv_phase() {
  local selector="$1"
  oc get csv -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | awk -F '\t' -v s="${selector}" 'tolower($1) ~ s {print $2; exit}'
}

package_channels() {
  local package="$1"
  oc get packagemanifest "${package}" -n openshift-marketplace \
    -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}' 2>/dev/null || true
}

catalog_ready() {
  local name="$1"
  oc get catalogsource "${name}" -n openshift-marketplace \
    -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true
}

semver_ge() {
  # Return 0 if $1 >= $2 (major.minor.patch, extra suffixes ignored).
  local left right
  left="$(printf '%s' "$1" | awk -F '[^0-9]+' '{print ($1+0)"."($2+0)"."($3+0)}')"
  right="$(printf '%s' "$2" | awk -F '[^0-9]+' '{print ($1+0)"."($2+0)"."($3+0)}')"
  printf '%s\n%s\n' "${right}" "${left}" | sort -C -V
}

section "Workstation"

if have_cmd oc; then
  pass "oc CLI is on PATH ($(command -v oc))"
else
  fail "oc CLI is not installed or not on PATH"
fi

if have_cmd git; then
  pass "git CLI is on PATH"
else
  fail "git CLI is not installed or not on PATH"
fi

if have_cmd oc && oc whoami >/dev/null 2>&1; then
  pass "Logged in as $(oc whoami) ($(oc whoami --show-server 2>/dev/null || echo unknown API))"
else
  fail "Not logged in. Run: oc login"
fi

if have_cmd oc && oc whoami >/dev/null 2>&1; then
  user="$(oc whoami)"
  if [[ "${user}" == kube:admin || "${user}" == system:admin || "${user}" == admin ]] \
    || [[ "$(oc auth can-i create clusterrolebindings --all-namespaces 2>/dev/null || true)" == "yes" ]]; then
    pass "Current user has cluster-admin (or equivalent) privileges"
  else
    fail "Current user (${user}) cannot create clusterrolebindings; cluster-admin is required"
  fi
fi

section "OpenShift cluster"

if have_cmd oc && oc whoami >/dev/null 2>&1; then
  ocp_version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
  if [[ -z "${ocp_version}" ]]; then
    fail "Could not read OpenShift version from clusterversion/version"
  elif [[ "${ocp_version}" == 4.20.* ]]; then
    pass "OpenShift version is ${ocp_version} (target 4.20)"
  elif semver_ge "${ocp_version}" "4.19.9"; then
    warn "OpenShift version is ${ocp_version}; this PoC targets 4.20 (4.19.9+ can run OpenShift AI 3.5)"
  else
    fail "OpenShift version is ${ocp_version}; need 4.20 (or at least 4.19.9 for OpenShift AI 3.5)"
  fi
fi

section "OpenShift GitOps"

if have_cmd oc && oc whoami >/dev/null 2>&1; then
  gitops_phase="$(csv_phase 'openshift-gitops-operator|gitops-operator')"
  if [[ "${gitops_phase}" == "Succeeded" ]]; then
    pass "OpenShift GitOps operator CSV is Succeeded"
  elif [[ -n "${gitops_phase}" ]]; then
    fail "OpenShift GitOps operator CSV phase is ${gitops_phase} (want Succeeded)"
  else
    fail "OpenShift GitOps operator is not installed"
  fi

  if oc_ok get ns openshift-gitops; then
    pass "Namespace openshift-gitops exists"
  else
    fail "Namespace openshift-gitops is missing"
  fi

  if oc get deploy -n openshift-gitops openshift-gitops-server >/dev/null 2>&1; then
    pass "Argo CD deployments are present in openshift-gitops"
  else
    warn "No Argo CD deployments found in openshift-gitops yet"
  fi
fi

section "Storage"

if have_cmd oc && oc whoami >/dev/null 2>&1; then
  if oc_ok get storageclass gp3-csi; then
    pass "StorageClass gp3-csi exists (chart default)"
  else
    fail "StorageClass gp3-csi is missing; set storage.defaultStorageClass after oc get storageclass"
  fi

  default_sc="$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1 || true)"
  if [[ -n "${default_sc}" ]]; then
    if [[ "${default_sc}" == "gp3-csi" ]]; then
      pass "Default StorageClass is gp3-csi"
    else
      warn "Default StorageClass is ${default_sc}, not gp3-csi; override storage.defaultStorageClass if PVCs should use it"
    fi
  else
    warn "No default StorageClass annotation found"
  fi
fi

section "Operator catalogs"

if have_cmd oc && oc whoami >/dev/null 2>&1; then
  for catalog in redhat-operators certified-operators; do
    state="$(catalog_ready "${catalog}")"
    if [[ "${state}" == "READY" ]]; then
      pass "CatalogSource ${catalog} is READY"
    elif [[ -n "${state}" ]]; then
      fail "CatalogSource ${catalog} state is ${state} (want READY)"
    else
      fail "CatalogSource ${catalog} was not found in openshift-marketplace"
    fi
  done

  rhoai_channels="$(package_channels rhods-operator)"
  if printf '%s\n' "${rhoai_channels}" | grep -Eq '^(stable|fast|eus)-3\.5$'; then
    pass "rhods-operator catalog offers an OpenShift AI 3.5 channel ($(printf '%s' "${rhoai_channels}" | grep -E '3\.5' | tr '\n' ',' | sed 's/,$//'))"
  elif [[ -n "${rhoai_channels}" ]]; then
    fail "rhods-operator has no 3.5 channel (found: $(printf '%s' "${rhoai_channels}" | tr '\n' ',' | sed 's/,$//'))"
  else
    fail "packagemanifest rhods-operator was not found (need redhat-operators)"
  fi

  if oc_ok get packagemanifest gpu-operator-certified -n openshift-marketplace; then
    pass "packagemanifest gpu-operator-certified is in the catalog"
  else
    fail "packagemanifest gpu-operator-certified is missing (need certified-operators)"
  fi

  if oc_ok get packagemanifest nfd -n openshift-marketplace \
    || oc_ok get packagemanifest nfd-operator -n openshift-marketplace; then
    pass "packagemanifest for Node Feature Discovery is in the catalog"
  else
    fail "Node Feature Discovery packagemanifest is missing"
  fi
fi

section "OpenShift AI freshness"

if have_cmd oc && oc whoami >/dev/null 2>&1; then
  rhoai_csv="$(oc get csv -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.version}{"\n"}{end}' 2>/dev/null \
    | awk -F '\t' 'tolower($1) ~ /rhods-operator|opendatahub/ {print $1 " " $2; exit}')"
  if [[ -z "${rhoai_csv}" ]]; then
    pass "OpenShift AI operator is not installed yet (fresh 3.5 install is OK)"
  elif printf '%s' "${rhoai_csv}" | grep -Eq '2\.25|v2\.25'; then
    fail "OpenShift AI 2.25 is installed (${rhoai_csv}); use a fresh cluster for 3.5"
  else
    pass "Existing OpenShift AI install does not look like 2.25 (${rhoai_csv})"
  fi
fi

section "GPUs"

if have_cmd oc && oc whoami >/dev/null 2>&1; then
  gpu_total=0
  shared_total=0
  while IFS= read -r cap; do
    [[ -z "${cap}" || "${cap}" == "<none>" ]] && continue
    gpu_total=$((gpu_total + cap))
  done < <(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null || true)
  while IFS= read -r cap; do
    [[ -z "${cap}" || "${cap}" == "<none>" ]] && continue
    shared_total=$((shared_total + cap))
  done < <(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu\.shared}{"\n"}{end}' 2>/dev/null || true)

  products="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.labels.nvidia\.com/gpu\.product}{"\n"}{end}' 2>/dev/null | sed '/^$/d' || true)"
  # Target: 1× g6.12xlarge (4× L4). After time-slicing GPU 0: ~3 nvidia.com/gpu + 4 gpu.shared.
  # Before ClusterPolicy: 4 nvidia.com/gpu. Need ≥2 dedicated for Gemma + Granite.
  if [[ "${gpu_total}" -eq 0 && "${shared_total}" -eq 0 ]]; then
    warn "No nvidia.com/gpu allocatable yet (GPU Operator ClusterPolicy comes from GitOps). Provision 1× g6.12xlarge (4× L4), not 3× g6.4xlarge."
  elif [[ "${gpu_total}" -ge 2 && "${shared_total}" -ge 4 ]]; then
    pass "Cluster advertises ${gpu_total} nvidia.com/gpu and ${shared_total} nvidia.com/gpu.shared (1× g6.12xlarge time-sliced GPU 0)"
  elif [[ "${gpu_total}" -ge 3 ]]; then
    pass "Cluster advertises ${gpu_total} nvidia.com/gpu (1× g6.12xlarge before or after time-slicing GPU 0)"
  else
    fail "Cluster advertises ${gpu_total} nvidia.com/gpu / ${shared_total} gpu.shared; need 1× g6.12xlarge (4× L4), not 3× g6.4xlarge (1× L4 each)"
  fi

  if printf '%s\n' "${products}" | grep -qi 'L4'; then
    pass "Node labels include NVIDIA L4 (${products//$'\n'/, })"
  elif [[ -n "${products}" ]]; then
    warn "GPU product labels are not L4: ${products//$'\n'/, }. Chart cluster.gpu.model is L4."
  else
    warn "No nvidia.com/gpu.product labels yet; NFD/GPU Operator apply these after GitOps"
  fi
fi

section "Git remote and Model Catalog pull"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if git -C "${repo_root}" remote get-url origin >/dev/null 2>&1; then
  pass "Git remote origin is $(git -C "${repo_root}" remote get-url origin)"
else
  fail "No git remote named origin; Argo CD and Tekton need a clone URL"
fi

if have_cmd oc && oc whoami >/dev/null 2>&1; then
  pull_auths="$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 --decode 2>/dev/null || true)"
  if [[ -z "${pull_auths}" ]]; then
    pull_auths="$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -D 2>/dev/null || true)"
  fi
  if printf '%s' "${pull_auths}" | grep -q 'registry.redhat.io'; then
    pass "Cluster pull secret has an auth entry for registry.redhat.io (Model Catalog ModelCar images)"
  else
    fail "Cluster pull secret has no registry.redhat.io auth; Model Catalog Gemma/Granite pulls will fail"
  fi
fi

section "Optional (installed later by GitOps or documented separately)"

if have_cmd oc && oc whoami >/dev/null 2>&1; then
  pipelines_phase="$(csv_phase 'openshift-pipelines-operator|pipelines-operator')"
  if [[ "${pipelines_phase}" == "Succeeded" ]]; then
    pass "OpenShift Pipelines operator CSV is Succeeded"
  else
    warn "OpenShift Pipelines is not installed yet; the PoC overlay can install it (components.pipelines)"
  fi

  uwm="$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)"
  if printf '%s' "${uwm}" | grep -Eq 'enableUserWorkload:[[:space:]]*true'; then
    pass "User Workload Monitoring is enabled (MaaS prerequisite)"
  else
    warn "User Workload Monitoring is not enabled (MaaS prerequisite). See README Quick Start to create cluster-monitoring-config."
  fi

  if oc_ok get csv -n openshift-kueue-operator 2>/dev/null; then
    warn "Kueue operator is present; this PoC keeps DataScienceCluster kueue.managementState: Removed"
  else
    pass "Kueue operator is absent (PoC leaves Kueue Removed)"
  fi
fi

printf '\nSummary: %s passed, %s warnings, %s failed\n' "${PASS}" "${WARN}" "${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  printf 'Prerequisites are not met.\n' >&2
  exit 1
fi
printf 'Required prerequisites are met.\n'
