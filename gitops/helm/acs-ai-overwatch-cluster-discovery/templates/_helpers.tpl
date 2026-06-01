{{- define "cluster-discovery.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- if .Values.global.partOf }}
app.kubernetes.io/part-of: {{ .Values.global.partOf }}
{{- end }}
{{- end }}

{{- define "cluster-discovery.argocdSyncWaveAnnotations" -}}
{{- $root := .root -}}
{{- $waveKey := .wave -}}
{{- if $root.Values.argocd.syncWaves.enabled }}
{{- $wave := index $root.Values.argocd.syncWaves $waveKey -}}
annotations:
  argocd.argoproj.io/sync-wave: {{ $wave | quote }}
{{- end }}
{{- end }}
