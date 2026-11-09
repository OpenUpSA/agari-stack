{{/*
Naming, labels and the whole environment contract of the Django application.
Every environment variable name below is read by config/settings/base.py; see
agari-platform/docs/deployment.md.
*/}}

{{- define "agari-platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "agari-platform.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "agari-platform.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "agari-platform.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "agari-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: agari
{{- end -}}

{{- define "agari-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "agari-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "agari-platform.serviceAccountName" -}}
{{- if .Values.serviceAccount.name -}}
{{- tpl .Values.serviceAccount.name . -}}
{{- else if .Values.serviceAccount.create -}}
{{- include "agari-platform.fullname" . -}}
{{- else -}}
default
{{- end -}}
{{- end -}}

{{- define "agari-platform.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}

{{- define "agari-platform.secretName" -}}
{{- if .Values.secret.existingSecret -}}
{{- tpl .Values.secret.existingSecret . -}}
{{- else -}}
{{- printf "%s-secrets" (include "agari-platform.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
The Django secret key. Generate one on first install and reuse the value that is
already in the cluster on upgrades, so tokens signed before an upgrade keep
verifying afterwards.
*/}}
{{- define "agari-platform.djangoSecretKey" -}}
{{- if .Values.secret.djangoSecretKey -}}
{{- .Values.secret.djangoSecretKey -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "agari-platform.secretName" .) -}}
{{- if and $existing (index ($existing.data | default dict) "djangoSecretKey") -}}
{{- index $existing.data "djangoSecretKey" | b64dec -}}
{{- else -}}
{{- randAlphaNum 50 -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* http or https, depending on whether the ingress terminates TLS. */}}
{{- define "agari-platform.scheme" -}}
{{- if .Values.ingress.tls }}https{{ else }}http{{ end -}}
{{- end -}}

{{/* A host[:port] suffix for generated URLs; empty when the port is standard. */}}
{{- define "agari-platform.portSuffix" -}}
{{- $port := int (default 0 .Values.config.externalPort) -}}
{{- if or (eq $port 0) (and (eq $port 80) (eq (include "agari-platform.scheme" .) "http")) (and (eq $port 443) (eq (include "agari-platform.scheme" .) "https")) -}}
{{- else -}}
{{- printf ":%d" $port -}}
{{- end -}}
{{- end -}}

{{/* Hosts the API answers for: config.allowedHosts, else the ingress hosts. */}}
{{- define "agari-platform.hostList" -}}
{{- $hosts := list -}}
{{- if .Values.config.allowedHosts -}}
{{- range .Values.config.allowedHosts -}}
{{- $hosts = append $hosts . -}}
{{- end -}}
{{- else -}}
{{- $hosts = list "localhost" "127.0.0.1" -}}
{{- if .Values.ingress.enabled -}}
{{- $hosts = append $hosts .Values.ingress.host -}}
{{- end -}}
{{- range .Values.ingress.extraHosts -}}
{{- $hosts = append $hosts .host -}}
{{- end -}}
{{- end -}}
{{- $hosts | uniq | toJson -}}
{{- end -}}

{{- define "agari-platform.allowedHosts" -}}
{{- include "agari-platform.hostList" . -}}
{{- end -}}

{{/*
Same list plus the pod's own IP. The kubelet sends probes to the pod IP, and
Django rejects a request whose Host header is not in ALLOWED_HOSTS, so the IP has
to be allowed for HTTP probes to succeed. $(POD_IP) is expanded by Kubernetes
from the POD_IP variable defined just above it in the same container.
*/}}
{{- define "agari-platform.allowedHostsWithPodIp" -}}
{{- $hosts := append (include "agari-platform.hostList" . | fromJsonArray) "$(POD_IP)" -}}
{{- $hosts | uniq | toJson -}}
{{- end -}}

{{- define "agari-platform.siteUrl" -}}
{{- if .Values.config.siteUrl -}}
{{- .Values.config.siteUrl -}}
{{- else -}}
{{- printf "%s://%s%s" (include "agari-platform.scheme" .) .Values.ingress.host (include "agari-platform.portSuffix" .) -}}
{{- end -}}
{{- end -}}

{{/*
FRONTEND_URL / CORS origin: the SPA's own origin. Falls back to the first extra
ingress host, which is how the umbrella chart wires agari.localhost in.
*/}}
{{- define "agari-platform.frontendUrl" -}}
{{- if .Values.config.frontendUrl -}}
{{- .Values.config.frontendUrl -}}
{{- else if .Values.ingress.extraHosts -}}
{{- printf "%s://%s%s" (include "agari-platform.scheme" .) (first .Values.ingress.extraHosts).host (include "agari-platform.portSuffix" .) -}}
{{- end -}}
{{- end -}}

{{/* Origins allowed to POST with cookies: CSRF_TRUSTED_ORIGINS. */}}
{{- define "agari-platform.csrfTrustedOrigins" -}}
{{- if .Values.config.csrfTrustedOrigins -}}
{{- .Values.config.csrfTrustedOrigins | toJson -}}
{{- else -}}
{{- $origins := list (include "agari-platform.siteUrl" .) -}}
{{- $frontend := include "agari-platform.frontendUrl" . -}}
{{- if $frontend -}}
{{- $origins = append $origins $frontend -}}
{{- end -}}
{{- if .Values.ingress.enabled -}}
{{- $origins = append $origins (printf "%s://%s%s" (include "agari-platform.scheme" .) .Values.ingress.host (include "agari-platform.portSuffix" .)) -}}
{{- end -}}
{{- range .Values.ingress.extraHosts -}}
{{- $origins = append $origins (printf "%s://%s%s" (include "agari-platform.scheme" .) .host (include "agari-platform.portSuffix" .)) -}}
{{- end -}}
{{- $origins | uniq | toJson -}}
{{- end -}}
{{- end -}}

{{/* Origins the SPA may call the API from: CORS_ALLOWED_ORIGINS. */}}
{{- define "agari-platform.corsAllowedOrigins" -}}
{{- if .Values.config.corsAllowedOrigins -}}
{{- .Values.config.corsAllowedOrigins | toJson -}}
{{- else -}}
{{- $frontend := include "agari-platform.frontendUrl" . -}}
{{- if $frontend -}}
{{- list $frontend | toJson -}}
{{- else -}}
{{- list | toJson -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
DATABASE_HOST: explicit, or the postgres Service of this release - the bundled
`postgres` chart runs as `<release>-postgres`.
*/}}
{{- define "agari-platform.databaseHost" -}}
{{- default (printf "%s-postgres" .Release.Name) .Values.config.database.host -}}
{{- end -}}

{{- define "agari-platform.jwtEnabled" -}}
{{- if hasPrefix "RS" (upper .Values.config.jwt.signingAlgorithm) }}true{{- end -}}
{{- end -}}

{{- define "agari-platform.jwtPath" -}}
{{- default "/etc/agari/jwt/private.pem" .Values.config.jwt.privateKeyPath -}}
{{- end -}}

{{/*
Extra flags for `manage.py bootstrap_admin`. The email comes from the
AGARI_ADMIN_EMAIL environment variable and the password from AGARI_ADMIN_PASSWORD,
so neither ends up in the process arguments (which are visible in `ps`).
*/}}
{{- define "agari-platform.bootstrapArgs" -}}
{{- if .Values.bootstrap.adminName }} --name {{ .Values.bootstrap.adminName | quote }}{{ end -}}
{{- if .Values.bootstrap.adminSurname }} --surname {{ .Values.bootstrap.adminSurname | quote }}{{ end -}}
{{- if .Values.bootstrap.resetPassword }} --reset-password{{ end -}}
{{- if .Values.bootstrap.superuser }} --superuser{{ end -}}
{{- end -}}

{{/* Non-secret configuration, consumed with envFrom. */}}
{{- define "agari-platform.configMapData" -}}
PYTHONUNBUFFERED: "1"
DJANGO_SETTINGS_MODULE: {{ .Values.config.djangoSettingsModule | quote }}
DJANGO_DEBUG: {{ .Values.config.djangoDebug | quote }}
DJANGO_ALLOWED_HOSTS: {{ include "agari-platform.allowedHosts" . | quote }}
DJANGO_CSRF_TRUSTED_ORIGINS: {{ include "agari-platform.csrfTrustedOrigins" . | quote }}
DJANGO_TIME_ZONE: {{ .Values.config.timeZone | quote }}
DJANGO_LOG_LEVEL: {{ .Values.config.logLevel | quote }}
DJANGO_SECURE_SSL_REDIRECT: {{ .Values.config.secureSslRedirect | quote }}
DJANGO_SECURE_HSTS_SECONDS: {{ .Values.config.hstsSeconds | int64 | quote }}
ENVIRONMENT: {{ .Values.config.environment | quote }}
API_VERSION: {{ .Values.config.apiVersion | quote }}
SITE_URL: {{ include "agari-platform.siteUrl" . | quote }}
FRONTEND_URL: {{ include "agari-platform.frontendUrl" . | quote }}
CORS_ALLOWED_ORIGINS: {{ include "agari-platform.corsAllowedOrigins" . | quote }}
# --- database -------------------------------------------------------------
DB_NAME: {{ .Values.config.database.name | quote }}
DB_USER: {{ .Values.config.database.user | quote }}
DB_HOST: {{ include "agari-platform.databaseHost" . | quote }}
DB_PORT: {{ .Values.config.database.port | int64 | quote }}
DB_CONN_MAX_AGE: {{ .Values.config.database.connMaxAge | int64 | quote }}
# --- jwt ------------------------------------------------------------------
JWT_SIGNING_ALGORITHM: {{ .Values.config.jwt.signingAlgorithm | quote }}
JWT_ACCESS_TOKEN_LIFETIME_MINUTES: {{ .Values.config.jwt.accessTokenLifetimeMinutes | int64 | quote }}
JWT_REFRESH_TOKEN_LIFETIME_DAYS: {{ .Values.config.jwt.refreshTokenLifetimeDays | int64 | quote }}
{{- if include "agari-platform.jwtEnabled" . }}
JWT_PRIVATE_KEY_PATH: {{ include "agari-platform.jwtPath" . | quote }}
{{- end }}
# --- keycloak compatible oidc ---------------------------------------------
KEYCLOAK_COMPAT_ENABLED: {{ .Values.config.keycloak.compatEnabled | quote }}
KEYCLOAK_CLIENT_ID: {{ .Values.config.keycloak.clientId | quote }}
KEYCLOAK_FRONTEND_CLIENT_ID: {{ .Values.config.keycloak.frontendClientId | quote }}
KEYCLOAK_TRUSTED_CLIENT_IDS: {{ .Values.config.keycloak.trustedClientIds | quote }}
# --- object storage -------------------------------------------------------
OBJECT_STORAGE_ENDPOINT: {{ .Values.config.objectStorage.endpoint | quote }}
OBJECT_STORAGE_PUBLIC_ENDPOINT: {{ .Values.config.objectStorage.publicEndpoint | quote }}
OBJECT_STORAGE_BUCKET: {{ .Values.config.objectStorage.bucket | quote }}
OBJECT_STORAGE_REGION: {{ .Values.config.objectStorage.region | quote }}
OBJECT_STORAGE_USE_SSL: {{ .Values.config.objectStorage.useSsl | quote }}
# --- search ---------------------------------------------------------------
ELASTICSEARCH_URL: {{ .Values.config.elasticsearch.url | quote }}
ELASTICSEARCH_INDEX: {{ .Values.config.elasticsearch.index | quote }}
ELASTICSEARCH_USERNAME: {{ .Values.config.elasticsearch.username | quote }}
ELASTICSEARCH_REQUEST_TIMEOUT: {{ .Values.config.elasticsearch.requestTimeout | int64 | quote }}
# --- email ----------------------------------------------------------------
DEFAULT_FROM_EMAIL: {{ .Values.config.email.defaultFrom | quote }}
EMAIL_BACKEND: {{ .Values.config.email.backend | quote }}
{{- if .Values.config.email.host }}
EMAIL_HOST: {{ .Values.config.email.host | quote }}
EMAIL_PORT: {{ .Values.config.email.port | int64 | quote }}
EMAIL_HOST_USER: {{ .Values.config.email.username | quote }}
EMAIL_USE_TLS: {{ .Values.config.email.useTls | quote }}
EMAIL_USE_SSL: {{ .Values.config.email.useSsl | quote }}
{{- end }}
# --- behaviour switches ---------------------------------------------------
AGARI_PUBLIC_DOCS: {{ .Values.config.behaviour.publicDocs | quote }}
AGARI_EXPOSE_ADMIN_API: {{ .Values.config.behaviour.exposeAdminApi | quote }}
AGARI_ALLOW_USER_ID_HEADER: {{ .Values.config.behaviour.allowUserIdHeader | quote }}
ALLOW_DUPLICATE_ISOLATE_IDS: {{ .Values.config.behaviour.allowDuplicateIsolateIds | quote }}
REQUIRE_FASTA_FILE: {{ .Values.config.behaviour.requireFastaFile | quote }}
{{- range $key, $value := .Values.config.extraConfig }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- end -}}

{{/*
Secret environment variables. Optional keys are marked `optional: true`, so a
missing one never keeps a pod from starting.
*/}}
{{- define "agari-platform.secretEnv" -}}
{{- $name := include "agari-platform.secretName" . -}}
- name: DJANGO_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $name }}
      key: djangoSecretKey
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $name }}
      key: databasePassword
