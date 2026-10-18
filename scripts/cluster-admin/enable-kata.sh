#!/usr/bin/env bash
# Turn on OpenShift sandboxed containers for approved Agent Sandbox workloads.
# The demo default leaves Kata off. This script records the choice on the live
# Argo CD Applications. Re-applying the git Application manifests resets it.
set -euo pipefail

PLATFORM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      PLATFORM="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "usage: $0 --platform baremetal|aws"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      echo "usage: $0 --platform baremetal|aws" >&2
      exit 2
      ;;
  esac
done

if [[ "${PLATFORM}" != "baremetal" && "${PLATFORM}" != "aws" ]]; then
  echo "usage: $0 --platform baremetal|aws" >&2
  exit 2
fi

if [[ "${PLATFORM}" == "baremetal" ]]; then
  RUNTIME="kata"
  cat <<'EOF'
Bare metal: nested Kata needs worker nodes that expose /dev/kvm (RHCOS, not RHEL compute).
The trust-plane chart installs the sandboxed-containers operator and a KataConfig.
Each approved sandbox then sets runtimeClassName=kata. No extra cloud instances are launched.
EOF
else
  RUNTIME="kata-remote"
  cat <<'EOF'
AWS: g6 VMs cannot nest Kata. Peer pods (kata-remote) launch one extra EC2 instance per sandbox.
This script does not create AWS keys. Before KataConfig can schedule peer pods, create the
cloud credential Secret your OpenShift sandboxed containers version documents, in
openshift-sandboxed-containers-operator, and confirm the peer-pod instance type. See
"Deploying Red Hat build of Agent Sandbox" (kata-remote / peer pods). Do not commit the keys.
EOF
fi

if ! command -v oc >/dev/null 2>&1; then
  echo "oc is required to patch the Argo CD Applications" >&2
  exit 1
fi

patch_app() {
  local name="$1"
  local payload="$2"
  if ! oc get application "${name}" -n openshift-gitops >/dev/null 2>&1; then
    echo "Application ${name} is not installed yet. Set these Helm values before you apply it:"
    echo "${payload}"
    return 0
  fi
  oc patch application "${name}" -n openshift-gitops --type merge -p "${payload}"
  oc annotate application "${name}" -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
  echo "patched ${name}"
}

patch_app acs-ai-overwatch-trust-plane "$(cat <<EOF
{"spec":{"source":{"helm":{"parameters":[
  {"name":"trustPlane.kata.enabled","value":"true"},
  {"name":"trustPlane.kata.platform","value":"${PLATFORM}"}
]}}}}
EOF
)"

patch_app acs-ai-overwatch-approved "$(cat <<EOF
{"spec":{"source":{"helm":{"parameters":[
  {"name":"sandbox.runtimeClass","value":"${RUNTIME}"}
]}}}}
EOF
)"

patch_app acs-ai-overwatch "$(cat <<EOF
{"spec":{"source":{"helm":{"parameters":[
  {"name":"agents.sandboxRuntimeClass","value":"${RUNTIME}"}
]}}}}
EOF
)"

echo "Kata requested (${PLATFORM} -> ${RUNTIME}). Wait until the KataConfig is Ready before starting approved sandboxes."
