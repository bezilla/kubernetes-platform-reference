#!/usr/bin/env bash
#
# Waits for the Envoy DATA PLANE to finish rolling. Not the controller.
#
# Everything else in this repository asks Argo CD whether the platform is ready,
# and for the edge that question has a gap in it. The envoy-gateway Application
# syncs the gateway-helm chart into envoy-gateway-system, which installs the
# CONTROLLER. The thing that actually terminates TLS is a second Deployment,
# envoy-platform-edge-platform-<hash>, which that controller creates in response
# to the Gateway resource. It is in no Application's resource tree:
#
#   envoy-gateway                          argocd-instance=envoy-gateway
#   envoy-platform-edge-platform-96f3a023  argocd-instance=<none>
#
# So wait-for-platform.sh cannot see it -- it reads Applications. The settle
# window cannot see it -- it samples Applications. assert-installed-versions.sh
# cannot see it -- its eight Deployments include envoy-gateway-system/
# envoy-gateway, which is the controller. Every green signal the upgrade test
# has can be true while the edge is not listening.
#
# That is not hypothetical. Run 34143528837 rolled back cleanly, converged, held
# the settle window for 31s, verified all eight Deployments on the previous
# versions -- and then demo-https.sh failed on a gateway that had not finished
# coming back, because rolling envoy-gateway v1.9.1 -> v1.9.0 rebuilds the proxy
# and nothing waited for it. The run before won the same race. A test whose
# result depends on which side of a rollout it lands on is not testing anything.
#
# Same rollout conditions assert-installed-versions.sh uses, and for the same
# reason: observedGeneration caught up, and replicas == updated == ready ==
# available == desired. status.replicas is the one that matters and the one a
# first pass leaves out -- during a surge the other counts can all equal desired
# while the old ReplicaSet is still there.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

E_NOTREADY=1            # read it, and the proxy has not finished rolling
E_PRECONDITION=2        # could not run: no cluster, no proxy, no tooling

DEADLINE="${1:-${EDGE_TIMEOUT_SECONDS:-300}}"
INTERVAL=5
NS='envoy-gateway-system'
GATEWAY_MANIFEST='platform/config/edge/20-gateway.yaml'

for t in kubectl jq yq; do
	command -v "$t" >/dev/null 2>&1 || {
		echo "wait-for-edge: $t is not on PATH" >&2; exit "$E_PRECONDITION"; }
done
kubectl cluster-info >/dev/null 2>&1 || {
	echo "wait-for-edge: no reachable cluster" >&2; exit "$E_PRECONDITION"; }

# Selected by the owning-gateway labels rather than by name: the name carries a
# hash of the Gateway's identity and is not stable across changes to it. The
# gateway's name and namespace come from the manifest so this tracks the repo
# rather than a literal copied out of one cluster.
gw_name="$(yq -r 'select(.kind == "Gateway") | .metadata.name' "$GATEWAY_MANIFEST" 2>/dev/null | head -1)"
gw_ns="$(yq -r 'select(.kind == "Gateway") | .metadata.namespace' "$GATEWAY_MANIFEST" 2>/dev/null | head -1)"
[ -n "$gw_name" ] && [ -n "$gw_ns" ] || {
	echo "wait-for-edge: could not read the Gateway name/namespace from ${GATEWAY_MANIFEST}" >&2
	exit "$E_PRECONDITION"; }
SEL="gateway.envoyproxy.io/owning-gateway-name=${gw_name},gateway.envoyproxy.io/owning-gateway-namespace=${gw_ns}"
printf '    proxy selector: %s\n' "$SEL"

dump_state() {
	printf '\nwait-for-edge: state at the deadline:\n' >&2
	kubectl -n "$NS" get deploy -l "$SEL" -o wide 2>&1 | sed 's/^/    /' >&2
	kubectl -n "$NS" get pods -l "$SEL" -o wide 2>&1 | sed 's/^/    /' >&2
	kubectl -n "$NS" describe deploy -l "$SEL" 2>&1 | tail -20 | sed 's/^/    /' >&2
}

start=$SECONDS
while :; do
	elapsed=$((SECONDS - start))

	if ! rows="$(kubectl -n "$NS" get deploy -l "$SEL" -o json 2>/dev/null | jq -r '
		.items[] | [ .metadata.name,
		             (.metadata.generation // 0),
		             (.status.observedGeneration // -1),
		             (.spec.replicas // 1),
		             (.status.updatedReplicas // 0),
		             (.status.readyReplicas // 0),
		             (.status.availableReplicas // 0),
		             (.status.replicas // 0),
		             (.status.unavailableReplicas // 0) ] | @tsv')"; then
		echo "wait-for-edge: could not query the proxy Deployment" >&2
		exit "$E_PRECONDITION"
	fi

	# No proxy is not "ready". If the controller has not created it, or the
	# selector matches nothing, that is a finding rather than a pass -- the same
	# "could not read" versus "read it and it is wrong" distinction the rest of
	# this repository makes.
	if [ -z "$rows" ]; then
		if [ "$elapsed" -ge "$DEADLINE" ]; then
			printf '\nwait-for-edge: FAILED -- no proxy Deployment matched %s after %ds\n' "$SEL" "$elapsed" >&2
			dump_state
			exit "$E_PRECONDITION"
		fi
		printf '  %3ds  no proxy Deployment yet\n' "$elapsed"
		sleep "$INTERVAL"; continue
	fi

	pending=''
	while IFS=$'\t' read -r name gen obs desired updated ready avail total unavail; do
		[ -n "$name" ] || continue
		if [ "$obs" != "$gen" ] || [ "$updated" != "$desired" ] || [ "$ready" != "$desired" ] \
		   || [ "$avail" != "$desired" ] || [ "$total" != "$updated" ] || [ "$unavail" != "0" ]; then
			pending="${pending} ${name}(gen ${gen}/obs ${obs} desired ${desired} updated ${updated} ready ${ready} avail ${avail} replicas ${total} unavail ${unavail})"
		fi
	done <<<"$rows"

	if [ -z "$pending" ]; then
		printf '    \033[32mok\033[0m   the edge proxy finished rolling (%ds)\n' "$elapsed"
		exit 0
	fi

	if [ "$elapsed" -ge "$DEADLINE" ]; then
		printf '\nwait-for-edge: FAILED -- the proxy did not finish rolling within %ds:%s\n' "$elapsed" "$pending" >&2
		dump_state
		exit "$E_NOTREADY"
	fi
	printf '  %3ds  rolling:%s\n' "$elapsed" "$pending"
	sleep "$INTERVAL"
done
