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

# Docker's image store. Docker Desktop 4.89 enables the containerd snapshotter
# by default, and it reports itself as Driver "overlayfs" rather than the
# classic "overlay2". Under it, pulling a multi-architecture reference stores an
# OCI index whose non-host manifests are referenced but whose blobs are not
# fetched. `kind load docker-image` imports with --all-platforms, walks those
# manifests, and dies on the first digest that was never pulled:
#
#   ctr: content digest sha256:8059...: not found
#
# It fails at step 4, several minutes in, on a machine that has already built a
# cluster and installed Argo CD -- and it fails only for PULLED images, so an
# image built locally loads fine and the cause looks like kind rather than
# Docker. Refuse up front and name the setting.
driver="$(docker system info --format '{{.Driver}}' 2>/dev/null || echo 'unknown')"
if [ "$driver" != 'overlay2' ]; then
	cat >&2 <<EOF
up: Docker's image store is "${driver}", not "overlay2".

    This is Docker Desktop's containerd image store. With it enabled, a
    multi-architecture image is stored as an index whose other platforms are
    referenced but not pulled, and \`kind load docker-image\` -- which imports
    with --all-platforms -- fails on the missing blob:

      ctr: content digest sha256:...: not found

    The failure lands minutes into \`make up\`, after the cluster and Argo CD
    are already installed, and only for images that were pulled rather than
    built, so it reads as a kind bug and is not one.

    Fix: Docker Desktop -> Settings -> General, and turn OFF
    "Use containerd for pulling and storing images". Then restart Docker and
    confirm with:

      docker system info --format '{{.Driver}}'      # expect: overlay2
EOF
	exit 1
fi

# --- the total wall-clock ceiling ----------------------------------------------
# APP_TIMEOUT_SECONDS bounds one component and wait-for-platform.sh bounds the
# final settle. Nothing bounded their SUM. Ten components each finishing one
# second inside a 900s per-app deadline is a bring-up of nearly three hours that
# never trips a single check: every individual deadline is honoured and the
# ceiling versions.env advertises is not enforced anywhere. UP_TIMEOUT_SECONDS
# was the name of a limit on the last wait, not on the run.
#
# So: one watchdog over the whole script, at UP_TIMEOUT_SECONDS.
#
# WHAT IT DOES ON TIMEOUT. It dumps first and kills second, and the order is the
# point. A bring-up killed silently at the ceiling tells you only that it was
# slow, which is the one thing you already knew. What is needed is what it was
# still waiting on and what the control plane looked like while it waited --
# Application sync/health, every pod not Running or Completed, control-plane
# restart counts, recent Warning events, and the node's own conditions. That is
# the difference between "it timed out" and the leader-election collapse this
# platform actually fails with.
#
# The dump goes to stderr AND to .work/up-timeout.log, because the terminal that
# ran a three-hour bring-up is not reliably the terminal anyone reads afterwards.
#
# Exit 124, the GNU timeout convention, so a caller can tell "ran out of wall
# clock" from "a component failed" without parsing output.
UP_DEADLINE="${UP_TIMEOUT_SECONDS:-900}"
UP_TIMEOUT_DUMP='.work/up-timeout.log'

up_dump_state() {
	mkdir -p .work
	{
		printf '\n=== up: WALL-CLOCK CEILING HIT after %ss (UP_TIMEOUT_SECONDS=%s) ===\n' \
			"$1" "$UP_DEADLINE"
		printf '\n--- Applications ---\n'
		kubectl get applications -n argocd \
			-o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
			--request-timeout=20s 2>&1
		printf '\n--- pods not Running/Completed, all namespaces ---\n'
		kubectl get pods -A --request-timeout=20s 2>&1 \
			| awk 'NR == 1 || ($4 != "Running" && $4 != "Completed")'
		printf '\n--- control plane, with restart counts ---\n'
		kubectl get pods -n kube-system \
			-o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount' \
			--request-timeout=20s 2>&1
		printf '\n--- recent Warning events ---\n'
		kubectl get events -A --field-selector type=Warning \
			--sort-by=.lastTimestamp --request-timeout=20s 2>&1 | tail -25
		printf '\n--- node conditions ---\n'
		kubectl describe node "${KIND_CLUSTER_NAME}-control-plane" --request-timeout=20s 2>&1 \
			| sed -n '/^Conditions:/,/^Addresses:/p'
		printf '\n=== end of timeout dump ===\n'
	} 2>&1 | tee -a "$UP_TIMEOUT_DUMP" >&2
}

# The sleep is a CHILD of the watchdog subshell and does not die with it, so its
# pid is recorded here for up_cleanup to reap. See the comment there for what a
# surviving sleep does to anything that pipes this script's output.
UP_WD_SLEEP_PIDFILE="$(mktemp "${TMPDIR:-/tmp}/up-watchdog.XXXXXX")"
UP_WD_DISARM="${UP_WD_SLEEP_PIDFILE}.disarm"

up_main_pid=$$
(
	sleep "$UP_DEADLINE" &
	wd_sleep=$!
	printf '%s' "$wd_sleep" > "$UP_WD_SLEEP_PIDFILE"
	wait "$wd_sleep" 2>/dev/null
	# Disarmed while this was asleep: the run finished and up_cleanup is tearing
	# the watchdog down. Firing now would dump a timeout and kill a bring-up that
	# had already succeeded.
	[ -f "$UP_WD_DISARM" ] && exit 0
	wd_self=$BASHPID
	up_dump_state "$UP_DEADLINE"
	printf '\nup: killing the bring-up at the %ss ceiling. State above and in %s\n' \
		"$UP_DEADLINE" "$UP_TIMEOUT_DUMP" >&2
	# Kill what the script is BLOCKED IN before signalling the script itself.
	# bash defers a trap until the current foreground command returns, so TERMing
	# the shell while it sits in `kubectl wait` does nothing until that wait ends
	# on its own -- which, at the ceiling, is precisely what is not going to
	# happen. The pending trap would then lose the race to the SIGKILL below and
	# the run would die 137 with no exit code anyone can act on. Killing the
	# descendant lets the foreground command return, the TERM handler runs, and
	# the script exits 124 as documented.
	for d in $(pgrep -P "$up_main_pid" 2>/dev/null); do
		[ "$d" = "$wd_self" ] && continue
		pkill -TERM -P "$d" 2>/dev/null || true
		kill -TERM "$d" 2>/dev/null || true
	done
	kill -TERM "$up_main_pid" 2>/dev/null || true
	# Last resort only. Reaching this means the TERM handler never ran.
	sleep 15
	kill -KILL "$up_main_pid" 2>/dev/null || true
) &
up_watchdog_pid=$!

# The watchdog outlives a successful run unless something reaps it, and a leaked
# `sleep 900` that later kills an unrelated process is a worse bug than the one
# this fixes.
up_cleanup() {
	# Disarm BEFORE killing anything. Killing the sleep is what wakes the
	# watchdog, and a watchdog that wakes without this flag proceeds straight
	# into dumping state and killing a run that just succeeded.
	: > "$UP_WD_DISARM" 2>/dev/null || true
	if [ -n "${up_watchdog_pid:-}" ]; then
		kill "$up_watchdog_pid" 2>/dev/null || true
	fi
	# Then the sleep. `kill` on the subshell does NOT take its children with it:
	# the sleep is orphaned to init and keeps the stdout and stderr it inherited
	# OPEN. Anything that reads this script through a pipe -- CI, `make up | tee`,
	# any wrapper -- then blocks waiting for EOF that cannot come until the full
	# ceiling elapses, on a run that already finished. Observed: a 288s bring-up
	# that a wrapper reported as 653s because a leaked `sleep 900` still held the
	# pipe.
	local wd_sleep
	wd_sleep="$(cat "$UP_WD_SLEEP_PIDFILE" 2>/dev/null || true)"
	if [ -n "$wd_sleep" ]; then
		kill "$wd_sleep" 2>/dev/null || true
	fi
	if [ -n "${up_watchdog_pid:-}" ]; then
		wait "$up_watchdog_pid" 2>/dev/null || true
		up_watchdog_pid=''
	fi
	rm -f "$UP_WD_SLEEP_PIDFILE" "$UP_WD_DISARM" 2>/dev/null || true
}
trap up_cleanup EXIT
trap 'printf "\nup: terminated at the %ss wall-clock ceiling\n" "$UP_DEADLINE" >&2; exit 124' TERM

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
