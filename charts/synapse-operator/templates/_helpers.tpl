{{/*
Standard label/selector helpers. Mirrors the conventional helm-create
output so callers can use Prometheus / Argo / Flux selectors without
surprise. Selector labels are an immutable subset of all-labels.
*/}}

{{- define "synapse-operator.name" -}}
{{- default "synapse-operator" .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "synapse-operator.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "synapse-operator.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "synapse-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels — IMMUTABLE on a Deployment once set. Keep this list
tiny and conservative; anything that can change between releases
(`version`, `managed-by`, …) must live in the all-labels block only.
*/}}
{{- define "synapse-operator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "synapse-operator.name" . }}
{{- if .Values.instanceLabelInSelector }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
app.kubernetes.io/component: controller
{{- end -}}

{{/*
Labels for metadata and the pod template. `instance` is always here, whether
or not it is in the selector (instanceLabelInSelector), so the selector stays
a subset of these.
*/}}
{{- define "synapse-operator.labels" -}}
helm.sh/chart: {{ include "synapse-operator.chart" . }}
app.kubernetes.io/name: {{ include "synapse-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: controller
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: synapse
{{- end -}}

{{- define "synapse-operator.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "synapse-operator.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
