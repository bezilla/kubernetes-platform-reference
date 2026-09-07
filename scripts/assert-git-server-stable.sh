#!/usr/bin/env bash
#
# Did the pod serving the repository stay up while Argo CD was fetching from it?
#
# This exists to kill or confirm one candidate. argocd-repositories has stalled
# on three of eight runner runs, and the condition text captured on the third
# names a truncated fetch from the in-cluster Git server:
#
#   curl 18 transfer closed with outstanding read data remaining
#   error: 7704 bytes of body are still expected
#   fatal: fetch-pack: invalid index-pack output
#
# A connection dying mid-packfile is what you would see if the server went away
# underneath it. up.sh gates on the readiness probe passing ONCE, which is not
# the same as the pod staying stably up for the eight Applications installed
# after it.
#
# WHY A COMPOSITE, and not just restartCount. That field catches a container
# killed and restarted in place, and misses the case where the POD was replaced
# -- a new pod starts at restartCount 0, so the counter reads clean exactly when
# the disruption was largest. The uid is what closes that: recorded before the
# install phase and compared after, a changed uid means replacement.
# lastState.terminated is free from the same object and says WHY, and OOMKilled
# versus Error is the difference between a starved node and a crash.
#
# WHAT THIS CANNOT SEE, stated so a clean result is not over-read: lighttpd
# terminating a response without the container dying -- a write timeout, a CGI
# worker exiting mid-stream -- produces exactly the observed truncation and
# leaves every one of these signals untouched. A clean result eliminates "the
# pod went away". It does not eliminate "the server closed the connection".
#
# IT REPORTS, IT DOES NOT FAIL. A restart is evidence about a cause still being
# isolated, not a defect anyone has decided is unacceptable -- the same line
# pin-delta.sh and the rollback leg's compatibility path already draw. Failing
# would also destroy what makes this useful: the value is correlating a restart
# with a slow argocd-repositories across many runs, and a red build on the first
# one ends the collection. If a future run pairs the two, that promotes it from
# candidate to cause, and THEN it is worth failing on, with the evidence to say
# so. Exit 1 marks a finding for a caller that later wants to act; nothing acts
# on it today.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

E_FINDING=1             # observed a restart or a replacement -- reported, not fatal
E_PRECONDITION=2        # could not run: no cluster, no pod, no tooling

NS='platform-system'
SEL='app.kubernetes.io/name=git-server'
BASELINE='.work/git-server-baseline'
MODE="${1:-check}"

for t in kubectl jq; do
	command -v "$t" >/dev/null 2>&1 || {
		echo "assert-git-server-stable: $t is not on PATH" >&2; exit "$E_PRECONDITION"; }
done

read_pod() {
	kubectl -n "$NS" get pod -l "$SEL" -o json 2>/dev/null | jq -r '
		.items[0] // empty
		| [ .metadata.uid,
		    (.status.containerStatuses[0].restartCount // 0),
		    (.status.containerStatuses[0].lastState.terminated.reason   // "-"),
		    (.status.containerStatuses[0].lastState.terminated.exitCode // "-"),
		    (.status.containerStatuses[0].lastState.terminated.finishedAt // "-"),
		    .metadata.name ] | @tsv'
}

row="$(read_pod)"
[ -n "$row" ] || { echo "assert-git-server-stable: no git-server pod in ${NS}" >&2; exit "$E_PRECONDITION"; }
IFS=$'\t' read -r uid restarts reason exitcode finished name <<<"$row"

case "$MODE" in
	record)
		mkdir -p "$(dirname "$BASELINE")" 2>/dev/null || true
		printf '%s\t%s\n' "$uid" "$restarts" > "$BASELINE" \
			|| { echo "assert-git-server-stable: could not write ${BASELINE}" >&2; exit "$E_PRECONDITION"; }
		printf '    git-server baseline: %s restarts=%s\n' "$name" "$restarts"
		exit 0
		;;
	check) ;;
	*) echo "usage: assert-git-server-stable.sh [record|check]" >&2; exit "$E_PRECONDITION" ;;
esac

# No baseline is "could not run", never "stable". Reporting a pod as steady when
# nothing recorded what it was before is the shape of answer this repository has
# been bitten by twice.
[ -s "$BASELINE" ] || {
	echo "assert-git-server-stable: no baseline at ${BASELINE} -- run 'record' first" >&2
	exit "$E_PRECONDITION"; }
IFS=$'\t' read -r base_uid base_restarts < "$BASELINE"

finding=0
if [ "$uid" != "$base_uid" ]; then
	finding=1
	printf '\n  \033[33mGIT-SERVER POD WAS REPLACED during the install phase\033[0m\n' >&2
	printf '    before %s\n    after  %s (%s)\n' "$base_uid" "$uid" "$name" >&2
	printf '    restartCount on the new pod reads %s and means nothing -- it is a new pod.\n' "$restarts" >&2
elif [ "$restarts" != "$base_restarts" ]; then
	finding=1
	printf '\n  \033[33mGIT-SERVER CONTAINER RESTARTED during the install phase\033[0m\n' >&2
	printf '    restartCount %s -> %s on %s\n' "$base_restarts" "$restarts" "$name" >&2
	printf '    last termination: reason=%s exitCode=%s at %s\n' "$reason" "$exitcode" "$finished" >&2
fi

if [ "$finding" -eq 1 ]; then
	printf '\n    The pod serving the repository went away while Argo CD was fetching\n' >&2
	printf '    from it. That is the leading explanation for a fetch dying mid-packfile,\n' >&2
	printf '    and it is why argocd-repositories is worth checking on this run.\n' >&2
	printf '    Reported, not failed: this is evidence about a cause still being\n' >&2
	printf '    isolated, not a defect anyone has ruled unacceptable.\n\n' >&2
	kubectl -n "$NS" describe pod -l "$SEL" 2>&1 | sed -n '/Events:/,$p' | head -12 | sed 's/^/    /' >&2
	exit "$E_FINDING"
fi

printf '    \033[32mok\033[0m   git-server stable through the install phase (same pod, %s restarts)\n' "$restarts"
exit 0
