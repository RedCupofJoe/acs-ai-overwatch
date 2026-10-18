{{- define "approved.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Values.global.partOf }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end }}

{{- define "approved.wave" -}}
{{- if .root.Values.argocd.syncWaves.enabled }}
annotations:
  argocd.argoproj.io/sync-wave: {{ index .root.Values.argocd.syncWaves .wave | quote }}
{{- end }}
{{- end }}

{{- define "approved.crdReady" -}}
{{- if not .root.Values.platformResources.waitForCrds }}true{{ end }}
{{- $crd := lookup "apiextensions.k8s.io/v1" "CustomResourceDefinition" "" .crdName }}
{{- if $crd }}true{{ end }}
{{- end }}

{{- define "approved.agentEnv" -}}
- name: HOST
  value: "0.0.0.0"
- name: PORT
  value: {{ .Values.agents.servicePort | quote }}
- name: AGENT_ROLE
  value: compliant-chris
- name: AGENT_HARNESS
  value: openclaw
- name: AGENT_ENABLE_NETWORK_AUDIT
  value: "false"
- name: AGENT_ENABLE_CAREER_CSV
  value: "true"
- name: AGENT_UI_DIR
  value: /opt/acs-agent-ui
- name: CAREER_CSV_PATH
  value: /opt/acs-agent/data/student_placement.csv
- name: AGENT_SYSTEM_PROMPT_FILE
  value: /etc/openshell/agent/system_prompt.txt
- name: OPENSHELL_SYSTEM_PROMPT_FILE
  value: /etc/openshell/agent/system_prompt.txt
- name: OPENSHELL_POLICY_FILE
  value: /etc/openshell/policy/approved-agent.yaml
- name: LLM_API_BASE
  value: {{ printf "http://%s.%s.svc.cluster.local:%v/v1" .Values.maas.gatewayService .Values.maas.namespace .Values.maas.gatewayPort | quote }}
- name: LLM_MODEL
  value: {{ .Values.maas.model | quote }}
- name: LLM_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.maas.apiKeySecret }}
      key: api-key
- name: LLM_USE_SPIFFE
  value: "true"
- name: SPIFFE_ENDPOINT_SOCKET
  value: unix:///spiffe-workload-api/spire-agent.sock
- name: SPIFFE_AUDIENCE
  value: maas
- name: LLM_TRUST_PROXY
  value: "false"
- name: NO_PROXY
  value: "127.0.0.1,localhost,.svc.cluster.local,.cluster.local"
{{- if .Values.observability.enabled }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ .Values.observability.endpoint | quote }}
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: grpc
- name: OTEL_TRACES_EXPORTER
  value: otlp
- name: OTEL_METRICS_EXPORTER
  value: none
- name: OTEL_LOGS_EXPORTER
  value: none
- name: OTEL_SERVICE_NAME
  value: compliant-chris
{{- end }}
{{- end }}
