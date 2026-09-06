#!/usr/bin/env bash
#
# Installs the platform on the PREVIOUS chart versions, then upgrades it in
# place to the pinned ones and requires it to still converge.
#
# Every other test here builds from nothing. That proves the platform can be
# created; it does not prove it can be moved, and moving it is what every
# dependency bump asks for. The failures that only appear on an upgrade
# are the expensive ones: a CRD whose schema changed under existing objects, a
# webhook that is unavailable during its own rollout and rejects everything
# while it is, a chart that renames a resource so the old one is orphaned.
#
# It touches no branch of yours. The old-version commit is built with plumbing,
# parked on a scratch ref, published to the in-cluster mirror, and deleted --
# the same discipline demo-gitops uses, for the same reason.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

SCRATCH='upgrade/from'
step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# manifest : current version variable : previous version variable
PAIRS=(
	"platform/applications/10-cert-manager.yaml:CERT_MANAGER_CHART_VERSION:UPGRADE_FROM_CERT_MANAGER"
	"platform/applications/11-envoy-gateway.yaml:ENVOY_GATEWAY_CHART_VERSION:UPGRADE_FROM_ENVOY_GATEWAY"
	"platform/applications/12-kyverno.yaml:KYVERNO_CHART_VERSION:UPGRADE_FROM_KYVERNO"
	"platform/applications/31-otel-collector.yaml:OTEL_COLLECTOR_CHART_VERSION:UPGRADE_FROM_OTEL_COLLECTOR"
)

cleanup() { git branch -D "$SCRATCH" >/dev/null 2>&1 || true; rm -f "${tmp_index:-}"; }
trap cleanup EXIT

# What each component reports it is running, read from the live Application.
running_versions() {
	kubectl -n argocd get applications -o json 2>/dev/null \
		| jq -r '.items[] | select(.spec.source.chart != null)
		         | "  \(.spec.source.chart)=\(.spec.source.targetRevision)"' | sort
}

# --- 1. build the old-version tree, off your branch ---------------------------
step "Building a commit pinned to the previous chart versions"
# See the note in scripts/demo-gitops.sh: `mktemp -t NAME` is a BSD prefix and a
# GNU template, and GNU rejects it for having too few X's. This form works on
# both.
tmp_index="$(mktemp "${TMPDIR:-/tmp}/upgrade-index.XXXXXX")"
GIT_INDEX_FILE="$tmp_index" git read-tree HEAD
for pair in "${PAIRS[@]}"; do
	IFS=':' read -r manifest curvar prevvar <<<"$pair"
	cur="${!curvar}"; prev="${!prevvar}"
	blob="$(git show "HEAD:${manifest}" \
		| sed "s|^\([[:space:]]*targetRevision:[[:space:]]*\)${cur}[[:space:]]*$|\1${prev}|" \
		| git hash-object -w --stdin)"
	GIT_INDEX_FILE="$tmp_index" git update-index --cacheinfo "100644,${blob},${manifest}"
	printf '    %-46s %s -> %s\n' "$(basename "$manifest")" "$cur" "$prev"
done
tree="$(GIT_INDEX_FILE="$tmp_index" git write-tree)"
commit="$(git commit-tree "$tree" -p HEAD -m "Pin the previous chart versions

Built by scripts/upgrade-test.sh. Never on a branch anyone works on.")"
git branch -f "$SCRATCH" "$commit" >/dev/null
printf '    %s on %s\n' "$(git rev-parse --short "$commit")" "$SCRATCH"

# --- 2. bring the platform up on those --------------------------------------
step "Bringing the platform up on the PREVIOUS versions"
PUBLISH_REF="$SCRATCH" make up || { echo "upgrade-test: the old-version bring-up failed" >&2; exit 1; }

step "What is running before the upgrade"
before="$(running_versions)"; printf '%s\n' "$before"

# --- 3. publish the current versions and let Argo CD move it ------------------
step "Publishing the pinned versions -- Argo CD upgrades in place from here"
./scripts/publish.sh 2>&1 | sed 's/^/    /'

# Publishing does not make anything OutOfSync on its own. The root Application
# has to notice the new commit and rewrite the eight child Application objects
# before any child can begin pulling a new chart -- and until that happens every
# child is still Synced and Healthy on the OLD version. Waiting for health here
# returns instantly and proves nothing, which is exactly what the first version
# of this script did: "converged in 0s", four components still on the versions
# they started on, and only the version assertion below caught it.
#
# So: wait for the SPECS to carry the pinned versions first. That is the moment
# the upgrade has actually been asked for. Only then is convergence meaningful.
step "Waiting for the root to push the new versions into the child Applications"
spec_deadline=$((SECONDS + 300))
while :; do
	pending=''
	for pair in "${PAIRS[@]}"; do
		IFS=':' read -r manifest curvar _ <<<"$pair"
		chart="$(grep -m1 -E '^[[:space:]]+chart:' "$manifest" | awk '{print $2}')"
		want="${!curvar}"
		got="$(kubectl -n argocd get applications -o json 2>/dev/null \
			| jq -r --arg c "$chart" '.items[] | select(.spec.source.chart==$c) | .spec.source.targetRevision')"
		[ "$got" = "$want" ] || pending="${pending} ${chart}(${got:-?}->${want})"
	done
	if [ -z "$pending" ]; then
		printf '    all four child Applications now name the pinned versions (%ds)\n' \
			"$((SECONDS - spec_deadline + 300))"
		break
	fi
	if [ "$SECONDS" -ge "$spec_deadline" ]; then
		printf '\nupgrade-test: FAILED -- the root never updated:%s\n' "$pending" >&2
		kubectl -n argocd get app platform-root -o jsonpath='{.status.sync.status} {.status.sync.revision}{"\n"}' >&2
		exit 1
	fi
	printf '    waiting on:%s\n' "$pending"
	sleep 10
done

step "Waiting for every Application to converge on the new versions"
./scripts/wait-for-platform.sh "${UP_TIMEOUT_SECONDS:-900}" || {
	echo "upgrade-test: FAILED -- the platform did not converge after the upgrade" >&2
	kubectl -n argocd get applications >&2
	exit 1
}

# --- 4. prove it actually moved ----------------------------------------------
# Converging is not the same as upgrading: an Application that never changed
# would also be Synced and Healthy. Assert the versions are the pinned ones AND
# that they differ from what was running before.
step "What is running after"
after="$(running_versions)"; printf '%s\n' "$after"

fail=0
for pair in "${PAIRS[@]}"; do
	IFS=':' read -r manifest curvar prevvar <<<"$pair"
	chart="$(grep -m1 -E '^[[:space:]]+chart:' "$manifest" | awk '{print $2}')"
	want="${!curvar}"
	got="$(printf '%s\n' "$after" | sed -n "s|^  ${chart}=||p")"
	if [ "$got" = "$want" ]; then
		printf '    \033[32mok\033[0m   %-28s now %s\n' "$chart" "$got"
	else
		printf '    \033[31mFAIL\033[0m %-28s is %s, expected %s\n' "$chart" "${got:-<none>}" "$want"
		fail=$((fail + 1))
	fi
done

if [ "$before" = "$after" ]; then
	echo "upgrade-test: FAILED -- nothing changed, so nothing was upgraded" >&2
	exit 1
fi
[ "$fail" -eq 0 ] || { printf '\nupgrade-test: %d component(s) did not reach the pinned version\n\n' "$fail" >&2; exit 1; }

printf '\n  \033[32mUpgraded in place, from the previous versions to the pinned ones, still converged.\033[0m\n\n'
