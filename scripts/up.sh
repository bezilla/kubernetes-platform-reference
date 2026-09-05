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

# `kubectl apply -f x | grep -v warning` reports GREP's exit status, not
# kubectl's, so a failed apply reads as a success. Capture first, filter after.
apply_manifest() {
	local out rc
	out="$(kubectl apply -f "$1" 2>&1)"; rc=$?
	printf '%s\n' "$out" | grep -v 'domain-qualified' | sed 's/^/      /' || true
	return "$rc"
}

# metadata.name is the first `name:` in each of these Application files; chart
# and source names come later in the document.
app_name() { grep -m1 -E '^[[:space:]]+name:[[:space:]]' "$1" | awk '{print $2}'; }

# --- preflight ----------------------------------------------------------------
missing=''
for t in docker kind kubectl helm git; do
	command -v "$t" >/dev/null 2>&1 || missing="${missing} ${t}"
done
[ -z "$missing" ] || { echo "up: missing required tools:${missing}" >&2; exit 1; }

docker info >/dev/null 2>&1 || { echo "up: Docker is not running." >&2; exit 1; }

# Cores are the single most common way this fails, and it fails as a starved API
# server rather than as an out-of-memory error, so it is worth refusing early
# with a message that names the real cause.
#
# The earlier version of this preflight checked only memory and then blamed the
# API server. That was the wrong resource. A run on an 8-core / 7.7 GiB machine
# sat at 4.6 GiB of 7.7 -- memory was never tight -- while CPU held 900-1900% of
# 800% available. etcd reads went from a 100ms budget to 1.0-1.5s, the API
# server could not answer a 5s lease renewal, and the controller manager and
# scheduler both lost leader election and crash-looped. Nothing reconciled after
# that, so every Application sat Progressing forever.
#
# The other half of that bug: memory was compared in whole GiB via integer
# division, so a 7.0 GiB Docker VM computed to 7 and passed a check that claimed
# to require 8. Both numbers are compared in MiB now.
read -r ncpu mem_bytes <<<"$(docker system info --format '{{.NCPU}} {{.MemTotal}}' 2>/dev/null || echo '0 0')"
mem_mib=$((mem_bytes / 1048576))

if [ "$ncpu" -lt "$MIN_CPUS" ] || [ "$mem_mib" -lt "$MIN_MEMORY_MIB" ]; then
	cat >&2 <<EOF
up: Docker has ${ncpu} CPUs and ${mem_mib} MiB of memory.
    This platform needs at least ${MIN_CPUS} CPUs and ${MIN_MEMORY_MIB} MiB
    (recommended: ${RECOMMENDED_CPUS} CPUs and ${RECOMMENDED_MEMORY_MIB} MiB).

    Below this the symptom is not an out-of-memory error -- it is the API server
    going unreachable while the controller manager and scheduler lose leader
    election, which reads like a broken cluster and is not one.

    Docker Desktop -> Settings -> Resources.
EOF
	exit 1
fi

if [ "$ncpu" -lt "$RECOMMENDED_CPUS" ] || [ "$mem_mib" -lt "$RECOMMENDED_MEMORY_MIB" ]; then
	printf '\nup: NOTE -- %s CPUs / %s MiB is under the recommended %s / %s.\n' \
		"$ncpu" "$mem_mib" "$RECOMMENDED_CPUS" "$RECOMMENDED_MEMORY_MIB" >&2
	printf 'up: the staged install below is what makes this size viable; expect it to be slow.\n\n' >&2
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
# Wait for the container to be RUNNING, not Ready. Its readiness probe requests
# the repository over the smart-HTTP handshake, which is the right probe -- a
# server that is listening but cannot run CGI answers "/" happily and fails
# every sync. But it means the pod cannot go Ready until something has been
# published, and publishing needs a running pod to exec into. Waiting for Ready
# here deadlocks the bring-up against its own probe.
step "Building and starting the in-cluster Git server"
./scripts/git-server-image.sh
kubectl apply -f bootstrap/git-server.yaml >/dev/null
deadline=$((SECONDS + 300))
until [ "$(kubectl -n platform-system get pod -l app.kubernetes.io/name=git-server \
		-o jsonpath='{.items[0].status.containerStatuses[0].state}' 2>/dev/null | grep -c running)" = "1" ]; do
	if [ "$SECONDS" -ge "$deadline" ]; then
		echo "up: the Git server container did not start within 300s" >&2
		kubectl -n platform-system get pods >&2
		kubectl -n platform-system describe pod -l app.kubernetes.io/name=git-server 2>&1 | tail -20 >&2
		exit 1
	fi
	sleep 3
done
echo "    Git server is running. Not Ready yet -- it has no repository to serve."

# --- 4. the sample workload's image -------------------------------------------
step "Building the sample workload image"
./scripts/sample-image.sh

# --- 5. publish ---------------------------------------------------------------
step "Publishing this repository to the in-cluster Git server"
./scripts/publish.sh
echo "    Waiting for the Git server to report Ready now that it has a repository"
kubectl -n platform-system wait --for=condition=available deploy/git-server --timeout=180s >/dev/null

# --- 6. install the platform, one component at a time -------------------------
# Argo CD sync waves order when the child Application OBJECTS are created. They
# do not stop a child from syncing its own contents while the next child is
# created, so wave annotations alone still let every Helm chart unpack at once --
# which is exactly the load that starved this control plane into losing leader
# election.
#
# Serializing for real means one component in flight at a time: apply a child,
# block until it is actually Synced and Healthy, only then create the next. The
# manifests are unchanged and still declare their own waves; this just refuses
# to run them concurrently.
step "Installing the platform in dependency order, one component at a time"
echo "    (each component must be Ready before the next is created)"

for manifest in platform/applications/*.yaml; do
	name="$(app_name "$manifest")"
	[ -n "$name" ] || { echo "up: could not read metadata.name from ${manifest}" >&2; exit 1; }
	printf '\n    --- %s (%s) ---\n' "$name" "$(basename "$manifest")"
	apply_manifest "$manifest"
	./scripts/wait-for-app.sh "$name" "${APP_TIMEOUT_SECONDS:-600}"
done

# --- 7. hand over to Argo CD --------------------------------------------------
# Every child already exists and already matches what this root syncs, so the
# root adopts them without re-installing anything. Steady state is unchanged:
# adding a component is still a file in platform/applications/ and a commit.
step "Applying the app-of-apps root -- Argo CD takes over from here"
apply_manifest bootstrap/root-application.yaml

step "Confirming every Application is Synced and Healthy"
./scripts/wait-for-platform.sh "${UP_TIMEOUT_SECONDS:-900}"

./scripts/status.sh
