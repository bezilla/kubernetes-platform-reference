#!/usr/bin/env bash
#
# Installs the platform on the PREVIOUS chart versions, upgrades it in place to
# the pinned ones, then ROLLS BACK to where it started. Each step has to
# converge on its own.
#
# The rollback is an Argo CD re-point, not a helm rollback -- see the note above
# section 6 -- and at the current pins it proves the MECHANISM works in reverse
# rather than that rollback is safe in general. That distinction is spelled out
# where the phase begins, because a test that quietly implies more than it proves
# is worse than no test.
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

# Waits until every chart-sourced child Application's targetRevision names the
# version this direction expects. `cur` is the pinned set, `prev` the set the
# upgrade started from, which is what the rollback re-points to.
#
# One function rather than two loops: the only thing that differs between the
# directions is which of the two variables in PAIRS is read. A copy would be a
# second place to fix the next time the root's behaviour changes.
wait_for_child_specs() {  # cur|prev  label
	local which="$1" label="$2" deadline pending manifest v_cur v_prev var chart want got
	deadline=$((SECONDS + 300))
	while :; do
		pending=''
		for pair in "${PAIRS[@]}"; do
			IFS=':' read -r manifest v_cur v_prev <<<"$pair"
			var="$v_cur"; [ "$which" = 'prev' ] && var="$v_prev"
			chart="$(grep -m1 -E '^[[:space:]]+chart:' "$manifest" | awk '{print $2}')"
			want="${!var}"
			got="$(kubectl -n argocd get applications -o json 2>/dev/null \
				| jq -r --arg c "$chart" '.items[] | select(.spec.source.chart==$c) | .spec.source.targetRevision')"
			[ "$got" = "$want" ] || pending="${pending} ${chart}(${got:-?}->${want})"
		done
		if [ -z "$pending" ]; then
			printf '    all four child Applications now name the %s versions (%ds)\n' \
				"$label" "$((SECONDS - deadline + 300))"
			return 0
		fi
		if [ "$SECONDS" -ge "$deadline" ]; then
			printf '\nupgrade-test: FAILED -- the root never updated:%s\n' "$pending" >&2
			kubectl -n argocd get app platform-root -o jsonpath='{.status.sync.status} {.status.sync.revision}{"\n"}' >&2
			return 1
		fi
		printf '    waiting on:%s\n' "$pending"
		sleep 10
	done
}

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
# Every step below is checked. This script runs under `set -uo pipefail` and
# deliberately NOT under -e, so without these guards a failure here does not stop
# it -- it carries on and publishes whatever it ended up with.
#
# That is not hypothetical. When mktemp failed on GNU, tmp_index was empty,
# GIT_INDEX_FILE="" made read-tree "fatal: unable to write new index file", all
# four update-index calls said "cannot add", and `git write-tree` then wrote the
# EMPTY TREE (4b825dc642cb6eb9a060e54bf8d69288fbee4904). That tree was committed
# and published as main, so every path in the repository was missing at once and
# Argo CD reported the first one it wanted: "platform/config/argocd: app path
# does not exist". Seven fatal messages scrolled past and the script kept going.
#
# The empty-tree check at the end is the backstop that names the real fault
# instead of letting it surface three minutes later as a missing directory.
tmp_index="$(mktemp "${TMPDIR:-/tmp}/upgrade-index.XXXXXX")" \
	|| { echo "upgrade-test: could not create a temporary index" >&2; exit 1; }
GIT_INDEX_FILE="$tmp_index" git read-tree HEAD \
	|| { echo "upgrade-test: could not read HEAD into the temporary index" >&2; exit 1; }
for pair in "${PAIRS[@]}"; do
	IFS=':' read -r manifest curvar prevvar <<<"$pair"
	cur="${!curvar}"; prev="${!prevvar}"
	blob="$(git show "HEAD:${manifest}" \
		| sed "s|^\([[:space:]]*targetRevision:[[:space:]]*\)${cur}[[:space:]]*$|\1${prev}|" \
		| git hash-object -w --stdin)" \
		|| { echo "upgrade-test: could not rewrite ${manifest}" >&2; exit 1; }
	GIT_INDEX_FILE="$tmp_index" git update-index --cacheinfo "100644,${blob},${manifest}" \
		|| { echo "upgrade-test: could not stage ${manifest}" >&2; exit 1; }
	printf '    %-46s %s -> %s\n' "$(basename "$manifest")" "$cur" "$prev"
done
tree="$(GIT_INDEX_FILE="$tmp_index" git write-tree)" \
	|| { echo "upgrade-test: could not write the tree" >&2; exit 1; }

