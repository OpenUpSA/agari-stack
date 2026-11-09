{{- define "mailpit.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mailpit.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "mailpit.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "mailpit.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "mailpit.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: agari
{{- end -}}

{{- define "mailpit.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mailpit.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* In-cluster SMTP endpoint, handed to agari-platform as EMAIL_HOST/EMAIL_PORT. */}}
{{- define "mailpit.smtpHost" -}}
{{- printf "%s.%s.svc.cluster.local" (include "mailpit.fullname" .) .Release.Namespace -}}
{{- end -}}

{{/* Browser URL of the web UI, used in the release notes. */}}
{{- define "mailpit.uiUrl" -}}
{{- if .Values.ingress.enabled -}}
{{- printf "http://%s:%d" .Values.ingress.host (int .Values.externalPort) -}}
{{- else -}}
{{- printf "http://localhost:%d" (int .Values.externalPort) -}}
{{- end -}}
{{- end -}}
