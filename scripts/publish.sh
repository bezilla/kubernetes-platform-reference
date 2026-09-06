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
# Every Application pins `targetRevision: main`, and lint.sh rejects a
# floating HEAD, so the ref they track has to be a real branch name. But this
# script mirrors whatever branch is checked out. From a topic branch the
# server therefore has no `main` at all, and every Application sits in
# ComparisonError -- "unable to resolve 'main' to a commit SHA" -- until its
# deadline expires. The platform can only come up on `main`, which makes a
# branch the one place you cannot test a change to it.
#
# Publishing the working branch under `main` as well is what makes the
# bring-up work from any branch. On `main` the two refspecs name the same
# ref and git rejects the duplicate, so only alias when they differ.
[ "$BRANCH" = 'main' ] || git push -q "$MIRROR" "+refs/heads/${BRANCH}:refs/heads/main"
git -C "$MIRROR" symbolic-ref HEAD "refs/heads/${BRANCH}"
# No `git update-server-info` here. That command exists to generate the static
# info/refs a DUMB HTTP client reads; the server runs git-http-backend, which
# answers the smart protocol from the repository itself. Running it anyway would
# leave a stale file that nothing consults.

kubectl -n "$NS" exec "$pod" -- sh -c 'rm -rf /srv/git/platform.git && mkdir -p /srv/git/platform.git'
tar -C "$MIRROR" -cf - . | kubectl -n "$NS" exec -i "$pod" -- tar -C /srv/git/platform.git -xf -

sha="$(git rev-parse --short HEAD)"
echo "publish: ${BRANCH} @ ${sha} -> http://git-server.${NS}.svc/git/platform.git"

# Argo polls every three minutes by default. Nudge it so the demonstration does
# not consist of waiting.
# Best-effort, deliberately: the repository is already published by this point,
# and Argo will pick it up on its own poll regardless. Under load the API server
# can time out on this annotation, and a failed nudge must not fail a publish
# that succeeded -- or every caller has to decide what a half-failure means.
if kubectl get application -n argocd platform-root >/dev/null 2>&1; then
	if kubectl -n argocd annotate applications --all \
		argocd.argoproj.io/refresh=hard --overwrite --request-timeout=20s >/dev/null 2>&1; then
		echo "publish: refresh requested on all Applications"
	else
		echo "publish: could not nudge Argo (API busy); it will poll within ${ARGOCD_POLL_HINT:-3m}"
	fi
fi
