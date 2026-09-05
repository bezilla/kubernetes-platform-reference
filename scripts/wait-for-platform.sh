#!/usr/bin/env bash
#
# Waits for every Argo CD Application to reach Synced + Healthy, then exits 0.
# Exits non-zero on anything else, including "I could not tell".
#
# The fail-closed part is the point. The obvious loop --
#
#     until [ "$(kubectl ... | wc -l)" = 0 ]; do sleep; done
#
# -- reports success when kubectl ITSELF fails, because a failed command prints
# nothing and nothing has a count of zero. This cluster starves its own API
# server during a heavy install, so that is not a theoretical case: it produced
# a confident "ALL CONVERGED" against an API server that had stopped answering.
# Every check here distinguishes "not converged" from "could not ask", and an
# unreachable API at the deadline is a failure, never a pass.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

DEADLINE_SECONDS="${1:-900}"
EXPECTED="${EXPECTED_APPS:-9}"
INTERVAL=15

start=$SECONDS
unreachable=0
last_table=''

while :; do
	elapsed=$((SECONDS - start))

	if ! table="$(kubectl -n argocd get applications --no-headers 2>/dev/null)"; then
		unreachable=$((unreachable + 1))
		printf '  %3ds  API server unreachable (%d consecutive) -- NOT counted as converged\n' \
			"$elapsed" "$unreachable" >&2
		if [ "$elapsed" -ge "$DEADLINE_SECONDS" ]; then
			printf '\nwait: FAILED -- API server unreachable at the deadline.\n' >&2
			printf 'wait: the control plane is usually starved, not broken. Check Docker memory:\n' >&2
			printf 'wait:   docker stats --no-stream %s-control-plane\n' "$KIND_CLUSTER_NAME" >&2
			exit 1
		fi
		sleep "$INTERVAL"
		continue
	fi
	unreachable=0

	total="$(printf '%s\n' "$table" | grep -c . || true)"
	ready="$(printf '%s\n' "$table" | awk '$2=="Synced" && $3=="Healthy"' | grep -c . || true)"
	last_table="$table"

	printf '  %3ds  %d/%d Synced+Healthy (expecting %d applications)\n' \
		"$elapsed" "$ready" "$total" "$EXPECTED"

	if [ "$total" -ge "$EXPECTED" ] && [ "$ready" -eq "$total" ]; then
		printf '\nwait: converged in %ds\n' "$elapsed"
		exit 0
	fi

	if [ "$elapsed" -ge "$DEADLINE_SECONDS" ]; then
		printf '\nwait: FAILED -- not converged after %ds\n\n' "$elapsed" >&2
		printf '%s\n' "$last_table" | sed 's/^/  /' >&2
		printf '\nwait: applications that did not converge:\n' >&2
		printf '%s\n' "$last_table" | awk '$2!="Synced" || $3!="Healthy" {print $1}' | while read -r app; do
			[ -z "$app" ] && continue
			printf '\n  --- %s ---\n' "$app" >&2
			kubectl -n argocd get app "$app" -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}{"\n"}' 2>/dev/null \
				| tr -d '\000' | head -4 | sed 's/^/    /' >&2
			kubectl -n argocd get app "$app" -o json 2>/dev/null \
				| jq -r '.status.resources[]? | select(.status!="Synced" and .status!=null) | "    out of sync: \(.kind)/\(.name)"' >&2
		done
		exit 1
	fi

	sleep "$INTERVAL"
done
