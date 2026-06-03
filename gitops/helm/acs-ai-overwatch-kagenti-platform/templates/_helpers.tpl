{{- define "kagenti-platform.labels" -}}
app.kubernetes.io/name: kagenti-platform
app.kubernetes.io/part-of: {{ .Values.global.partOf }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end }}

{{- define "kagenti-platform.argocdSyncWaveAnnotations" -}}
{{- $root := .root -}}
{{- $wave := .wave -}}
{{- if $root.Values.argocd.syncWaves.enabled -}}
argocd.argoproj.io/sync-wave: {{ index $root.Values.argocd.syncWaves $wave | quote }}
{{- end -}}
{{- end }}
