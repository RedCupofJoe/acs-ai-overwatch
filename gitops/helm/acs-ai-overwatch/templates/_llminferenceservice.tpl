{{- define "acs-ai-overwatch.modelCarImage" -}}
{{- trimPrefix "oci://" . -}}
{{- end }}

{{- define "acs-ai-overwatch.vllmModelArg" -}}
{{- if hasPrefix "oci://" .modelUri -}}
{{- default "/mnt/models" .vllmModelPath -}}
{{- else if hasPrefix "hf://" .modelUri -}}
{{- trimPrefix "hf://" .modelUri -}}
{{- else -}}
{{- .modelUri -}}
{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.useLlmInferenceService" -}}
{{- $root := .root -}}
{{- $backend := default "llminferenceservice" .backend -}}
{{- $crdReady := include "acs-ai-overwatch.crdReady" (dict "root" $root "crdName" $root.Values.platformResources.crds.llmInferenceService) -}}
{{- if and (eq $backend "llminferenceservice") $crdReady -}}true{{- end -}}
{{- end }}

{{- define "acs-ai-overwatch.llmInferenceService" -}}
{{- $root := .root -}}
{{- $llm := .llm -}}
{{- $ns := .namespace -}}
{{- $component := .component -}}
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: {{ $llm.name }}
  {{- include "acs-ai-overwatch.argocdPlatformCrAnnotations" (dict "root" $root "wave" "platformCRs") | nindent 2 }}
    opendatahub.io/model-type: generative
    acs-ai-overwatch.io/model-source: openshift-ai-model-catalog
  namespace: {{ $ns }}
  labels:
    {{- include "acs-ai-overwatch.labels" $root | nindent 4 }}
    app.kubernetes.io/name: {{ $llm.name }}
    app.kubernetes.io/component: {{ $component }}
spec:
  replicas: 1
  model:
    uri: {{ $llm.modelUri | quote }}
    name: {{ $llm.servedModelName | quote }}
  router:
    route: {}
    gateway: {}
    scheduler: {}
  template:
    {{- if $root.Values.accelerators.gpuTaintToleration.enabled }}
    tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
    {{- end }}
    containers:
      - name: main
        # Appended to the KServe vLLM launcher ($@ / VLLM_ADDITIONAL_ARGS).
        # Model cards default max_model_len far beyond an L4 (Granite 131072 needs ~20Gi KV).
        args:
          - --max-model-len
          - {{ $llm.maxModelLen | default "4096" | quote }}
          - --gpu-memory-utilization
          - {{ $llm.gpuMemoryUtilization | default "0.90" | quote }}
        resources:
          requests:
            cpu: "2"
            memory: 16Gi
            {{ $llm.gpuResource }}: {{ $llm.gpuCount | quote }}
          limits:
            cpu: "4"
            memory: 24Gi
            {{ $llm.gpuResource }}: {{ $llm.gpuCount | quote }}
{{- end }}

{{- define "acs-ai-overwatch.standaloneVllmDeployment" -}}
{{- $root := .root -}}
{{- $llm := .llm -}}
{{- $ns := .namespace -}}
{{- $component := .component -}}
{{- $extraArgs := .extraArgs | default list -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $llm.name }}
  {{- include "acs-ai-overwatch.argocdSyncWaveAnnotations" (dict "root" $root "wave" "workloads") | nindent 2 }}
  namespace: {{ $ns }}
  labels:
    {{- include "acs-ai-overwatch.labels" $root | nindent 4 }}
    app.kubernetes.io/name: {{ $llm.name }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ $llm.name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ $llm.name }}
        app.kubernetes.io/component: {{ $component }}
    spec:
      {{- if $root.Values.accelerators.gpuTaintToleration.enabled }}
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      {{- end }}
{{- if hasPrefix "oci://" $llm.modelUri }}
      initContainers:
        - name: modelcar
          image: {{ include "acs-ai-overwatch.modelCarImage" $llm.modelUri | quote }}
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -euo pipefail
              mkdir -p /mnt/models
              if [ -d /models ]; then
                cp -a /models/. /mnt/models/
              elif [ -d /opt/models ]; then
                cp -a /opt/models/. /mnt/models/
              else
                echo "ModelCar image has no /models directory" >&2
                ls -la /
                exit 1
              fi
          volumeMounts:
            - name: models
              mountPath: /mnt/models
{{- end }}
      containers:
        - name: vllm
          image: {{ $llm.vllmImage }}
          args:
            - --model
            - {{ include "acs-ai-overwatch.vllmModelArg" $llm | quote }}
            - --served-model-name
            - {{ $llm.servedModelName | quote }}
            - --max-model-len
            - {{ $llm.maxModelLen | quote }}
            - --gpu-memory-utilization
            - {{ $llm.gpuMemoryUtilization | quote }}
            - --port
            - {{ $llm.servicePort | quote }}
            - --enforce-eager
{{- range $extraArgs }}
            - {{ . | quote }}
{{- end }}
          ports:
            - name: http
              containerPort: {{ $llm.servicePort }}
{{- if hasPrefix "hf://" $llm.modelUri }}
          env:
            - name: HUGGING_FACE_HUB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: huggingface-token
                  key: token
                  optional: true
{{- end }}
          resources:
            requests:
              {{ $llm.gpuResource }}: {{ $llm.gpuCount | quote }}
              cpu: "2"
              memory: 16Gi
            limits:
              {{ $llm.gpuResource }}: {{ $llm.gpuCount | quote }}
              cpu: "4"
              memory: 24Gi
{{- if hasPrefix "oci://" $llm.modelUri }}
          volumeMounts:
            - name: models
              mountPath: /mnt/models
              readOnly: true
{{- end }}
          readinessProbe:
            httpGet:
              path: /v1/models
              port: http
            initialDelaySeconds: 60
            periodSeconds: 15
            failureThreshold: 40
{{- if hasPrefix "oci://" $llm.modelUri }}
      volumes:
        - name: models
          emptyDir:
            sizeLimit: 40Gi
{{- end }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $llm.name }}
  {{- include "acs-ai-overwatch.argocdSyncWaveAnnotations" (dict "root" $root "wave" "workloads") | nindent 2 }}
  namespace: {{ $ns }}
  labels:
    {{- include "acs-ai-overwatch.labels" $root | nindent 4 }}
    app.kubernetes.io/name: {{ $llm.name }}
spec:
  selector:
    app.kubernetes.io/name: {{ $llm.name }}
  ports:
    - name: http
      port: {{ $llm.servicePort }}
      targetPort: http
{{- end }}
