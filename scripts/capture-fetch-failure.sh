#!/usr/bin/env bash
#
# Collects both sides of a failing git fetch, once, when one is detected.
#
# Every theory about the argocd-repositories stall so far came from reading an
# error string rather than the exchange, and two of them died on contact with
# the code. This exists so the next occurrence produces evidence instead of
# another mechanism.
#
# WHAT IT COLLECTS, AND WHICH SIDE IS THE PRIMARY SOURCE.
#
#   repo-server.log   THE primary source. Argo CD's repo-server is the client,
#                     and it is the only party that observed the truncation --
#                     the condition text on the Application comes from here.
#                     It logs at info and is chatty about git operations.
#
#   git-server-access.log   THE DISCRIMINATOR, and the reason it is worth
#                     collecting even though it is usually silent.
#
#                     lighttpd's %b records what it handed to the socket layer,
#                     not what the client received. Measured both ways on a live
#                     cluster:
#
#                       client cut at 43316 bytes  -> logged `200 364612` (full)
#                       server died mid-pack       -> logged `200 11947`  (short)
#
#                     So the byte count separates two causes that produce the
#                     same symptom at the client:
#
#                       FULL count  -> the server wrote the whole response. The
#                                      loss is downstream of it: the client, the
#                                      socket, or the path between. Nothing here
#                                      will tell you more.
#                       SHORT count -> the server itself stopped early, and this
#                                      is the first hard evidence of that. Read
#                                      git-server-all.log for git-http-backend's
#                                      stderr, which does report failures it
#                                      detects: "git-pack-objects died with
#                                      error" was captured that way.
#
#                     NOT filtered to go-git. Argo CD's repo-server uses go-git
#                     only for info/refs and shells out to the real git binary
#                     for the fetch itself, so the git-upload-pack POST -- the
#                     request that actually fails -- carries `git/2.53.0`.
#                     Filtering on go-git captured the ref probes and missed the
#                     exchange. Everything except the readiness probe is kept;
#                     the probe hits the same endpoint every 5 seconds and would
#                     otherwise be the whole file.
#
#   events            For both namespaces. Cheap, and rules out scheduling or
#                     eviction without another run.
#
# Enabling lighttpd's debug.log-* was tested and rejected: with
# debug.log-request-handling and debug.log-timeouts on, a forced mid-response
# disconnect produced only URI parsing and path resolution, nothing naming the
# abort -- ten extra lines per request, against a probe every five seconds, for
# no signal.
#
# EMPTY IS NOT THE SAME AS FAILED. Every collection records its own outcome in
# MANIFEST.txt as OK, EMPTY, or FAILED. "Captured nothing because there was
# nothing to capture" and "captured nothing because kubectl could not reach the
# cluster" produce identical files, and this repository has been bitten by that
# shape more than once.
#
# It runs AFTER the stall is detected, so it cannot change the timing of the
# exchange it is describing. Nothing here retries, sleeps, or waits.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

E_PRECONDITION=2

APP="${1:-unknown}"
ELAPSED="${2:-0}"
OUT="${CAPTURE_DIR:-.ci-artifacts/fetch-failure}"
MANIFEST="$OUT/MANIFEST.txt"

command -v kubectl >/dev/null 2>&1 || {
	echo "capture-fetch-failure: kubectl is not on PATH" >&2; exit "$E_PRECONDITION"; }
mkdir -p "$OUT" 2>/dev/null || {
	echo "capture-fetch-failure: could not create ${OUT}" >&2; exit "$E_PRECONDITION"; }

# Once per run. The condition persists for minutes and wait-for-app polls
# through all of it; capturing on every poll would overwrite the first and best
# view with progressively later ones.
if [ -e "$OUT/.captured" ]; then exit 0; fi
: > "$OUT/.captured"

note() { printf '%-34s %s\n' "$1" "$2" >> "$MANIFEST"; }

# Runs one collection and records OK / EMPTY / FAILED for it. The distinction is
# the point: a caller reading an empty file must be able to tell which happened.
collect() {  # label outfile command...
	local label="$1" out="$2"; shift 2
	if ! "$@" > "$out" 2>"$out.err"; then
		note "$label" "FAILED  (see $(basename "$out").err)"
		return 0
	fi
	if [ -s "$out" ]; then
		note "$label" "OK      $(wc -l < "$out" | tr -d ' ') lines"
	else
		note "$label" "EMPTY   (command succeeded and returned nothing)"
	fi
	rm -f "$out.err" 2>/dev/null
}

{
	printf 'capture-fetch-failure\n'
	printf 'application    %s\n' "$APP"
	printf 'stalled for    %ss at capture time\n' "$ELAPSED"
	printf 'captured at    %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	printf '\n'
} > "$MANIFEST"

collect 'repo-server (PRIMARY)' "$OUT/repo-server.log" \
	kubectl -n argocd logs deploy/argocd-repo-server --tail=800 --timestamps
collect 'application-controller'  "$OUT/app-controller.log" \
	kubectl -n argocd logs statefulset/argocd-application-controller --tail=300 --timestamps
collect 'git-server (all)'        "$OUT/git-server-all.log" \
	kubectl -n platform-system logs -l app.kubernetes.io/name=git-server --tail=800 --timestamps
collect 'events argocd'           "$OUT/events-argocd.txt" \
	kubectl -n argocd get events --sort-by=.lastTimestamp
collect 'events platform-system'  "$OUT/events-platform-system.txt" \
	kubectl -n platform-system get events --sort-by=.lastTimestamp
collect 'application yaml'        "$OUT/application.yaml" \
	kubectl -n argocd get application "$APP" -o yaml
collect 'git-server pod'          "$OUT/git-server-pod.yaml" \
	kubectl -n platform-system get pod -l app.kubernetes.io/name=git-server -o yaml

# The client slice, derived from the full log rather than fetched again so the
# two describe the same moment. Access-log lines only, minus the readiness
# probe -- which leaves every request Argo made, by either of its two clients.
if [ -s "$OUT/git-server-all.log" ]; then
	grep -E '"(GET|POST) /git/' "$OUT/git-server-all.log" | grep -v 'kube-probe' \
		> "$OUT/git-server-access-clients.log" 2>/dev/null
	if [ -s "$OUT/git-server-access-clients.log" ]; then
		note 'git-server access (clients)' "OK      $(wc -l < "$OUT/git-server-access-clients.log" | tr -d ' ') lines -- SHORT byte count = server stopped early"
	else
		note 'git-server access (clients)' 'EMPTY   (no non-probe requests in the retained log)'
	fi
else
	note 'git-server access (clients)' 'SKIPPED (the git-server log itself was empty or failed)'
fi

{
	printf '\n'
	printf 'READING git-server-access-clients.log:\n'
	printf '  a FULL byte count (~360000 for this repo) means the server wrote the whole\n'
	printf '  response and the loss is downstream of it -- client, socket, or path.\n'
	printf '  a SHORT count means the server itself stopped early. Then read\n'
	printf '  git-server-all.log for git-http-backend stderr.\n'
	printf '\n'
	printf 'The failing request is the git-upload-pack POST, and it carries the real git\n'
	printf 'binary as its agent (git/2.53.0 in argocd v3.5.2), not go-git. go-git appears\n'
	printf 'only on info/refs.\n'
} >> "$MANIFEST"

printf '\n  captured both sides of the %s fetch failure -> %s\n' "$APP" "$OUT" >&2
sed 's/^/    /' "$MANIFEST" >&2
