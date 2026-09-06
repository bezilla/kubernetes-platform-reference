#!/usr/bin/env bash
#
# Proves versions.env is the single source of truth, rather than the first of
# several copies.
#
# The Argo CD Application manifests cannot source a shell file, so each one
# carries its chart version and repository literally. That duplication is
# unavoidable and it is exactly the kind that rots: someone bumps a chart in one
# place, the other keeps working, and the file that claims to be authoritative
# quietly stops being it.
#
# versions.env has asserted since it was written that `make check-versions`
# catches this. That target did not exist. This is it.
#
# Compared literally, not semantically: `v1.9.1` and `1.9.1` are a mismatch
# here, because Helm treats them as different strings and a pin that needs
# interpretation is not a pin.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# manifest : chart : version variable : repo variable
PAIRS=(
	"platform/applications/10-cert-manager.yaml:cert-manager:CERT_MANAGER_CHART_VERSION:CERT_MANAGER_REPO"
	"platform/applications/11-envoy-gateway.yaml:gateway-helm:ENVOY_GATEWAY_CHART_VERSION:ENVOY_GATEWAY_REPO"
	"platform/applications/12-kyverno.yaml:kyverno:KYVERNO_CHART_VERSION:KYVERNO_REPO"
	"platform/applications/31-otel-collector.yaml:opentelemetry-collector:OTEL_COLLECTOR_CHART_VERSION:OTEL_REPO"
)

field() { grep -m1 -E "^[[:space:]]+$2:" "$1" | sed "s/^[[:space:]]*$2:[[:space:]]*//; s/[[:space:]]*#.*//; s/[[:space:]]*$//"; }

printf '\n== chart versions match versions.env\n'
for pair in "${PAIRS[@]}"; do
	IFS=':' read -r manifest chart var _ <<<"$pair"
	[ -f "$manifest" ] || { bad "no such manifest: $manifest"; continue; }

	got_chart="$(field "$manifest" chart)"
	[ "$got_chart" = "$chart" ] || bad "${manifest}: chart is '${got_chart}', expected '${chart}'"

	want="${!var}"
	got="$(field "$manifest" targetRevision)"
	if [ "$got" = "$want" ]; then
		ok "$(printf '%-28s %s' "$chart" "$got")"
	else
		bad "${manifest}: targetRevision '${got}' != ${var} '${want}'"
	fi
done

# The repository is compared with the oci:// scheme and any chart path stripped:
# versions.env holds what `helm` needs on a command line, an Application holds
# what Argo CD needs in a repoURL, and for OCI those are legitimately different
# spellings of one registry. Everything before the difference still has to match.
printf '\n== chart repositories match versions.env\n'
for pair in "${PAIRS[@]}"; do
	IFS=':' read -r manifest chart _ repovar <<<"$pair"
	[ -f "$manifest" ] || continue
	want="${!repovar}"; want="${want#oci://}"; want="${want%/${chart}}"
	got="$(field "$manifest" repoURL)"; got="${got#oci://}"; got="${got%/${chart}}"
	if [ "$got" = "$want" ]; then
		ok "$(printf '%-28s %s' "$chart" "$got")"
	else
		bad "${manifest}: repoURL '${got}' != ${repovar} '${want}'"
	fi
done

# Argo CD itself is installed by up.sh, which reads the variable directly, so
# there is nothing to drift. Asserted rather than assumed: if that install ever
# stops reading versions.env, this catches it.
printf '\n== the imperative installs read versions.env\n'
for var in ARGOCD_CHART_VERSION ARGOCD_REPO KIND_NODE_IMAGE; do
	if grep -q "\$$var\|\${$var}" scripts/up.sh; then
		ok "up.sh uses \$$var"
	else
		bad "up.sh no longer reads \$$var -- it may be hard-coded now"
	fi
done

printf '\n'
[ "$fail" -eq 0 ] || { printf '%d version check(s) failed\n\n' "$fail"; exit 1; }
printf 'all version checks passed\n\n'
