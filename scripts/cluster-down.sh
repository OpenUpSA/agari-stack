#!/usr/bin/env bash
#
# Deletes the local k3d cluster.
#
#   scripts/cluster-down.sh                  delete the cluster
#   scripts/cluster-down.sh --stop-runtime   also stop the podman API service
#
# The images that were imported into the cluster (localhost/agari-*:local) are
# kept, so a later cluster-up.sh plus deploy.sh needs no rebuild. Volumes with
# the database, bucket and index data are deleted with the cluster; use
# `helm uninstall` first if you want the Postgres/MinIO persistentVolume data to
# survive (the charts keep their PVCs by default).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

STOP_RUNTIME=0
for arg in "$@"; do
  case "${arg}" in
    --stop-runtime) STOP_RUNTIME=1 ;;
    -h | --help)
      script_help "$0"
      exit 0
      ;;
    *) die "unknown argument: ${arg} (try --help)" ;;
  esac
done

need k3d

k3d_env

if [ -f "${PODMAN_PID}" ] || podman_api_up; then
  if cluster_exists; then
    say "deleting cluster ${CLUSTER_NAME}"
    k3d cluster delete "${CLUSTER_NAME}"
  else
    say "cluster ${CLUSTER_NAME} does not exist"
  fi
else
  warn "the podman API service is not running - nothing to delete"
fi

if [ "${STOP_RUNTIME}" = 1 ]; then
  stop_podman_api
fi
