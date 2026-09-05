#!/usr/bin/env bash
#
# Builds the Git server image and side-loads it into the kind node.
#
# Separate from sample-image.sh on purpose: that one builds a workload from a
# sibling repository that may not be there, and is allowed to fall back. This
# one builds platform plumbing from a Dockerfile in this repo, and there is no
# fallback -- without it Argo CD has nothing to read and the platform does not
# come up at all.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

IMAGE="${GIT_SERVER_IMAGE_REPO}:${GIT_SERVER_IMAGE_TAG}"

echo "git-server-image: building ${IMAGE}"
docker build -q -t "$IMAGE" bootstrap/git-server >/dev/null
kind load docker-image "$IMAGE" --name "$KIND_CLUSTER_NAME"
echo "git-server-image: loaded ${IMAGE} into kind/${KIND_CLUSTER_NAME}"
