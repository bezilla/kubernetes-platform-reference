#!/usr/bin/env bash
#
# Every environment, every tenant, rendered and checked. No cluster.
#
# The platform had exactly one environment for a long time, and "it works" meant
# "it works in the one shape anyone ever rendered". An environment file is a set
# of platform defaults layered UNDER a team's values, so a team that says nothing
# gets numbers appropriate to where the service is running, and a team that says
# something wins. That is only true if somebody checks it, in every combination,
# on every commit.
#
# What this proves: every environment renders for every tenant, the output is
# valid Kubernetes, and it satisfies the guardrails.
#
# What it does not prove: that staging and production have ever been brought up.
# They have not. Only `local` is installed by `make up`, because there is one
# kind cluster, and pretending otherwise would be the stub this repository keeps
# refusing to build. The environment files are a rendering contract, and this is
# the check that they hold.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0; skip=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  \033[33mskip\033[0m %s\n' "$1"; skip=$((skip + 1)); }

ENVS=(); for f in environments/*.yaml; do ENVS+=("$(basename "$f" .yaml)"); done
APPS=(); for d in apps/*/; do APPS+=("$(basename "$d")"); done
[ "${#ENVS[@]}" -gt 0 ] || { echo "check-environments: no environments/*.yaml" >&2; exit 1; }
[ "${#APPS[@]}" -gt 0 ] || { echo "check-environments: no apps/*/" >&2; exit 1; }

have_kubeconform=1
command -v kubeconform >/dev/null 2>&1 || have_kubeconform=0

printf '\n== every environment renders, for every tenant\n'
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
for env in "${ENVS[@]}"; do
	for app in "${APPS[@]}"; do
		out="${work}/${env}-${app}.yaml"
		if helm template "$app" charts/paved-road \
				-f "environments/${env}.yaml" -f "apps/${app}/values.yaml" \
				--namespace "tenant-${app}" > "$out" 2>"${out}.err"; then
			ok "$(printf '%-12s %-16s %s objects' "$env" "$app" "$(grep -c '^kind:' "$out")")"
		else
			bad "${env} / ${app} failed to render"
			sed 's/^/       /' "${out}.err" | head -4
		fi
	done
done

printf '\n== the rendered output is valid Kubernetes\n'
if [ "$have_kubeconform" -eq 0 ]; then
	note "$(( ${#ENVS[@]} * ${#APPS[@]} )) rendering(s) NOT validated: kubeconform is not on PATH"
else
	for f in "$work"/*.yaml; do
		[ -s "$f" ] || continue
		name="$(basename "$f" .yaml)"
		if kubeconform -strict -ignore-missing-schemas "$f" >/dev/null 2>&1; then
			ok "$name validates"
		else
			bad "$name does not validate"
			kubeconform -strict -ignore-missing-schemas "$f" 2>&1 | sed 's/^/       /' | head -3
		fi
	done
fi

# The point of the layer, asserted rather than described. A tenant that sets only
# the four required fields must come out differently in each environment -- if it
# does not, the files are decoration.
printf '\n== the environment layer actually changes the output\n'
minimal="${work}/minimal-values.yaml"
cat > "$minimal" <<'YAML'
owner: {team: search, contact: search@example.com}
image: {repository: platform.local/quote-api, tag: "0.1.0", pullPolicy: Never}
YAML
declare -a shapes=()
for env in "${ENVS[@]}"; do
	r="$(helm template minimal charts/paved-road -f "environments/${env}.yaml" -f "$minimal" \
		--namespace tenant-x 2>/dev/null)"
	replicas="$(printf '%s' "$r" | grep -m1 '^  replicas:' | awk '{print $2}')"
	cpu="$(printf '%s' "$r" | grep -m1 'cpu:' | awk '{print $2}')"
	pdb="$(printf '%s' "$r" | grep -c 'kind: PodDisruptionBudget')"
	envlabel="$(printf '%s' "$r" | grep -m1 -A1 'DEPLOYMENT_ENVIRONMENT' | tail -1 | tr -d ' "' | sed 's/value://')"
	printf '       %-12s replicas=%-3s cpu=%-7s PDB=%s environment=%s\n' \
		"$env" "${replicas:-?}" "${cpu:-?}" "$pdb" "${envlabel:-?}"
	shapes+=("${replicas}|${cpu}|${pdb}|${envlabel}")
done
uniq_shapes="$(printf '%s\n' "${shapes[@]}" | sort -u | grep -c .)"
if [ "$uniq_shapes" -eq "${#ENVS[@]}" ]; then
	ok "${#ENVS[@]} environments produce ${uniq_shapes} distinct shapes"
else
	bad "${#ENVS[@]} environments produce only ${uniq_shapes} distinct shape(s) -- the layer is decorative"
fi

printf '\n== the guardrails admit every environment\n'
# Rendered output must satisfy the same four rules admission enforces. Checked
# as fields rather than through the CLI, because `kyverno apply` resolves the
# namespaceSelector against a cluster that is not here -- the same trap that
# once made this repository's own policy suite report 42 passes over nothing.
for f in "$work"/*-*.yaml; do
	[ -s "$f" ] || continue
	name="$(basename "$f" .yaml)"
	case "$name" in minimal-values) continue ;; esac
	miss=''
	grep -q 'runAsNonRoot: true'                        "$f" || miss="${miss} runAsNonRoot"
	grep -q 'app.kubernetes.io/name:'                   "$f" || miss="${miss} name-label"
	grep -q 'platform.internal/team:'                   "$f" || miss="${miss} team-label"
	grep -q 'platform.internal/owner:'                  "$f" || miss="${miss} owner-label"
	grep -q 'readinessProbe:'                           "$f" || miss="${miss} readinessProbe"
	grep -qE 'limits:|limits: *\{'                      "$f" || miss="${miss} limits"
	grep -qE 'image: .*:[^ ]+'                          "$f" || miss="${miss} image-tag"
	grep -qE 'image: .*:latest'                         "$f" && miss="${miss} latest-tag"
	if [ -z "$miss" ]; then ok "$name satisfies all four guardrails"
	else bad "$name is missing:${miss}"; fi
done

printf '\n'
[ "$skip" -eq 0 ] || printf '%d check(s) SKIPPED -- not run, not passed\n' "$skip"
[ "$fail" -eq 0 ] || { printf '%d environment check(s) failed\n\n' "$fail"; exit 1; }
printf 'every environment renders, validates and passes the guardrails\n\n'
