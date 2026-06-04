#!/usr/bin/env bash
# Print Kagenti UI / Keycloak authentication URLs and demo credentials.
#
# Usage:
#   ./scripts/kagenti-auth-info.sh
#
# Requires: oc logged in, Phase 4 (kagenti Helm release) installed.
set -euo pipefail

KC_NS="${KEYCLOAK_NAMESPACE:-keycloak}"
KAGENTI_NS="${KAGENTI_NAMESPACE:-kagenti-system}"
KC_REALM="${KEYCLOAK_REALM:-kagenti}"

require_oc() {
  if ! command -v oc >/dev/null 2>&1; then
    echo "ERROR: oc not found in PATH" >&2
    exit 1
  fi
  if ! oc whoami >/dev/null 2>&1; then
    echo "ERROR: not logged in — run 'oc login' first" >&2
    exit 1
  fi
}

decode_secret_field() {
  local ns="$1" secret="$2" field="$3"
  local raw
  raw="$(oc get secret "$secret" -n "$ns" -o "jsonpath={.data.${field}}" 2>/dev/null || true)"
  if [ -z "$raw" ]; then
    echo "(not set)"
    return
  fi
  echo "$raw" | base64 -d
}

route_host() {
  local ns="$1" name="$2"
  oc get route "$name" -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null || true
}

require_oc

if ! helm status kagenti -n "$KAGENTI_NS" >/dev/null 2>&1; then
  echo "WARN: Helm release 'kagenti' not found in ${KAGENTI_NS} — Phase 4 may not be installed yet." >&2
fi

UI_HOST="$(route_host "$KAGENTI_NS" kagenti-ui)"
API_HOST="$(route_host "$KAGENTI_NS" kagenti-api)"
KC_HOST="$(route_host "$KC_NS" keycloak)"

echo "============================================"
echo "  Kagenti authentication (Phase 4)"
echo "============================================"
echo ""
echo "Realm:     ${KC_REALM}"
echo "Client ID: kagenti (from kagenti-ui-oauth-secret)"
echo ""
if [ -n "$UI_HOST" ]; then
  echo "Kagenti UI:  https://${UI_HOST}/"
else
  echo "Kagenti UI:  (route kagenti-ui not found in ${KAGENTI_NS})"
fi
if [ -n "$API_HOST" ]; then
  echo "Kagenti API: https://${API_HOST}/"
else
  echo "Kagenti API: (route kagenti-api not found in ${KAGENTI_NS})"
fi
if [ -n "$KC_HOST" ]; then
  echo "Keycloak:    https://${KC_HOST}/"
  echo "Login:       https://${KC_HOST}/realms/${KC_REALM}/account"
  echo "Admin UI:    https://${KC_HOST}/admin/  (master realm admin — see below)"
else
  echo "Keycloak:    (route keycloak not found in ${KC_NS})"
fi
echo ""

if oc get secret kagenti-ui-oauth-secret -n "$KAGENTI_NS" >/dev/null 2>&1; then
  echo "OAuth (UI):"
  echo "  ENABLE_AUTH:   $(decode_secret_field "$KAGENTI_NS" kagenti-ui-oauth-secret ENABLE_AUTH)"
  echo "  REDIRECT_URI:  $(decode_secret_field "$KAGENTI_NS" kagenti-ui-oauth-secret REDIRECT_URI)"
  echo "  AUTH_ENDPOINT: $(decode_secret_field "$KAGENTI_NS" kagenti-ui-oauth-secret AUTH_ENDPOINT)"
  echo ""
fi

echo "--- UI login users (realm ${KC_REALM}) ---"
if oc get secret kagenti-test-user -n "$KC_NS" >/dev/null 2>&1; then
  echo "  $(decode_secret_field "$KC_NS" kagenti-test-user username) / $(decode_secret_field "$KC_NS" kagenti-test-user password)"
else
  echo "  (secret kagenti-test-user not found in ${KC_NS})"
fi
if oc get secret kagenti-test-users -n "$KC_NS" >/dev/null 2>&1; then
  echo "  admin:     $(decode_secret_field "$KC_NS" kagenti-test-users admin-password)"
  echo "  dev-user:  $(decode_secret_field "$KC_NS" kagenti-test-users dev-user-password)"
  echo "  ns-admin:  $(decode_secret_field "$KC_NS" kagenti-test-users ns-admin-password)"
fi
echo ""
echo "--- Keycloak master admin (console only) ---"
if oc get secret keycloak-initial-admin -n "$KC_NS" >/dev/null 2>&1; then
  echo "  $(decode_secret_field "$KC_NS" keycloak-initial-admin username) / $(decode_secret_field "$KC_NS" keycloak-initial-admin password)"
else
  echo "  (secret keycloak-initial-admin not found in ${KC_NS})"
fi
echo ""
echo "Full checklist: gitops/helm/acs-ai-overwatch-kagenti-platform/KEYCLOAK.md"
echo "============================================"
