#!/usr/bin/env bash
#
# Deletes the cluster and the working directory. Everything this platform builds
# lives in the cluster or in .work/, so there is nothing else to clean up -- no
# volumes to prune, no state directory, nothing written outside the repo.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
	kind delete cluster --name "$KIND_CLUSTER_NAME"
else
	echo "down: no cluster named '${KIND_CLUSTER_NAME}'."
fi
rm -rf .work
echo "down: removed .work/"
