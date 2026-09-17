#!/usr/bin/env bash
# Pre-GitOps GPU / NFD prep from vendored workshop configs/.
#
# Default is safe for this PoC: AWS GPU MachineSet + NFD/GPU operators + NFD instance.
# Does NOT apply workshop ClusterPolicy or DataScienceCluster (Helm/GitOps owns those).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO_ROOT="$(cluster_admin_repo_root)"
CONFIGS="${REPO_ROOT}/configs"

SKIP_MACHINESET=false
SKIP_GPU_OPERATORS=false
RESET_MACHINESET_JOB=false
SMOKE_TEST=false
WITH_RHOAI_DEPS=false
WITH_RHOAI_OPERATOR=false
WITH_GPU_CLUSTERPOLICY=false
WITH_WORKSHOP_DSC=false
WITH_KUEUE=false
WITH_TEMPO=false
WITH_CONNECTIVITY_LINK=false
WITH_GPU_EXTRAS=false
SKIP_WAIT=false
DRY_RUN=false
CSV_TIMEOUT=600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-machineset) SKIP_MACHINESET=true; shift ;;
    --skip-gpu-operators) SKIP_GPU_OPERATORS=true; shift ;;
    --reset-machineset-job) RESET_MACHINESET_JOB=true; shift ;;
    --smoke-test) SMOKE_TEST=true; shift ;;
    --with-rhoai-deps) WITH_RHOAI_DEPS=true; shift ;;
    --with-rhoai-operator) WITH_RHOAI_OPERATOR=true; shift ;;
    --with-gpu-clusterpolicy) WITH_GPU_CLUSTERPOLICY=true; shift ;;
    --with-workshop-dsc) WITH_WORKSHOP_DSC=true; shift ;;
    --with-kueue) WITH_KUEUE=true; shift ;;
    --with-tempo) WITH_TEMPO=true; shift ;;
    --with-connectivity-link) WITH_CONNECTIVITY_LINK=true; shift ;;
    --with-gpu-extras) WITH_GPU_EXTRAS=true; shift ;;
    --skip-wait) SKIP_WAIT=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: 05-apply-platform-prep.sh [options]

Vendored workshop overlays under configs/. Default (safe for this PoC):

  00-cluster-setup/05-aws-gpu-machineset   (no-op on non-AWS)
  01-nvidia-gpu-operator/00 NFD operator
  01-nvidia-gpu-operator/01 GPU operator
  01-nvidia-gpu-operator/02 NFD instance

Skipped by default (GitOps/Helm owns these):

  01/.../03 ClusterPolicy gpu-cluster-policy  (no time-slicing)
  04/.../01 DataScienceCluster default-dsc    (kueue Unmanaged)
  03 Kueue, Tempo, Connectivity Link

Options:
  --skip-machineset           Do not apply the AWS GPU MachineSet Job
  --skip-gpu-operators        Do not apply NFD/GPU operators or NFD instance
  --reset-machineset-job      Delete job-aws-gpu-machineset before apply
  --smoke-test                Apply 02-nvidia-gpu-workload (needs nvidia.com/gpu)
  --with-rhoai-deps           LWS, JobSet, OpenTelemetry, Cluster Observability
  --with-rhoai-operator       Apply 04-rhoai-setup/00 only (not the workshop DSC)
  --with-gpu-clusterpolicy    DANGER: workshop ClusterPolicy overwrites time-slicing
  --with-workshop-dsc         DANGER: workshop default-dsc fights Helm
  --with-kueue                Also subscribe Kueue (PoC DSC has kueue Removed)
  --with-tempo                Also subscribe Tempo (prefer observability chart)
  --with-connectivity-link    Kuadrant / Connectivity Link (full workshop MaaS)
  --with-gpu-extras           NVIDIA console plugin + DCGM dashboard (remote JSON)
  --skip-wait                 Do not wait for CSVs/CRDs
  --dry-run                   kustomize build only; do not apply

Requires: oc login as cluster-admin. Run after install-pre-gitops.sh so
nvidia-gpu-operator / openshift-nfd namespaces exist with managed-by labels.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "${DRY_RUN}" == true ]]; then
  if command -v oc >/dev/null 2>&1; then
    KUBE_CMD=(oc)
  elif command -v kubectl >/dev/null 2>&1; then
    KUBE_CMD=(kubectl)
  else
    echo "Required: oc or kubectl (for kustomize build)" >&2
    exit 1
  fi
else
  cluster_admin_require_cluster_admin
fi

kustomize_build() {
  local dir="$1"
  if "${KUBE_CMD[@]}" kustomize "${dir}" >/dev/null; then
    return 0
  fi
  echo "kustomize build failed: ${dir}" >&2
  return 1
}

apply_overlay() {
  local dir="$1"
  cluster_admin_info "kustomize: ${dir#"${REPO_ROOT}/"}"
  kustomize_build "${dir}"
  if [[ "${DRY_RUN}" == true ]]; then
    return 0
  fi
  "${KUBE_CMD[@]}" apply -k "${dir}"
}

