#!/usr/bin/env bash
#
# Checks the deployed stack the way a user would touch it: through the ingress,
# by host name. Exit code 0 means every hard check passed.
#
#   scripts/verify.sh              run everything
#   scripts/verify.sh --verbose    show the bodies of the responses too
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

VERBOSE=0
for arg in "$@"; do
  case "${arg}" in
    --verbose | -v) VERBOSE=1 ;;
    -h | --help)
      script_help "$0"
      exit 0
      ;;
    *) die "unknown argument: ${arg} (try --help)" ;;
  esac
done

need kubectl
need curl

FAILED=0
PASSED=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() {
  printf '  \033[31m✗\033[0m %s\n' "$*"
  FAILED=$((FAILED + 1))
}
soft_fail() { printf '  \033[33m!\033[0m %s\n' "$*"; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# check <description> <host> <path> [jq/python filter to look for in the body]
check_http() {
  local what="$1" host="$2" path="$3" filter="${4:-}"
  local body
  if ! body="$(curl -fsS --max-time 20 -H "Host: ${host}" "http://127.0.0.1:${HTTP_PORT}${path}" 2>/dev/null)"; then
    fail "${what} (GET http://${host}:${HTTP_PORT}${path})"
    return 1
  fi
  if [ -n "${filter}" ] && ! printf '%s' "${body}" | grep -qE "${filter}"; then
    fail "${what} (no match for /${filter}/)"
    [ "${VERBOSE}" = 1 ] && printf '%s\n' "${body}" | head -c 500
    return 1
  fi
  pass "${what}"
  [ "${VERBOSE}" = 1 ] && printf '%s\n' "${body}" | head -c 500 && echo
  return 0
}

section "workloads (namespace ${NAMESPACE})"
for workload in deploy/agari-postgres deploy/agari-minio deploy/agari-elasticsearch \
  deploy/agari-platform-web deploy/agari-platform-worker deploy/agari-frontend \
  deploy/agari-mailpit; do
  # Mailpit is optional (mailpit.enabled), so it is only reported on when the
  # chart is installed.
  if ! kubectl -n "${NAMESPACE}" get "${workload}" >/dev/null 2>&1; then
    printf '  \033[33m-\033[0m %s is not installed\n' "${workload}"
    continue
  fi
  if kubectl -n "${NAMESPACE}" rollout status "${workload}" --timeout=10s >/dev/null 2>&1; then
    pass "${workload} rolled out"
  else
    fail "${workload} is not ready - kubectl -n ${NAMESPACE} describe ${workload}"
  fi
done

section "migration Job"
MIGRATE_JOB="$(kubectl -n "${NAMESPACE}" get job -l app.kubernetes.io/component=migrate \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
if [ -n "${MIGRATE_JOB}" ] && \
  kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${MIGRATE_JOB}" --timeout=10s >/dev/null 2>&1; then
  pass "${MIGRATE_JOB} completed"
else
  fail "no completed migration Job - kubectl -n ${NAMESPACE} logs -l app.kubernetes.io/component=migrate"
fi
if kubectl -n "${NAMESPACE}" get job/agari-minio-bucket-setup >/dev/null 2>&1; then
  # Normally already gone: the hook is deleted again once it succeeds, so this
  # only reports on a run that is still in flight (or still failing).
  if kubectl -n "${NAMESPACE}" wait --for=condition=complete job/agari-minio-bucket-setup --timeout=10s >/dev/null 2>&1; then
    pass "agari-minio-bucket-setup completed"
  else
    fail "agari-minio-bucket-setup has not completed - kubectl -n ${NAMESPACE} logs job/agari-minio-bucket-setup"
  fi
fi

section "API"
check_http "GET /info/health" "${API_HOST}" "/info/health" '"status"|ok' || true
check_http "GET /docs/ (swagger)" "${API_HOST}" "/docs/" "swagger|openapi" || true
check_http "GET /.well-known/openid-configuration" "${API_HOST}" "/.well-known/openid-configuration" "token_endpoint" || true
# The admin login page is Django's Unfold theme, so look for the form field
# rather than for the word "Django" (which it never renders).
check_http "GET /admin/login/ (admin)" "${API_HOST}" "/admin/login/" 'id="id_username"' || true

# The SPA authenticates with client_credentials against the platform's Keycloak
# compatibility layer, using the client id and secret baked into its source.
# A token is not enough on its own: the SPA reads GET /info/whoami with it, so
# that call has to resolve too or the browser ends up on "Token contained no
# recognizable user identification".
section "OIDC compatibility (client_credentials as the SPA sends it)"
TOKEN_JSON="$(curl -sS --max-time 20 -H "Host: ${API_HOST}" \
  -d "grant_type=client_credentials&client_id=${DMS_CLIENT_ID}&client_secret=${DMS_CLIENT_SECRET}" \
  "http://127.0.0.1:${HTTP_PORT}/protocol/openid-connect/token" 2>/dev/null || true)"
if printf '%s' "${TOKEN_JSON}" | grep -q 'access_token'; then
  pass "POST /protocol/openid-connect/token returned a token"
  [ "${VERBOSE}" = 1 ] && printf '  %s\n' "${TOKEN_JSON:0:120}..."
  ACCESS_TOKEN="$(printf '%s' "${TOKEN_JSON}" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  WHOAMI="$(curl -sS --max-time 20 -w '\n%{http_code}' -H "Host: ${API_HOST}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "http://127.0.0.1:${HTTP_PORT}/info/whoami" 2>/dev/null || true)"
  WHOAMI_CODE="${WHOAMI##*$'\n'}"
  WHOAMI_BODY="${WHOAMI%$'\n'*}"
  if [ "${WHOAMI_CODE}" = "200" ] && printf '%s' "${WHOAMI_BODY}" | grep -q '"is_authenticated":true'; then
    pass "the token resolves to a user (GET /info/whoami)"
  else
    fail "the token does not resolve to a user (HTTP ${WHOAMI_CODE}) - it carries no usable subject, so SimpleJWT rejects it"
    [ "${VERBOSE}" = 1 ] && printf '  %s\n' "${WHOAMI_BODY:0:300}"
  fi
else
  soft_fail "no token - the platform did not accept client_id=dms (see agari-platform.secret.keycloakClientSecrets)"
  [ "${VERBOSE}" = 1 ] && printf '  %s\n' "${TOKEN_JSON:0:300}"
fi

section "storage"
check_http "MinIO is live" "${MINIO_HOST}" "/minio/health/live" "" || true
check_http "MinIO console answers" "${MINIO_HOST%%.*}-console.${MINIO_HOST#*.}" "/" "MinIO" || true
if kubectl -n "${NAMESPACE}" exec deploy/agari-minio -- sh -c 'test -d /data/agari-data' >/dev/null 2>&1; then
  pass "bucket agari-data exists"
else
  fail "bucket agari-data is missing on the MinIO volume"
fi

section "search"
check_http "Elasticsearch is up" "${ELASTIC_HOST}" "/_cluster/health" '"status"' || true
ES_STATUS="$(curl -sS --max-time 20 -H "Host: ${ELASTIC_HOST}" "http://127.0.0.1:${HTTP_PORT}/_cluster/health" 2>/dev/null || true)"
case "${ES_STATUS}" in
  *'"status":"green"'*) pass "cluster health is green" ;;
  *'"status":"yellow"'*) soft_fail "cluster health is yellow - a single node cannot allocate replicas; check the agari-* index settings (elasticsearch.indexDefaults)" ;;
  *) soft_fail "could not read the cluster health" ;;