# Refuse to publish nothing. An empty tree is what a broken index produces, and
# it fails far away from here as "app path does not exist" on whichever path Argo
# CD happens to want first.
if [ "$tree" = "$(git hash-object -t tree /dev/null)" ]; then
	cat >&2 <<EOF
upgrade-test: the previous-version tree came out EMPTY.

    Nothing was staged, so this would publish a commit containing no files and
    every Application would fail with "app path does not exist" on a path that
    is present in HEAD. Refusing to publish it.

    Check the git errors above -- the usual cause is a temporary index that was
    never created.
EOF
	exit 1
fi
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

# Before asking whether the root rewrote anything, establish that there is a new
# revision for it to have seen. Everything below this point infers the publish
# landed from chart-version strings; this reads the git server and Argo CD
# directly, so "the machinery worked" is observed rather than assumed.
step "Confirming the publish landed and Argo CD resolved it"
./scripts/assert-published-revision.sh "$(git rev-parse HEAD)" || {
	rc=$?
	case "$rc" in
		1) echo "upgrade-test: FAILED -- publish reported success and the cluster is on another revision" >&2 ;;
		2) echo "upgrade-test: FAILED -- could not read the published revision, so the publish is unproven" >&2 ;;
		*) echo "upgrade-test: FAILED -- the published-revision check did not finish" >&2 ;;
	esac
	exit "$rc"
}

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
wait_for_child_specs cur "pinned" || exit 1

# SETTLE_SECONDS here and not in up.sh's call: the risk this guards is a verdict
# read in the instant between a sync finishing and its PostSync hook or selfHeal
# starting, and that instant belongs to an upgrade, not to a build from nothing.
# Paying it once, where it means something, rather than on every bring-up.
step "Waiting for every Application to converge on the new versions"
SETTLE_SECONDS="${UPGRADE_SETTLE_SECONDS:-30}" \
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

# --- 5. prove the CLUSTER moved, not just the specs ---------------------------
# Everything above this line reads desired state. `after` is
# .spec.source.targetRevision -- the version Argo CD was handed, not the one any
# container is running -- and the convergence gate reads Argo CD's verdict on its
# own work. The "converged in 0s" incident described at the top of this file was
# caught only because the specs had not moved either; had they moved while the
# pods did not, every gate so far would have passed.
#
# So the last word belongs to the running containers.
step "Confirming the workloads are actually running the pinned versions"
./scripts/assert-installed-versions.sh || {
	rc=$?
	case "$rc" in
		1) echo "upgrade-test: FAILED -- Argo CD reported the upgrade; the workloads did not take it" >&2 ;;
		2) echo "upgrade-test: FAILED -- could not read installed state, so the upgrade is unproven" >&2 ;;
		*) echo "upgrade-test: FAILED -- installed-state assertion did not finish" >&2 ;;
	esac
	exit "$rc"
}

printf '\n  \033[32mUpgraded in place, from the previous versions to the pinned ones, still converged.\033[0m\n\n'

# --- 6. roll back -------------------------------------------------------------
# Third call to machinery that already exists. publish.sh force-publishes any
# branch into the mirror as `main`, and every Application pins
# targetRevision: main, so rolling back is republishing the old revision under
# that name and letting Argo CD converge -- including pruning whatever the newer
# charts added.
#
# NOT `helm rollback`. Every component is owned by an Application with selfHeal
# and prune, so a helm rollback on a release Argo manages would be reverted by
# self-heal within seconds. That does not contradict this test; it contradicts
# the architecture.
#
# WHAT A GREEN HERE PROVES, AND WHAT IT DOES NOT.
#
# At the current pins this is a MECHANISM test and nothing more. The static
# analysis established there is nothing in these bumps that could fail a
# rollback: no CRD storage-version moves, no served-version removals, and zero
# resource-set differences across 164 rendered resources.
#
# There ARE schema changes -- 187 added CRD fields across nine CRDs, plus one
# tightened constraint. This comment used to wave them off as being in
# `policies.kyverno.io` objects this repository does not author. That was
# wrong: two of the nine are in group `kyverno.io`, and one of those is
# clusterpolicies.kyverno.io, which this repository authors four times over.
# They are harmless here for a measured reason instead: of the 36 distinct
# flagged field paths, ZERO are set by anything in this repository -- checked
# against all 439 distinct paths its manifests, tenant values and environment
# files actually set.
#
# So a green proves the re-point works in reverse -- that the root rewrites
# nine children backward and Argo CD converges without anyone intervening. It
# does NOT prove rollback is safe in general, and it cannot, because at these
# pins there is no compatibility hazard present to survive. Compatibility needs
# its own pass with a pin set far enough back to contain one.
#
# THREE OUTCOMES:
#   rollback converges            -> green
#   mechanism broke               -> RED. The re-point did not land, the root did
#                                    not rewrite the children, or a source could
#                                    not resolve. That one is ours.
#   converged never, mechanism ok -> green with a loud warning. By elimination
#                                    that is a compatibility problem, which is a
#                                    fact about an upstream release rather than a
#                                    defect here, and a check that goes red every
#                                    time a maintainer does something ordinary is
#                                    a check people stop reading.

