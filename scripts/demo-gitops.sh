#!/usr/bin/env bash
#
# The loop, shown rather than described: a commit changes the running cluster.
#
# Flips quote-api between two and three replicas, commits that one line, pushes
# it to the in-cluster Git server, and watches Argo CD move the Deployment. It
# toggles rather than only scaling up so the demonstration can be run repeatedly
# and each run is a real cycle, not a no-op.
#
# It makes a real commit, because a demonstration of GitOps that does not commit
# is a demonstration of kubectl. The commit is ordinary and revertible; run it
# again to go back.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VALUES=apps/quote-api/values.yaml
NS=tenant-quotes
DEPLOY=quote-api

kubectl -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1 || { echo "demo-gitops: no ${DEPLOY}. Run 'make up'." >&2; exit 1; }
[ -z "$(git status --porcelain -- "$VALUES")" ] || {
	echo "demo-gitops: ${VALUES} has uncommitted changes; commit or discard them first." >&2; exit 1; }

current="$(awk '/^replicas:/ {print $2}' "$VALUES")"
if [ "$current" = "3" ]; then target=2; else target=3; fi

printf '\n\033[1mBefore\033[0m\n'
printf '  %-22s %s\n' "$VALUES" "replicas: $current"
kubectl -n "$NS" get deploy "$DEPLOY" -o custom-columns='DEPLOYMENT:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas' --no-headers | sed 's/^/  /'
printf '  argo revision          %s\n' "$(kubectl -n argocd get app "$DEPLOY" -o jsonpath='{.status.sync.revision}' | cut -c1-7)"

printf '\n\033[1mEditing one line and committing it\033[0m\n'
sed -i.bak "s/^replicas: ${current}\$/replicas: ${target}/" "$VALUES" && rm -f "${VALUES}.bak"
git add -- "$VALUES"
git commit -q -m "Run quote-api on ${target} replicas

One line in the app team's values file. No Deployment edited, no kubectl."
sha="$(git rev-parse --short HEAD)"
printf '  %s  replicas: %s -> %s\n' "$sha" "$current" "$target"

printf '\n\033[1mPublishing (this setup'"'"'s git push)\033[0m\n'
./scripts/publish.sh 2>&1 | sed 's/^/  /'

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
printf '\n  Run this again to toggle back to %s.\n\n' "$current"
