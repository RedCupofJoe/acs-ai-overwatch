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

{{/* Default StorageClass for PVCs (discovery ConfigMap overrides values.yaml). */}}
{{- define "acs-ai-overwatch.storageClassName" -}}
{{- $valuesDefault := .Values.storage.defaultStorageClass | default "gp3-csi" -}}
{{- if .Values.clusterDiscovery.enabled -}}
{{- $cm := lookup "v1" "ConfigMap" .Values.clusterDiscovery.namespace .Values.clusterDiscovery.configMapName -}}
{{- if and $cm $cm.data.defaultStorageClass -}}
{{- $cm.data.defaultStorageClass -}}
{{- else -}}
{{- $valuesDefault -}}
{{- end -}}
{{- else -}}
{{- $valuesDefault -}}
{{- end -}}
{{- end }}

{{/*
  OLM Subscription channel: prefer cluster-discovery ConfigMap, else values.yaml default.
  Usage: include "acs-ai-overwatch.operatorChannel" (dict "root" . "key" "quayOperatorChannel" "default" .Values.quayStorage.quayOperator.subscription.channel)
*/}}
{{- define "acs-ai-overwatch.operatorChannel" -}}
{{- $root := .root -}}
{{- $key := .key -}}
{{- $default := .default -}}
{{- if and $root.Values.clusterDiscovery.enabled $key -}}
{{- $cm := lookup "v1" "ConfigMap" $root.Values.clusterDiscovery.namespace $root.Values.clusterDiscovery.configMapName -}}
{{- if and $cm $cm.data (index $cm.data $key) -}}
{{- index $cm.data $key -}}
{{- else -}}
{{- $default -}}
{{- end -}}
{{- else -}}
{{- $default -}}
{{- end -}}
{{- end }}

{{/*
  Argo CD sync-wave annotation. Usage:
    metadata:
      name: example
      {{- include "acs-ai-overwatch.argocdSyncWaveAnnotations" (dict "root" . "wave" "namespace") | nindent 2 }}
      labels: ...
*/}}
{{- define "acs-ai-overwatch.argocdSyncWaveAnnotations" -}}
{{- $root := .root -}}
{{- $waveKey := .wave -}}
{{- if $root.Values.argocd.syncWaves.enabled }}
{{- $wave := index $root.Values.argocd.syncWaves $waveKey -}}
annotations:
  argocd.argoproj.io/sync-wave: {{ $wave | quote }}
{{- end }}
{{- end }}

{{/*
  Sync-wave plus SkipDryRunOnMissingResource for operator-owned CRDs (may not exist on first sync).
*/}}
{{- define "acs-ai-overwatch.argocdPlatformCrAnnotations" -}}
{{- $root := .root -}}
{{- $waveKey := .wave -}}
annotations:
{{- if $root.Values.argocd.syncWaves.enabled }}
  argocd.argoproj.io/sync-wave: {{ index $root.Values.argocd.syncWaves $waveKey | quote }}
{{- end }}
  argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end }}

{{- define "acs-ai-overwatch.createNamespaces" -}}
{{- if not .Values.gitops.bootstrapNamespaces -}}true{{- end -}}
{{- end }}

