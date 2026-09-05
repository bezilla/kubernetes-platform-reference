#!/usr/bin/env bash
#
# Everything that can be checked without a cluster.
#
# The authored chart is linted and rendered, because `helm lint` alone passes on
# a chart that produces invalid YAML -- it checks the chart, not the output. The
# rendered output is then validated, so a template that emits broken indentation
# fails here rather than at sync time.
#
# Validation is kubeconform, not `kubectl --dry-run=client`. Client dry-run still
# reaches the API server for its OpenAPI schema, so it needs a cluster -- which
# CI does not have, and which is exactly when you most want this to run. It also
# hangs rather than failing when the cluster is merely unreachable.
#
# -ignore-missing-schemas: Gateway API, cert-manager and Kyverno types are CRDs
# with no schema in the upstream bundle. Their YAML is still parsed and their
# apiVersion/kind still checked; the field-level schema is not. That is the
# honest limit of validating custom resources without a cluster, and it is why
# the guardrail suite in tests/ exists as well.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

printf '\n== helm lint\n'
if helm lint charts/paved-road --values apps/quote-api/values.yaml >/dev/null 2>&1; then
	ok 'charts/paved-road lints against the sample values'
else
	bad 'charts/paved-road failed helm lint'
	helm lint charts/paved-road --values apps/quote-api/values.yaml 2>&1 | sed 's/^/       /'
fi

printf '\n== helm template\n'
if out="$(helm template quote-api charts/paved-road --values apps/quote-api/values.yaml \
		--namespace tenant-quotes 2>&1)"; then
	ok 'chart renders'
	if printf '%s' "$out" | kubeconform -strict -ignore-missing-schemas -summary >/dev/null 2>&1; then
		ok 'rendered output validates'
	else
		bad 'rendered output does not validate'
		printf '%s' "$out" | kubeconform -strict -ignore-missing-schemas 2>&1 | sed 's/^/       /' | head -6
	fi
else
	bad 'chart failed to render'
	printf '%s\n' "$out" | sed 's/^/       /' | head -10
fi

printf '\n== values schema rejects what it claims to\n'
# A schema nobody has watched reject something is a schema nobody knows works.
for bad_values in \
	'owner: {team: payments}' \
	'owner: {team: payments, contact: a@b.c}
image: {repository: x, tag: latest}' \
	'owner: {team: payments, contact: a@b.c}
image: {repository: x, tag: "1"}
resources: {tier: enormous}'
do
	printf '%s\n' "$bad_values" > /tmp/bad-values-$$.yaml
	if helm template t charts/paved-road -f /tmp/bad-values-$$.yaml >/dev/null 2>&1; then
		bad "values.schema.json ACCEPTED invalid values: $(printf '%s' "$bad_values" | tr '\n' ' ' | cut -c1-60)"
	else
		ok "rejected: $(printf '%s' "$bad_values" | tr '\n' ' ' | cut -c1-58)"
	fi
	rm -f /tmp/bad-values-$$.yaml
done

printf '\n== manifests validate\n'
before=$fail
for f in bootstrap/*.yaml platform/applications/*.yaml platform/config/*/*.yaml tests/guardrails/*.yaml; do
	# Two deliberate exclusions, both because they are not Kubernetes objects:
	# cluster/kind.yaml is kind's own config format, and *-values.yaml files are
	# Helm inputs. Neither has a kind, and no schema describes either.
	[ -e "$f" ] || continue
	case "$f" in *-values.yaml) continue ;; esac
	if ! kubeconform -strict -ignore-missing-schemas "$f" >/dev/null 2>&1; then
		bad "does not validate: $f"
		kubeconform -strict -ignore-missing-schemas "$f" 2>&1 | sed 's/^/       /' | head -3
	fi
done
[ "$fail" -eq "$before" ] && ok 'every manifest validates'

printf '\n== versions are pinned\n'
# A floating tag in the platform is the same defect the guardrails reject in
# workloads, so it is checked the same way.
if grep -nE "targetRevision: *['\"]?(HEAD|latest|\*)" platform/applications/*.yaml >/dev/null 2>&1; then
	bad 'an Application uses a floating targetRevision'
	grep -nE "targetRevision: *['\"]?(HEAD|latest|\*)" platform/applications/*.yaml | sed 's/^/       /'
else
	ok 'no floating chart versions'
fi

printf '\n'
[ "$fail" -eq 0 ] || { printf '%d check(s) failed\n\n' "$fail"; exit 1; }
printf 'all checks passed\n\n'
