#!/usr/bin/env bash
#
# Asserts what is RUNNING, not what Argo CD was told to run.
#
# Every other gate in upgrade-test.sh reads desired state. Gate 1 waits for
# .spec.source.targetRevision on the child Applications, gate 3 compares that
# same field before and after; both read a string Argo CD was handed. Gate 2
# reads Argo CD's own Synced/Healthy verdict, which is its opinion of its own
# work. None of them opens a pod.
#
# That gap has already produced a false pass in this very script. Its header
# records the first version reporting "converged in 0s" with four components
# still on the versions they started on -- Applications Synced, Applications
# Healthy, and nothing upgraded. What caught it was the version assertion, and
# the version assertion reads desired state too. It caught that failure because
# the specs had not been rewritten either; a run where the specs move and the
# pods do not would have gone green.
#
# So this reads the image off the running containers. A pod is the one place
# that cannot be told a version it is not running.
#
# WHAT IT READS, and why Deployments only:
# The four charts also render Jobs and test Pods. The Jobs are Helm hooks with
# hook-delete-policy set, so they are gone by the time anything could assert on
# them. The test Pods are `helm.sh/hook: test`, which Argo CD does not create at
# all -- and they are the reason a naive sweep fails: both of them run
# ghcr.io/kyverno/readiness-checker:latest, in the old chart and the new one
# alike. A container pinned to `latest` cannot demonstrate a version change,
# and asserting that every image moved would fail on the two containers that
# never can. The Deployments are the workloads that persist, and all eight of
# their containers carry a real version.
#
# status.containerStatuses rather than spec.containers: the spec is what the pod
# asked for, which during a rollout is already the new image on a pod that has
# not started it. containerStatuses is the runtime's report of what it actually
# pulled and ran.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

# Exit codes, following demo-isolation.sh. The distinction is required rather
# than decorative: a Deployment that could not be queried and a Deployment still
# running last week's image are different findings, and collapsing them into
# exit 1 reports a broken kubeconfig as a failed upgrade.
E_FAILED=1              # read it, and it is running the wrong version
E_PRECONDITION=2        # could not run: no cluster, no such workload, no tooling
E_HARNESS=3             # could not finish: the wait ran out with pods still rolling

# 0 means one pass and no waiting, which is what a probe wants. Anything else is
# a hard ceiling; this never polls forever.
DEADLINE="${1:-${ASSERT_TIMEOUT_SECONDS:-300}}"
INTERVAL=10

# The image tag is the component's APP version, which for two of these four is
# not the chart version -- Kyverno chart 3.9.0 ships app v1.19.0, the collector
# chart 0.172.0 ships app 0.159.0. versions.env carries both, so this compares
# against a pin rather than against a number derived here.
#
# namespace : deployment : container : expected-version variable
ROWS=(
	"cert-manager:cert-manager:cert-manager-controller:CERT_MANAGER_APP_VERSION"
	"cert-manager:cert-manager-webhook:cert-manager-webhook:CERT_MANAGER_APP_VERSION"
	"cert-manager:cert-manager-cainjector:cert-manager-cainjector:CERT_MANAGER_APP_VERSION"
	"envoy-gateway-system:envoy-gateway:envoy-gateway:ENVOY_GATEWAY_APP_VERSION"
	"kyverno:kyverno-admission-controller:kyverno:KYVERNO_APP_VERSION"
	"kyverno:kyverno-background-controller:controller:KYVERNO_APP_VERSION"
	"kyverno:kyverno-reports-controller:controller:KYVERNO_APP_VERSION"
	"platform-observability:otel-collector-opentelemetry-collector:opentelemetry-collector:OTEL_COLLECTOR_APP_VERSION"
)

command -v kubectl >/dev/null 2>&1 || {
	echo "assert-installed-versions: kubectl is not on PATH" >&2; exit "$E_PRECONDITION"; }
kubectl cluster-info >/dev/null 2>&1 || {
	echo "assert-installed-versions: no reachable cluster" >&2; exit "$E_PRECONDITION"; }

# Reads every RUNNING pod of one Deployment and prints the image its named
# container is actually running, one per line. Prints nothing and returns
# non-zero when it could not ask -- which the caller must not read as "matches".
running_images() {
	local ns="$1" dep="$2" ctr="$3" sel
	# The single quotes are deliberate: $k and $v are Go template variables that
	# kubectl expands, not shell variables.
	# shellcheck disable=SC2016
	sel="$(kubectl -n "$ns" get deploy "$dep" \
		-o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null)" || return 1
	[ -n "$sel" ] || return 1
	sel="${sel%,}"
	kubectl -n "$ns" get pods -l "$sel" --field-selector=status.phase=Running \
		-o jsonpath="{range .items[*]}{range .status.containerStatuses[?(@.name=='${ctr}')]}{.image}{\"\\n\"}{end}{end}" 2>/dev/null || return 1
}

