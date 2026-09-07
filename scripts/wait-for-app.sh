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

# A ComparisonError that names a missing path is not a slow sync. Argo CD cannot
# resolve the source at all, caches that failure, and returns the cached error on
# every later comparison -- so the Application sits Unknown until the deadline no
# matter how generous the deadline is. Observed in CI: argocd-repositories held
# Unknown/Healthy from 10s to 905s on
#
#   Manifest generation error (cached): platform/config/argocd: app path does not exist
#
# and burned seventeen minutes proving nothing. Waiting is the wrong response to
# an error that cannot change while you wait.
#
# Told apart from a transient by REPEATING, not by the message alone. A
# comparison can legitimately fail for a moment while publish.sh is replacing the
# repository under it, and that recovers on the next poll; a cached permanent
# error does not. Requiring the same permanent-looking message on this many
# CONSECUTIVE polls keeps a blip from turning into a red build, and still fails
# in well under a minute instead of at the ceiling.
PERMANENT_STRIKES=3

start=$SECONDS
unreachable=0
permanent=0
last_cond=''
cond_repeats=0
cond_since=0

# Prints a condition the FIRST time it is seen and every time it CHANGES, never
# on a repeat. A stalled Application is polled every INTERVAL seconds for as long
# as the deadline allows -- argocd-repositories once sat unsynced for 373s, which
# is 37 polls -- and printing the same sentence 37 times buries it in its own
# repetition. Instead the message is printed once and its run is closed out with
# how long it held, so a slow run reads as a short list of distinct states with
# durations rather than a wall of identical lines.
flush_cond() {
	[ -n "$last_cond" ] || return 0
	[ "$cond_repeats" -gt 1 ] || { last_cond=''; cond_repeats=0; return 0; }
	printf '      %3ds  %s: ^ that condition held for %d polls (%ds)\n' \
		"$elapsed" "$APP" "$cond_repeats" "$((elapsed - cond_since))" >&2
	last_cond=''; cond_repeats=0
}

note_cond() {
	local c="$1"
	if [ -z "$c" ]; then flush_cond; return 0; fi
	if [ "$c" = "$last_cond" ]; then cond_repeats=$((cond_repeats + 1)); return 0; fi
	flush_cond
	printf '      %3ds  %s: %s\n' "$elapsed" "$APP" "$c" >&2
	last_cond="$c"; cond_repeats=1; cond_since="$elapsed"
}

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
		flush_cond
		printf '      %s is Ready (%ds)\n' "$APP" "$elapsed"
		exit 0
	fi

	# Read the error conditions only while unsynced. Deliberately a second call
	# rather than folding everything into one `-o json`: the single-call rule
	# above exists so sync and health describe the same moment, and that still
	# holds. A condition read a few seconds later is diagnostic, not a verdict.
	#
	# If jq is missing this yields an empty string, the case below resets the
	# counter, and the script behaves exactly as it did before -- no fast path,
	# no false failure.
	if [ "$sync" != 'Synced' ]; then
		cond="$(kubectl -n argocd get application "$APP" -o json --request-timeout=20s 2>/dev/null \
			| jq -r '[.status.conditions[]? | select(.type | test("Error")) | .message] | join(" | ")' 2>/dev/null || true)"

		# Say what Argo CD actually said. This read already happened on every poll
		# and its result was printed only when it matched the pattern below, so
		# every OTHER condition was fetched and discarded. That is why 9ed392c
		# closes with the root cause of the 905s incident still open: the evidence
		# was in hand ~37 times and thrown away each time. argocd-repositories has
		# since sat at Unknown/Healthy for 373s on a runner with the fast-fail
		# never firing, which means the message was not "app path does not exist"
		# and nobody knows what it was.
		#
		# Purely additive. The case below is untouched and the fast-fail behaves
		# exactly as before; this only stops the diagnosis being deleted on the
		# way past.
		note_cond "$cond"

		case "$cond" in
			*'app path does not exist'*)
				permanent=$((permanent + 1))
				printf '      %3ds  %s: source cannot resolve -- strike %d of %d\n' \
					"$elapsed" "$APP" "$permanent" "$PERMANENT_STRIKES" >&2
				if [ "$permanent" -ge "$PERMANENT_STRIKES" ]; then
					printf '\nwait-for-app: FAILED FAST -- %s cannot resolve its source (%ds of a %ds deadline)\n' \
						"$APP" "$elapsed" "$DEADLINE_SECONDS" >&2
					printf '    %s\n' "$cond" >&2
					printf '\n    This is a permanent error, not a slow sync. The path is not present in\n' >&2
					printf '    the revision Argo CD resolved, and Argo caches that failure -- waiting\n' >&2
					printf '    out the deadline cannot change it. Check that scripts/publish.sh pushed\n' >&2
					printf '    the revision you expect, and that the path exists in THAT revision.\n' >&2
					exit 1
				fi
				;;
			*)
				permanent=0
				;;
		esac
	else
		permanent=0
	fi

	if [ "$elapsed" -ge "$DEADLINE_SECONDS" ]; then
		flush_cond
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