- name: OBJECT_STORAGE_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $name }}
      key: objectStorageAccessKey
- name: OBJECT_STORAGE_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $name }}
      key: objectStorageSecretKey
{{- if .Values.config.elasticsearch.username }}
- name: ELASTICSEARCH_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $name }}
      key: elasticsearchPassword
      optional: true
{{- end }}
- name: KEYCLOAK_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ $name }}
      key: keycloakClientSecret
      optional: true
- name: KEYCLOAK_CLIENT_SECRETS
  valueFrom:
    secretKeyRef:
      name: {{ $name }}
      key: keycloakClientSecrets
      optional: true
- name: SENDGRID_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $name }}
      key: sendgridApiKey
      optional: true
{{- if .Values.config.email.host }}
- name: EMAIL_HOST_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $name }}
      key: emailPassword
      optional: true
{{- end }}
{{- end -}}

{{/* The pod IP is used by the probe Host header and by ALLOWED_HOSTS. */}}
{{- define "agari-platform.podIpEnv" -}}
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: DJANGO_ALLOWED_HOSTS
  value: {{ include "agari-platform.allowedHostsWithPodIp" . | quote }}
{{- end -}}

{{/*
Host header for the HTTP probes. Sending a real hostname keeps the probe
identical to a user request (and keeps it out of CSRF/host-check edge cases).
*/}}
{{- define "agari-platform.probeHost" -}}
{{- if .Values.ingress.enabled -}}
{{- .Values.ingress.host -}}
{{- else -}}
localhost
{{- end -}}
{{- end -}}

