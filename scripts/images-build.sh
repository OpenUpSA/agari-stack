#!/usr/bin/env bash
#
# Builds the two first-party images and imports them into the k3d cluster.
#
#   scripts/images-build.sh                  build both, then import
#   scripts/images-build.sh platform         build/import only the API+worker
#   scripts/images-build.sh frontend         build/import only the SPA
#   scripts/images-build.sh --no-import ...  build without importing
#
# The platform image is agari-platform/Dockerfile unchanged: one image runs the
# web (gunicorn), the worker and the migration Job.
#
# The frontend image is agari-stack/images/Dockerfile.frontend, which builds the
# SPA the way upstream does but rewrites the two service URLs the local stack
# replaces (the SPA hardcodes them) - see that file. The agari-frontend checkout
# is never modified.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

WORKSPACE_DIR="$(cd "${ROOT_DIR}/.." && pwd)"

BUILD_PLATFORM=1
BUILD_FRONTEND=1
IMPORT=1

for arg in "$@"; do
  case "${arg}" in
    platform) BUILD_FRONTEND=0 ;;
    frontend) BUILD_PLATFORM=0 ;;
    --no-import) IMPORT=0 ;;
    -h | --help)
      script_help "$0"
      exit 0
      ;;
    *) die "unknown argument: ${arg} (try --help)" ;;
  esac
done

need podman

if [ "${BUILD_PLATFORM}" = 1 ]; then
  PLATFORM_DIR="${PLATFORM_DIR:-${WORKSPACE_DIR}/agari-platform}"
  [ -f "${PLATFORM_DIR}/Dockerfile" ] || die "no Dockerfile in ${PLATFORM_DIR} (set PLATFORM_DIR)"

  say "building ${PLATFORM_IMAGE} from ${PLATFORM_DIR}"
  # --format docker keeps the HEALTHCHECK the upstream Dockerfile defines; the
  # OCI manifest format drops it (Kubernetes uses the chart's probes anyway).
  podman build --format docker -t "${PLATFORM_IMAGE}" "${PLATFORM_DIR}"
fi

if [ "${BUILD_FRONTEND}" = 1 ]; then
  FRONTEND_DIR="${FRONTEND_DIR:-${WORKSPACE_DIR}/agari-frontend}"
  [ -f "${FRONTEND_DIR}/website/package.json" ] || die "not a checkout of agari-frontend: ${FRONTEND_DIR} (set FRONTEND_DIR)"

  say "building ${FRONTEND_IMAGE} from ${FRONTEND_DIR}"
  podman build \
    --ignorefile "${ROOT_DIR}/images/frontend.containerignore" \
    --file "${ROOT_DIR}/images/Dockerfile.frontend" \
    --build-arg "AGARI_API_ORIGIN=${API_ORIGIN}" \
    -t "${FRONTEND_IMAGE}" \
    "${FRONTEND_DIR}"
fi

if [ "${IMPORT}" = 1 ]; then
  k3d_env
  need k3d

  if ! cluster_exists; then
    warn "cluster ${CLUSTER_NAME} does not exist - skipping the import (run scripts/cluster-up.sh)"
    exit 0
  fi

  images=()
  [ "${BUILD_PLATFORM}" = 1 ] && images+=("${PLATFORM_IMAGE}")
  [ "${BUILD_FRONTEND}" = 1 ] && images+=("${FRONTEND_IMAGE}")

  say "importing ${images[*]} into ${CLUSTER_NAME}"
  # --mode direct streams the image into the node's containerd, without starting
  # the k3d-tools helper node the default ("tools") mode needs.
  k3d image import --mode direct --cluster "${CLUSTER_NAME}" "${images[@]}"
fi

say "done"
