#!/usr/bin/env bash
#
# Six violations refused, one compliant deploy admitted.
#
# This is the demonstration and it is also the test. A guardrail nobody has
# watched reject something is a guardrail nobody knows works -- and that is not
# hypothetical here: `disallow-latest-tag` sat in Enforce for a day while
# admitting `:latest`, because its pattern used a `|` that Kyverno does not have
# and so matched every image. Reading the policy did not find it. Deploying a
# violation found it immediately.
#
# Each fixture is tests/guardrails/compliant.yaml with exactly one rule broken,
# so a rejection can only be caused by the thing that was broken. The script
# fails if any violation is ADMITTED, and fails if the compliant deploy is
# REJECTED -- the second is the more dangerous direction, because a policy that
# blocks correct manifests teaches teams to ask for exemptions.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NS=tenant-quotes
FIXTURES=tests/guardrails
pass=0; fail=0

kubectl get ns "$NS" >/dev/null 2>&1 || { echo "demo-guardrails: no ${NS} namespace. Run 'make up'." >&2; exit 1; }

cleanup() { kubectl -n "$NS" delete deploy -l app.kubernetes.io/name=policy-probe --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

printf '\n\033[1mEach of these breaks exactly one guardrail. All six must be refused.\033[0m\n\n'

for f in "$FIXTURES"/violation-*.yaml; do
	name="$(basename "$f" .yaml | sed 's/^violation-//')"
	out="$(kubectl apply -f "$f" 2>&1 | tr -d '\000')"
	# Three outcomes, not two. A manifest can also be refused by the API server
	# itself -- a bad selector, a schema error -- and that is NOT the guardrail
	# working: admission policy never ran. Collapsing that into "rejected" would
	# have this suite report success while testing nothing, so it is called out
	# separately and counted as a failure of the fixture.
	if printf '%s' "$out" | grep -qi 'is invalid\|error validating'; then
		printf '  \033[31mBAD FIXTURE\033[0m  %-19s  refused by the API server, not by a policy\n' "$name"
		printf '%s\n\n' "$out" | sed 's/^/            /' | head -3
		fail=$((fail + 1))
		continue
	fi
	if printf '%s' "$out" | grep -q 'denied the request'; then
		policy="$(printf '%s' "$out" | grep -oE '^[a-z-]+:$' | head -1 | tr -d ':')"
		rule="$(printf '%s' "$out" | grep -oE '^ +autogen-[a-z-]+' | head -1 | tr -d ' ')"
		# -E: basic sed has no (a|b) alternation, and Kyverno says both
		# "validation error" and "validation failure" depending on the rule type.
		reason="$(printf '%s' "$out" | sed -nE "s/.*validation (error|failure): //p" | head -1 | cut -c1-92)"
		printf '  \033[32mREJECTED\033[0m  %-22s  \033[1m%s\033[0m\n' "$name" "${policy:-?}"
		printf '            rule    %s\n' "${rule:-?}"
		printf '            reason  %s...\n\n' "$reason"
		pass=$((pass + 1))
	else
		printf '  \033[31mADMITTED\033[0m  %-22s  -- this violation was NOT caught\n' "$name"
		printf '            %s\n\n' "$(printf '%s' "$out" | head -1)"
		kubectl -n "$NS" delete -f "$f" --wait=false >/dev/null 2>&1 || true
		fail=$((fail + 1))
	fi
done

printf '\033[1mThe same Deployment with nothing broken. It must be admitted.\033[0m\n\n'
if out="$(kubectl apply -f "$FIXTURES/compliant.yaml" 2>&1)"; then
	printf '  \033[32mADMITTED\033[0m  compliant               %s\n' "$out"
	kubectl -n "$NS" rollout status deploy/policy-probe --timeout=120s 2>&1 | tail -1 | sed 's/^/            /'
	pass=$((pass + 1))
else
	printf '  \033[31mREJECTED\033[0m  compliant -- a guardrail is blocking a correct manifest\n'
	printf '%s\n' "$out" | sed 's/^/            /' | head -6
	fail=$((fail + 1))
fi

printf '\n%d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