{{/*
  True when platformResources.waitForCrds is false or the named CRD is installed (Helm lookup).
  Requires Argo/repo-server cluster access for lookup; if lookup never works, set waitForCrds: false
  after operators are up.
*/}}
{{- define "acs-ai-overwatch.crdReady" -}}
{{- $root := .root -}}
{{- $crdName := .crdName -}}
{{- if not $root.Values.platformResources.waitForCrds -}}true{{- end -}}
{{- $crd := lookup "apiextensions.k8s.io/v1" "CustomResourceDefinition" "" $crdName -}}
{{- if $crd -}}true{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.clusterConfigReady" -}}
{{- if .Values.cluster.appsDomain -}}true{{- end -}}
{{- if .Values.clusterDiscovery.enabled -}}
{{- $cm := lookup "v1" "ConfigMap" .Values.clusterDiscovery.namespace .Values.clusterDiscovery.configMapName -}}
{{- if and $cm $cm.data.appsDomain -}}true{{- end -}}
{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.appsDomain" -}}
{{- if .Values.cluster.appsDomain -}}
{{- .Values.cluster.appsDomain -}}
{{- else if .Values.clusterDiscovery.enabled -}}
{{- $cm := lookup "v1" "ConfigMap" .Values.clusterDiscovery.namespace .Values.clusterDiscovery.configMapName -}}
{{- if and $cm $cm.data.appsDomain -}}
{{- $cm.data.appsDomain -}}
{{- else -}}
{{- fail (printf "cluster.appsDomain is unset. Sync Argo CD Application %q first (writes ConfigMap %s/%s), then refresh this Application. Or run: ./scripts/discover-cluster-values.sh" .Values.clusterDiscovery.discoveryApplicationName .Values.clusterDiscovery.namespace .Values.clusterDiscovery.configMapName) -}}
{{- end -}}
{{- else -}}
{{- fail "cluster.appsDomain is unset. Enable clusterDiscovery or run ./scripts/discover-cluster-values.sh" -}}
{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.clusterName" -}}
{{- if ne .Values.cluster.name "acs-ai-overwatch" -}}
{{- .Values.cluster.name -}}
{{- else -}}
{{- $cm := lookup "v1" "ConfigMap" .Values.clusterDiscovery.namespace .Values.clusterDiscovery.configMapName -}}
{{- if and $cm $cm.data.clusterName -}}
{{- $cm.data.clusterName -}}
{{- else -}}
{{- .Values.cluster.name -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.mattermostRouteHost" -}}
{{- if .Values.mattermost.route.host -}}
{{- .Values.mattermost.route.host -}}
{{- else if .Values.clusterDiscovery.enabled -}}
{{- $cm := lookup "v1" "ConfigMap" .Values.clusterDiscovery.namespace .Values.clusterDiscovery.configMapName -}}
{{- if and $cm $cm.data.mattermostRouteHost -}}
{{- $cm.data.mattermostRouteHost -}}
{{- else -}}
{{- $domain := include "acs-ai-overwatch.appsDomain" . -}}
{{- printf "mattermost-%s.%s" .Values.mattermost.namespace $domain -}}
{{- end -}}
{{- else -}}
{{- $domain := include "acs-ai-overwatch.appsDomain" . -}}
{{- printf "mattermost-%s.%s" .Values.mattermost.namespace $domain -}}
{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.mattermostPostgresDataSource" -}}
{{- $pg := .Values.mattermost.postgres -}}
{{- printf "postgres://%s:%s@%s.%s.svc.cluster.local:5432/%s?sslmode=disable&connect_timeout=10" $pg.username $pg.password $pg.serviceName .Values.mattermost.namespace $pg.database -}}
{{- end }}

{{- define "acs-ai-overwatch.mattermostSiteUrl" -}}
{{- if .Values.mattermost.siteUrl -}}
{{- .Values.mattermost.siteUrl -}}
{{- else if .Values.clusterDiscovery.enabled -}}
{{- $cm := lookup "v1" "ConfigMap" .Values.clusterDiscovery.namespace .Values.clusterDiscovery.configMapName -}}
{{- if and $cm $cm.data.mattermostSiteUrl -}}
{{- $cm.data.mattermostSiteUrl -}}
{{- else -}}
{{- printf "https://%s" (include "acs-ai-overwatch.mattermostRouteHost" .) -}}
{{- end -}}
{{- else -}}
{{- printf "https://%s" (include "acs-ai-overwatch.mattermostRouteHost" .) -}}
{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.quayRegistryServer" -}}
{{- if .Values.quayStorage.registryCredentials.server -}}
{{- .Values.quayStorage.registryCredentials.server -}}
{{- else -}}
{{- $cm := lookup "v1" "ConfigMap" .Values.clusterDiscovery.namespace .Values.clusterDiscovery.configMapName -}}
{{- if and $cm $cm.data.quayRegistryServer -}}
{{- $cm.data.quayRegistryServer -}}
{{- else -}}
{{- $domain := include "acs-ai-overwatch.appsDomain" . -}}
{{- if hasPrefix "apps." $domain -}}
{{- printf "quay-quay.%s" $domain -}}
{{- else -}}
{{- printf "quay-quay.apps.%s" $domain -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.kagentiPlatformUrl" -}}
{{- if .Values.kagenti.platformUrl -}}
{{- .Values.kagenti.platformUrl -}}
{{- else -}}
http://kagenti-backend.kagenti-system.svc.cluster.local:8000
{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.kagentiAgentPlatformEnv" -}}
- name: PLATFORM_URL
  value: {{ include "acs-ai-overwatch.kagentiPlatformUrl" . | quote }}
{{- end }}

{{- define "acs-ai-overwatch.slmVllmServiceUrl" -}}
http://{{ .Values.slm.vllm.name }}.{{ .Values.kagenti.namespace }}.svc.cluster.local:{{ .Values.slm.vllm.servicePort }}/v1
{{- end }}

{{- define "acs-ai-overwatch.slmRhoaiServiceUrl" -}}
http://{{ .Values.slm.rhoai.inferenceServiceName }}-predictor.{{ .Values.kagenti.namespace }}.svc.cluster.local/v1
{{- end }}

{{- define "acs-ai-overwatch.slmLlmApiBase" -}}
{{- if eq .Values.slm.backend "rhoai" -}}
{{- include "acs-ai-overwatch.slmRhoaiServiceUrl" . -}}
{{- else -}}
{{- include "acs-ai-overwatch.slmVllmServiceUrl" . -}}
{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.slmLlmModel" -}}
{{- if eq .Values.slm.backend "rhoai" -}}
{{- .Values.slm.rhoai.servedModelName -}}
{{- else if .Values.slm.vllm.servedModelName -}}
{{- .Values.slm.vllm.servedModelName -}}
{{- else -}}
{{- .Values.slm.vllm.model -}}
{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.slmAgentLlmEnv" -}}
- name: LLM_API_BASE
  value: {{ include "acs-ai-overwatch.slmLlmApiBase" . | quote }}
- name: LLM_MODEL
  value: {{ include "acs-ai-overwatch.slmLlmModel" . | quote }}
{{- end }}

{{- define "acs-ai-overwatch.kagentiApiBaseUrl" -}}
{{- if .Values.kagenti.api.baseUrl -}}
{{- .Values.kagenti.api.baseUrl -}}
{{- else -}}
{{- $cm := lookup "v1" "ConfigMap" .Values.clusterDiscovery.namespace .Values.clusterDiscovery.configMapName -}}
{{- if and $cm $cm.data.kagentiApiBaseUrl -}}
{{- $cm.data.kagentiApiBaseUrl -}}
{{- else -}}
{{- $domain := include "acs-ai-overwatch.appsDomain" . -}}
{{- if hasPrefix "apps." $domain -}}
{{- printf "https://kagenti-api.%s" $domain -}}
{{- else -}}
{{- printf "https://kagenti-api.apps.%s" $domain -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.gitRepoUrl" -}}
{{- if .Values.kagenti.appSource.repoUrl -}}
{{- .Values.kagenti.appSource.repoUrl -}}
{{- else -}}
{{- $cm := lookup "v1" "ConfigMap" .Values.clusterDiscovery.namespace .Values.clusterDiscovery.configMapName -}}
{{- if and $cm $cm.data.gitRepoUrl -}}
{{- $cm.data.gitRepoUrl -}}
{{- else -}}
{{- fail "kagenti.appSource.repoUrl is unset and cluster ConfigMap has no gitRepoUrl" -}}
{{- end -}}
{{- end -}}
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
TEAM_NAME="{{ .Values.mattermost.bootstrap.teamName }}"
TEAM_DISPLAY="{{ .Values.mattermost.bootstrap.teamDisplayName }}"

json_field() {
  local key="$1"
  local file="${2:-/dev/stdin}"
  jq -r --arg k "${key}" 'if type == "array" then (.[0][$k] // empty) else (.[$k] // empty) end' "${file}" 2>/dev/null | head -1
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
  curl -sf --http1.1 -i -X POST "${MM_API}/api/v4/users/login" \
    -H "Content-Type: application/json" \
    -d "{\"login_id\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASSWORD}\"}" \
    > /tmp/login_response.txt
  awk 'BEGIN{body=0} /^\r?$/{body=1; next} body{print}' /tmp/login_response.txt > /tmp/login.json
  local token
  token="$(awk 'BEGIN{IGNORECASE=1} /^token:/{sub(/^[^:]+:[ \t]*/,""); gsub(/\r$/,""); print; exit}' /tmp/login_response.txt)"
  if [ -z "${token}" ]; then
    token="$(grep -Fi 'MMAUTHTOKEN=' /tmp/login_response.txt | head -1 | sed -n 's/.*MMAUTHTOKEN=\([^;]*\).*/\1/p')"
  fi
  if [ -z "${token}" ]; then
    token="$(json_field token /tmp/login.json)"
  fi
  echo "${token}"
}

ensure_team() {
  local token="$1"
  local code
  code="$(curl -s -o /tmp/team_get.json -w "%{http_code}" \
    "${MM_API}/api/v4/teams/name/${TEAM_NAME}" \
    -H "Authorization: Bearer ${token}")"
  if [ "${code}" = "200" ]; then
    json_field id /tmp/team_get.json
    return 0
  fi
  code="$(curl -s -o /tmp/team_create.json -w "%{http_code}" -X POST "${MM_API}/api/v4/teams" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${TEAM_NAME}\",\"display_name\":\"${TEAM_DISPLAY}\",\"type\":\"O\"}")"
  if [ "${code}" != "201" ] && [ "${code}" != "200" ]; then
    echo "Failed to create team ${TEAM_NAME} (HTTP ${code}):"
    cat /tmp/team_create.json
    exit 1
  fi
  json_field id /tmp/team_create.json
}

add_team_member() {
  local token="$1"
  local team_id="$2"
  local user_id="$3"
  local code
  code="$(curl -s -o /tmp/team_member.json -w "%{http_code}" -X POST "${MM_API}/api/v4/teams/${team_id}/members" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{\"team_id\":\"${team_id}\",\"user_id\":\"${user_id}\"}")"
  if [ "${code}" != "201" ] && [ "${code}" != "400" ]; then
    echo "Failed to add user ${user_id} to team (HTTP ${code}):"
    cat /tmp/team_member.json
    exit 1
  fi
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
  echo "Failed to log in as bootstrap admin (no session token in response)."
  echo "Response headers:"
  sed -n '1,/^\r\?$/p' /tmp/login_response.txt 2>/dev/null || true
  echo "Response body:"
  cat /tmp/login.json 2>/dev/null || true
  exit 1
fi

curl -sf "${MM_API}/api/v4/users/me" \
  -H "Authorization: Bearer ${TOKEN}" \
  -o /tmp/me.json
ADMIN_ID="$(json_field id /tmp/me.json)"
if [ -z "${ADMIN_ID}" ]; then
  echo "Could not resolve admin user id:"
  cat /tmp/me.json
  exit 1
fi

TEAM_ID="$(ensure_team "${TOKEN}")"
if [ -z "${TEAM_ID}" ]; then
  echo "Could not resolve team id for ${TEAM_NAME}."
  exit 1
fi
add_team_member "${TOKEN}" "${TEAM_ID}" "${ADMIN_ID}"

HITL_CODE=$(curl -s -o /tmp/create_hitl.json -w "%{http_code}" -X POST "${MM_API}/api/v4/users" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${HITL_EMAIL}\",\"username\":\"${HITL_USER}\",\"password\":\"${HITL_PASSWORD}\"}")

if [ "${HITL_CODE}" != "201" ] && [ "${HITL_CODE}" != "400" ]; then
  echo "Unexpected response creating ${HITL_USER} user (HTTP ${HITL_CODE}):"
  cat /tmp/create_hitl.json
  exit 1
fi

curl -sf "${MM_API}/api/v4/users/username/${HITL_USER}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -o /tmp/hitl_user.json
HITL_ID="$(json_field id /tmp/hitl_user.json)"
if [ -n "${HITL_ID}" ]; then
  add_team_member "${TOKEN}" "${TEAM_ID}" "${HITL_ID}"
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

HOOK_CODE=$(curl -s -o /tmp/hook.json -w "%{http_code}" -X POST "${MM_API}/api/v4/hooks/incoming" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"channel_id\":\"${CHANNEL_ID}\",\"display_name\":\"ACS Integration\",\"description\":\"Slack-compatible incoming webhook for ACS\",\"username\":\"acs\"}")

if [ "${HOOK_CODE}" != "201" ] && [ "${HOOK_CODE}" != "200" ]; then
  echo "Create webhook returned HTTP ${HOOK_CODE}; looking for existing ACS Integration hook..."
  curl -sf "${MM_API}/api/v4/teams/${TEAM_ID}/hooks/incoming" \
    -H "Authorization: Bearer ${TOKEN}" \
    -o /tmp/hook_list.json
  HOOK_ID="$(jq -r '.[] | select(.display_name=="ACS Integration") | .id' /tmp/hook_list.json 2>/dev/null | head -1)"
  if [ -z "${HOOK_ID}" ] || [ "${HOOK_ID}" = "null" ]; then
    echo "Unexpected response creating incoming webhook (HTTP ${HOOK_CODE}):"
    cat /tmp/hook.json
    exit 1
  fi
  echo "{\"id\":\"${HOOK_ID}\"}" > /tmp/hook.json
fi

HOOK_ID="$(json_field id /tmp/hook.json)"
HOOK_TOKEN="$(json_field token /tmp/hook.json)"
if [ -n "${HOOK_ID}" ] && [ -z "${HOOK_TOKEN}" ]; then
  HOOK_GET_CODE=$(curl -s -o /tmp/hook_get.json -w "%{http_code}" \
    "${MM_API}/api/v4/hooks/incoming/${HOOK_ID}" \
    -H "Authorization: Bearer ${TOKEN}")
  if [ "${HOOK_GET_CODE}" = "200" ]; then
    HOOK_TOKEN="$(json_field token /tmp/hook_get.json)"
  fi
fi
if [ -z "${HOOK_ID}" ]; then
  echo "Failed to resolve incoming webhook id:"
  cat /tmp/hook.json
  exit 1
fi

# Mattermost uses a single secret segment in the webhook URL (/hooks/{token}).
if [ -n "${HOOK_TOKEN}" ]; then
  WEBHOOK_URL="${SITE_URL%/}/hooks/${HOOK_TOKEN}"
else
  WEBHOOK_URL="${SITE_URL%/}/hooks/${HOOK_ID}"
fi

if ! kubectl -n {{ .Values.mattermost.namespace }} create configmap mattermost-acs-integration \
  --from-literal=ACS_INCOMING_WEBHOOK_URL="${WEBHOOK_URL}" \
  --from-literal=NOTE="Slack-compatible POST target for ACS; Content-Type application/json." \
  --dry-run=client -o yaml | kubectl apply -f -; then
  echo "Failed to write ConfigMap mattermost-acs-integration (check bootstrap ServiceAccount RBAC and kubectl in-cluster auth)."
  exit 1
fi

echo "Stored ACS_INCOMING_WEBHOOK_URL in ConfigMap mattermost-acs-integration."
echo "${WEBHOOK_URL}"
{{- end }}

{{- define "acs-ai-overwatch.acsBootstrapScript" -}}
#!/usr/bin/env bash
set -euo pipefail

ACS_NS="{{ .Values.acs.central.namespace }}"
CENTRAL_NAME="{{ .Values.acs.central.name }}"
SC_NAME="{{ .Values.acs.securedCluster.name }}"
CLUSTER_NAME="{{ .Values.acs.securedCluster.clusterName }}"
CENTRAL_ENDPOINT="{{ .Values.acs.securedCluster.centralEndpoint }}"
POLICY_CM="{{ .Values.acs.policy.configMapName }}"
POLICY_NS="{{ .Values.acs.testRange.namespace }}"
TELEMETRY_POLICY_CM="{{ .Values.agentTelemetryPolicy.rhacs.configMapName }}"
IMPORT_TELEMETRY_POLICY="{{ .Values.agentTelemetryPolicy.rhacs.enabled }}"
IMPORT_POLICY="{{ .Values.acs.bootstrap.importPolicy }}"
NOTIFIER_NAME="{{ .Values.acs.policy.notifierName }}"
MATTERMOST_CM="{{ .Values.acs.bootstrap.mattermostIntegrationConfigMap }}"
MATTERMOST_NS="{{ .Values.mattermost.namespace }}"

wait_for() {
  local tries=0
  until "$@"; do
    tries=$((tries + 1))
    if [ "$tries" -ge 120 ]; then
      echo "Timed out waiting for: $*"
      exit 1
    fi
    sleep 10
  done
}

echo "Waiting for Central deployment..."
wait_for oc get deployment central -n "${ACS_NS}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q '^1$'

echo "Waiting for Central admin credentials..."
wait_for oc get secret central-htpasswd -n "${ACS_NS}"

ADMIN_PASSWORD="$(oc get secret central-htpasswd -n "${ACS_NS}" -o jsonpath='{.data.password}' | base64 -d)"

if ! oc get secret sensor-tls -n "${ACS_NS}" >/dev/null 2>&1; then
  echo "Generating SecuredCluster init bundle..."
  if ! roxctl central init-bundles generate "${CLUSTER_NAME}" \
    -e "${CENTRAL_ENDPOINT}" \
    -p "${ADMIN_PASSWORD}" \
    --insecure-skip-tls-verify \
    --output-secrets - > /tmp/acs-init-bundle.yaml 2>/tmp/roxctl-gen.err; then
    if grep -q AlreadyExists /tmp/roxctl-gen.err; then
      echo "Init bundle ${CLUSTER_NAME} already exists in Central — revoking stale bundle and retrying..."
      BUNDLE_ID="$(roxctl -e "${CENTRAL_ENDPOINT}" -p "${ADMIN_PASSWORD}" --insecure-skip-tls-verify \
        central init-bundles list -o csv 2>/dev/null | awk -F',' -v name="${CLUSTER_NAME}" '$1==name {gsub(/"/,"",$5); print $5}' | head -1)"
      if [ -n "${BUNDLE_ID}" ]; then
        roxctl -e "${CENTRAL_ENDPOINT}" -p "${ADMIN_PASSWORD}" --insecure-skip-tls-verify \
          central init-bundles revoke "${BUNDLE_ID}"
      fi
      roxctl central init-bundles generate "${CLUSTER_NAME}" \
        -e "${CENTRAL_ENDPOINT}" \
        -p "${ADMIN_PASSWORD}" \
        --insecure-skip-tls-verify \
        --output-secrets - > /tmp/acs-init-bundle.yaml
    else
      cat /tmp/roxctl-gen.err >&2
      exit 1
    fi
  fi
  oc apply -f /tmp/acs-init-bundle.yaml
else
  echo "Init bundle secrets already present — skipping generation"
fi

if ! oc get securedcluster "${SC_NAME}" -n "${ACS_NS}" >/dev/null 2>&1; then
  echo "Creating SecuredCluster ${SC_NAME}..."
  cat <<EOF | oc apply -f -
apiVersion: platform.stackrox.io/v1alpha1
kind: SecuredCluster
metadata:
  name: ${SC_NAME}
  namespace: ${ACS_NS}
spec:
  clusterName: ${CLUSTER_NAME}
  centralEndpoint: ${CENTRAL_ENDPOINT}
  auditLogs:
    collection: Auto
  admissionControl:
    listenOnCreates: true
    listenOnEvents: true
    listenOnUpdates: true
  perNode:
    collector:
      collection: CORE_BPF
    taintToleration: TolerateTaints
  sensor:
    tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/infra
        operator: Exists
EOF
else
  echo "SecuredCluster ${SC_NAME} already exists — skipping"
fi

echo "Waiting for sensor deployment..."
wait_for oc get deployment sensor -n "${ACS_NS}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q '^1$'

if [ "${IMPORT_POLICY}" = "true" ]; then
  echo "WARN: acs.bootstrap.importPolicy is deprecated — apply SecurityPolicy CRs via GitOps instead."
fi

if oc get configmap "${MATTERMOST_CM}" -n "${MATTERMOST_NS}" >/dev/null 2>&1; then
  WEBHOOK_URL="$(oc get configmap "${MATTERMOST_CM}" -n "${MATTERMOST_NS}" -o jsonpath='{.data.ACS_INCOMING_WEBHOOK_URL}')"
  if [ -n "${WEBHOOK_URL}" ]; then
    echo "Configuring RHACS notifier ${NOTIFIER_NAME} -> Mattermost webhook..."
    roxctl -e "${CENTRAL_ENDPOINT}" -p "${ADMIN_PASSWORD}" --insecure-skip-tls-verify \
      central notifiers upsert mattermost \
      --name "${NOTIFIER_NAME}" \
      --mattermost-url "${WEBHOOK_URL}" \
      --mattermost-channel "town-square" || \
      echo "WARN: notifier upsert failed (verify roxctl version supports mattermost notifiers)"
  fi
else
  echo "ConfigMap ${MATTERMOST_NS}/${MATTERMOST_CM} not found — skipping Mattermost notifier setup"
fi

echo "ACS bootstrap complete."
{{- end }}

{{/*
  Phase 5 — optional OTEL env vars for agent Deployments when observability.agentInstrumentation.enabled.
  Reads acs-ai-overwatch-observability-config written by the observability chart bootstrap Job.
*/}}
{{- define "acs-ai-overwatch.observabilityConfigReady" -}}
{{- if not .Values.observability.agentInstrumentation.enabled -}}{{- end -}}
{{- $cm := lookup "v1" "ConfigMap" .Values.observability.integrationConfigMap.namespace .Values.observability.integrationConfigMap.name -}}
{{- if and $cm $cm.data.otelCollectorGrpcEndpoint -}}true{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.otelAgentEnv" -}}
{{- $root := .root -}}
{{- $serviceName := .serviceName -}}
{{- if and $root.Values.observability.agentInstrumentation.enabled (include "acs-ai-overwatch.observabilityConfigReady" $root) -}}
{{- $cm := lookup "v1" "ConfigMap" $root.Values.observability.integrationConfigMap.namespace $root.Values.observability.integrationConfigMap.name -}}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ $cm.data.otelCollectorGrpcEndpoint | quote }}
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: grpc
- name: OTEL_TRACES_EXPORTER
  value: otlp
- name: OTEL_METRICS_EXPORTER
  value: none
- name: OTEL_LOGS_EXPORTER
  value: none
- name: OTEL_SERVICE_NAME
  value: {{ $serviceName | quote }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ printf "service.namespace=%s,deployment.environment=acs-ai-overwatch" $root.Values.kagenti.namespace | quote }}
{{- end -}}
{{- end }}

{{/*
  Telemetry compliance label for Kagenti agent pods (RHACS + NetworkPolicy enforcement).
  Usage: {{- include "acs-ai-overwatch.agentTelemetryLabel" (dict "root" . "compliant" true) | nindent 8 }}
*/}}
{{- define "acs-ai-overwatch.agentTelemetryLabelKey" -}}
{{- .Values.agentTelemetryPolicy.requiredLabel.key -}}
{{- end }}

{{- define "acs-ai-overwatch.agentTelemetryLabel" -}}
{{- $root := .root -}}
{{- $compliant := .compliant -}}
{{- if $root.Values.agentTelemetryPolicy.enabled -}}
{{ $root.Values.agentTelemetryPolicy.requiredLabel.key }}: {{ if $compliant }}{{ $root.Values.agentTelemetryPolicy.requiredLabel.compliantValue | quote }}{{ else }}{{ $root.Values.agentTelemetryPolicy.requiredLabel.nonCompliantValue | quote }}{{ end }}
{{- end -}}
{{- end }}
