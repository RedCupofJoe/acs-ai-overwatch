# Shared helpers for the per-agent demo scripts.
# Source this file. Do not execute it.

RANGE_NS="${RANGE_NS:-test-range}"
MONITORING_NS="${MONITORING_NS:-monitoring}"
STACKROX_NS="${STACKROX_NS:-stackrox}"
CHAT_TIMEOUT="${CHAT_TIMEOUT:-180}"

require_oc() {
  if ! command -v oc >/dev/null 2>&1; then
    echo "oc is required. Log in to the cluster first." >&2
    exit 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required." >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to encode the chat message." >&2
    exit 1
  fi
}

agent_pod() {
  local name="$1"
  local pod
  pod="$(oc get pods -n "${RANGE_NS}" -l "app.kubernetes.io/name=${name}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${pod}" ]]; then
    echo "No Running pod for ${name} in ${RANGE_NS}." >&2
    exit 1
  fi
  printf '%s\n' "${pod}"
}

agent_exec() {
  local name="$1"
  local script="$2"
  local pod
  pod="$(agent_pod "${name}")"
  oc exec -n "${RANGE_NS}" "${pod}" -c "${name}" -- sh -c "${script}"
}

print_banner() {
  local title="$1"
  local watch="$2"
  echo
  echo "=== ${title} ==="
  echo "Watch: ${watch}"
  echo
}

print_workload() {
  local name="$1"
  local pod kind telemetry approved runtime harness
  pod="$(agent_pod "${name}")"
  if oc get sandbox "${name}" -n "${RANGE_NS}" >/dev/null 2>&1; then
    kind="Sandbox"
  elif oc get deploy "${name}" -n "${RANGE_NS}" >/dev/null 2>&1; then
    kind="Deployment"
  else
    kind="Pod"
  fi
  telemetry="$(oc get pod "${pod}" -n "${RANGE_NS}" -o jsonpath='{.metadata.labels.acs-ai-overwatch\.io/telemetry}' 2>/dev/null || true)"
  approved="$(oc get pod "${pod}" -n "${RANGE_NS}" -o jsonpath='{.metadata.labels.acs-ai-overwatch\.io/approved}' 2>/dev/null || true)"
  runtime="$(oc get pod "${pod}" -n "${RANGE_NS}" -o jsonpath='{.metadata.labels.acs-ai-overwatch\.io/runtime}' 2>/dev/null || true)"
  harness="$(oc get pod "${pod}" -n "${RANGE_NS}" -o jsonpath='{.metadata.labels.acs-ai-overwatch\.io/harness}' 2>/dev/null || true)"
  echo "workload: ${kind}/${name}"
  echo "pod: ${pod}"
  echo "telemetry: ${telemetry:-<missing>}"
  echo "approved: ${approved:-<missing>}"
  echo "runtime: ${runtime:-plain pod}"
  echo "harness: ${harness:-llama.cpp}"
}

print_scanners() {
  local name="$1"
  agent_exec "${name}" '
for b in nmap masscan rustscan naabu; do
  installed=absent
  command -v "$b" >/dev/null 2>&1 && installed=installed
  running=no
  for d in /proc/[0-9]*; do
    cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null || true)
    case "$cmd" in
      "$b"*|*/"$b"*) running=yes ;;
    esac
  done
  echo "$b $installed running=$running"
done
'
}

wait_for_scanner() {
  local name="$1"
  local state=""
  local _
  echo "Waiting for a scanner process in ${name}..."
  for _ in $(seq 1 20); do
    state="$(print_scanners "${name}" 2>/dev/null || true)"
    if grep -q 'running=yes' <<<"${state}"; then
      printf '%s\n' "${state}"
      return 0
    fi
    sleep 1
  done
  echo "No scanner process appeared within 20s."
  printf '%s\n' "${state}"
  return 0
}

print_transcripts() {
  local name="$1"
  echo "Transcripts:"
  agent_exec "${name}" 'ls -lt /agent-reference-information 2>/dev/null | head -n 8 || echo "(no transcript directory)"'
}

print_spiffe() {
  local name="$1"
  echo "SPIFFE JWT-SVID:"
  agent_exec "${name}" '
if [ -s /run/spiffe-svid/jwt_svid.token ]; then
  echo "present at /run/spiffe-svid/jwt_svid.token"
else
  echo "missing"
fi
'
}

print_policy() {
  local policy="$1"
  local actions
  if ! oc get securitypolicy "${policy}" -n "${STACKROX_NS}" >/dev/null 2>&1; then
    echo "SecurityPolicy ${policy} is not in ${STACKROX_NS}."
    return 0
  fi
  actions="$(oc get securitypolicy "${policy}" -n "${STACKROX_NS}" -o jsonpath='{.spec.enforcementActions}' 2>/dev/null || true)"
  echo "SecurityPolicy ${policy} enforcement: ${actions:-<unset>}"
}

print_bridge() {
  echo "Mattermost bridge (latest lines):"
  oc logs -n "${MONITORING_NS}" deploy/acs-mattermost-bridge --tail=12 2>/dev/null \
    || echo "(acs-mattermost-bridge is not running)"
}

agent_chat() {
  local name="$1"
  local message="$2"
  local url host payload reply
  if [[ -n "${AGENT_URL:-}" ]]; then
    url="${AGENT_URL%/}/chat"
  else
    host="$(oc get route "${name}" -n "${RANGE_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    if [[ -z "${host}" ]]; then
      echo "Route ${name} is missing in ${RANGE_NS}." >&2
      exit 1
    fi
    url="https://${host}/chat"
  fi
  echo "POST ${url}"
  echo "message: ${message}"
  payload="$(MSG="${message}" python3 -c 'import json, os; print(json.dumps({"message": os.environ["MSG"]}))')"
  reply="$(curl -skS --max-time "${CHAT_TIMEOUT}" -X POST "${url}" \
    -H 'Content-Type: application/json' \
    -d "${payload}")"
  echo
  echo "Reply:"
  printf '%s\n' "${reply}" | python3 -c 'import json,sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    print(raw)
    raise SystemExit(0)
print(data.get("reply", raw))'
  echo
}
