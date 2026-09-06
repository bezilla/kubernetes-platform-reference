#!/usr/bin/env bash
#
# The loop, shown rather than described: a commit changes the running cluster.
#
# Flips quote-api between two and three replicas, publishes that one-line commit
# to the in-cluster Git server, and watches Argo CD move the Deployment. It
# toggles rather than only scaling up so the demonstration can be run repeatedly
# and each run is a real cycle, not a no-op.
#
# It makes a real commit, because a demonstration of GitOps that does not commit
# is a demonstration of kubectl. What it does NOT do is put that commit on your
# branch. The earlier version edited apps/quote-api/values.yaml in the working
# tree and ran `git commit` on whatever was checked out, so every demo run left
# a "Run quote-api on N replicas" commit in the middle of the user's own work,
# and a dirty tree if it failed partway. Demo noise is not history.
#
# So the commit is built with plumbing -- a blob, a tree, a commit object -- and
# parked on a scratch branch that is published and then deleted. HEAD, the
# index and the working tree are never touched. The commit is as real as any
# other; it simply belongs to the demonstration rather than to the repository.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VALUES=apps/quote-api/values.yaml
NS=tenant-quotes
DEPLOY=quote-api
SCRATCH='demo/gitops'

kubectl -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1 || { echo "demo-gitops: no ${DEPLOY}. Run 'make up'." >&2; exit 1; }

# Delete the scratch branch however this exits, including on failure. It is a
# ref this script owns entirely, so removing it can never lose anyone's work.
cleanup() { git branch -D "$SCRATCH" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# The toggle reads the CLUSTER, not the file. The file is no longer edited, so
# it always says the same thing, and deriving the target from it would make
# every run after the first a no-op.
current="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}')"
if [ "$current" = "3" ]; then target=2; else target=3; fi

printf '\n\033[1mBefore\033[0m\n'
printf '  %-22s %s\n' "$VALUES" "replicas: $(git show "HEAD:${VALUES}" | awk '/^replicas:/ {print $2}') (on HEAD, unchanged by this demo)"
kubectl -n "$NS" get deploy "$DEPLOY" -o custom-columns='DEPLOYMENT:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas' --no-headers | sed 's/^/  /'
printf '  argo revision          %s\n' "$(kubectl -n argocd get app "$DEPLOY" -o jsonpath='{.status.sync.revision}' | cut -c1-7)"

printf '\n\033[1mBuilding the commit (off your branch)\033[0m\n'

# A temporary index so the real one is never written. read-tree loads HEAD into
# it, update-index swaps in the one changed blob, write-tree turns it back into
# a tree object. None of this consults or modifies the working tree.
# Not `mktemp -t NAME`. BSD mktemp reads -t's argument as a PREFIX and appends
# its own suffix, so that form works on macOS; GNU mktemp reads it as a TEMPLATE
# and requires at least three trailing X's, so the same line is
# "mktemp: too few X's in template" on every Linux runner. An explicit template
# path is accepted by both, and is the form the rest of this repository uses.
tmp_index="$(mktemp "${TMPDIR:-/tmp}/demo-gitops-index.XXXXXX")"
cleanup_index() { rm -f "$tmp_index"; cleanup; }
trap cleanup_index EXIT

blob="$(git show "HEAD:${VALUES}" \
	| sed "s/^replicas: [0-9][0-9]*\$/replicas: ${target}/" \
	| git hash-object -w --stdin)"
GIT_INDEX_FILE="$tmp_index" git read-tree HEAD
GIT_INDEX_FILE="$tmp_index" git update-index --cacheinfo "100644,${blob},${VALUES}"
tree="$(GIT_INDEX_FILE="$tmp_index" git write-tree)"

commit="$(git commit-tree "$tree" -p HEAD -m "Run quote-api on ${target} replicas

One line in the app team's values file. No Deployment edited, no kubectl.")"
git branch -f "$SCRATCH" "$commit" >/dev/null

printf '  %s  replicas: %s -> %s  (on %s, not %s)\n' \
	"$(git rev-parse --short "$commit")" "$current" "$target" "$SCRATCH" "$(git rev-parse --abbrev-ref HEAD)"

printf '\n\033[1mPublishing (this setup'"'"'s git push)\033[0m\n'
PUBLISH_REF="$SCRATCH" ./scripts/publish.sh 2>&1 | sed 's/^/  /'

printf '\n\033[1mWatching Argo CD apply it\033[0m\n'
start=$SECONDS
deadline=$((SECONDS + 240))
while :; do
	d="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')"
	r="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
	rev="$(kubectl -n argocd get app "$DEPLOY" -o jsonpath='{.status.sync.revision}' 2>/dev/null | cut -c1-7)"
	printf '  %3ds  desired=%s ready=%s  argo revision=%s\n' "$((SECONDS - start))" "$d" "${r:-0}" "${rev:-?}"
	[ "$d" = "$target" ] && [ "${r:-0}" = "$target" ] && { printf '\n  \033[32mThe cluster followed the commit.\033[0m\n'; break; }
	[ $SECONDS -ge $deadline ] && { printf '\n  did not converge within 240s\n' >&2; exit 1; }
	sleep 10
done

printf '\n\033[1mAfter\033[0m\n'
kubectl -n "$NS" get pods -l "app.kubernetes.io/name=${DEPLOY}" --no-headers | awk '{printf "  %s  %s  %s  age %s\n", $1, $2, $3, $5}'
printf '\n  Your branch and working tree are untouched. Run this again to toggle back to %s.\n\n' "$current"
