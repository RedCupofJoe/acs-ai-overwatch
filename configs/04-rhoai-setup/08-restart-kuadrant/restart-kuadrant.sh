#!/usr/bin/env bash
# Restart Kuadrant operators after the OpenShift AI gateway (Istio / Gateway API) is
# ready so AuthPolicies are accepted and MaaS gateway auth headers are injected.
#
# Run after steps 04 (MaaS gateway), 05 (namespace gateway access), 06 (MaaS database), and 07 (MaaS connection).
# See: https://github.com/opendatahub-io/models-as-a-service/issues/330

set -euo pipefail

KUADRANT_NS="${KUADRANT_NS:-kuadrant-system}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"

KUADRANT_OPERATOR_DEPLOY="${KUADRANT_OPERATOR_DEPLOY:-kuadrant-operator-controller-manager}"
AUTHORINO_OPERATOR_DEPLOY="${AUTHORINO_OPERATOR_DEPLOY:-authorino-operator}"
ISTIO_GATEWAY_CONTROLLER_NAMES="${ISTIO_GATEWAY_CONTROLLER_NAMES:-openshift.io/gateway-controller/v1}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_oc() {
  if ! command -v oc >/dev/null 2>&1; then
    die "oc CLI is required but not found in PATH"
  fi
  oc whoami >/dev/null 2>&1 || die "Not logged in to a cluster (oc whoami failed)"
}

wait_for_rollout() {
  local deployment="$1"
  echo "Waiting for deployment/${deployment} rollout in ${KUADRANT_NS} (${ROLLOUT_TIMEOUT})..."
  oc rollout status "deployment/${deployment}" -n "${KUADRANT_NS}" --timeout="${ROLLOUT_TIMEOUT}"
}

ensure_gateway_controller_env() {
  local current
  current="$(oc get deployment "${KUADRANT_OPERATOR_DEPLOY}" -n "${KUADRANT_NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ISTIO_GATEWAY_CONTROLLER_NAMES")].value}' 2>/dev/null || true)"

  if [ "${current}" = "${ISTIO_GATEWAY_CONTROLLER_NAMES}" ]; then
    echo "ISTIO_GATEWAY_CONTROLLER_NAMES is already set to ${ISTIO_GATEWAY_CONTROLLER_NAMES}"
    return 0
  fi

  if [ -n "${current}" ]; then
    echo "WARNING: ISTIO_GATEWAY_CONTROLLER_NAMES is '${current}', expected '${ISTIO_GATEWAY_CONTROLLER_NAMES}'"
    echo "         Skipping automatic patch; update the deployment manually if AuthPolicies stay unaccepted."
    return 0
  fi

  echo "Setting ISTIO_GATEWAY_CONTROLLER_NAMES=${ISTIO_GATEWAY_CONTROLLER_NAMES} on ${KUADRANT_OPERATOR_DEPLOY}"
  oc -n "${KUADRANT_NS}" patch deployment "${KUADRANT_OPERATOR_DEPLOY}" --type=json \
    -p="[{\"op\": \"add\", \"path\": \"/spec/template/spec/containers/0/env/-\", \"value\": {\"name\": \"ISTIO_GATEWAY_CONTROLLER_NAMES\", \"value\": \"${ISTIO_GATEWAY_CONTROLLER_NAMES}\"}}]"
}

print_gateway_class_status() {
  echo ""
  echo "Gateway classes:"
  oc get gatewayclass -o custom-columns=\
'NAME:.metadata.name,CONTROLLER:.spec.controllerName,ACCEPTED:.status.conditions[?(@.type=="Accepted")].status' \
    2>/dev/null || echo "  (no GatewayClass resources found)"
}

print_kuadrant_status() {
  echo ""
  echo "Kuadrant status:"
  if ! oc get kuadrant kuadrant -n "${KUADRANT_NS}" >/dev/null 2>&1; then
    echo "  Kuadrant CR 'kuadrant' not found in ${KUADRANT_NS}"
    return 1
  fi

  local ready message
  ready="$(oc get kuadrant kuadrant -n "${KUADRANT_NS}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  message="$(oc get kuadrant kuadrant -n "${KUADRANT_NS}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"

  echo "  Ready: ${ready:-Unknown}"
  if [ -n "${message}" ]; then
    echo "  Message: ${message}"
  fi

  [ "${ready}" = "True" ]
}

print_authpolicy_status() {
  echo ""
  echo "AuthPolicy acceptance:"
  if ! oc get authpolicy -A >/dev/null 2>&1; then
    echo "  No AuthPolicy resources found"
    return 0
  fi

  oc get authpolicy -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,ACCEPTED:.status.conditions[?(@.type=="Accepted")].status,REASON:.status.conditions[?(@.type=="Accepted")].reason' \
    2>/dev/null || true

  local statuses count_false
  statuses="$(oc get authpolicy -A -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Accepted")].status}{"\n"}{end}')"
  if [ -z "${statuses}" ]; then
    return 0
  fi

  count_false="$(printf '%s\n' "${statuses}" | grep -c '^False$' || true)"
  [ "${count_false}" -eq 0 ]
}

