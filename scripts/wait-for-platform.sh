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
EXPECTED="${EXPECTED_APPS:-10}"
INTERVAL=15

# The same permanent error wait-for-app.sh already fails fast on, at the platform
# level. That one was written after argocd-repositories held Unknown/Healthy from
# 10s to 905s in the upgrade job on
#
#   Manifest generation error (cached): platform/config/argocd: app path does not exist
#
# Argo CD caches a manifest generation failure and returns the cached error on
# every later comparison, so the Application cannot recover while you poll it and
# a longer deadline buys nothing but wall clock. wait-for-app.sh covers the
# per-component waits during bring-up; this loop is the whole-platform gate and
# had no equivalent, so the same error costs a full UP_TIMEOUT here.
#
# Told apart from a transient by REPEATING rather than by the message: a
# comparison can fail for a moment while publish.sh is replacing the repository
# underneath it, and recovers on the next poll. Same threshold as wait-for-app.sh
# so the two behave alike.
PERMANENT_STRIKES=3

# A distinct code, and the reason is classification rather than tidiness. A
# caller that reads "convergence failed" and concludes "then it must be an
# upstream compatibility problem" would be wrong here: a source that cannot
# resolve is the re-point having failed, which is ours. Collapsing it into the
# generic exit 1 is what would make that reasoning unsound, so it gets its own
# code and callers that classify can tell the two apart.
E_UNRESOLVABLE=4

# How long the converged state must HOLD before it is believed. Zero keeps the
# old behaviour of returning on the first sample that looks right.
#
# Why 30 and not 0: Synced+Healthy is a verdict about an instant, and there are
# instants during an upgrade when it is true and about to stop being true -- a
# sync that has finished while its PostSync hook has not started, or the moment
# before selfHeal notices drift. Both transitions are seconds wide, not minutes.
# At INTERVAL=15 a 30s window is three independent observations, so a single
# stale read cannot carry it.
#
# Why not longer: the next thing a longer window would buy is catching Argo CD's
# own poll re-resolving to a different revision, which is minutes away by
# default. That is worth catching and is not worth minutes of dead runtime here,
# because assert-published-revision.sh checks the resolved revision directly.
SETTLE="${SETTLE_SECONDS:-0}"

start=$SECONDS
unreachable=0
last_table=''
permanent=0
settled_since=''

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
		permanent=0
		if [ "$SETTLE" -eq 0 ]; then
			printf '\nwait: converged in %ds\n' "$elapsed"
			exit 0
		fi
		if [ -z "$settled_since" ]; then
			settled_since="$elapsed"
			printf '  %3ds  all %d Synced+Healthy -- holding %ds to confirm it sticks\n' \
				"$elapsed" "$ready" "$SETTLE"
		elif [ "$((elapsed - settled_since))" -ge "$SETTLE" ]; then
			printf '\nwait: converged in %ds and held for %ds\n' \
				"$settled_since" "$((elapsed - settled_since))"
			exit 0
		fi
	else
		# Losing the converged state restarts the window rather than shortening
		# it. A run that flaps has not converged, and averaging over the flap
		# would report the thing this window exists to catch as a pass.
		if [ -n "$settled_since" ]; then
			printf '  %3ds  converged state did not hold -- settle window restarted\n' "$elapsed" >&2
			settled_since=''
		fi

		# Only the unsynced Applications are asked for conditions, and only while
		# unsynced. A second kubectl call on purpose: the table above must
		# describe one moment, and a condition read seconds later is diagnostic
		# rather than a verdict. If jq is absent this yields nothing, the counter
		# resets, and the loop behaves exactly as it did before -- no fast path
		# and, more importantly, no false failure.
		hit=''
		while read -r app; do
			[ -n "$app" ] || continue
			cond="$(kubectl -n argocd get application "$app" -o json --request-timeout=20s 2>/dev/null \
				| jq -r '[.status.conditions[]? | select(.type | test("Error")) | .message] | join(" | ")' 2>/dev/null || true)"
			case "$cond" in
				*'app path does not exist'*) hit="${hit}${hit:+; }${app}: ${cond}" ;;
			esac
		done <<<"$(printf '%s\n' "$table" | awk '$2!="Synced" {print $1}')"

		if [ -n "$hit" ]; then
			permanent=$((permanent + 1))
			printf '  %3ds  a source cannot resolve -- strike %d of %d\n' \
				"$elapsed" "$permanent" "$PERMANENT_STRIKES" >&2
			if [ "$permanent" -ge "$PERMANENT_STRIKES" ]; then
				printf '\nwait: FAILED FAST -- a source cannot resolve (%ds of a %ds deadline)\n' \
					"$elapsed" "$DEADLINE_SECONDS" >&2
				printf '    %s\n' "$hit" >&2
				printf '\n    This is a permanent error, not a slow sync. Argo CD caches the\n' >&2
				printf '    manifest generation failure, so waiting out the deadline cannot\n' >&2
				printf '    change it. Check that scripts/publish.sh pushed the revision you\n' >&2
				printf '    expect, and that the path exists in THAT revision.\n' >&2
				exit "$E_UNRESOLVABLE"
			fi
		else
			permanent=0
		fi
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
