#!/usr/bin/env bash
#
# Installs (or upgrades) the whole stack into the local cluster.
#
#   scripts/deploy.sh                                  install, wait, print notes
#   scripts/deploy.sh --set agari-platform.web.replicaCount=2
#   scripts/deploy.sh --atomic                         roll back a failed release
#
# Everything is one Helm release: the umbrella chart in charts/agari-stack pulls
# in postgres, minio, elasticsearch, mailpit, agari-platform and agari-frontend,
# and values/k3d.yaml adds the local administrator. Migrations, sync_roles and
# bootstrap_admin run in a Job that is created together with the rest of the
# release (not as a hook, which would deadlock against `--wait`); the web and
# worker pods wait for it in an init container, so this returns once the
# database schema is in place.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

need helm "https://helm.sh/docs/intro/install"
need kubectl
need k3d

k3d_env

cluster_exists || die "cluster ${CLUSTER_NAME} does not exist (run scripts/cluster-up.sh)"

CHART_DIR="${ROOT_DIR}/charts/agari-stack"
VALUES=("${ROOT_DIR}/values/k3d.yaml")

# Anything --set/-f/--version-like goes straight to helm.
EXTRA_ARGS=("$@")

say "resolving chart dependencies"
# `update`, not `build`: the subcharts are local (file://../<chart>) and the
# packaged copies in charts/agari-stack/charts/ are gitignored, so rebuilding
# them is what makes an edit under charts/<component>/ actually deploy.
helm dependency update "${CHART_DIR}" >/dev/null

say "installing release ${RELEASE} in namespace ${NAMESPACE}"
helm upgrade --install "${RELEASE}" "${CHART_DIR}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values "${VALUES[0]}" \
  --wait \
  --timeout "${HELM_TIMEOUT}" \
  "${EXTRA_ARGS[@]}"

say "release ${RELEASE} is installed"

# Useful when a migration or the first administrator is what you are debugging.
if kubectl -n "${NAMESPACE}" get job -l app.kubernetes.io/component=migrate -o name >/dev/null 2>&1; then
  say "migration log"
  kubectl -n "${NAMESPACE}" logs -l app.kubernetes.io/component=migrate --tail=40 --prefix 2>/dev/null || true
fi

if ! kubectl -n "${NAMESPACE}" rollout status deploy/agari-platform-web --timeout=5m >/dev/null 2>&1; then
  warn "deploy/agari-platform-web is not rolled out - check 'kubectl -n ${NAMESPACE} get pods'"
fi

helm -n "${NAMESPACE}" get notes "${RELEASE}" || true

say "check it end to end with scripts/verify.sh"