print_wasmplugin_status() {
  echo ""
  echo "WasmPlugins:"
  local count
  count="$(oc get wasmplugins -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${count}" -eq 0 ]; then
    echo "  None found (expected after AuthPolicies are accepted)"
    return 1
  fi

  oc get wasmplugins -A
  return 0
}

print_maas_authpolicy_hint() {
  echo ""
  echo "MaaS API AuthPolicy (if present):"
  if oc get authpolicy maas-api-auth-policy -n redhat-ods-applications >/dev/null 2>&1; then
    oc get authpolicy maas-api-auth-policy -n redhat-ods-applications \
      -o jsonpath='  Accepted: {.status.conditions[?(@.type=="Accepted")].status}{"\n"}  Message: {.status.conditions[?(@.type=="Accepted")].message}{"\n"}'
  else
    echo "  maas-api-auth-policy not found (apply MaaS gateway / tenant first)"
  fi
}

wait_for_kuadrant_ready() {
  local elapsed=0
  echo ""
  echo "Polling Kuadrant and AuthPolicies for up to ${READY_TIMEOUT}s..."

  while [ "${elapsed}" -lt "${READY_TIMEOUT}" ]; do
    local kuadrant_ok authpolicy_ok
    kuadrant_ok=0
    authpolicy_ok=0

    if print_kuadrant_status >/dev/null 2>&1; then
      kuadrant_ok=1
    fi
    if print_authpolicy_status >/dev/null 2>&1; then
      authpolicy_ok=1
    fi

    if [ "${kuadrant_ok}" -eq 1 ] && [ "${authpolicy_ok}" -eq 1 ]; then
      return 0
    fi

    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  return 1
}

restart_operators() {
  echo "Restarting Kuadrant operators in ${KUADRANT_NS}..."
  oc rollout restart "deployment/${KUADRANT_OPERATOR_DEPLOY}" -n "${KUADRANT_NS}"
  oc rollout restart "deployment/${AUTHORINO_OPERATOR_DEPLOY}" -n "${KUADRANT_NS}"

  wait_for_rollout "${KUADRANT_OPERATOR_DEPLOY}"
  wait_for_rollout "${AUTHORINO_OPERATOR_DEPLOY}"
}

main() {
  require_oc

  oc get namespace "${KUADRANT_NS}" >/dev/null 2>&1 \
    || die "Namespace ${KUADRANT_NS} not found. Install Connectivity Link (section 03) first."

  print_gateway_class_status
  ensure_gateway_controller_env
  restart_operators

  if wait_for_kuadrant_ready; then
    echo ""
    echo "Kuadrant reconciliation succeeded."
  else
    echo ""
    echo "WARNING: Kuadrant or AuthPolicies did not become ready within ${READY_TIMEOUT}s."
  fi

  print_kuadrant_status || true
  print_authpolicy_status || true
  print_wasmplugin_status || true
  print_maas_authpolicy_hint

  echo ""
  echo "Next steps if MaaS tokens UI still fails:"
  echo "  1. Reload the dashboard MaaS tokens page"
  echo "  2. Check maas-ui logs: oc logs -n redhat-ods-applications deployment/rhods-dashboard -c maas-ui --tail=30"
  echo "  3. Check maas-api logs: oc logs -n redhat-ods-applications deployment/maas-api --tail=30"
  echo "  4. Non-admin users need project list access; use admin or add dev to cluster-admins"
}

main "$@"