esac

section "mail (Mailpit)"
if ! kubectl -n "${NAMESPACE}" get deploy/agari-mailpit >/dev/null 2>&1; then
  printf '  \033[33m-\033[0m Mailpit is not installed (mailpit.enabled=false) - skipping the mail checks\n'
else
  check_http "Mailpit answers (web UI and API)" "${MAILPIT_HOST}" "/api/v1/info" '"Version"' || true

  # Invitations and magic links are only testable if the platform hands them to
  # Mailpit instead of writing them to its own log.
  MAIL_BACKEND="$(kubectl -n "${NAMESPACE}" get configmap agari-platform \
    -o jsonpath='{.data.EMAIL_BACKEND}' 2>/dev/null || true)"
  MAIL_HOST="$(kubectl -n "${NAMESPACE}" get configmap agari-platform \
    -o jsonpath='{.data.EMAIL_HOST}' 2>/dev/null || true)"
  if printf '%s' "${MAIL_BACKEND}" | grep -qi 'smtp' && [ -n "${MAIL_HOST}" ]; then
    pass "the platform mails through ${MAIL_HOST} (EMAIL_BACKEND=${MAIL_BACKEND##*.})"
  else
    fail "the platform does not mail through Mailpit (EMAIL_BACKEND='${MAIL_BACKEND}', EMAIL_HOST='${MAIL_HOST}') - mail only reaches the pod log"
  fi

  # The round trip a user makes: ask for a sign-in link, read it out of Mailpit
  # and exchange the code for a token. Needs an administrator, because minting a
  # link for someone else requires the create_user permission.
  ADMIN_TOKEN="$(curl -sS --max-time 20 -H "Host: ${API_HOST}" \
    -d "grant_type=password&client_id=${DMS_CLIENT_ID}&client_secret=${DMS_CLIENT_SECRET}&username=${ADMIN_EMAIL}&password=${ADMIN_PASSWORD}" \
    "http://127.0.0.1:${HTTP_PORT}/protocol/openid-connect/token" 2>/dev/null |
    sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [ -z "${ADMIN_TOKEN}" ]; then
    soft_fail "${ADMIN_EMAIL} did not sign in - set ADMIN_EMAIL/ADMIN_PASSWORD to run the magic-link round trip"
  else
    BEFORE_ID="$(ingress_curl "${MAILPIT_HOST}" "/api/v1/message/latest" 2>/dev/null |
      sed -n 's/.*"ID":"\([^"]*\)".*/\1/p' | head -n 1)"
    # redirect_uri has to be the SPA origin, not a deeper path: the link is built
    # as "<redirect_uri>?userid=..&code=..", and only the route at the root
    # renders the callback that exchanges the code. This is what the SPA itself
    # sends (window.location.origin in services/authService.ts).
    LINK_JSON="$(curl -sS --max-time 20 -X POST -H "Host: ${API_HOST}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" -H 'Content-Type: application/json' \
      -d "{\"email\":\"${ADMIN_EMAIL}\",\"redirect_uri\":\"${SPA_ORIGIN}\",\"send_email\":true}" \
      "http://127.0.0.1:${HTTP_PORT}/users/" 2>/dev/null || true)"
    if printf '%s' "${LINK_JSON}" | grep -q '"link"'; then
      pass "POST /users/ minted a sign-in link for ${ADMIN_EMAIL}"
      MESSAGE=""
      for _ in $(seq 1 20); do
        MESSAGE="$(ingress_curl "${MAILPIT_HOST}" "/api/v1/message/latest" 2>/dev/null || true)"
        MESSAGE_ID="$(printf '%s' "${MESSAGE}" | sed -n 's/.*"ID":"\([^"]*\)".*/\1/p' | head -n 1)"
        if [ -n "${MESSAGE_ID}" ] && [ "${MESSAGE_ID}" != "${BEFORE_ID}" ] &&
          printf '%s' "${MESSAGE}" | grep -q "Your AGARI sign-in link"; then
          break
        fi
        sleep 0.5
      done
      if printf '%s' "${MESSAGE}" | grep -q "Your AGARI sign-in link"; then
        pass "the mail is readable in Mailpit (GET /api/v1/message/latest)"
        # A link that points anywhere but the root drops the user on the login
        # form with the code still in the address bar.
        if printf '%s' "${MESSAGE}" | grep -qE "${SPA_ORIGIN}\?userid=|${SPA_ORIGIN}/\?userid="; then
          pass "the mailed link opens the SPA root, where the callback runs"
        else
          fail "the mailed link does not point at ${SPA_ORIGIN}/?userid=.. - the SPA only exchanges the code at the root route"
        fi
        CODE="$(printf '%s' "${MESSAGE}" | sed -n 's/.*code=\([A-Za-z0-9_-]*\).*/\1/p' | head -n 1)"
        [ -n "${CODE}" ] || CODE="$(printf '%s' "${LINK_JSON}" |
          sed -n 's/.*code=\([A-Za-z0-9_-]*\).*/\1/p' | head -n 1)"
        SIGNIN_JSON="$(curl -sS --max-time 20 -H "Host: ${API_HOST}" \
          -d "grant_type=authorization_code&client_id=${DMS_CLIENT_ID}&code=${CODE}" \
          "http://127.0.0.1:${HTTP_PORT}/protocol/openid-connect/token" 2>/dev/null || true)"
        ACCESS_TOKEN="$(printf '%s' "${SIGNIN_JSON}" |
          sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        WHOAMI_CODE="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -H "Host: ${API_HOST}" \
          -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          "http://127.0.0.1:${HTTP_PORT}/info/whoami" 2>/dev/null || true)"
        if [ -n "${ACCESS_TOKEN}" ] && [ "${WHOAMI_CODE}" = "200" ]; then
          pass "the link from the mail signs a user in (authorization_code -> GET /info/whoami)"
        else
          fail "the mailed code did not sign a user in${CODE:+ (code ${CODE})} - see scripts/verify.sh --verbose"
          [ "${VERBOSE}" = 1 ] && printf '  %s\n' "${SIGNIN_JSON:0:300}"
        fi
        # Keep the inbox showing what was actually requested by hand. Mailpit
        # only accepts deletions in bulk, and by explicit id: DELETE on a single
        # message answers 405.
        [ -n "${MESSAGE_ID}" ] &&
          ingress_curl "${MAILPIT_HOST}" "/api/v1/messages" -X DELETE \
            -H 'Content-Type: application/json' \
            -d "{\"IDs\":[\"${MESSAGE_ID}\"]}" >/dev/null 2>&1 || true
      else
        fail "no sign-in mail arrived in Mailpit - check 'kubectl -n ${NAMESPACE} logs deploy/agari-platform-web | tail'"
      fi
    else
      fail "POST /users/ did not mint a link for ${ADMIN_EMAIL}"
      [ "${VERBOSE}" = 1 ] && printf '  %s\n' "${LINK_JSON:0:300}"
    fi
  fi
fi

section "SPA"
SPA_HTML="$(curl -fsS --max-time 30 -H "Host: ${SPA_HOST}" "http://127.0.0.1:${HTTP_PORT}/" 2>/dev/null || true)"
if [ -z "${SPA_HTML}" ]; then
  fail "the SSR server did not answer on http://${SPA_HOST}:${HTTP_PORT}/"
else
  pass "the SSR server rendered $(printf '%s' "${SPA_HTML}" | wc -c) bytes"
  if printf '%s' "${SPA_HTML}" | grep -qi 'agari'; then
    pass "the HTML looks like the AGARI app"
  else
    soft_fail "the HTML does not mention AGARI - check the container logs"
  fi
  # The API origin is compiled into the client bundle (the SPA hardcodes it), so
  # the check has to follow the entry script - the server-rendered shell does
  # not mention it.
  ENTRY_JS="$(printf '%s' "${SPA_HTML}" | grep -oE '/static/[A-Za-z0-9._-]+\.js' | head -n 1 || true)"
  if [ -z "${ENTRY_JS}" ]; then
    soft_fail "no client entry script in the HTML - cannot check the API origin"
  else
    SPA_BUNDLE="$(curl -fsS --max-time 30 -H "Host: ${SPA_HOST}" \
      "http://127.0.0.1:${HTTP_PORT}${ENTRY_JS}" 2>/dev/null || true)"
    case "${SPA_BUNDLE}" in
      *"${API_HOST}"*) pass "the client bundle (${ENTRY_JS}) points at ${API_HOST}" ;;
      *) fail "${ENTRY_JS} does not reference ${API_HOST} - was the image built with scripts/images-build.sh?" ;;
    esac
  fi
fi

printf '\n%d checks passed, %d failed\n' "${PASSED}" "${FAILED}"
if [ "${FAILED}" -gt 0 ]; then
  exit 1
fi
