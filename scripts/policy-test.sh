#!/usr/bin/env bash
#
# The offline guardrail suite: every policy, both directions, no cluster.
#
# `kyverno test` evaluates the real policy files against fixture Pods and
# compares each verdict against the one written down in kyverno-test.yaml. It is
# the check that would have caught disallow-latest-tag admitting `:latest`,
# because it asserts not only that violations fail but that compliant resources
# pass -- a policy matching everything and a policy matching nothing both look
# fine if you only assert one direction.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v kyverno >/dev/null 2>&1 || {
	cat >&2 <<'EOF'
policy-test: the kyverno CLI is not installed.

    brew install kyverno
    or https://github.com/kyverno/kyverno/releases

This gate does not skip: a policy suite that quietly does not run is how a
policy that matches everything reaches production.
EOF
	exit 1
}

exec kyverno test tests/guardrails
