{{- define "observability.labels" -}}
app.kubernetes.io/name: acs-ai-overwatch-observability
app.kubernetes.io/part-of: {{ .Values.global.partOf }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end }}

{{- define "observability.argocdSyncWaveAnnotations" -}}
{{- $root := .root -}}
{{- $wave := .wave -}}
{{- if $root.Values.argocd.syncWaves.enabled -}}
argocd.argoproj.io/sync-wave: {{ index $root.Values.argocd.syncWaves $wave | quote }}
{{- end -}}
{{- end }}

{{- define "observability.crdReady" -}}
{{- $root := .root -}}
{{- $crdName := .crdName -}}
{{- if not $root.Values.platformResources.waitForCrds -}}true{{- end -}}
{{- $crd := lookup "apiextensions.k8s.io/v1" "CustomResourceDefinition" "" $crdName -}}
{{- if $crd -}}true{{- end -}}
{{- end }}

{{- define "observability.tempoOtlpEndpoint" -}}
{{ printf "tempo-%s.%s.svc.cluster.local:4317" .Values.tempo.monolithic.name .Values.tempo.monolithic.namespace }}
{{- end }}

{{- define "observability.tempoQueryFrontend" -}}
{{ printf "http://tempo-%s-query-frontend.%s.svc.cluster.local:3200" .Values.tempo.monolithic.name .Values.tempo.monolithic.namespace }}
{{- end }}

{{- define "observability.mlflowTracesUrl" -}}
{{ printf "http://%s.%s.svc.cluster.local:%v%s" .Values.mlflow.instanceName .Values.mlflow.namespace .Values.mlflow.servicePort .Values.mlflow.tracesPath }}
{{- end }}

{{- define "observability.otelGrpcEndpoint" -}}
{{ printf "%s.%s.svc.cluster.local:%v" .Values.otelCollector.name .Values.namespace .Values.otelCollector.service.grpcPort }}
{{- end }}

{{- define "observability.otelHttpEndpoint" -}}
{{ printf "http://%s.%s.svc.cluster.local:%v" .Values.otelCollector.name .Values.namespace .Values.otelCollector.service.httpPort }}
{{- end }}
