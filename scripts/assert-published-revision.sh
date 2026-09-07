#!/usr/bin/env bash
#
# Proves the re-point actually landed, by reading the two places that can
# disagree with the local repository.
#
# Every version assertion in upgrade-test.sh compares one local value against
# another local value. `publish.sh` prints the SHA it pushed and nothing captures
# it; the chart-version gates read .spec.source.targetRevision, which is a string
# Argo CD was handed. None of that observes whether the in-cluster Git server
# holds the commit, or whether Argo CD ever resolved it. A publish that silently
# did nothing -- a tar that wrote an empty tree, a git-server pod that restarted
# and lost /srv/git, a ref pushed under the wrong name -- leaves every one of
# those assertions passing.
#
# That matters beyond tidiness. If a convergence failure is going to be read as
# "the machinery worked and something downstream refused", then "the machinery
# worked" has to be something observed rather than assumed.
#
# TWO READS, because they fail independently:
#
#   the mirror   `git rev-parse --verify refs/heads/main^{commit}` inside the
#                git-server pod. Catches: publish never landed, the tar wrote
#                nothing or wrote garbage, the wrong ref was pushed, the pod
#                restarted and took /srv/git with it. The ^{commit} peel is not
#                decoration -- rev-parse on a ref alone reads the ref file and
#                will happily print a SHA whose object is missing, which is
#                exactly the state a truncated tar leaves behind.
#                Does NOT catch: Argo CD never looking.
#
#   Argo CD      platform-root's .status.sync.revision. Catches: Argo holding a
#                stale revision because the refresh was dropped -- publish.sh
#                nudges best-effort and says so when the nudge fails.
#                Does NOT catch: a mirror that holds the wrong commit, since Argo
#                would faithfully report that wrong commit. Which is why the
#                first read exists.
#
# Neither can tell you the commit is the one you MEANT to publish; both are
# compared against a SHA the caller supplies. What they establish is that the
# cluster and the caller agree, which is the part that was previously assumed.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

E_FAILED=1              # read it, and the cluster is on a different revision
E_PRECONDITION=2        # could not run: no cluster, no git-server, no tooling
E_HARNESS=3             # could not finish: Argo never reported any revision

EXPECTED="${1:-$(git rev-parse HEAD)}"
DEADLINE="${2:-${PUBLISHED_REVISION_TIMEOUT_SECONDS:-180}}"
INTERVAL=10
NS='platform-system'

command -v kubectl >/dev/null 2>&1 || {
	echo "assert-published-revision: kubectl is not on PATH" >&2; exit "$E_PRECONDITION"; }
kubectl cluster-info >/dev/null 2>&1 || {
	echo "assert-published-revision: no reachable cluster" >&2; exit "$E_PRECONDITION"; }

printf '    expecting %s\n' "$EXPECTED"

# --- 1. what the mirror actually serves ---------------------------------------
pod="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=git-server \
	-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$pod" ] || {
	echo "assert-published-revision: no git-server pod in ${NS}" >&2; exit "$E_PRECONDITION"; }

# Not suppressed into an empty string: a failure here is reported as a failure,
# because "the command did not run" and "the ref is not there" are different
# findings and only one of them is this repository's fault.
served="$(kubectl -n "$NS" exec "$pod" -- \
	git --git-dir=/srv/git/platform.git rev-parse --verify 'refs/heads/main^{commit}' 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
	printf '\nassert-published-revision: could not read refs/heads/main from the mirror.\n' >&2
	printf '    %s\n' "$served" >&2
	printf '\n    The pod answered but the ref did not resolve to a commit. A truncated\n' >&2
	printf '    tar leaves exactly this: a ref file naming an object that is not there.\n' >&2
	exit "$E_FAILED"
fi

# An empty read is not a disagreement about which commit is served; it is a read
# that did not happen. Reported as its own finding so the message names the real
# fault rather than printing "serving <nothing>" and leaving it to be puzzled out.
if [ -z "$served" ]; then
	printf '\nassert-published-revision: the mirror read returned nothing.\n' >&2
	printf '    The command reported success and produced no SHA, which is a broken\n' >&2
	printf '    read rather than a wrong revision. Nothing here is proven.\n' >&2
	exit "$E_PRECONDITION"
fi

if [ "$served" != "$EXPECTED" ]; then
	printf '\nassert-published-revision: FAILED -- the mirror serves a different commit.\n' >&2
	printf '    expected  %s\n    serving   %s\n' "$EXPECTED" "$served" >&2
	printf '\n    publish.sh reported success and the git server holds something else.\n' >&2
	exit "$E_FAILED"
fi
printf '    \033[32mok\033[0m   mirror refs/heads/main = %s\n' "${served:0:12}"

# --- 2. what Argo CD resolved -------------------------------------------------
# Bounded, because this one legitimately lags: publish.sh's refresh is
# best-effort and Argo polls on its own schedule when the nudge is dropped.
start=$SECONDS
while :; do
	elapsed=$((SECONDS - start))
	if ! rev="$(kubectl -n argocd get app platform-root \
		-o jsonpath='{.status.sync.revision}' --request-timeout=20s 2>/dev/null)"; then
		printf '  %3ds  could not read platform-root -- NOT counted as agreeing\n' "$elapsed" >&2
		rev=''
	fi

	if [ "$rev" = "$EXPECTED" ]; then
		printf '    \033[32mok\033[0m   platform-root synced revision = %s (%ds)\n' "${rev:0:12}" "$elapsed"
		printf '\n  \033[32mThe re-point landed: the mirror holds it and Argo CD resolved it.\033[0m\n'
		exit 0
	fi

	if [ "$elapsed" -ge "$DEADLINE" ]; then
		if [ -z "$rev" ]; then
			printf '\nassert-published-revision: platform-root never reported a revision in %ds.\n' "$elapsed" >&2
			kubectl -n argocd get app platform-root -o wide >&2 2>&1 || true
			exit "$E_HARNESS"
		fi
		printf '\nassert-published-revision: FAILED -- Argo CD is on a different revision.\n' >&2
		printf '    mirror serves       %s\n    platform-root synced %s\n' "$EXPECTED" "$rev" >&2
		printf '\n    The commit is published and Argo CD did not pick it up within %ds.\n' "$DEADLINE" >&2
		printf '    publish.sh nudges best-effort; check whether it reported the nudge failing.\n' >&2
		kubectl -n argocd get app platform-root -o wide >&2 2>&1 || true
		exit "$E_FAILED"
	fi
	printf '  %3ds  platform-root on %s, waiting for %s\n' \
		"$elapsed" "${rev:0:12}${rev:+...}" "${EXPECTED:0:12}"
	sleep "$INTERVAL"
done
