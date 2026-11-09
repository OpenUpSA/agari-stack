#!/usr/bin/env bash
#
# Builds the derived k3s node image used by the local AGARI k3d cluster:
#
#   docker.io/rancher/k3s:v1.35.5-k3s1
#     + patched /bin/k3s  (see patch-validate-cgroups.py)
#     + k3d entrypoint scripts (see images/Dockerfile.k3s)
#
# Usage: scripts/build-k3s-image.sh [image-tag]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

K3S_VERSION="${K3S_VERSION:-v1.35.5-k3s1}"
K3S_IMAGE="${K3S_IMAGE:-docker.io/rancher/k3s:${K3S_VERSION}}"
IMAGE_TAG="${1:-localhost/agari-k3s:${K3S_VERSION}-patched}"

PODMAN="${PODMAN:-podman}"
BUILD_DIR="${ROOT_DIR}/build"
mkdir -p "${BUILD_DIR}"

if [ ! -x "${BUILD_DIR}/k3s-orig" ]; then
  echo ">> extracting /bin/k3s from ${K3S_IMAGE}"
  "${PODMAN}" create --name agari-k3s-extract --entrypoint /bin/true "${K3S_IMAGE}" >/dev/null
  "${PODMAN}" cp agari-k3s-extract:/bin/k3s "${BUILD_DIR}/k3s-orig"
  "${PODMAN}" rm -f agari-k3s-extract >/dev/null
  chmod 0755 "${BUILD_DIR}/k3s-orig"
fi

echo ">> patching ${BUILD_DIR}/k3s-orig -> ${BUILD_DIR}/k3s"
python3 "${SCRIPT_DIR}/patch-validate-cgroups.py" "${BUILD_DIR}/k3s-orig" "${BUILD_DIR}/k3s"
chmod 0755 "${BUILD_DIR}/k3s"

echo ">> building ${IMAGE_TAG}"
cd "${ROOT_DIR}"
"${PODMAN}" build -f images/Dockerfile.k3s -t "${IMAGE_TAG}" --build-arg "K3S_IMAGE=${K3S_IMAGE}" .

echo ">> done: ${IMAGE_TAG}"
