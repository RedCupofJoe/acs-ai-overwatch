{{- define "acs-ai-overwatch.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "acs-ai-overwatch.labels" -}}
app.kubernetes.io/name: {{ include "acs-ai-overwatch.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- if .Values.global.partOf }}
app.kubernetes.io/part-of: {{ .Values.global.partOf }}
{{- end }}
{{- end }}

{{- define "acs-ai-overwatch.chartLabel" -}}
{{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{- define "mattermost.bootstrapScript" -}}
#!/usr/bin/env bash
set -euo pipefail

MM_API="${MATTERMOST_INTERNAL_URL:?}"
SITE_URL="${MATTERMOST_SITE_URL:?}"
ADMIN_EMAIL="${ADMIN_EMAIL:?}"
ADMIN_USER="${ADMIN_USERNAME:?}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?}"
HITL_EMAIL="${HITL_EMAIL:?}"
HITL_PASSWORD="${HITL_PASSWORD:?}"
HITL_USER="human-in-the-loop"

json_field() {
  local key="$1"
  local file="${2:-/dev/stdin}"
  grep -o "\"${key}\":\"[^\"]*\"" "${file}" | head -1 | cut -d '"' -f 4
}

wait_for_mattermost() {
  local i
  for i in $(seq 1 120); do
    if curl -sf "${MM_API}/api/v4/system/ping" | grep -q '"status":"OK"'; then
      return 0
    fi
    echo "waiting for Mattermost (${i}/120)..."
    sleep 5
  done
  echo "Mattermost did not become ready in time."
  exit 1
}

api_token() {
  curl -sf -X POST "${MM_API}/api/v4/users/login" \
    -H "Content-Type: application/json" \
    -d "{\"login_id\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASSWORD}\"}" \
    -o /tmp/login.json
  json_field token /tmp/login.json
}

wait_for_mattermost

HTTP_CODE=$(curl -s -o /tmp/create_admin.json -w "%{http_code}" -X POST "${MM_API}/api/v4/users" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${ADMIN_EMAIL}\",\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASSWORD}\"}")

if [ "${HTTP_CODE}" != "201" ] && [ "${HTTP_CODE}" != "400" ]; then
  echo "Unexpected response creating bootstrap admin (HTTP ${HTTP_CODE}):"
  cat /tmp/create_admin.json
  exit 1
fi

TOKEN="$(api_token)"
if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "null" ]; then
  echo "Failed to log in as bootstrap admin."
  cat /tmp/login.json || true
  exit 1
fi

HITL_CODE=$(curl -s -o /tmp/create_hitl.json -w "%{http_code}" -X POST "${MM_API}/api/v4/users" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${HITL_EMAIL}\",\"username\":\"${HITL_USER}\",\"password\":\"${HITL_PASSWORD}\"}")

if [ "${HITL_CODE}" != "201" ] && [ "${HITL_CODE}" != "400" ]; then
  echo "Unexpected response creating ${HITL_USER} user (HTTP ${HITL_CODE}):"
  cat /tmp/create_hitl.json
  exit 1
fi

curl -sf "${MM_API}/api/v4/users/me/teams" \
  -H "Authorization: Bearer ${TOKEN}" \
  -o /tmp/teams.json

TEAM_ID="$(json_field id /tmp/teams.json)"
if [ -z "${TEAM_ID}" ]; then
  echo "Could not resolve team id from /users/me/teams:"
  cat /tmp/teams.json
  exit 1
fi

curl -sf "${MM_API}/api/v4/teams/${TEAM_ID}/channels/name/town-square" \
  -H "Authorization: Bearer ${TOKEN}" \
  -o /tmp/ts.json

CHANNEL_ID="$(json_field id /tmp/ts.json)"
if [ -z "${CHANNEL_ID}" ]; then
  echo "Could not resolve Town Square channel id:"
  cat /tmp/ts.json
  exit 1
fi

curl -sf -X POST "${MM_API}/api/v4/hooks/incoming" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"channel_id\":\"${CHANNEL_ID}\",\"display_name\":\"ACS Integration\",\"description\":\"Slack-compatible incoming webhook for ACS\",\"username\":\"acs\"}" \
  -o /tmp/hook.json

HOOK_ID="$(json_field id /tmp/hook.json)"
HOOK_TOKEN="$(json_field token /tmp/hook.json)"
if [ -z "${HOOK_ID}" ] || [ -z "${HOOK_TOKEN}" ]; then
  echo "Failed to create incoming webhook:"
  cat /tmp/hook.json
  exit 1
fi

WEBHOOK_URL="${SITE_URL%/}/hooks/${HOOK_ID}/${HOOK_TOKEN}"

kubectl -n {{ .Values.mattermost.namespace }} create configmap mattermost-acs-integration \
  --from-literal=ACS_INCOMING_WEBHOOK_URL="${WEBHOOK_URL}" \
  --from-literal=NOTE="Slack-compatible POST target for ACS; Content-Type application/json." \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Stored ACS_INCOMING_WEBHOOK_URL in ConfigMap mattermost-acs-integration."
echo "${WEBHOOK_URL}"
{{- end }}