wait_for_csv() {
  local ns="$1"
  if [[ "${SKIP_WAIT}" == true || "${DRY_RUN}" == true ]]; then
    return 0
  fi
  cluster_admin_info "Waiting up to ${CSV_TIMEOUT}s for a Succeeded CSV in ${ns} ..."
  local start now
  start="$(date +%s)"
  while true; do
    local phases
    phases="$("${KUBE_CMD[@]}" get csv -n "${ns}" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || true)"
    if grep -qx 'Succeeded' <<<"${phases}"; then
      cluster_admin_info "CSV Succeeded in ${ns}"
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= CSV_TIMEOUT )); then
      echo "Timed out waiting for CSV in ${ns}" >&2
      "${KUBE_CMD[@]}" get csv -n "${ns}" || true
      return 1
    fi
    sleep 10
  done
}

wait_for_crd() {
  local crd="$1"
  if [[ "${SKIP_WAIT}" == true || "${DRY_RUN}" == true ]]; then
    return 0
  fi
  cluster_admin_info "Waiting for CRD ${crd} ..."
  "${KUBE_CMD[@]}" wait --for=condition=Established "crd/${crd}" --timeout="${CSV_TIMEOUT}s"
}

warn_danger() {
  echo "WARNING: $*" >&2
}

wait_machineset_job() {
  local ns=nvidia-gpu-operator
  local job=job-aws-gpu-machineset
  if ! "${KUBE_CMD[@]}" get job "${job}" -n "${ns}" >/dev/null 2>&1; then
    return 0
  fi
  local succeeded failed
  succeeded="$("${KUBE_CMD[@]}" get job "${job}" -n "${ns}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  failed="$("${KUBE_CMD[@]}" get job "${job}" -n "${ns}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
  if [[ "${succeeded}" == "1" ]]; then
    cluster_admin_info "GPU MachineSet Job already succeeded."
    return 0
  fi
  if [[ -n "${failed}" && "${failed}" != "0" ]]; then
    echo "GPU MachineSet Job failed (backoff limit). Latest log:" >&2
    "${KUBE_CMD[@]}" logs -n "${ns}" "job/${job}" --tail=20 >&2 || true
    echo "MachineSet itself may still be Ready. Check: oc get machinesets -n openshift-machine-api" >&2
    echo "To retry after RBAC/script fixes: $0 --reset-machineset-job" >&2
    echo "Do not reset if you already scaled GPU nodes above GPU_REPLICAS (default 1)." >&2
    return 0
  fi
  cluster_admin_info "Waiting for GPU MachineSet Job to complete (no-op on non-AWS) ..."
  "${KUBE_CMD[@]}" wait --for=condition=complete "job/${job}" -n "${ns}" --timeout=180s || \
    echo "MachineSet Job not complete yet (check: oc logs -n ${ns} job/${job})" >&2
}

# --- 00 AWS GPU MachineSet -------------------------------------------------

if [[ "${SKIP_MACHINESET}" != true ]]; then
  if [[ "${RESET_MACHINESET_JOB}" == true && "${DRY_RUN}" != true ]]; then
    cluster_admin_info "Deleting job-aws-gpu-machineset (if present) ..."
    "${KUBE_CMD[@]}" delete job job-aws-gpu-machineset -n nvidia-gpu-operator --ignore-not-found
  fi
  if [[ "${DRY_RUN}" != true ]] && "${KUBE_CMD[@]}" get job job-aws-gpu-machineset -n nvidia-gpu-operator >/dev/null 2>&1; then
    cluster_admin_info "Job job-aws-gpu-machineset already exists; refreshing RBAC/ConfigMap."
    cluster_admin_info "To recreate: $0 --reset-machineset-job"
    # Job specs are immutable; apply -k fails if env changed. Apply non-Job objects.
    apply_overlay "${CONFIGS}/00-cluster-setup/05-aws-gpu-machineset" || \
      cluster_admin_info "Ignoring immutable Job conflict (delete the Job to pick up job.yaml changes)."
  else
    apply_overlay "${CONFIGS}/00-cluster-setup/05-aws-gpu-machineset"
  fi
  if [[ "${DRY_RUN}" != true && "${SKIP_WAIT}" != true ]]; then
    wait_machineset_job
  fi
else
  cluster_admin_info "Skipping AWS GPU MachineSet (--skip-machineset)"
fi

# --- 01 NFD + GPU operator + NFD instance ----------------------------------

if [[ "${SKIP_GPU_OPERATORS}" != true ]]; then
  apply_overlay "${CONFIGS}/01-nvidia-gpu-operator/00-nfd-operator"
  wait_for_csv openshift-nfd
  wait_for_crd nodefeaturediscoveries.nfd.openshift.io

  apply_overlay "${CONFIGS}/01-nvidia-gpu-operator/01-nvidia-gpu-operator"
  wait_for_csv nvidia-gpu-operator

  apply_overlay "${CONFIGS}/01-nvidia-gpu-operator/02-nfd-instance"

  if [[ "${WITH_GPU_CLUSTERPOLICY}" == true ]]; then
    warn_danger "Applying workshop ClusterPolicy gpu-cluster-policy (no time-slicing). GitOps will overwrite this on sync."
    apply_overlay "${CONFIGS}/01-nvidia-gpu-operator/03-nvidia-gpu-instance"
  else
    cluster_admin_info "Skipping workshop ClusterPolicy (Helm time-slicing ClusterPolicy is applied by Argo CD)."
  fi

  if [[ "${WITH_GPU_EXTRAS}" == true ]]; then
    cluster_admin_info "GPU extras: console plugin (DCGM dashboard fetches JSON from GitHub)."
    apply_overlay "${CONFIGS}/01-nvidia-gpu-operator/05-optional-nvidia-console-plugin"
    apply_overlay "${CONFIGS}/01-nvidia-gpu-operator/04-optional-nvidia-monitoring-dashboard"
  fi
