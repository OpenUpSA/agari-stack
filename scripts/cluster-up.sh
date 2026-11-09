#!/usr/bin/env bash
#
# Creates (or starts) the local k3d cluster the AGARI stack runs on.
#
#   scripts/cluster-up.sh              create it if it does not exist
#   scripts/cluster-up.sh --recreate   delete and create it from scratch
#
# What it does, in order:
#
#   1. starts `podman system service` with cluster/containers.conf, which forces
#      a private cgroup namespace (rootless k3d needs it, see that file),
#   2. builds the patched k3s node image if it is missing (see
#      scripts/build-k3s-image.sh for why),
#   3. runs `k3d cluster create` with the ingress ports mapped to the host.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

RECREATE=0
for arg in "$@"; do
  case "${arg}" in
    --recreate) RECREATE=1 ;;
    -h | --help)
      script_help "$0"
      exit 0
      ;;
    *) die "unknown argument: ${arg} (try --help)" ;;
  esac
done

need podman "install podman"
need k3d "https://k3d.io - or put it in ~/.local/bin"
need kubectl "https://kubernetes.io/docs/tasks/tools"
need python3 "used by scripts/build-k3s-image.sh"

k3d_env

if [ "${RECREATE}" = 1 ] && cluster_exists; then
  say "deleting cluster ${CLUSTER_NAME}"
  k3d cluster delete "${CLUSTER_NAME}"
fi

ensure_podman_api

if cluster_exists; then
  say "cluster ${CLUSTER_NAME} already exists"
  if ! kubectl --context "k3d-${CLUSTER_NAME}" get node >/dev/null 2>&1; then
    say "starting cluster ${CLUSTER_NAME}"
    k3d cluster start "${CLUSTER_NAME}" --wait
  fi
else
  if ! podman image exists "${K3S_IMAGE}"; then
    say "node image ${K3S_IMAGE} is missing - building it"
    "${SCRIPT_DIR}/build-k3s-image.sh" "${K3S_IMAGE}"
  fi

  say "creating cluster ${CLUSTER_NAME} (http ${HTTP_PORT}, https ${HTTPS_PORT})"
  # --kubelet-arg=feature-gates=KubeletInUserNamespace=true: the node runs in a
  # user namespace, which the kubelet otherwise refuses to work in.
  # K3D_FIX_CGROUPV2 lets k3d pre-write its cgroup v2 fixes; the entrypoint
  # scripts are baked into our node image as well.
  # image-gc-*: the kubelet garbage-collects container images when the disk the
  # node sees (here: the host's root filesystem) is over 85% full, and it never
  # stops until it reaches 80% - which it cannot, because images alone are far
  # smaller than that. On a machine that idles around 87% full this deleted the
  # freshly imported localhost/agari-platform:local within minutes of every
  # images-build.sh run, leaving pods in ImagePullBackOff. Raising the
  # thresholds keeps local images safe until the disk is genuinely nearly full.
  K3D_FIX_CGROUPV2=1 k3d cluster create "${CLUSTER_NAME}" \
    --image "${K3S_IMAGE}" \
    --port "${HTTP_PORT}:80@loadbalancer" \
    --port "${HTTPS_PORT}:443@loadbalancer" \
    --k3s-arg "--kubelet-arg=feature-gates=KubeletInUserNamespace=true@all" \
    --k3s-arg "--kubelet-arg=image-gc-high-threshold=95@all" \
    --k3s-arg "--kubelet-arg=image-gc-low-threshold=90@all" \
    --wait \
    --timeout 300s
fi

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
say "waiting for the node to be ready"
kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null

say "cluster ${CLUSTER_NAME} is up"
cat <<EOF

Next:
  scripts/images-build.sh    build and import the platform and frontend images
  scripts/deploy.sh          helm upgrade --install the whole stack
  scripts/verify.sh          check that everything answers

Ingress: http://127.0.0.1:${HTTP_PORT} - the stack is reached by host name:
  ${SPA_ORIGIN}                     SPA
  ${API_ORIGIN}                  API, swagger at /docs/
  http://${MINIO_HOST}:${HTTP_PORT}             object storage
  http://${ELASTIC_HOST}:${HTTP_PORT}           elasticsearch
EOF
