{{- define "minio.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "minio.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "minio.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "minio.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "minio.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: agari
{{- end -}}

{{- define "minio.selectorLabels" -}}
app.kubernetes.io/name: {{ include "minio.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "minio.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- tpl .Values.auth.existingSecret . -}}
{{- else -}}
{{- printf "%s-credentials" (include "minio.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "minio.secretKey.accessKey" -}}
{{- default "accessKey" .Values.auth.secretKeys.accessKey -}}
{{- end -}}
{{- define "minio.secretKey.secretKey" -}}
{{- default "secretKey" .Values.auth.secretKeys.secretKey -}}
{{- end -}}

{{- define "minio.pvcName" -}}
{{- printf "%s-data" (include "minio.fullname" .) -}}
{{- end -}}

{{/* In-cluster S3 endpoint, handed to agari-platform as OBJECT_STORAGE_ENDPOINT. */}}
{{- define "minio.endpoint" -}}
{{- printf "http://%s.%s.svc.cluster.local:%d" (include "minio.fullname" .) .Release.Namespace (int .Values.service.port) -}}
{{- end -}}

{{/* Preferred bucket for the platform; first entry of .Values.buckets by default. */}}
{{- define "minio.primaryBucket" -}}
{{- if .Values.buckets -}}
{{- $b := first .Values.buckets -}}
{{- if kindIs "map" $b -}}{{- $b.name -}}{{- else -}}{{- $b -}}{{- end -}}
{{- end -}}
{{- end -}}
