{{- define "acs-ai-overwatch.ggufInitContainer" -}}
- name: pull-gguf
  image: {{ .image }}
  imagePullPolicy: Always
  command: ["/usr/local/bin/pull-model"]
  env:
    - name: AGENT_HF_MODEL_ID
      value: {{ .root.Values.agents.huggingface.modelRepo | quote }}
    - name: MODEL_LOCAL_DIR
      value: {{ printf "%s/hf-model" (.root.Values.agents.huggingface.cacheMountPath | default "/models") | quote }}
    - name: MODEL_FILE
      value: {{ .root.Values.agents.huggingface.modelFile | quote }}
  volumeMounts:
    - name: models
      mountPath: {{ .root.Values.agents.huggingface.cacheMountPath | default "/models" }}
{{- end }}

{{- define "acs-ai-overwatch.llamaCppSidecar" -}}
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

{{- define "acs-ai-overwatch.agentRoute" -}}
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: {{ .name }}
  {{- include "acs-ai-overwatch.argocdSyncWaveAnnotations" (dict "root" .root "wave" "agents") | nindent 2 }}
  namespace: {{ .root.Values.agents.namespace }}
  labels:
    {{- include "acs-ai-overwatch.labels" .root | nindent 4 }}
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
