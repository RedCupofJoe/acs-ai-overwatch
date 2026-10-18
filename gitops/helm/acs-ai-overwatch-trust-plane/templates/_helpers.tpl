{{- define "trust.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Values.global.partOf }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end }}

{{- define "trust.wave" -}}
{{- if .root.Values.argocd.syncWaves.enabled }}
annotations:
  argocd.argoproj.io/sync-wave: {{ index .root.Values.argocd.syncWaves .wave | quote }}
{{- end }}
{{- end }}

{{- define "trust.crdReady" -}}
{{- if not .root.Values.platformResources.waitForCrds }}true{{ end }}
{{- $crd := lookup "apiextensions.k8s.io/v1" "CustomResourceDefinition" "" .crdName }}
{{- if $crd }}true{{ end }}
{{- end }}

{{- define "trust.appsDomain" -}}
{{- if .Values.cluster.appsDomain }}
{{- .Values.cluster.appsDomain }}
{{- else }}
{{- $cm := lookup "v1" "ConfigMap" .Values.clusterDiscovery.namespace .Values.clusterDiscovery.configMapName }}
{{- if and $cm $cm.data.appsDomain }}{{ $cm.data.appsDomain }}{{ end }}
{{- end }}
{{- end }}

{{- define "trust.runtimeClass" -}}
{{- if .Values.trustPlane.kata.enabled }}
{{- if eq .Values.trustPlane.kata.platform "baremetal" }}
kata
{{- else if eq .Values.trustPlane.kata.platform "aws" }}
kata-remote
{{- else }}
{{- fail "trustPlane.kata.enabled is true but trustPlane.kata.platform must be baremetal or aws" }}
{{- end }}
{{- end }}
{{- end }}
