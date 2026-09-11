{{/*
Expand the name of the chart.
*/}}
{{- define "synapse.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "synapse.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "synapse.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "synapse.labels" -}}
helm.sh/chart: {{ include "synapse.chart" . }}
{{ include "synapse.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "synapse.selectorLabels" -}}
app.kubernetes.io/name: {{ include "synapse.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "synapse.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "synapse.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Address of the bundled Dragonfly, as synapse must be told to reach it.

Delegates to the subchart's own `dragonfly.fullname` rather than reimplementing
it, so a chart bump that changes the naming rule cannot drift from what we
inject. The subchart helper only reads fullnameOverride / nameOverride /
Chart.Name / Release.Name, so a synthetic scope is enough. Only call this when
`.Values.dragonfly.enabled` is true - Helm prunes a disabled dependency before
rendering, and the define goes with it.
*/}}
{{- define "synapse.dragonflyFullname" -}}
{{- include "dragonfly.fullname" (dict "Values" .Values.dragonfly "Release" .Release "Chart" (dict "Name" "dragonfly")) -}}
{{- end }}

{{/*
The Redis URL for the bundled Dragonfly, or "" when it should not be injected.

Empty (i.e. no auto-wiring) when any of these hold:
  - the dependency is off, or auto-wiring was explicitly disabled
  - the operator already set REDIS_URL in `.Values.env`
  - `synapse.config` carries a `proxy.redis.url` that is not the shipped
    localhost placeholder

That last case is the one that matters most: `REDIS_URL` is applied AFTER the
config file is parsed and assigns unconditionally, so injecting it would
silently override a URL the operator had deliberately configured.
*/}}
{{- define "synapse.autoRedisUrl" -}}
{{- $df := .Values.dragonfly | default dict -}}
{{- if and $df.enabled (dig "autoWire" true (.Values.redis | default dict)) -}}
{{- if not (hasKey (.Values.env | default dict) "REDIS_URL") -}}
{{- $cfg := fromYaml (.Values.synapse.config | default "") -}}
{{- $configured := dig "proxy" "redis" "url" "" ($cfg | default dict) -}}
{{- if or (eq $configured "") (eq $configured "redis://127.0.0.1:6379/0") -}}
{{- $scheme := ternary "rediss" "redis" (dig "tls" "enabled" false $df) -}}
{{- printf "%s://%s:%v/0" $scheme (include "synapse.dragonflyFullname" .) (dig "service" "port" 6379 $df) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
