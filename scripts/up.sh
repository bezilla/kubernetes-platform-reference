#!/usr/bin/env bash
#
# The whole platform, from nothing, in one command.
#
# Order matters and each step explains why it is where it is. Only the first two
# things are installed imperatively -- Argo CD, because a reconciler cannot
# reconcile itself into existence, and the Git server, because Argo CD needs
# something to reconcile FROM. Everything after that is a commit.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# --- preflight ----------------------------------------------------------------
missing=''
for t in docker kind kubectl helm git; do
	command -v "$t" >/dev/null 2>&1 || missing="${missing} ${t}"
done
[ -z "$missing" ] || { echo "up: missing required tools:${missing}" >&2; exit 1; }

docker info >/dev/null 2>&1 || { echo "up: Docker is not running." >&2; exit 1; }

# Memory is the single most common way this fails, and it fails as a starved API
# server rather than as an out-of-memory error, so it is worth refusing early
# with a message that names the real cause. Measured: the platform settles around
# 4 GiB, and a 3.8 GiB Docker VM killed the control plane outright.
mem_bytes="$(docker system info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
mem_gib=$((mem_bytes / 1073741824))
if [ "$mem_gib" -lt 7 ]; then
	cat >&2 <<EOF
up: Docker has ${mem_gib} GiB of memory. This platform needs 8 GiB.

    The platform settles at about 4 GiB, but the install peaks well above it
    while four Helm charts unpack at once. Below 8 GiB the symptom is not an
    out-of-memory error -- it is the API server going unreachable, which reads
    like a broken cluster and is not one.

    Docker Desktop -> Settings -> Resources -> Memory.
EOF
	exit 1
fi

# --- 1. the cluster -----------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
	echo "up: cluster '${KIND_CLUSTER_NAME}' already exists; reusing it. 'make down' first for a clean run."
else
	step "Creating the kind cluster (pinned node image)"
	kind create cluster --name "$KIND_CLUSTER_NAME" --config cluster/kind.yaml \
		--image "$KIND_NODE_IMAGE" --wait 180s
fi
kubectl config use-context "kind-${KIND_CLUSTER_NAME}" >/dev/null

# Another kind cluster on the same machine is the other way this fails: five
# nodes on eight cores starved this control plane into a TLS handshake timeout.
others="$(kind get clusters 2>/dev/null | grep -vx "$KIND_CLUSTER_NAME" || true)"
[ -z "$others" ] || printf '\nup: WARNING -- other kind clusters are running and will contend for CPU:\n%s\n\n' \
	"$(printf '%s\n' "$others" | sed 's/^/      /')"

# --- 2. Argo CD ---------------------------------------------------------------
step "Installing Argo CD ${ARGOCD_CHART_VERSION} (the one imperative install)"
helm repo add argo "$ARGOCD_REPO" >/dev/null 2>&1 || true
helm repo update argo >/dev/null 2>&1 || true
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
	--namespace argocd --create-namespace \
	--values bootstrap/argocd-values.yaml --wait --timeout 12m >/dev/null
echo "    Argo CD is up."

# --- 3. the Git server --------------------------------------------------------
step "Building and starting the in-cluster Git server"
./scripts/git-server-image.sh
kubectl apply -f bootstrap/git-server.yaml >/dev/null
kubectl -n platform-system rollout status deploy/git-server --timeout=300s >/dev/null
echo "    Git server is running (not yet ready: nothing published to it)."

# --- 4. the sample workload's image -------------------------------------------
step "Building the sample workload image"
./scripts/sample-image.sh

# --- 5. publish ---------------------------------------------------------------
step "Publishing this repository to the in-cluster Git server"
./scripts/publish.sh

# --- 6. hand over to Argo CD --------------------------------------------------
step "Applying the app-of-apps root -- Argo CD takes over from here"
kubectl apply -f bootstrap/root-application.yaml 2>&1 | grep -v 'domain-qualified' || true

step "Waiting for every Application to reach Synced and Healthy"
echo "    (first run pulls five charts; several minutes is normal)"
./scripts/wait-for-platform.sh "${UP_TIMEOUT_SECONDS:-900}"

./scripts/status.sh
