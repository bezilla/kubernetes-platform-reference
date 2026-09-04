#!/usr/bin/env bash
#
# publish: this setup's `git push`.
#
# Mirrors the working repository into the in-cluster Git server, then tells Argo
# CD to look. With a real Git provider you would delete this file and push.
#
# Only refs/heads/* is mirrored. `git push --mirror` would also copy refs/stash,
# refs/notes and anything else lying around; Argo only ever resolves a branch,
# and publishing refs nobody asked for is how a local experiment ends up as the
# cluster's desired state.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
MIRROR='.work/platform.git'
NS='platform-system'

pod="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=git-server \
	-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$pod" ] || { echo "publish: no git-server pod; run 'make up' first" >&2; exit 1; }

rm -rf "$MIRROR"
mkdir -p .work
git init -q --bare "$MIRROR"
git push -q "$MIRROR" "+refs/heads/${BRANCH}:refs/heads/${BRANCH}"
git -C "$MIRROR" symbolic-ref HEAD "refs/heads/${BRANCH}"
# Without this there is no info/refs and `git ls-remote` over dumb HTTP returns
# nothing -- Argo would report "unknown revision" against a repository that
# visibly has commits in it.
git -C "$MIRROR" update-server-info

kubectl -n "$NS" exec "$pod" -- sh -c 'rm -rf /srv/git/platform.git && mkdir -p /srv/git/platform.git'
tar -C "$MIRROR" -cf - . | kubectl -n "$NS" exec -i "$pod" -- tar -C /srv/git/platform.git -xf -

sha="$(git rev-parse --short HEAD)"
echo "publish: ${BRANCH} @ ${sha} -> http://git-server.${NS}.svc/platform.git"

# Argo polls every three minutes by default. Nudge it so the demonstration does
# not consist of waiting.
if kubectl get application -n argocd platform-root >/dev/null 2>&1; then
	kubectl -n argocd patch application platform-root --type merge \
		-p '{"metadata":{"annotations":{"platform.internal/published":"'"$sha"'"}}}' >/dev/null
	kubectl -n argocd annotate applications --all argocd.argoproj.io/refresh=hard --overwrite >/dev/null
	echo "publish: refresh requested on all Applications"
fi