{{- define "agari-platform.jwtVolumeMount" -}}
{{- if include "agari-platform.jwtEnabled" . }}
- name: jwt-private-key
  mountPath: {{ include "agari-platform.jwtPath" . }}
  subPath: jwt-private-key.pem
  readOnly: true
{{- end }}
{{- end -}}

{{- define "agari-platform.jwtVolume" -}}
{{- if include "agari-platform.jwtEnabled" . }}
- name: jwt-private-key
  secret:
    secretName: {{ include "agari-platform.secretName" . }}
    items:
      - key: jwt-private-key.pem
        path: jwt-private-key.pem
{{- end }}
{{- end -}}

{{/*
Init container shared by the web and the worker Deployment: blocks until the
schema is migrated.

`manage.py migrate --check` exits non-zero while any migration is outstanding -
and also while the database is still unreachable - so one loop covers both
"Postgres is still starting" and "the migration Job has not finished yet".
Nothing here waits for the migration Job by name: the Job and the Deployments
are created together, and this is what keeps them in the right order.
*/}}
{{- define "agari-platform.waitForSchemaInitContainer" -}}
- name: wait-for-schema
  image: {{ include "agari-platform.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command:
    - sh
    - -c
    - |
      set -eu

      echo "waiting for the schema to be migrated (up to {{ .Values.migrations.waitForSchemaSeconds }}s)"
      deadline=$(( $(date +%s) + {{ .Values.migrations.waitForSchemaSeconds }} ))
      while :; do
        if python manage.py migrate --check >/dev/null 2>&1; then
          echo "the schema is up to date"
          exit 0
        fi
        if [ "$(date +%s)" -ge "${deadline}" ]; then
          echo "the schema was not migrated in time; the last check said:" >&2
          python manage.py migrate --check >&2 || true
          exit 1
        fi
        sleep 5
      done
  envFrom:
    - configMapRef:
        name: {{ include "agari-platform.fullname" . }}
    {{- with .Values.extraEnvFrom }}
    {{- toYaml . | nindent 12 }}
    {{- end }}
  env:
    {{- include "agari-platform.secretEnv" . | nindent 12 }}
    {{- with .Values.extraEnv }}
    {{- toYaml . | nindent 12 }}
    {{- end }}
  resources:
    {{- toYaml .Values.migrations.resources | nindent 12 }}
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - ALL
  volumeMounts:
    {{- include "agari-platform.jwtVolumeMount" . | nindent 12 }}
    {{- with .Values.extraVolumeMounts }}
    {{- toYaml . | nindent 12 }}
    {{- end }}
{{- end -}}