else
  cluster_admin_info "Skipping NFD/GPU operators (--skip-gpu-operators)"
fi

# --- 02 CUDA smoke (optional) ----------------------------------------------

if [[ "${SMOKE_TEST}" == true ]]; then
  cluster_admin_info "Applying CUDA smoke pods (need nvidia.com/gpu and GPU taint toleration)."
  apply_overlay "${CONFIGS}/02-nvidia-gpu-workload/00-gpu-test-namespace"
  apply_overlay "${CONFIGS}/02-nvidia-gpu-workload/01-nvidia-gpu-workload"
  apply_overlay "${CONFIGS}/02-nvidia-gpu-workload/02-nvidia-gpu-nvidia-smi"
else
  cluster_admin_info "Skipping 02-nvidia-gpu-workload (pass --smoke-test after GPUs are advertised)."
fi

# --- 03 RHOAI operator dependencies (optional) -----------------------------

if [[ "${WITH_RHOAI_DEPS}" == true ]]; then
  apply_overlay "${CONFIGS}/03-rhoai-operator-dependencies/00-leaderworkerset-operator"
  wait_for_csv openshift-lws-operator
  wait_for_crd leaderworkersetoperators.operator.openshift.io
  apply_overlay "${CONFIGS}/03-rhoai-operator-dependencies/01-leaderworkerset-instance"
  apply_overlay "${CONFIGS}/03-rhoai-operator-dependencies/02-jobset-operator"
  apply_overlay "${CONFIGS}/03-rhoai-operator-dependencies/04-opentelemetry-operator"
  apply_overlay "${CONFIGS}/03-rhoai-operator-dependencies/06-cluster-observability-operator"

  if [[ "${WITH_KUEUE}" == true ]]; then
    warn_danger "Installing Kueue; PoC DataScienceCluster keeps kueue Removed."
    apply_overlay "${CONFIGS}/03-rhoai-operator-dependencies/03-kueue-operator"
  fi
  if [[ "${WITH_TEMPO}" == true ]]; then
    warn_danger "Installing Tempo from workshop; observability chart also manages openshift-tempo-operator."
    apply_overlay "${CONFIGS}/03-rhoai-operator-dependencies/05-tempo-operator"
  fi
  if [[ "${WITH_CONNECTIVITY_LINK}" == true ]]; then
    apply_overlay "${CONFIGS}/03-rhoai-operator-dependencies/07-connectivity-link-operator"
    wait_for_csv kuadrant-system
    apply_overlay "${CONFIGS}/03-rhoai-operator-dependencies/08-optional-connectivity-link-console-plugin"
    apply_overlay "${CONFIGS}/03-rhoai-operator-dependencies/09-connectivity-link-kuadrant"
    if [[ "${DRY_RUN}" != true ]]; then
      cluster_admin_info "Run configs/03-rhoai-operator-dependencies/10-connectivity-link-tls-setup/connectivity-link-tls-setup.sh after Kuadrant is Ready."
    fi
  fi
else
  cluster_admin_info "Skipping 03-rhoai-operator-dependencies (pass --with-rhoai-deps for LWS/JobSet/OTEL/COO)."
fi

# --- 04 RHOAI operator only (optional) -------------------------------------

if [[ "${WITH_RHOAI_OPERATOR}" == true ]]; then
  apply_overlay "${CONFIGS}/04-rhoai-setup/00-rhoai-operator"
  wait_for_csv redhat-ods-operator
fi

if [[ "${WITH_WORKSHOP_DSC}" == true ]]; then
  warn_danger "Applying workshop default-dsc (kueue Unmanaged, extra Managed components). This fights Helm."
  apply_overlay "${CONFIGS}/04-rhoai-setup/01-datasciencecluster"
else
  cluster_admin_info "Skipping workshop DataScienceCluster (Helm default-dsc is applied by Argo CD)."
fi

cat <<EOF

Platform prep finished (dry-run=${DRY_RUN}).

GitOps still owns ClusterPolicy (time-slicing) and DataScienceCluster.
Next:
  1. oc apply -k gitops/argocd/
  2. Wait for GPU operator pods (driver 2/2) after ClusterPolicy syncs:
       oc get pods -n nvidia-gpu-operator
       oc describe node | grep -E 'nvidia.com/gpu|pci-10de' | head
  3. Hard-refresh acs-ai-overwatch after the cluster ConfigMap exists

See configs/README.md
EOF