dump_state() {
	printf '\nassert-installed-versions: state at the deadline:\n' >&2
	for row in "${ROWS[@]}"; do
		IFS=':' read -r ns dep ctr var <<<"$row"
		printf '\n  --- %s/%s (want %s) ---\n' "$ns" "$dep" "${!var}" >&2
		kubectl -n "$ns" get deploy "$dep" -o wide 2>&1 | sed 's/^/    /' >&2
		kubectl -n "$ns" get pods -o wide 2>&1 | sed 's/^/    /' >&2
	done
}

start=$SECONDS
while :; do
	elapsed=$((SECONDS - start))
	wrong=0; unreadable=0; pending=0; report=''

	for row in "${ROWS[@]}"; do
		IFS=':' read -r ns dep ctr var <<<"$row"
		want="${!var}"

		if ! images="$(running_images "$ns" "$dep" "$ctr")"; then
			unreadable=$((unreadable + 1))
			report="${report}$(printf '\n    \033[31mUNREADABLE\033[0m %s/%s -- could not query the Deployment or its pods' "$ns" "$dep")"
			continue
		fi
		if [ -z "$images" ]; then
			# No running pod yet. Distinct from a wrong image: mid-rollout this is
			# the normal state, so it is only a failure once the ceiling expires.
			pending=$((pending + 1))
			report="${report}$(printf '\n    ....       %s/%s -- no running pod yet' "$ns" "$dep")"
			continue
		fi

		bad=''; seen=0; observed=''
		while IFS= read -r img; do
			[ -n "$img" ] || continue
			seen=$((seen + 1))
			observed="${img##*:}"
			# Compare the tag, not the whole reference: the registry host is the
			# chart's business and may be mirrored, the tag is the version.
			[ "$observed" = "$want" ] || bad="${bad} ${img}"
		done <<<"$images"

		# Nothing was actually compared. That is not a pass. `images` can be
		# non-empty and still carry no image -- a pod whose containerStatuses
		# exist but whose .image is not yet populated emits a bare newline -- and
		# scoring that as ok is precisely the "could not read" result wearing a
		# "read it and it is right" label.
		if [ "$seen" -eq 0 ]; then
			pending=$((pending + 1))
			report="${report}$(printf '\n    ....       %s/%s -- running pod reports no image yet' "$ns" "$dep")"
			continue
		fi

		if [ -n "$bad" ]; then
			wrong=$((wrong + 1))
			report="${report}$(printf '\n    \033[31mWRONG\033[0m      %s/%s is running%s, expected :%s' "$ns" "$dep" "$bad" "$want")"
		else
			# Print what was OBSERVED, not what was wanted. An ok line that echoes
			# the expectation back proves only that the expectation exists.
			report="${report}$(printf '\n    \033[32mok\033[0m         %-52s %s (%d container(s))' "${ns}/${dep}" "$observed" "$seen")"
		fi
	done

	if [ "$wrong" -eq 0 ] && [ "$unreadable" -eq 0 ] && [ "$pending" -eq 0 ]; then
		printf '%b\n' "$report"
		printf '\n  \033[32mInstalled state matches the pins: %d containers across %d Deployments.\033[0m\n' \
			"${#ROWS[@]}" "${#ROWS[@]}"
		exit 0
	fi

	# A wrong image is settled, not pending. Waiting cannot turn a pod that is
	# running and reporting the old version into a pass -- only a new rollout
	# can, and by this point in upgrade-test.sh Argo CD has already declared the
	# Application Healthy. Failing immediately reports the real finding instead
	# of spending the ceiling to report it later.
	if [ "$wrong" -gt 0 ]; then
		printf '%b\n' "$report"
		printf '\nassert-installed-versions: FAILED -- %d component(s) are running a version that is not pinned.\n' "$wrong" >&2
		printf 'assert-installed-versions: desired state said upgraded; installed state did not move.\n' >&2
		exit "$E_FAILED"
	fi

	if [ "$DEADLINE" -eq 0 ] || [ "$elapsed" -ge "$DEADLINE" ]; then
		printf '%b\n' "$report"
		if [ "$unreadable" -gt 0 ]; then
			printf '\nassert-installed-versions: could not read %d Deployment(s) after %ds.\n' "$unreadable" "$elapsed" >&2
			dump_state
			exit "$E_PRECONDITION"
		fi
		printf '\nassert-installed-versions: %d Deployment(s) still had no running pod after %ds.\n' "$pending" "$elapsed" >&2
		dump_state
		exit "$E_HARNESS"
	fi

	printf '  %3ds  waiting on %d Deployment(s) with no running pod\n' "$elapsed" "$pending"
	sleep "$INTERVAL"
done
