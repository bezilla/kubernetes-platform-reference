#!/usr/bin/env bash
#
# What a pin bump changed, read from two chart tarballs. No cluster.
#
# The question this answers is not "did rollback fail" -- that needs a live
# cluster and is a later phase. It is "did this version change alter what a
# rollback would MEAN", asked at the moment the pin moves and before anything
# is deployed anywhere.
#
# It exists because that analysis was done by hand once: 39 CRD files compared
# across four components and 164 rendered resources set-diffed. Doing it by hand
# does not survive the next bump, and the interesting findings were not the ones
# anybody predicted.
#
# WHAT IT REPORTS, and why each matters:
#
#   storage version moved   Objects are persisted at the storage version. If it
#                           moved, the older CRD cannot read what the newer one
#                           wrote, and rollback from this pin stops being
#                           possible at all. This is the one with teeth.
#
#   served version changed  A version that stops being served breaks objects and
#                           clients still using it. Reported separately from the
#                           field comparison on purpose -- see the note above
#                           common_versions() for why that is not redundant.
#
#   resource set changed    Something one chart declares and the other does not.
#                           Going back, Argo CD prunes what the newer chart
#                           added; the reverse leaves the older chart's resource
#                           unmanaged.
#
#   field added             The hazard that hides. A field only the newer CRD
#                           knows is SILENTLY PRUNED on the way back -- not
#                           rejected, dropped, with Argo CD reporting Synced.
#                           The storage-version check does not catch this,
#                           because it is a schema change WITHIN a version.
#
#   field removed           The pinned chart dropped it. Objects setting it lose
#                           it on the way forward; it returns on the way back.
#
#   constraint tightened    The only one of the six with a hazard in the
#                           direction this platform actually deploys. The five
#                           above ask what a ROLLBACK would lose -- a path not
#                           tested here yet. A tightened constraint breaks
#                           FORWARD: if a chart narrows a regex and a live object
#                           holds a value the new one rejects, the upgrade fails.
#                           Nothing above can see it, because the field is
#                           present on both sides and only its validation moved.
#
#                           Scoped to tightening, not to change. Loosening is
#                           safe forward and is not reported: a diff of every
#                           keyword over seventeen thousand field paths is mostly
#                           reworded descriptions, and a report people skip is
#                           worse than no report.
#
# IT DOES NOT FAIL THE BUILD. Everything here is a fact about a decision an
# upstream maintainer made, not a defect in this repository. A check that goes
# red every time someone upstream does something normal is a check people learn
# to ignore, and then it is worse than no check.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

# Three outcomes, three codes -- "could not run" is not "ran and found nothing",
# and a caller that cannot tell them apart reports a failed chart pull as a
# clean bill of health. 1 means THERE IS SOMETHING TO READ, not that anything is
# broken; whatever runs this must not treat it as a failure.
E_NONE=0                # ran, no delta
E_FINDINGS=1            # ran, found deltas -- informational, never a defect
E_PRECONDITION=2        # could not run: a chart would not pull, a values block
                        # would not render, a tool is missing

# component : chart : repo var : manifest : namespace : previous var : pinned var
COMPONENTS=(
	"cert-manager:cert-manager:CERT_MANAGER_REPO:platform/applications/10-cert-manager.yaml:cert-manager:UPGRADE_FROM_CERT_MANAGER:CERT_MANAGER_CHART_VERSION"
	"envoy-gateway:gateway-helm:ENVOY_GATEWAY_REPO:platform/applications/11-envoy-gateway.yaml:envoy-gateway-system:UPGRADE_FROM_ENVOY_GATEWAY:ENVOY_GATEWAY_CHART_VERSION"
	"kyverno:kyverno:KYVERNO_REPO:platform/applications/12-kyverno.yaml:kyverno:UPGRADE_FROM_KYVERNO:KYVERNO_CHART_VERSION"
	"otel-collector:opentelemetry-collector:OTEL_REPO:platform/applications/31-otel-collector.yaml:platform-observability:UPGRADE_FROM_OTEL_COLLECTOR:OTEL_COLLECTOR_CHART_VERSION"
)

