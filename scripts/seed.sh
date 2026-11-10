#!/usr/bin/env bash
#
# Seeds optional local test data - never part of scripts/deploy.sh, so a
# production deployment has no path to it:
#
#   scripts/seed.sh                     two orgs, one user per role, 6 projects
#   scripts/seed.sh --schemas-dir ...   (default: schemas/ next to this script)
#   scripts/seed.sh --dry-run           print the command, run nothing
#
# The reference schemas live on the host, not in the platform image, so they
# are copied into the web pod first and handed to `manage.py seed_dev_data`
# with --schemas-dir. Idempotent: run it as often as you like.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

need kubectl
k3d_env
cluster_exists || die "cluster ${CLUSTER_NAME} does not exist (run scripts/cluster-up.sh)"

SCHEMAS_DIR="${ROOT_DIR}/schemas"
DRY_RUN=0
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --schemas-dir) SCHEMAS_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

[ -d "${SCHEMAS_DIR}" ] || die "no such schemas directory: ${SCHEMAS_DIR}"

CONTAINER="web"
POD="$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/component=web \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "${POD}" ] && [ "$(kubectl -n "${NAMESPACE}" get pod "${POD}" \
  -o jsonpath='{.status.phase}')" = Running ] \
  || die "no running agari-platform-web pod (run scripts/deploy.sh first)"

# kubectl cp needs tar inside the container; python images ship it.
say "copying schemas from ${SCHEMAS_DIR} into ${POD}"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "kubectl -n ${NAMESPACE} cp ${SCHEMAS_DIR}/. ${POD}:/tmp/seed-schemas -c ${CONTAINER}"
else
  kubectl -n "${NAMESPACE}" exec "${POD}" -c "${CONTAINER}" -- mkdir -p /tmp/seed-schemas
  kubectl -n "${NAMESPACE}" cp "${SCHEMAS_DIR}/." "${POD}:/tmp/seed-schemas" -c "${CONTAINER}"
fi

CMD=(python manage.py seed_dev_data --schemas-dir /tmp/seed-schemas)
[ ${#EXTRA_ARGS[@]} -gt 0 ] && CMD+=("${EXTRA_ARGS[@]}")

say "running manage.py seed_dev_data"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "kubectl -n ${NAMESPACE} exec ${POD} -c ${CONTAINER} -- ${CMD[*]}"
  exit 0
fi

kubectl -n "${NAMESPACE}" exec "${POD}" -c "${CONTAINER}" -- "${CMD[@]}"

say "seeded accounts (password ${AGARI_SEED_PASSWORD:-agari-seed})"
cat >&2 <<'EOF'
  orgs     National Institute for Communicable Diseases - RSA, Kenya Medical Research Institute
  users    one per org role in each org: nicd-org-owner@agari.localhost,
           kemri-org-viewer@agari.localhost, ... (4 roles x 2 orgs)
           plus single accounts: system-admin, agari-service-account,
           attr-project-admin/contributor/viewer @agari.localhost
  projects one per schema, split across the two orgs
EOF