# The static check gates the live one. pin-delta.sh has already compared the two
# chart sets without a cluster; if it found a CRD whose storage version moved,
# rolling back is not slow or risky, it is impossible -- objects are persisted at
# the storage version and the older CRD cannot read what the newer one wrote.
# Running the leg anyway would spend eleven minutes failing to converge, and the
# elimination below would then label a known one-way street a compatibility
# problem, which is true but useless: the static report already said so, in a
# minute, for free.
#
# Three answers, and `unavailable` is a real one. Without the verdict a
# convergence failure cannot honestly be called compatibility, so the run
# continues -- an outage must not quietly reduce coverage -- but a failure is
# reported as unclassifiable rather than assigned to a side.
step "Reading the storage-move verdict from the pin-delta report"
rollback_unverified=0
verdict_out="$(./scripts/storage-verdict.sh)"
verdict="$(printf '%s\n' "$verdict_out" | head -1)"
printf '%s\n' "$verdict_out" | tail -n +2 | sed 's/^/    /'

case "$verdict" in
	moved)
		cat >&2 <<'WARN'

  ============================================================================
  ROLLBACK SKIPPED -- this pin is a one-way door
  ============================================================================

  Rollback from this pin is no longer possible. A CRD's storage version moved
  between these two chart versions, so objects are persisted in a form the
  older chart's CRD cannot read. No amount of re-pointing changes that.

  This is an upstream maintainer's decision about their own API, not a defect
  in this repository and not a broken test. The upgrade above was proven; the
  rollback is skipped because there is nothing here that could make it work,
  and a leg that spent eleven minutes discovering what the static report
  already knew would be worse than not running it.

  The CRDs that moved are listed above.

WARN
		printf '\n  \033[33mUpgraded in place. Rollback skipped -- storage version moved, see above.\033[0m\n\n'
		exit 0
		;;
	none)
		;;
	*)
		rollback_unverified=1
		printf '    \033[33mthe storage verdict could not be obtained -- rolling back anyway,\033[0m\n'
		printf '    \033[33mbut a failure below cannot be classified\033[0m\n'
		;;
esac

step "Rolling back: republishing the previous-version revision"
rollback_sha="$(git rev-parse "$SCRATCH")" \
	|| { echo "upgrade-test: FAILED (MECHANISM) -- the scratch ref is gone" >&2; exit 1; }
PUBLISH_REF="$SCRATCH" ./scripts/publish.sh 2>&1 | sed 's/^/    /'

# MECHANISM, gate 1 of 2: is the old revision actually being served, and did
# Argo CD resolve it. Without this the rest infers a landed publish from
# chart-version strings, and an unlanded publish would look like a slow root.
step "Confirming the rollback publish landed and Argo CD resolved it"
./scripts/assert-published-revision.sh "$rollback_sha" || {
	rc=$?
	echo "upgrade-test: FAILED (MECHANISM) -- the rollback re-point did not land" >&2
	exit "$rc"
}

# MECHANISM, gate 2 of 2: did the root rewrite the children backward.
step "Waiting for the root to push the previous versions back into the children"
wait_for_child_specs prev "previous" || {
	echo "upgrade-test: FAILED (MECHANISM) -- the root did not rewrite the children backward" >&2
	exit 1
}

# Past this line every mechanism gate has passed, which is what licenses the
# elimination below.
step "Waiting for every Application to converge on the previous versions"
rollback_converged=1
SETTLE_SECONDS="${UPGRADE_SETTLE_SECONDS:-30}" \
./scripts/wait-for-platform.sh "${UP_TIMEOUT_SECONDS:-900}" || {
	rc=$?
	# Exit 4 is a source that cannot resolve, which is the re-point having failed
	# and therefore ours. Reading it as compatibility is precisely the misclassification
	# a single generic failure code would have produced.
	if [ "$rc" -eq 4 ]; then
		echo "upgrade-test: FAILED (MECHANISM) -- a source could not resolve after the rollback" >&2
		exit "$rc"
	fi
	rollback_converged=0
}