for t in helm yq jq; do
	command -v "$t" >/dev/null 2>&1 || {
		echo "pin-delta: $t is not on PATH" >&2; exit "$E_PRECONDITION"; }
done

# PIN_DELTA_WORKDIR lets a caller keep the pulled charts between runs. Unset, it
# is a temp directory that goes away, so the default leaves nothing behind.
WORK="${PIN_DELTA_WORKDIR:-}"
if [ -z "$WORK" ]; then
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/pin-delta.XXXXXX")" || {
		echo "pin-delta: could not create a working directory" >&2; exit "$E_PRECONDITION"; }
	trap 'rm -rf "$WORK"' EXIT
fi
mkdir -p "$WORK"

findings=0
VERDICT_PINS=''
declare -a F_STORAGE=() F_SERVED=() F_RESOURCE=() F_ADDED=() F_REMOVED=() F_TIGHTEN=()

note() { printf '  %s\n' "$1"; }

# --- pulling and rendering ----------------------------------------------------

pull_chart() {  # dest chart repo version
	local dest="$1" chart="$2" repo="$3" ver="$4"
	[ -d "$dest/$chart" ] && return 0     # already cached in a kept workdir
	mkdir -p "$dest"
	if [ "${repo#oci://}" != "$repo" ]; then
		helm pull "$repo" --version "$ver" --untar --untardir "$dest" >/dev/null 2>&1
	else
		helm pull "$chart" --repo "$repo" --version "$ver" --untar --untardir "$dest" >/dev/null 2>&1
	fi
}

render() {      # chartdir release valuesfile namespace outfile
	helm template "$2" "$1" -f "$3" --namespace "$4" --include-crds 2>/dev/null > "$5"
	[ -s "$5" ]
}

