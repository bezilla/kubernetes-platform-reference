#!/usr/bin/env bash
#
# Validates everything this platform installs against each Kubernetes version
# the CI matrix brings up -- structurally, without a cluster, in about a minute.
#
# The question it answers is narrow and specific: does any object we render name
# an API that a covered Kubernetes version does not have? That is the one thing
# the three-leg bring-up matrix catches which a single leg would not, and it is
# catchable statically. Everything else the matrix proves is bring-up behaviour.
#
# WHY IT DOES NOT USE -ignore-missing-schemas THE WAY lint.sh DOES
#
# lint.sh and check-environments.sh both run `kubeconform -strict
# -ignore-missing-schemas` with no -kubernetes-version, which means two things:
# they validate against the schema set for master rather than any version we
# actually run, and a missing schema is SKIPPED. Measured, on the fixture in
# tests/schema/:
#
#   kubeconform -strict -ignore-missing-schemas -kubernetes-version 1.34.0
#     -> Valid: 0, Invalid: 0, Errors: 0, Skipped: 1   exit 0
#   kubeconform -strict                         -kubernetes-version 1.34.0
#     -> Valid: 0, Invalid: 0, Errors: 1, Skipped: 0   exit 1
#
# A removed API and a custom resource are the SAME observation to kubeconform --
# "no schema for this kind" -- so the flag that makes CRDs tolerable is exactly
# the flag that makes a removed API invisible. Turning it on globally would make
# this check pass on the defect it exists to find.
#
# So the flag is not used. Instead every resource is classified by its API group
# against an explicit list of groups that ship WITH Kubernetes, and the two cases
# are separated after the fact:
#
#   built-in group, no schema at this version  -> REMOVED API, a finding
#   custom group,   no schema at this version  -> a CRD, counted and reported
#
# The list is explicit rather than a suffix rule because gateway.networking.k8s.io
# ends in k8s.io and is a CRD. A rule that matched on the suffix would classify
# every Gateway and HTTPRoute as built-in and report their absent schemas as
# removed APIs on all three legs.
#
# WHAT THIS DOES NOT CATCH
#
# Schema validation compares structure against a version's API definitions. It
# does not execute anything. It cannot see:
#
#   - a validating or mutating webhook rejecting the object (Kyverno's own
#     policies, cert-manager's webhook, Gateway API's validating webhook)
#   - a controller refusing a field it parses but will not act on
#   - admission-time defaulting that changes what is finally stored
#   - x-kubernetes-validations CEL rules on a CRD
#   - anything that depends on cluster state: RBAC, quota, another object's
#     existence, a StorageClass that is not there
#   - whether the thing actually starts
#
# A green run here means the YAML has the right shape for that API version. It
# does not mean the cluster will accept it, and it is not a substitute for a
# bring-up. Deprecated-but-present APIs are also not flagged: a schema still
# exists for them, so they validate. This finds REMOVALS.
#
# NETWORK
#
# kubeconform downloads every schema from raw.githubusercontent.com; it embeds
# none. That is not new here -- `make lint` already has this dependency, and a
# download failure there is an Error rather than a Skip even with
# -ignore-missing-schemas, so lint already fails closed when the network is
# down. This check makes three times as many requests, one set per version,
# which is why it is a separate target and a separate CI job rather than another
# step inside a required check. Same placement conversation pin-delta had.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

# Three outcomes, three codes, the same contract pin-delta.sh established. The
# distinction is the point: a run that could not fetch a schema has NOT found
# that the manifests are clean, and a caller that cannot tell those apart
# reports a network outage as a passing compatibility check.
E_NONE=0                # ran, every rendering validated on every version
E_FINDINGS=1            # ran, found removed APIs or schema violations
E_PRECONDITION=2        # could not run: a tool is missing, a chart would not
                        # pull, a schema set is unreachable

# API groups that ship with Kubernetes. Anything not on this list is treated as
# a custom resource, whose absent schema is expected rather than a finding.
BUILTIN_GROUPS="
core
apps
batch
autoscaling
policy
networking.k8s.io
rbac.authorization.k8s.io
storage.k8s.io
scheduling.k8s.io
coordination.k8s.io
discovery.k8s.io
node.k8s.io
certificates.k8s.io
admissionregistration.k8s.io
apiextensions.k8s.io
apiregistration.k8s.io
authentication.k8s.io
authorization.k8s.io
events.k8s.io
flowcontrol.apiserver.k8s.io
resource.k8s.io
"