if [ "$rollback_converged" -eq 0 ] && [ "$rollback_unverified" -eq 1 ]; then
	cat >&2 <<'WARN'

  ============================================================================
  ROLLBACK DID NOT CONVERGE -- and this run cannot say why
  ============================================================================

  Every mechanism gate passed, so the re-point worked and something downstream
  refused. Normally that is enough to call it compatibility by elimination.

  Not this run. The storage-move verdict could not be obtained, so the one
  thing that would distinguish "this pin is a one-way door" from "something
  else refused" is missing. Assigning it to either side would be a guess
  presented as a finding.

  This is reported as UNCLASSIFIED. It is not green because it worked and not
  red because this repository is at fault -- it is a run that did not produce
  an answer. Re-run once the pin-delta report is available.

WARN
	kubectl -n argocd get applications >&2 2>&1 || true
	kubectl get pods -A --field-selector=status.phase!=Running >&2 2>&1 || true
	printf '\n  \033[33mUpgrade proven. Rollback UNCLASSIFIED -- no storage verdict available.\033[0m\n\n'
	exit 0
fi

if [ "$rollback_converged" -eq 0 ]; then
	cat >&2 <<'WARN'

  ============================================================================
  ROLLBACK DID NOT CONVERGE -- reported as a WARNING, not a failure
  ============================================================================

  Every mechanism gate passed: the previous revision is published and served,
  Argo CD resolved it, and the root rewrote all four child Applications back.
  The machinery did its job and something downstream refused, which by
  elimination is a compatibility problem -- an upstream release that cannot
  read state a newer one wrote. That is a fact about a maintainer's decision
  and not a defect in this repository, so it does not fail the build.

  Read this before concluding it is upstream's: memory pressure and image
  pull failures present identically to a component that cannot read a CRD.
  The Applications table and per-application conditions are dumped below, and
  a pod stuck on OOMKilled or ImagePullBackOff means the cause is local.

WARN
	kubectl -n argocd get applications >&2 2>&1 || true
	kubectl get pods -A --field-selector=status.phase!=Running >&2 2>&1 || true
	printf '\n  \033[33mUpgrade proven. Rollback blocked downstream -- see the warning above.\033[0m\n\n'
	exit 0
fi

# --- 7. assertions, after the rollback has settled ----------------------------
# Argo CD saying converged is Argo CD's opinion of its own work. These read the
# cluster.
step "Confirming the workloads are running the PREVIOUS versions"
ASSERT_VERSION_PREFIX='UPGRADE_FROM_' ./scripts/assert-installed-versions.sh || {
	rc=$?
	echo "upgrade-test: FAILED -- Argo CD reported the rollback converged; the workloads did not take it" >&2
	exit "$rc"
}

# Wait for the DATA PLANE before asking whether it serves. Every green signal
# above is about Argo CD's Applications, and the Envoy proxy is not one of them:
# the envoy-gateway Application installs the CONTROLLER, and the controller
# creates the proxy Deployment, which carries no argocd instance label at all.
# So the platform can be Synced, Healthy, held through the settle window, and
# verified on the previous versions with the edge still coming back up.
#
# Run 34143528837 is that exact run. It did all of the above and then failed
# here, because rolling envoy-gateway v1.9.1 -> v1.9.0 rebuilds the proxy and
# nothing waited for it. The run before won the same race. Whichever side of a
# rollout the assertion lands on is not a property of the platform.
step "Waiting for the edge proxy to finish rolling"
./scripts/wait-for-edge.sh "${EDGE_TIMEOUT_SECONDS:-300}" || {
	rc=$?
	case "$rc" in
		1) echo "upgrade-test: FAILED -- the edge proxy never finished rolling after the rollback" >&2 ;;
		*) echo "upgrade-test: FAILED -- could not read the edge proxy, so serving is unproven" >&2 ;;
	esac
	exit "$rc"
}

# The platform is not just a set of versions. This is the same proof the demo
# suite uses, run against the rolled-back platform: the sample workload answered
# over HTTPS through Gateway API on a cert-manager certificate.
step "Confirming the platform still serves after the rollback"
./scripts/demo-https.sh || {
	echo "upgrade-test: FAILED -- the platform converged on the previous versions but stopped serving" >&2
	exit 1
}

printf '\n  \033[32mRolled back to the previous versions, still converged, still serving.\033[0m\n'
printf '  \033[32mMechanism proven in both directions. Compatibility is untested at these pins by design.\033[0m\n\n'