# Builds three flat tables per side. Flat text rather than one JSON document
# because the schemas are large -- Kyverno's rendered chart is 5.8M -- and a
# recursive walk over that in jq exhausts memory, while `jq --stream` reads it in
# constant space. The tables are then comparable with sort/comm.
model() {       # rendered.yaml prefix
	local src="$1" pre="$2" all="$2.all.json"
	yq ea -o=json '[.]' "$src" > "$all" 2>/dev/null || return 1

	jq -r '.[] | select(.kind != null) | "\(.kind)/\(.metadata.name // "?")"' "$all" \
		| sort -u > "$pre.resources" || return 1

	# doc index, version index, crd, version, served, storage
	jq -r 'to_entries[] | select(.value.kind == "CustomResourceDefinition")
	       | .key as $d | .value.metadata.name as $n
	       | (.value.spec.versions // [] | to_entries[])
	       | "\($d)\t\(.key)\t\($n)\t\(.value.name)\t\(.value.served)\t\(.value.storage)"' \
		"$all" > "$pre.vermap" || return 1

	jq -r --stream '
		select(length == 2) | .[0] as $p
		| ($p | index("openAPIV3Schema")) as $i
		| select($i != null)
		| ($p | index("versions")) as $vj
		| select($vj != null)
		| ([ range($i + 1; ($p | length)) as $k
		     | select($p[$k-1] == "properties") | $p[$k] ] | join(".")) as $f
		| select($f != "")
		| "\($p[0])\t\($p[$vj+1])\t\($f)"' "$all" | sort -u > "$pre.rawfields" || return 1

	# Constraint keywords, for the sixth check. Same stream, filtered to the
	# keywords that can make a valid object invalid -- description and default
	# are deliberately absent, and they are most of the volume.
	#
	# `required` is a sibling of `properties`, not a key under the field it
	# constrains, so its VALUE names the child: it is re-keyed onto that child.
	jq -r --stream '
		select(length == 2) | .[0] as $p | .[1] as $v
		| ($p | index("openAPIV3Schema")) as $i
		| select($i != null)
		| ($p | index("versions")) as $vj
		| select($vj != null)
		| [ range($i + 1; ($p | length)) | select($p[. - 1] == "properties") ] as $ix
		| (if ($ix | length) > 0 then ($ix | max) else $i end) as $last
		| ([ $ix[] | $p[.] ] | join(".")) as $f0
		| (if $f0 == "" then "(root)" else $f0 end) as $f
		| ($p[($last + 1):] | map(select(type == "string")) | join(".")) as $kw
		| select($kw != "")
		| ($kw | split(".") | last) as $leaf
		| select($leaf | IN("type","pattern","enum","required","nullable",
		                    "minLength","minimum","minItems",
		                    "maxLength","maximum","maxItems"))
		| if $leaf == "required"
		  then "\($p[0])\t\($p[$vj+1])\t\(if $f0 == "" then $v else "\($f0).\($v)" end)\t\($kw)\ttrue"
		  else "\($p[0])\t\($p[$vj+1])\t\($f)\t\($kw)\t\($v)"
		  end' "$all" | sort -u > "$pre.rawconstraints" || return 1

	# Resolve (doc,versionIndex) to (crd,version) so the two sides are comparable
	# by name -- document order is an artefact of rendering, not of the chart.
	awk -F'\t' 'NR==FNR { key[$1"\t"$2] = $3"\t"$4; next }
	            { k = $1"\t"$2; if (k in key) print key[k]"\t"$3 }' \
		"$pre.vermap" "$pre.rawfields" | sort -u > "$pre.fields"

	# Same resolution, then collapse enum members into one comma-joined row per
	# (crd, version, field, keyword). Grouped with sort + awk rather than awk's
	# asort, which is a gawk extension and absent from the awk on a mac.
	awk -F'\t' 'NR==FNR { key[$1"\t"$2] = $3"\t"$4; next }
	            { k = $1"\t"$2; if (k in key) print key[k]"\t"$3"\t"$4"\t"$5 }' \
		"$pre.vermap" "$pre.rawconstraints" \
	| sort -t"$(printf '\t')" -k1,4 -k5,5 \
	| awk -F'\t' '{ k = $1 FS $2 FS $3 FS $4
	                 if (k == pk) { v = v "," $5 } else { if (pk != "") print pk FS v; pk = k; v = $5 } }
	               END { if (pk != "") print pk FS v }' > "$pre.constraints"
	rm -f "$all"
}

# A version that disappears entirely would otherwise surface as every one of its
# fields "removed" -- hundreds of lines saying once what the served check says in
# one. So the field comparison is scoped to versions present on BOTH sides, which
# is what keeps the served check from being redundant rather than the reverse.
common_versions() { # prevfields pinfields -> crd\tversion
	comm -12 <(cut -f1,2 "$1" | sort -u) <(cut -f1,2 "$2" | sort -u)
}

# --- per component ------------------------------------------------------------

printf '\n\033[1m== pin delta: previous -> pinned\033[0m\n'

for row in "${COMPONENTS[@]}"; do
	IFS=':' read -r name chart repovar manifest ns prevvar pinvar <<<"$row"
	repo="${!repovar}"; prev="${!prevvar}"; pin="${!pinvar}"

	printf '\n  \033[1m%s\033[0m  %s -> %s\n' "$name" "$prev" "$pin"
	VERDICT_PINS="${VERDICT_PINS}${VERDICT_PINS:+ }${name}:${prev}>${pin}"

	[ -f "$manifest" ] || { echo "pin-delta: no such manifest: $manifest" >&2; exit "$E_PRECONDITION"; }
	vals="$WORK/$name.values.yaml"
	yq -r '.spec.source.helm.values // ""' "$manifest" > "$vals" 2>/dev/null || {
		echo "pin-delta: could not read the values block from $manifest" >&2; exit "$E_PRECONDITION"; }

	for side in prev pin; do
		ver="$prev"; [ "$side" = pin ] && ver="$pin"
		pull_chart "$WORK/$name-$side" "$chart" "$repo" "$ver" || {
			echo "pin-delta: could not pull $chart $ver from $repo" >&2; exit "$E_PRECONDITION"; }
		render "$WORK/$name-$side/$chart" "$name" "$vals" "$ns" "$WORK/$name-$side.yaml" || {
			echo "pin-delta: $chart $ver rendered nothing with $manifest's values" >&2; exit "$E_PRECONDITION"; }
		model "$WORK/$name-$side.yaml" "$WORK/$name-$side" || {
			echo "pin-delta: could not model $chart $ver" >&2; exit "$E_PRECONDITION"; }
	done

	P="$WORK/$name-prev"; N="$WORK/$name-pin"
	before=$findings

	# 1. storage version moved.
	#
	# awk rather than join. BSD join has no -j, only -1/-2, so `join -j1` fails
	# with a usage error -- and the first version of this check piped that error
	# to /dev/null, so it produced no output and the branch reported nothing on a
	# mac. It passed its own synthetic test by finding nothing to find. Nothing
	# here suppresses an error that would otherwise be read as "no findings".
	awk -F'\t' '
		NR == FNR { if ($6 == "true") prev[$3] = $4; next }
		{ if ($6 == "true") pin[$3] = $4 }
		END { for (c in pin) if ((c in prev) && prev[c] != pin[c]) printf "%s\t%s\t%s\n", c, prev[c], pin[c] }
	' "$P.vermap" "$N.vermap" | sort > "$WORK/$name.storage"
	while IFS=$'\t' read -r crd o n; do
		[ -n "${crd:-}" ] || continue
		F_STORAGE+=("$name|$crd|$o|$n"); findings=$((findings + 1))
	done < "$WORK/$name.storage"
	# 2. served set changed
	# BSD sed does not interpret \t, in the pattern or the replacement, so the
	# comm column split is done in awk -- this has to behave the same on a mac
	# and on the runner.
	comm -3 <(awk -F'\t' '$5=="true" {print $3"."$4}' "$P.vermap" | sort -u) \
	        <(awk -F'\t' '$5=="true" {print $3"."$4}' "$N.vermap" | sort -u) \
	| awk -F'\t' 'NF>=2 && $1=="" {print "+" FS $2; next} {print "-" FS $1}' > "$WORK/$name.served"
	while IFS=$'\t' read -r sign v; do
		[ -n "${v:-}" ] || continue
		F_SERVED+=("$name|$sign|$v"); findings=$((findings + 1))
	done < "$WORK/$name.served"

	# 3. resource set changed
	comm -3 "$P.resources" "$N.resources" \
	| awk -F'\t' 'NF>=2 && $1=="" {print "+" FS $2; next} {print "-" FS $1}' > "$WORK/$name.res"
	while IFS=$'\t' read -r sign r; do
		[ -n "${r:-}" ] || continue
		F_RESOURCE+=("$name|$sign|$r"); findings=$((findings + 1))
	done < "$WORK/$name.res"

	# 4 and 5. fields, scoped to versions both sides serve
	common_versions "$P.fields" "$N.fields" > "$WORK/$name.common"
	if [ -s "$WORK/$name.common" ]; then
		keep() { awk -F'\t' 'NR==FNR {k[$1 FS $2]=1; next} (($1 FS $2) in k)' "$WORK/$name.common" "$1"; }
		keep "$P.fields" | sort -u > "$WORK/$name.pf"
		keep "$N.fields" | sort -u > "$WORK/$name.nf"
		comm -13 "$WORK/$name.pf" "$WORK/$name.nf" > "$WORK/$name.added"
		comm -23 "$WORK/$name.pf" "$WORK/$name.nf" > "$WORK/$name.removed"
		while IFS=$'\t' read -r crd v f; do
			[ -n "${f:-}" ] || continue
			F_ADDED+=("$name|$crd|$v|$f"); findings=$((findings + 1))
		done < "$WORK/$name.added"
		while IFS=$'\t' read -r crd v f; do
			[ -n "${f:-}" ] || continue
			F_REMOVED+=("$name|$crd|$v|$f"); findings=$((findings + 1))
		done < "$WORK/$name.removed"
	fi

	# 6. constraint tightening.
	#
	# The other five ask whether a rollback would lose something. This one asks
	# whether the UPGRADE would reject something already in the cluster, which is
	# the direction this platform actually deploys -- and the only hazard here
	# that bites on the way forward. If a chart tightens a regex and a live
	# object does not match it, the sync fails; nothing in checks 1-5 sees that,
	# because the field is present on both sides and only its validation moved.
	#
	# Scoped to TIGHTENING. A diff of every keyword across seventeen thousand
	# field paths reports mostly nothing anyone can act on, and a report people
	# skip is worse than no report. Loosening is safe forward and is not listed.
	#
	# A positive self-test rather than a silent empty result: if a component has
	# CRD versions but yielded no constraints at all, that is an extraction
	# failure, and it exits rather than reporting a clean bill of health. The
	# storage check in this file already shipped once producing nothing because
	# its error went to /dev/null, and that must not be repeatable here.
	for side in prev pin; do
		if [ -s "$WORK/$name-$side.vermap" ] && [ ! -s "$WORK/$name-$side.constraints" ]; then
			printf 'pin-delta: %s (%s) declares %s CRD version(s) but produced no constraints.\n' \
				"$name" "$side" "$(wc -l < "$WORK/$name-$side.vermap" | tr -d ' ')" >&2
			printf 'pin-delta: that is an extraction failure, not an absence of constraints.\n' >&2
			exit "$E_PRECONDITION"
		fi
	done

	if [ -s "$WORK/$name.common" ]; then
		comm -12 "$WORK/$name.pf" "$WORK/$name.nf" > "$WORK/$name.commonfields"
		awk -F'\t' -v OFS='\t' -v cff="$WORK/$name.commonfields" -v pvf="$P.constraints" '
			function leafof(kw,   m, arr) { m = split(kw, arr, "."); return arr[m] }
			function isnum(x) { return (x ~ /^-?[0-9]+(\.[0-9]+)?$/) }
			function emit(c, v, f, k, why, a, b) { print c, v, f, k, why, a, b }
			FILENAME == cff { cf[$1 FS $2 FS $3] = 1; next }
			FILENAME == pvf { p[$1 FS $2 FS $3 FS $4] = $5; next }
			{ n[$1 FS $2 FS $3 FS $4] = $5 }
			END {
				for (k in n) {
					split(k, a, "\t"); crd = a[1]; ver = a[2]; fld = a[3]; kw = a[4]
					if (!((crd FS ver FS fld) in cf)) continue
					leaf = leafof(kw); nv = n[k]; had = (k in p); pv = had ? p[k] : ""
					if (leaf == "pattern") {
						if (!had) emit(crd, ver, fld, kw, "pattern added", "(none)", nv)
						else if (pv != nv) emit(crd, ver, fld, kw, "pattern changed", pv, nv)
					} else if (leaf == "type") {
						if (had && pv != nv) emit(crd, ver, fld, kw, "type changed", pv, nv)
					} else if (leaf == "enum") {
						if (!had) emit(crd, ver, fld, kw, "enum added, was unconstrained", "(none)", nv)
						else {
							nn = split(nv, na, ","); delete seen
							for (i = 1; i <= nn; i++) seen[na[i]] = 1
							np = split(pv, pa, ","); lost = ""
							for (i = 1; i <= np; i++) if (!(pa[i] in seen)) lost = lost (lost == "" ? "" : ",") pa[i]
							if (lost != "") emit(crd, ver, fld, kw, "enum narrowed, lost " lost, pv, nv)
						}
					} else if (leaf == "required") {
						if (!had) emit(crd, ver, fld, kw, "became required", "(optional)", "required")
					} else if (leaf == "nullable") {
						if (had && pv == "true" && nv == "false") emit(crd, ver, fld, kw, "nullable true to false", pv, nv)
					} else if (leaf == "minLength" || leaf == "minimum" || leaf == "minItems") {
						if (!had) emit(crd, ver, fld, kw, "lower bound added", "(none)", nv)
						else if (isnum(pv) && isnum(nv) && nv + 0 > pv + 0) emit(crd, ver, fld, kw, "lower bound raised", pv, nv)
					} else if (leaf == "maxLength" || leaf == "maximum" || leaf == "maxItems") {
						if (!had) emit(crd, ver, fld, kw, "upper bound added", "(none)", nv)
						else if (isnum(pv) && isnum(nv) && nv + 0 < pv + 0) emit(crd, ver, fld, kw, "upper bound lowered", pv, nv)
					}
				}
				# nullable that disappears defaults to false, which is tighter.
				for (k in p) {
					if (k in n) continue
					split(k, a, "\t"); crd = a[1]; ver = a[2]; fld = a[3]; kw = a[4]
					if (!((crd FS ver FS fld) in cf)) continue
					if (leafof(kw) == "nullable" && p[k] == "true")
						emit(crd, ver, fld, kw, "nullable true to absent, defaults false", "true", "(absent)")
				}
			}' "$WORK/$name.commonfields" "$P.constraints" "$N.constraints" \
			| sort > "$WORK/$name.tighten"
		while IFS=$'\t' read -r crd v f kw why a b; do
			[ -n "${f:-}" ] || continue
			F_TIGHTEN+=("$name|$crd|$v|$f|$kw|$why|$a|$b"); findings=$((findings + 1))
		done < "$WORK/$name.tighten"
	fi

	if [ "$findings" -eq "$before" ]; then
		printf '    \033[32mno delta\033[0m  %d resources, %d CRD versions compared\n' \
			"$(wc -l < "$N.resources" | tr -d ' ')" "$(wc -l < "$N.vermap" | tr -d ' ')"
	else
		printf '    %d finding(s)\n' "$((findings - before))"
	fi
done

# --- the storage verdict, written for the rollback leg -------------------------
#
# A machine-readable answer to one question: did any CRD's storage version move.
# The rollback leg needs that verdict and must not get it by grepping the prose
# below -- a report is for a person, and a section heading is not an interface.
#
# The `pins:` line is what keeps a stale verdict from being believed. It records
# the exact previous>pinned pairs this run compared, and a reader that finds a
# different set treats the file as absent rather than as an answer. That is the
# whole defence against the failure mode of a checked-in verdict: this file can
# go out of date, but it cannot go out of date SILENTLY.
write_verdict() {
	local out="$1" f c crd o n
	mkdir -p "$(dirname "$out")" 2>/dev/null || return 1
	{
		printf '# generated by scripts/pin-delta.sh -- not edited by hand\n'
		printf 'pins: %s\n' "$VERDICT_PINS"
		if [ "${#F_STORAGE[@]}" -gt 0 ]; then
			printf 'verdict: moved\n'
			for f in "${F_STORAGE[@]}"; do
				IFS='|' read -r c crd o n <<<"$f"
				printf '%s\t%s\t%s\t%s\n' "$c" "$crd" "$o" "$n"
			done
		else
			printf 'verdict: none\n'
		fi
	} > "$out"
}

# Two destinations on purpose. The workdir copy is what CI publishes in the
# artifact; the .work copy is what a local `make upgrade-test` can read after a
# local `make pin-delta`. .work is gitignored and `make down` removes it, so the
# local copy cannot outlive the cluster it was reasoned about.
write_verdict "$WORK/storage-verdict.txt" \
	|| echo "pin-delta: could not write the verdict to the workdir" >&2
write_verdict '.work/pin-delta/storage-verdict.txt' \
	|| echo "pin-delta: could not write the verdict under .work" >&2

# --- the report ---------------------------------------------------------------

printf '\n\033[1m== findings\033[0m\n'

if [ "${#F_STORAGE[@]}" -gt 0 ]; then
	printf '\n  \033[1mSTORAGE VERSION MOVED\033[0m\n'
	note "Rollback from this pin is no longer possible. Objects are persisted at"
	note "the storage version, so the previous chart's CRD cannot read what the"
	note "pinned one wrote. This is upstream's decision to make and not a defect"
	note "here -- it means the pin is a one-way door, not that anything is wrong."
	for f in "${F_STORAGE[@]}"; do IFS='|' read -r c crd o n <<<"$f"
		printf '    %-16s %-46s %s -> %s\n' "$c" "$crd" "$o" "$n"; done
fi

if [ "${#F_SERVED[@]}" -gt 0 ]; then
	printf '\n  \033[1mSERVED API VERSION CHANGED\033[0m\n'
	note "- was served by the previous chart and is not served by the pinned one:"
	note "  objects and clients still on it break when the pin is applied."
	note "+ is served only by the pinned chart: it disappears on the way back."
	for f in "${F_SERVED[@]}"; do IFS='|' read -r c s v <<<"$f"
		printf '    %-16s %s %s\n' "$c" "$s" "$v"; done
fi

if [ "${#F_RESOURCE[@]}" -gt 0 ]; then
	printf '\n  \033[1mRESOURCE SET CHANGED\033[0m\n'
	note "+ exists only in the pinned chart: Argo CD prunes it on the way back."
	note "- exists only in the previous chart: it returns on the way back, and is"
	note "  unmanaged in the meantime."
	for f in "${F_RESOURCE[@]}"; do IFS='|' read -r c s r <<<"$f"
		printf '    %-16s %s %s\n' "$c" "$s" "$r"; done
fi

if [ "${#F_ADDED[@]}" -gt 0 ]; then
	printf '\n  \033[1mCRD FIELD ADDED BY THE PINNED CHART\033[0m\n'
	note "A resource that sets one of these loses it on the way back -- SILENTLY"
	note "PRUNED by the API server, not rejected, with Argo CD still reporting"
	note "Synced. Nothing warns you. Check whether anything in this repository or"
	note "in a tenant's manifests actually sets one before treating it as benign."
	for f in "${F_ADDED[@]}"; do IFS='|' read -r c crd v fp <<<"$f"
		printf '    %-16s %-40s %-10s %s\n' "$c" "$crd" "$v" "$fp"; done
fi

if [ "${#F_REMOVED[@]}" -gt 0 ]; then
	printf '\n  \033[1mCRD FIELD REMOVED BY THE PINNED CHART\033[0m\n'
	note "The pinned chart no longer declares these. A resource setting one loses"
	note "it when the pin is applied; the field returns on the way back."
	for f in "${F_REMOVED[@]}"; do IFS='|' read -r c crd v fp <<<"$f"
		printf '    %-16s %-40s %-10s %s\n' "$c" "$crd" "$v" "$fp"; done
fi

if [ "${#F_TIGHTEN[@]}" -gt 0 ]; then
	printf '\n  \033[1mCONSTRAINT TIGHTENED -- this one breaks FORWARD\033[0m\n'
	note "Every section above asks what a rollback would lose. This one asks what"
	note "the UPGRADE will reject. The field still exists on both sides; only its"
	note "validation moved, so nothing above can see it."
	note ""
	note "An object already in the cluster that satisfied the previous rule and"
	note "does not satisfy the pinned one makes the sync fail when the pin lands."
	note "Check whether anything actually holds a value these would now reject."
	note ""
	note "A changed pattern is reported as suspect, not as broken: proving one"
	note "regex accepts everything another does is not something this can do"
	note "cheaply, so it says the regex moved and leaves the reading to you."
	for f in "${F_TIGHTEN[@]}"; do IFS='|' read -r c crd v fp kw why a b <<<"$f"
		printf '    %-14s %-34s %-9s %s\n' "$c" "$crd" "$v" "$fp"
		printf '    %-14s   %s (%s)\n' "" "$why" "$kw"
		printf '    %-14s   %s  ->  %s\n' "" "$a" "$b"; done
fi

printf '\n'
if [ "$findings" -eq 0 ]; then
	printf '  \033[32mNo delta across %d components. Nothing about these bumps changes what a rollback means.\033[0m\n\n' \
		"${#COMPONENTS[@]}"
	exit "$E_NONE"
fi
printf '  %d finding(s) across %d components. Read them; none of them is a build failure.\n\n' \
	"$findings" "${#COMPONENTS[@]}"
exit "$E_FINDINGS"
