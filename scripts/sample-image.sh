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
# nobody but its author can run. So there is a fallback, built from
# bootstrap/fallback-workload on a pinned public base. The paved road, the edge,
# the certificate and the policies are all still demonstrated. What is lost is
# the telemetry, and only that.
#
# The fallback is BUILT rather than pulled-and-tagged, and that is the whole
# point of it. Tagging stock nginx-unprivileged satisfied three of the four
# things this image has to be -- non-root, tagged, resource-bounded -- and
# quietly failed the fourth. The chart's startup and readiness probes both
# request /healthz, stock nginx serves no such path, and so every fallback run
# crash-looped: 15 failed probes, container killed, repeat, until the
# Application hit its 900s deadline Degraded. It cost nothing to fix and it is
# not fixable from the outside, because the probe path is the chart's contract
# with any workload, not a property of the image it happened to pull.

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

echo "sample-image: ${SIBLING} not found -- building the fallback workload" >&2
echo "sample-image: base ${SAMPLE_IMAGE_FALLBACK}; serves /healthz so the chart's probes pass" >&2
echo "sample-image: the platform is fully demonstrated; only the OTLP telemetry is not" >&2
docker build -q -t "$IMAGE" --build-arg "BASE=${SAMPLE_IMAGE_FALLBACK}" \
	bootstrap/fallback-workload >/dev/null
kind load docker-image "$IMAGE" --name "$KIND_CLUSTER_NAME"
echo "sample-image: loaded ${IMAGE} into kind/${KIND_CLUSTER_NAME}"
