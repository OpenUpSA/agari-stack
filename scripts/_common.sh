# shellcheck shell=bash
#
# Shared settings and helpers for the agari-stack scripts. Sourced, not run.
#
# Everything is overridable from the environment, e.g.
#   HTTP_PORT=9090 scripts/cluster-up.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-agari}"
RELEASE="${RELEASE:-agari}"
NAMESPACE="${NAMESPACE:-agari}"

# The k3d load balancer is published on these host ports. 80/443 usually need
# root (or are already taken by another web server), 8080/8443 never do.
HTTP_PORT="${HTTP_PORT:-8080}"
HTTPS_PORT="${HTTPS_PORT:-8443}"

K3S_VERSION="${K3S_VERSION:-v1.35.5-k3s1}"
K3S_IMAGE="${K3S_IMAGE:-localhost/agari-k3s:${K3S_VERSION}-patched}"

PLATFORM_IMAGE="${PLATFORM_IMAGE:-localhost/agari-platform:local}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-localhost/agari-frontend:local}"

API_HOST="${API_HOST:-api.agari.localhost}"
SPA_HOST="${SPA_HOST:-agari.localhost}"
MINIO_HOST="${MINIO_HOST:-minio.agari.localhost}"
ELASTIC_HOST="${ELASTIC_HOST:-elastic.agari.localhost}"
MAILPIT_HOST="${MAILPIT_HOST:-mailpit.agari.localhost}"

API_ORIGIN="${API_ORIGIN:-http://${API_HOST}:${HTTP_PORT}}"
SPA_ORIGIN="${SPA_ORIGIN:-http://${SPA_HOST}:${HTTP_PORT}}"

# The SPA authenticates with client_credentials as `dms`, using a secret that is
# compiled into its own source. Has to match agari-platform.secret.keycloakClientSecrets.
DMS_CLIENT_ID="${DMS_CLIENT_ID:-dms}"
DMS_CLIENT_SECRET="${DMS_CLIENT_SECRET:-VDyLEjGR3xDQvoQlrHq5AB6OwbW0Refc}"

# The bootstrap administrator of the local cluster (values/k3d.yaml). Used by
# verify.sh to reach the mail flows, which need an administrator's API token.
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@agari.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-agari-admin}"

# k3d drives podman through its Docker-compatible API. A dedicated socket (and
# PID) keeps the cluster from sharing a runtime with whatever else the user is
# doing with podman.
RUNTIME_DIR="${AGARI_RUNTIME_DIR:-/tmp/agari-podman}"
PODMAN_SOCK="${RUNTIME_DIR}/podman.sock"
PODMAN_PID="${RUNTIME_DIR}/service.pid"
PODMAN_LOG="${RUNTIME_DIR}/service.log"
CONTAINERS_CONF="${ROOT_DIR}/cluster/containers.conf"

HELM_TIMEOUT="${HELM_TIMEOUT:-15m}"

say() { printf '\n\033[1m>> %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33mwarning: %s\033[0m\n' "$*" >&2; }
die() {
  printf '\033[31merror: %s\033[0m\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH${2:+ ($2)}"
}

# The stack drives rootless podman through ${PODMAN_SOCK}. Under sudo, PATH
# points at root's binaries (no ~/.local/bin/k3d), $HOME changes and the
# scripts would start a second, rootful podman API service.
if [ "$(id -u)" = 0 ]; then
  die "do not run this with sudo: the stack uses rootless podman (sudo's PATH and HOME point elsewhere)"
fi

# k3d talks to podman over the socket; kubectl uses the k3d-managed kubeconfig.
# DOCKER_SOCK is what k3d bind-mounts into its k3d-tools helper node: with it
# unset k3d asks the runtime for /var/run/docker.sock, which rootless podman
# cannot create ("mkdir /var/run/docker.sock: permission denied").
k3d_env() {
  export DOCKER_HOST="unix://${PODMAN_SOCK}"
  export DOCKER_SOCK="${PODMAN_SOCK}"
  export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
}

podman_api_up() {
  curl -sS -o /dev/null --max-time 5 --unix-socket "${PODMAN_SOCK}" http://d/_ping 2>/dev/null
}

# Starts `podman system service`, the API k3d needs, with the containers.conf
# that forces a private cgroup namespace (see cluster/containers.conf - without
# it a rootless k3s container dies instantly).
ensure_podman_api() {
  if podman_api_up; then
    return 0
  fi

  say "starting podman API service on ${PODMAN_SOCK}"
  mkdir -p "${RUNTIME_DIR}"

  CONTAINERS_CONF_OVERRIDE="${CONTAINERS_CONF}" \
  DOCKER_SOCK="${PODMAN_SOCK}" \
    setsid podman system service --timeout=0 "unix://${PODMAN_SOCK}" \
    </dev/null >"${PODMAN_LOG}" 2>&1 &

  echo $! >"${PODMAN_PID}"

  local i
  for i in $(seq 1 100); do
    podman_api_up && return 0
    sleep 0.2
  done

  tail -n 20 "${PODMAN_LOG}" >&2 || true
  die "the podman API service did not come up (see ${PODMAN_LOG})"
}

stop_podman_api() {
  if [ -f "${PODMAN_PID}" ]; then
    local pid
    pid="$(cat "${PODMAN_PID}")"
    if kill -0 "${pid}" 2>/dev/null; then
      say "stopping podman API service (pid ${pid})"
      kill "${pid}" 2>/dev/null || true
    fi
    rm -f "${PODMAN_PID}"
  fi
}

cluster_exists() {
  k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "${CLUSTER_NAME}"
}

# The cluster's own traffic goes through the ingress; *.localhost resolves to
# 127.0.0.1 on any host that follows RFC 6761 (systemd's nss-myhostname,
# glibc/nss-dns on most distributions). If it does not on yours, add
# "127.0.0.1 api.agari.localhost agari.localhost minio.agari.localhost
#  minio-console.agari.localhost elastic.agari.localhost
#  mailpit.agari.localhost" to /etc/hosts.
#
# Usage: ingress_curl <host> <path> [curl args...]
ingress_curl() {
  local host="$1" path="$2"
  shift 2
  curl -sS --max-time 20 -H "Host: ${host}" "$@" "http://127.0.0.1:${HTTP_PORT}${path}"
}

# Prints the "# ..." header of a script as its --help text.
script_help() {
  awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$1"
}
