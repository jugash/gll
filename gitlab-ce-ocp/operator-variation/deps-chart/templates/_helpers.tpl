{{- define "deps.labels" -}}
app.kubernetes.io/part-of: gitlab-deps
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Generate or reuse a password. Helm has no state, so we only auto-generate on
first install by looking up any existing secret; otherwise use the provided value. */}}
{{- define "deps.postgresPassword" -}}
{{- if .Values.postgresql.password -}}
{{- .Values.postgresql.password -}}
{{- else -}}
{{- $s := lookup "v1" "Secret" .Release.Namespace "gitlab-postgresql" -}}
{{- if $s -}}{{ index $s.data "password" | b64dec }}{{- else -}}{{ randAlphaNum 24 }}{{- end -}}
{{- end -}}
{{- end -}}

{{- define "deps.postgresAdminPassword" -}}
{{- if .Values.postgresql.adminPassword -}}
{{- .Values.postgresql.adminPassword -}}
{{- else -}}
{{- $s := lookup "v1" "Secret" .Release.Namespace "gitlab-postgresql" -}}
{{- if and $s (index $s.data "postgres-password") -}}{{ index $s.data "postgres-password" | b64dec }}{{- else -}}{{ randAlphaNum 24 }}{{- end -}}
{{- end -}}
{{- end -}}

{{- define "deps.redisPassword" -}}
{{- if .Values.redis.password -}}
{{- .Values.redis.password -}}
{{- else -}}
{{- $s := lookup "v1" "Secret" .Release.Namespace "gitlab-redis" -}}
{{- if $s -}}{{ index $s.data "password" | b64dec }}{{- else -}}{{ randAlphaNum 24 }}{{- end -}}
{{- end -}}
{{- end -}}

{{- define "deps.minioSecretKey" -}}
{{- if .Values.minio.secretKey -}}
{{- .Values.minio.secretKey -}}
{{- else -}}
{{- $s := lookup "v1" "Secret" .Release.Namespace "gitlab-objectstore" -}}
{{- if $s -}}{{ index $s.data "secretkey" | b64dec }}{{- else -}}{{ randAlphaNum 32 }}{{- end -}}
{{- end -}}
{{- end -}}