# component : chart : repo var : manifest : namespace : version var
COMPONENTS=(
	"cert-manager:cert-manager:CERT_MANAGER_REPO:platform/applications/10-cert-manager.yaml:cert-manager:CERT_MANAGER_CHART_VERSION"
	"envoy-gateway:gateway-helm:ENVOY_GATEWAY_REPO:platform/applications/11-envoy-gateway.yaml:envoy-gateway-system:ENVOY_GATEWAY_CHART_VERSION"
	"kyverno:kyverno:KYVERNO_REPO:platform/applications/12-kyverno.yaml:kyverno:KYVERNO_CHART_VERSION"
	"otel-collector:opentelemetry-collector:OTEL_REPO:platform/applications/31-otel-collector.yaml:platform-observability:OTEL_COLLECTOR_CHART_VERSION"
)

for t in helm kubeconform yq jq; do
	command -v "$t" >/dev/null 2>&1 || {
		printf 'schema-check: %s is not on PATH\n' "$t" >&2; exit "$E_PRECONDITION"; }
done

# The versions come from versions.env, not from a list written here, so the
# check covers exactly what the matrix brings up and cannot drift from it. The
# exact patch is used rather than the minor: the schema sets are published per
# patch, and validating against v1.32.11 when the leg runs v1.32.11 removes a
# judgement call about whether the difference could matter.
VERSIONS=()
for var in CI_K8S_IMAGE_132 CI_K8S_IMAGE_133 CI_K8S_IMAGE_134; do
	img="${!var:-}"
	[ -n "$img" ] || { printf 'schema-check: %s is not set in versions.env\n' "$var" >&2
		exit "$E_PRECONDITION"; }
	v="${img#*:v}"; v="${v%%@*}"
	case "$v" in
		[0-9]*.[0-9]*.[0-9]*) VERSIONS+=("$v") ;;
		*) printf 'schema-check: could not read a version out of %s=%s\n' "$var" "$img" >&2
		   exit "$E_PRECONDITION" ;;
	esac
done
[ "${#VERSIONS[@]}" -gt 0 ] || {
	printf 'schema-check: no Kubernetes versions derived from versions.env\n' >&2
	exit "$E_PRECONDITION"; }

WORK="${SCHEMA_CHECK_WORKDIR:-}"
if [ -z "$WORK" ]; then
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/schema-check.XXXXXX")" || {
		printf 'schema-check: could not create a working directory\n' >&2
		exit "$E_PRECONDITION"; }
	trap 'rm -rf "$WORK"' EXIT
fi
mkdir -p "$WORK/corpus"

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# --- build the corpus ---------------------------------------------------------

printf '\n\033[1m== rendering everything this platform installs\033[0m\n'

rendered=0

# The four platform charts, at their pinned versions, with the values block the
# Application actually carries and --include-crds. Rendering with different
# values than the platform uses would validate a configuration nobody installs.
for spec in "${COMPONENTS[@]}"; do
	IFS=':' read -r name chart repovar manifest ns vervar <<<"$spec"
	repo="${!repovar}"; ver="${!vervar}"
	[ -f "$manifest" ] || {
		printf 'schema-check: no such manifest: %s\n' "$manifest" >&2; exit "$E_PRECONDITION"; }

	if [ "${repo#oci://}" != "$repo" ]; then
		helm pull "$repo" --version "$ver" --untar --untardir "$WORK/charts/$name" >/dev/null 2>&1
	else
		helm pull "$chart" --repo "$repo" --version "$ver" --untar --untardir "$WORK/charts/$name" >/dev/null 2>&1
	fi
	[ -d "$WORK/charts/$name/$chart" ] || {
		printf 'schema-check: could not pull %s %s from %s\n' "$chart" "$ver" "$repo" >&2
		exit "$E_PRECONDITION"; }

	vals="$WORK/$name.values.yaml"
	yq -r '.spec.source.helm.values // ""' "$manifest" > "$vals" 2>/dev/null || {
		printf 'schema-check: could not read the values block from %s\n' "$manifest" >&2
		exit "$E_PRECONDITION"; }

	out="$WORK/corpus/chart-${name}.yaml"
	helm template "$name" "$WORK/charts/$name/$chart" -f "$vals" \
		--namespace "$ns" --include-crds > "$out" 2>/dev/null
	[ -s "$out" ] || {
		printf 'schema-check: %s %s rendered nothing with %s values\n' "$chart" "$ver" "$manifest" >&2
		exit "$E_PRECONDITION"; }
	rendered=$((rendered + 1))
	ok "$(printf '%-16s %-10s %4d objects' "$name" "$ver" "$(grep -c '^kind:' "$out")")"
done

