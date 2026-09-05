#!/usr/bin/env bash
#
# Waits for ONE Argo CD Application to reach Synced + Healthy, then exits 0.
# Exits non-zero on anything else, including "I could not tell".
#
# This is the primitive that makes the staged bring-up in up.sh real. Argo CD
# sync waves order when child Application OBJECTS are created; they do not stop
# the children from syncing their own contents in parallel once created. Five
# Helm charts unpacking at once is what starves this control plane, so up.sh
# applies one child at a time and blocks here until it is actually Ready.
#
# The fail-closed discipline is the same as wait-for-platform.sh and matters for
# the same reason: a failed kubectl prints nothing, and nothing parses as "not
# Synced" just as easily as it parses as "converged". An unreachable API server
# at the deadline is a failure, never a pass.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP="${1:?usage: wait-for-app.sh <application> [deadline-seconds]}"
DEADLINE_SECONDS="${2:-600}"
INTERVAL=10

start=$SECONDS
unreachable=0

while :; do
	elapsed=$((SECONDS - start))

	# One call for both fields, so sync and health can never be read a few
	# seconds apart and describe two different moments.
	if ! status="$(kubectl -n argocd get application "$APP" \
			-o jsonpath='{.status.sync.status}{" "}{.status.health.status}' \
			--request-timeout=20s 2>/dev/null)"; then
		# Covers both "API unreachable" and "not created yet". Neither is
		# convergence, and neither is allowed to end the wait early.
		unreachable=$((unreachable + 1))
		printf '      %3ds  %s: cannot read status (%d consecutive) -- NOT counted as Ready\n' \
			"$elapsed" "$APP" "$unreachable" >&2
		if [ "$elapsed" -ge "$DEADLINE_SECONDS" ]; then
			printf '\nwait-for-app: FAILED -- %s unreadable at the deadline (%ds).\n' \
				"$APP" "$elapsed" >&2
			exit 1
		fi
		sleep "$INTERVAL"
		continue
	fi
	unreachable=0

	sync="${status%% *}"
	health="${status##* }"

	printf '      %3ds  %s: %s / %s\n' \
		"$elapsed" "$APP" "${sync:-<none>}" "${health:-<none>}"

	if [ "$sync" = 'Synced' ] && [ "$health" = 'Healthy' ]; then
		printf '      %s is Ready (%ds)\n' "$APP" "$elapsed"
		exit 0
	fi

	if [ "$elapsed" -ge "$DEADLINE_SECONDS" ]; then
		printf '\nwait-for-app: FAILED -- %s did not become Ready within %ds (last: %s/%s)\n' \
			"$APP" "$elapsed" "${sync:-<none>}" "${health:-<none>}" >&2
		kubectl -n argocd get app "$APP" \
			-o jsonpath='{.status.operationState.phase}: {.status.operationState.message}{"\n"}' \
			--request-timeout=20s 2>/dev/null | tr -d '\000' | head -4 | sed 's/^/    /' >&2
		kubectl -n argocd get app "$APP" -o json --request-timeout=20s 2>/dev/null \
			| jq -r '.status.conditions[]? | "    cond \(.type): \(.message)"' 2>/dev/null | head -4 >&2
		exit 1
	fi

	sleep "$INTERVAL"
done
