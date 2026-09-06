#!/usr/bin/env bash
#
# selfHeal, shown rather than asserted.
#
# Every Application in this repository sets `syncPolicy.automated.selfHeal:
# true`. That is nine files making one claim, and until this script existed
# nothing checked it. An unexercised claim in nine places is not nine times more
# true than an unexercised claim in one.
#
# So: delete a Deployment the platform owns, out of band, the way a tired
# operator would at 03:00. Argo CD should notice the live state no longer
# matches Git and put it back without being asked. Nothing here nudges it -- no
# refresh annotation, no sync command -- because a demonstration that pokes the
# thing it is demonstrating proves only that poking works.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NS='tenant-quotes'
DEPLOY='quote-api'
APP='quote-api'
DEADLINE=240

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

kubectl -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1 || {
	echo "demo-selfheal: no ${DEPLOY} in ${NS}. Run 'make up'." >&2; exit 1; }

step 'The claim'
kubectl -n argocd get app "$APP" \
	-o jsonpath='  {.metadata.name}: selfHeal={.spec.syncPolicy.automated.selfHeal} prune={.spec.syncPolicy.automated.prune}{"\n"}'
printf '  every Application in platform/applications/ sets the same\n'

step 'Before'
before_uid="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.metadata.uid}')"
kubectl -n "$NS" get deploy "$DEPLOY" \
	-o custom-columns='DEPLOYMENT:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas' \
	--no-headers | sed 's/^/  /'
printf '  uid %s\n' "$before_uid"

step "Deleting it out of band — no commit, no Argo CD involvement"
kubectl -n "$NS" delete deploy "$DEPLOY" --wait=true 2>&1 | sed 's/^/  /'
gone="$(kubectl -n "$NS" get deploy "$DEPLOY" -o name 2>/dev/null || true)"
[ -z "$gone" ] && printf '  confirmed: Deployment/%s no longer exists\n' "$DEPLOY" \
               || { echo "demo-selfheal: delete did not take effect" >&2; exit 1; }

step 'Waiting for Argo CD to notice and restore it'
start=$SECONDS
restored=''
while :; do
	elapsed=$((SECONDS - start))
	uid="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
	ready="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
	want="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')"
	sync="$(kubectl -n argocd get app "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo '?')"
	if [ -n "$uid" ]; then state='present'; else state='absent'; fi
	printf '  %3ds  deployment=%-7s  ready=%s/%s  app=%s\n' \
		"$elapsed" "$state" "${ready:-0}" "${want:-?}" "${sync:-?}"
	if [ -n "$uid" ] && [ "${ready:-0}" = "${want}" ] && [ "$sync" = 'Synced' ]; then
		restored="$uid"; break
	fi
	if [ "$elapsed" -ge "$DEADLINE" ]; then
		printf '\ndemo-selfheal: FAILED -- not restored within %ds\n' "$DEADLINE" >&2
		kubectl -n argocd get app "$APP" -o jsonpath='{.status.conditions[*].message}{"\n"}' >&2
		exit 1
	fi
	sleep 5
done

step 'After'
kubectl -n "$NS" get deploy "$DEPLOY" \
	-o custom-columns='DEPLOYMENT:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas' \
	--no-headers | sed 's/^/  /'
printf '  uid %s\n' "$restored"
if [ "$restored" != "$before_uid" ]; then
	printf '  the uid changed — this is a new object, rebuilt from Git, not the old one recovered\n'
else
	printf '  the uid is unchanged, which should not happen after a delete\n' >&2
fi
printf '\n  \033[32mNobody ran a sync. Nobody committed anything. Git was still the desired state.\033[0m\n\n'
