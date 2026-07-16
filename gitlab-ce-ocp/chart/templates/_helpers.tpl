{{/* Expand the name of the chart. */}}
{{- define "gitlab-ce-ocp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified app name. */}}
{{- define "gitlab-ce-ocp.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "gitlab-ce-ocp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "gitlab-ce-ocp.labels" -}}
helm.sh/chart: {{ include "gitlab-ce-ocp.chart" . }}
{{ include "gitlab-ce-ocp.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Selector labels. */}}
{{- define "gitlab-ce-ocp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gitlab-ce-ocp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* ServiceAccount name. */}}
{{- define "gitlab-ce-ocp.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "gitlab-ce-ocp.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* SCC name. */}}
{{- define "gitlab-ce-ocp.sccName" -}}
{{- if .Values.openshift.scc.create -}}
{{- printf "%s-%s" .Values.openshift.scc.name .Release.Namespace | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Values.openshift.scc.existing -}}
{{- end -}}
{{- end -}}
