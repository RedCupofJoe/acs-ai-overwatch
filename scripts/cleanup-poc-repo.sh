#!/usr/bin/env bash
# Reset local GitOps files to the portable PoC baseline (no cluster-specific settings).
#
# Run from the repo root after a PoC demo to undo opt-in phases, local discovery
# output, and scratch files before the next cluster or before sharing the fork.
#
# Does NOT delete or modify anything on the OpenShift cluster — repo only.
#
# Usage:
#   ./scripts/cleanup-poc-repo.sh              # apply resets
#   ./scripts/cleanup-poc-repo.sh --dry-run    # show what would change
#   ./scripts/cleanup-poc-repo.sh --reset-repo-urls   # also normalize Argo repoURL fields
#
# Environment:
#   GIT_REPO_URL   HTTPS Git remote for Argo Applications (default: git remote origin)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASELINE="${SCRIPT_DIR}/baseline"

DRY_RUN=false
RESET_REPO_URLS=false

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --reset-repo-urls)
      RESET_REPO_URLS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

log() {
  printf '%s\n' "$*"
}

run() {
  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] $*"
  else
    "$@"
  fi
}

copy_baseline() {
  local src="$1"
  local dest="$2"
  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] cp ${src} -> ${dest}"
  else
    cp "${src}" "${dest}"
    log "restored ${dest#"${REPO_ROOT}/"}"
  fi
}

remove_path() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    return
  fi
  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] rm -rf ${path#"${REPO_ROOT}/"}"
    return
  fi
  rm -rf "${path}"
  log "removed ${path#"${REPO_ROOT}/"}"
}

normalize_git_remote() {
  local raw="${1:-}"
  raw="${raw%.git}"
  if [[ "${raw}" =~ ^git@([^:]+):(.+)$ ]]; then
    printf 'https://%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return
  fi
  printf '%s' "${raw}"
}

resolve_git_repo_url() {
  if [[ -n "${GIT_REPO_URL:-}" ]]; then
    normalize_git_remote "${GIT_REPO_URL}"
    return
  fi
  if git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    normalize_git_remote "$(git -C "${REPO_ROOT}" config --get remote.origin.url 2>/dev/null || true)"
    return
  fi
  printf ''
}

reset_argo_repo_urls() {
  local repo_url
  repo_url="$(resolve_git_repo_url)"
  if [[ -z "${repo_url}" ]]; then
    log "skip Argo repoURL reset (set GIT_REPO_URL or configure git remote origin)"
    return
  fi

  local app
  for app in "${REPO_ROOT}"/gitops/argocd/application*.yaml; do
    [[ -f "${app}" ]] || continue
    if [[ "${DRY_RUN}" == true ]]; then
      log "[dry-run] set spec.source.repoURL=${repo_url} in ${app#"${REPO_ROOT}/"}"
    else
      if command -v python3 >/dev/null 2>&1; then
        python3 - "${app}" "${repo_url}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
url = sys.argv[2]
lines = path.read_text().splitlines(keepends=True)
out = []
for line in lines:
    if line.lstrip().startswith("repoURL:"):
        indent = line[: len(line) - len(line.lstrip())]
        out.append(f"{indent}repoURL: {url}\n")
    else:
        out.append(line)
path.write_text("".join(out))
PY
      else
        # Fallback: replace first repoURL line in each Application manifest.
        sed -i.bak "s|repoURL: .*|repoURL: ${repo_url}|" "${app}"
        rm -f "${app}.bak"
      fi
      log "set repoURL in ${app#"${REPO_ROOT}/"}"
    fi
  done
}

ensure_observability_disabled() {
  local values="${REPO_ROOT}/gitops/helm/acs-ai-overwatch-observability/values.yaml"
  [[ -f "${values}" ]] || return 0
  if grep -q '^enabled: true' "${values}" 2>/dev/null; then
    if [[ "${DRY_RUN}" == true ]]; then
      log "[dry-run] set enabled: false in gitops/helm/acs-ai-overwatch-observability/values.yaml"
    else
      sed -i.bak 's/^enabled: true/enabled: false/' "${values}"
      rm -f "${values}.bak"
      log "set enabled: false in gitops/helm/acs-ai-overwatch-observability/values.yaml"
    fi
  fi
}

main() {
  cd "${REPO_ROOT}"

  log "ACS AI Overwatch — repo cleanup (baseline GitOps, no cluster-specific files)"
  if [[ "${DRY_RUN}" == true ]]; then
    log "Mode: dry-run (no files modified)"
  fi
  log ""

  copy_baseline "${BASELINE}/values-poc.yaml" \
    "${REPO_ROOT}/gitops/helm/acs-ai-overwatch/values-poc.yaml"
  copy_baseline "${BASELINE}/kustomization.yaml" \
    "${REPO_ROOT}/gitops/argocd/kustomization.yaml"
  copy_baseline "${BASELINE}/kagenti-platform-values.yaml" \
    "${REPO_ROOT}/gitops/helm/acs-ai-overwatch-kagenti-platform/values.yaml"

  ensure_observability_disabled

  remove_path "${REPO_ROOT}/gitops/helm/acs-ai-overwatch/values-cluster.yaml"
  remove_path "${REPO_ROOT}/scratch"

  if [[ "${RESET_REPO_URLS}" == true ]]; then
    reset_argo_repo_urls
  fi

  log ""
  log "Done. Review with: git status && git diff"
  log "Cluster resources were not changed. Tear down the cluster separately if needed."
}

main "$@"