# The authored chart, every environment against every tenant -- the same matrix
# check-environments.sh renders, because that is what actually reaches a cluster.
ENVS=(); for f in environments/*.yaml; do [ -e "$f" ] && ENVS+=("$(basename "$f" .yaml)"); done
APPS=(); for d in apps/*/; do [ -d "$d" ] && APPS+=("$(basename "$d")"); done
[ "${#ENVS[@]}" -gt 0 ] && [ "${#APPS[@]}" -gt 0 ] || {
	printf 'schema-check: no environments/*.yaml or no apps/*/\n' >&2; exit "$E_PRECONDITION"; }

for env in "${ENVS[@]}"; do
	for app in "${APPS[@]}"; do
		out="$WORK/corpus/app-${env}-${app}.yaml"
		helm template "$app" charts/paved-road \
			-f "environments/${env}.yaml" -f "apps/${app}/values.yaml" \
			--namespace "tenant-${app}" > "$out" 2>/dev/null
		[ -s "$out" ] || {
			printf 'schema-check: charts/paved-road rendered nothing for %s/%s\n' "$env" "$app" >&2
			exit "$E_PRECONDITION"; }
		rendered=$((rendered + 1))
	done
done
ok "$(printf '%-16s %-10s %4d rendering(s)' "paved-road" "authored" "$(( ${#ENVS[@]} * ${#APPS[@]} ))")"

# The static manifests, the same set lint.sh validates, with the same two
# exclusions: kind's own config format and Helm values files are not Kubernetes
# objects and no schema describes either.
statics=0
for f in bootstrap/*.yaml platform/applications/*.yaml platform/config/*/*.yaml tests/guardrails/*.yaml; do
	[ -e "$f" ] || continue
	case "$f" in *-values.yaml|*/values.yaml) continue ;; esac
	cp "$f" "$WORK/corpus/static-$(printf '%s' "$f" | tr '/' '-')"
	statics=$((statics + 1))
done
[ "$statics" -gt 0 ] || {
	printf 'schema-check: no static manifests were collected\n' >&2; exit "$E_PRECONDITION"; }
ok "$(printf '%-16s %-10s %4d file(s)' "static" "manifests" "$statics")"

corpus_files="$(find "$WORK/corpus" -type f -name '*.yaml' | wc -l | tr -d ' ')"
[ "$corpus_files" -gt 0 ] || {
	printf 'schema-check: the corpus is empty -- nothing was rendered\n' >&2; exit "$E_PRECONDITION"; }

# --- validate -----------------------------------------------------------------
#
# Removal is detected as a DIFFERENTIAL, not as an absence.
#
# The naive rule -- "built-in group with no schema at this version means the API
# was removed" -- is wrong, and measurably so. kubernetes-json-schema ships no
# schema for apiextensions.k8s.io/v1 CustomResourceDefinition at ANY version, in
# either the standalone or the standalone-strict set (checked: 404 on v1.32.11,
# v1.33.12 and v1.34.0, both variants). Under that rule every CRD these charts
# install is reported as a removed API, which is 49 false findings per leg and
# exactly the kind of check this repository keeps discovering was never checking.
#
# So a kind is only reported as removed when its schema is PRESENT at one covered
# version and ABSENT at another. That is a fact about the versions rather than a
# fact about the schema source, and it needs no allow-list to maintain.
#
# The cost of that soundness, stated plainly: an API removed BEFORE the oldest
# covered version is absent from all three legs, so it lands in "not covered by
# the schema source" rather than in "removed". That set is printed rather than
# swallowed, precisely so it cannot be mistaken for a clean bill of health.

printf '\n\033[1m== validating against each version in the matrix\033[0m\n'

groups_re="$(printf '%s' "$BUILTIN_GROUPS" | grep -v '^$' | paste -sd'|' -)"
kindmap="$WORK/kindmap.tsv"
: > "$kindmap"
invalid_all="$WORK/invalid.tsv"
: > "$invalid_all"
prev_total=''

for kver in "${VERSIONS[@]}"; do
	json="$WORK/result-${kver}.json"
	# -verbose is not cosmetic. Without it kubeconform omits VALID resources from
	# the JSON entirely, so `.resources` holds only problems -- a corpus with
	# nothing wrong yields an empty array, indistinguishable from a corpus that
	# was never read. Measured: 0 resources without it, 1 with it, on a manifest
	# that validates.
	kubeconform -strict -verbose -output json -kubernetes-version "$kver" \
		-schema-location default \
		"$WORK/corpus"/*.yaml > "$json" 2>/dev/null
	[ -s "$json" ] || {
		printf 'schema-check: kubeconform produced no output for %s\n' "$kver" >&2
		exit "$E_PRECONDITION"; }

	# THE CONTROL. A schema that could not be DOWNLOADED and a schema that does
	# not EXIST are both statusError; only the message separates them. Collapsed,
	# an outage would read as a clean run. A download failure is therefore not a
	# result at all -- it aborts, and nothing is concluded about the manifests.
	netfail="$(jq -r '[.resources[] | select(.status == "statusError")
	                  | select(.msg | test("failed downloading schema"))] | length' "$json")"
	if [ "${netfail:-0}" -gt 0 ]; then
		printf '\nschema-check: %d schema(s) could not be DOWNLOADED for %s.\n' "$netfail" "$kver" >&2
		jq -r '[.resources[] | select(.status == "statusError")
		        | select(.msg | test("failed downloading schema")) | .msg] | .[0]' "$json" \
			| cut -c1-160 | sed 's/^/    /' >&2
		printf '\n    This is a fetch failure, not a compatibility result. The manifests\n' >&2
		printf '    were not checked, so nothing is concluded about them.\n' >&2
		exit "$E_PRECONDITION"
	fi

	total="$(jq -r '.resources | length' "$json")"
	[ "${total:-0}" -gt 0 ] || {
		printf 'schema-check: kubeconform reported ZERO resources for %s, from %d corpus file(s).\n' \
			"$kver" "$corpus_files" >&2
		printf 'schema-check: reporting nothing is not the same as finding nothing.\n' >&2
		exit "$E_PRECONDITION"; }

	# Every leg reads the same corpus, so every leg must see the same number of
	# objects. A leg that silently read fewer would under-report findings in
	# proportion to what it dropped, and would still look green.
	if [ -n "$prev_total" ] && [ "$total" != "$prev_total" ]; then
		printf 'schema-check: %s saw %d resources, an earlier version saw %d.\n' \
			"$kver" "$total" "$prev_total" >&2
		printf 'schema-check: the corpus is identical for every version, so this is a\n' >&2
		printf 'schema-check: parsing failure, not a compatibility difference.\n' >&2
		exit "$E_PRECONDITION"
	fi
	prev_total="$total"

	rows="$WORK/rows-${kver}.tsv"
	jq -r '.resources[]
	       | [ (.status // "?"), (.version // ""), (.kind // "?"),
	           (.name // "?"), (.filename // "?"),
	           ((.msg // "") | gsub("\t"; " ")) ] | @tsv' "$json" > "$rows"

	awk -F'\t' -v kver="$kver" '
		{ st=$1; av=$2; k=$3; msg=$6
		  n = split(av, p, "/"); g = (n > 1 ? p[1] : "core")
		  cls = (st == "statusError" && msg ~ /could not find schema/) ? "NOSCHEMA" : "HASSCHEMA"
		  key = kver "\t" g "\t" av "\t" k "\t" cls
		  if (!(key in seen)) { seen[key] = 1; print key } }
	' "$rows" >> "$kindmap"

	awk -F'\t' -v kver="$kver" '$1 == "statusInvalid" {
		print kver "\t" $2 "/" $3 "\t" $4 "\t" substr($6, 1, 70) }' "$rows" >> "$invalid_all"

	valid_n="$(awk -F'\t' '$1=="statusValid"' "$rows" | grep -c . | tr -d ' ')"
	noschema_n="$(awk -F'\t' '$1=="statusError" && $6 ~ /could not find schema/' "$rows" | grep -c . | tr -d ' ')"
	invalid_n="$(awk -F'\t' '$1=="statusInvalid"' "$rows" | grep -c . | tr -d ' ')"
	printf '  \033[32mok\033[0m   %s\n' \
		"$(printf 'k8s %-9s %4d objects  %4d valid  %4d invalid  %4d without a schema' \
			"$kver" "$total" "$valid_n" "$invalid_n" "$noschema_n")"
done

# --- classify -----------------------------------------------------------------

nvers="${#VERSIONS[@]}"

# One row per (apiVersion, kind): whether the group is built-in, which covered
# versions had a schema, and which did not.
summary="$WORK/summary.tsv"
awk -F'\t' -v re="^($groups_re)$" -v n="$nvers" '
	{ kv=$1; g=$2; av=$3; k=$4; cls=$5; key = av "\t" k
	  isb[key] = (g ~ re) ? 1 : 0
	  if (cls == "NOSCHEMA") { miss[key] = miss[key] (miss[key] ? "," : "") kv; nm[key]++ }
	  else                   { has[key]  = has[key]  (has[key]  ? "," : "") kv; nh[key]++ } }
	END { for (key in isb)
	        printf "%s\t%d\t%d\t%d\t%s\t%s\n", key, isb[key], nm[key]+0, nh[key]+0,
	               (miss[key] ? miss[key] : "-"), (has[key] ? has[key] : "-") }
' "$kindmap" | sort > "$summary"

# Removed: built-in, missing on at least one covered version and present on at
# least one other. Absent everywhere is a coverage gap, reported separately.
removed="$WORK/removed.tsv"
awk -F'\t' '$3 == 1 && $4 > 0 && $5 > 0' "$summary" > "$removed"
uncovered_builtin="$WORK/uncovered-builtin.tsv"
awk -F'\t' '$3 == 1 && $5 == 0' "$summary" > "$uncovered_builtin"
uncovered_custom="$WORK/uncovered-custom.tsv"
awk -F'\t' '$3 == 0 && $5 == 0' "$summary" > "$uncovered_custom"

removed_n="$(grep -c . "$removed" | tr -d ' ')"
invalid_n="$(grep -c . "$invalid_all" | tr -d ' ')"
ub_n="$(grep -c . "$uncovered_builtin" | tr -d ' ')"
uc_n="$(grep -c . "$uncovered_custom" | tr -d ' ')"
findings=$((removed_n + invalid_n))

# --- report -------------------------------------------------------------------

if [ "$removed_n" -gt 0 ]; then
	printf '\n\033[1m== API PRESENT ON ONE COVERED VERSION AND ABSENT ON ANOTHER\033[0m\n'
	printf '  A built-in API whose schema exists for some versions in the matrix and\n'
	printf '  not others -- a removal (or an addition) inside the covered range. On the\n'
	printf '  versions listed as missing, the API server rejects this object.\n\n'
	printf '    %-40s %-22s %s\n' 'APIVERSION/KIND' 'MISSING ON' 'PRESENT ON'
	awk -F'\t' '{ printf "    %-40s %-22s %s\n", $1 "/" $2, $6, $7 }' "$removed"
fi

if [ "$invalid_n" -gt 0 ]; then
	printf '\n\033[1m== DOES NOT MATCH THE SCHEMA FOR THIS VERSION\033[0m\n'
	printf '  The API exists at this version and the object does not fit it: a field\n'
	printf '  that moved, a type that changed, a required field that is not set.\n\n'
	printf '    %-9s %-40s %-24s %s\n' 'K8S' 'APIVERSION/KIND' 'NAME' 'WHY'
	awk -F'\t' '{ printf "    %-9s %-40s %-24s %s\n", $1, $2, $3, $4 }' "$invalid_all"
fi

printf '\n\033[1m== not validated, on every covered version\033[0m\n'
printf '  Neither passed nor failed. The schema source ships nothing for these, so\n'
printf '  their FIELDS were never checked on any leg -- only that the YAML parses.\n'
if [ "$uc_n" -gt 0 ]; then
	printf '\n  custom resources (%d kinds) -- expected: no CRD has a schema here\n' "$uc_n"
	awk -F'\t' '{ printf "    %s/%s\n", $1, $2 }' "$uncovered_custom" | sort | sed 's/$//'
fi
if [ "$ub_n" -gt 0 ]; then
	printf '\n  built-in groups (%d kinds) -- the schema source ships no schema for these\n' "$ub_n"
	printf '  at any covered version, so an API removed BEFORE %s is indistinguishable\n' "${VERSIONS[0]}"
	printf '  from a kind that was never shipped. Read this list rather than trusting it.\n'
	awk -F'\t' '{ printf "    %s/%s\n", $1, $2 }' "$uncovered_builtin" | sort
fi

printf '\n'
printf '  corpus: %d rendering(s) + %d static file(s) = %d file(s), %d objects each leg\n' \
	"$rendered" "$statics" "$corpus_files" "$prev_total"
printf '  versions: %s\n' "$(printf '%s ' "${VERSIONS[@]}")"
printf '  what this proves: structure against each version'"'"'s API definitions.\n'
printf '  what it does not: webhooks, controllers, CEL rules, cluster state, runtime.\n\n'

if [ "$findings" -eq 0 ]; then
	printf '  \033[32mNo API removed inside the covered range, and no schema violation,\033[0m\n'
	printf '  \033[32mon any of the %d versions.\033[0m\n\n' "$nvers"
	exit "$E_NONE"
fi
printf '  \033[31m%d finding(s): %d removed API, %d schema violation(s).\033[0m\n\n' \
	"$findings" "$removed_n" "$invalid_n"
exit "$E_FINDINGS"
