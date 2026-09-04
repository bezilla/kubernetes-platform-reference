#!/usr/bin/env bash
#
# Builds the sample workload and side-loads it into the kind node.
#
# The workload is the service from otel-service-reference -- the instrumented
# half of this pair of repositories. It has no published image and no remote, so
# this builds from the sibling checkout when it is there.
#
# When it is not, the platform still has to come up: a reference platform whose
# `make up` depends on a second private repository is a reference platform
# nobody but its author can run. The fallback is a pinned public image that
# satisfies every guardrail (non-root, tagged, probeable), so the paved road,
# the edge, the certificate and the policies are all still demonstrated. What is
# lost is the telemetry, and only that.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

SIBLING='../otel-service-reference'
IMAGE="${SAMPLE_IMAGE_REPO}:${SAMPLE_IMAGE_TAG}"

if [ -f "${SIBLING}/deploy/Dockerfile" ]; then
	echo "sample-image: building ${IMAGE} from ${SIBLING}"
	docker build -q -t "$IMAGE" -f "${SIBLING}/deploy/Dockerfile" "$SIBLING" >/dev/null
	kind load docker-image "$IMAGE" --name "$KIND_CLUSTER_NAME"
	echo "sample-image: loaded ${IMAGE} into kind/${KIND_CLUSTER_NAME}"
	exit 0
fi

echo "sample-image: ${SIBLING} not found -- falling back to ${SAMPLE_IMAGE_FALLBACK}" >&2
echo "sample-image: the platform is fully demonstrated; only the OTLP telemetry is not" >&2
docker pull -q "$SAMPLE_IMAGE_FALLBACK" >/dev/null
docker tag "$SAMPLE_IMAGE_FALLBACK" "$IMAGE"
kind load docker-image "$IMAGE" --name "$KIND_CLUSTER_NAME"
echo "sample-image: loaded ${IMAGE} into kind/${KIND_CLUSTER_NAME}"
