{{- define "misbehavior.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Values.global.partOf }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end }}

{{- define "misbehavior.wave" -}}
{{- if .root.Values.argocd.syncWaves.enabled }}
annotations:
  argocd.argoproj.io/sync-wave: {{ index .root.Values.argocd.syncWaves .wave | quote }}
{{- end }}
{{- end }}

{{- define "misbehavior.image" -}}
image-registry.openshift-image-registry.svc:5000/{{ .root.Values.agents.builderNamespace }}/{{ .stream }}:latest
{{- end }}

{{- define "misbehavior.enforce" -}}
{{- eq .Values.enforcement.mode "enforce" -}}
{{- end }}

{{- define "misbehavior.gpuTolerations" -}}
{{- if .Values.agents.gpuTaintToleration }}
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
{{- end }}
{{- end }}

{{- define "misbehavior.ggufInit" -}}
- name: pull-gguf
  image: {{ .image }}
  imagePullPolicy: Always
  command: ["/usr/local/bin/pull-model"]
  env:
    - name: AGENT_HF_MODEL_ID
      value: {{ .root.Values.agents.huggingface.modelRepo | quote }}
    - name: MODEL_LOCAL_DIR
      value: {{ printf "%s/hf-model" .root.Values.agents.huggingface.cacheMountPath | quote }}
    - name: MODEL_FILE
      value: {{ .root.Values.agents.huggingface.modelFile | quote }}
  volumeMounts:
    - name: models
      mountPath: {{ .root.Values.agents.huggingface.cacheMountPath }}
{{- end }}

{{- define "misbehavior.llama" -}}
- name: llama-cpp
  image: {{ .root.Values.agents.llamaCpp.image }}
  imagePullPolicy: {{ .root.Values.agents.llamaCpp.imagePullPolicy }}
  args:
    - -m
    - /models/gguf/model.gguf
    - --host
    - 0.0.0.0
    - --port
    - {{ .root.Values.agents.llamaCpp.port | quote }}
    - -ngl
    - {{ .root.Values.agents.llamaCpp.ngl | quote }}
    - -c
    - {{ .root.Values.agents.llamaCpp.contextSize | quote }}
    - --alias
    - {{ .root.Values.agents.llamaCpp.servedModelName | quote }}
  ports:
    - name: llama
      containerPort: {{ .root.Values.agents.llamaCpp.port }}
  resources:
    requests:
      {{ .root.Values.agents.gpuResource }}: {{ .root.Values.agents.gpuCount | quote }}
      cpu: "500m"
      memory: 4Gi
    limits:
      {{ .root.Values.agents.gpuResource }}: {{ .root.Values.agents.gpuCount | quote }}
      cpu: "2"
      memory: 8Gi
  volumeMounts:
    - name: models
      mountPath: /models
  readinessProbe:
    tcpSocket:
      port: llama
    initialDelaySeconds: 15
    periodSeconds: 10
    failureThreshold: 36
{{- end }}

{{- define "misbehavior.localLlamaEnv" -}}
- name: LLM_API_BASE
  value: {{ printf "http://127.0.0.1:%v/v1" .Values.agents.llamaCpp.port | quote }}
- name: LLM_MODEL
  value: {{ .Values.agents.llamaCpp.servedModelName | quote }}
- name: LLM_TRUST_PROXY
  value: "false"
- name: NO_PROXY
  value: "127.0.0.1,localhost,.svc.cluster.local,.cluster.local"
{{- end }}

{{- define "misbehavior.otelEnv" -}}
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
  value: {{ .serviceName | quote }}
{{- end }}
{{- end }}

{{- define "misbehavior.route" -}}
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: {{ .name }}
  {{- include "misbehavior.wave" (dict "root" .root "wave" "agents") | nindent 2 }}
  namespace: {{ .root.Values.agents.namespace }}
  labels:
    {{- include "misbehavior.labels" .root | nindent 4 }}
    app.kubernetes.io/name: {{ .name }}
spec:
  to:
    kind: Service
    name: {{ .name }}
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
{{- end }}
