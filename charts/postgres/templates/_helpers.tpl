{{/* Common naming and label helpers. */}}

{{- define "postgres.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "postgres.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "postgres.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "postgres.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "postgres.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: agari
{{- end -}}

{{- define "postgres.selectorLabels" -}}
app.kubernetes.io/name: {{ include "postgres.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Name of the Secret holding the credentials. */}}
{{- define "postgres.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- tpl .Values.auth.existingSecret . -}}
{{- else -}}
{{- printf "%s-auth" (include "postgres.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Secret key names, so a user-supplied Secret can use any key names it likes. */}}
{{- define "postgres.secretKey.username" -}}
{{- default "username" .Values.auth.secretKeys.username -}}
{{- end -}}
{{- define "postgres.secretKey.password" -}}
{{- default "password" .Values.auth.secretKeys.password -}}
{{- end -}}
{{- define "postgres.secretKey.database" -}}
{{- default "database" .Values.auth.secretKeys.database -}}
{{- end -}}

{{/* Host:port of the database reachable from inside the cluster. */}}
{{- define "postgres.host" -}}
{{- printf "%s.%s.svc.cluster.local" (include "postgres.fullname" .) .Release.Namespace -}}
{{- end -}}

{{/* Name of the PVC backing PGDATA. */}}
{{- define "postgres.pvcName" -}}
{{- printf "%s-data" (include "postgres.fullname" .) -}}
{{- end -}}
