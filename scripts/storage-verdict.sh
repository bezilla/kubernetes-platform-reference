#!/usr/bin/env bash
#
# Answers one question for the rollback leg: did any CRD's storage version move
# between the previous pins and the current ones. Prints exactly one token on
# the first line -- `none`, `moved`, or `unavailable` -- and any detail after it.
#
# WHY THE LEG DOES NOT JUST RUN pin-delta.sh. That script pulls eight charts
# from four external registries. Putting it inside upgrade-test.sh would mean a
# Docker Hub blip fails an eleven-minute cluster job for a reason that has
# nothing to do with the cluster, and it would compute a verdict the pin-delta
# job has already computed and published on the same commit.
#
# WHY NOT A CHECKED-IN VERDICT FILE. It would go stale silently, and nothing
# would force a refresh. The defence here is the `pins:` line: pin-delta records
# exactly which previous>pinned pairs it compared, and this reader rebuilds that
# string from versions.env. A file describing different pins is not an answer to
# the question being asked, so it is reported as `unavailable` rather than
# believed. The file can go out of date; it cannot do so silently.
#
# `unavailable` is a real answer and not an error. The caller is required to run
# the rollback anyway and to refuse to classify a failure -- a registry outage
# should not quietly reduce coverage, and it should not be allowed to masquerade
# as evidence either way.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

# STORAGE_VERDICT_FILE is what CI sets after downloading the pin-delta artifact.
# The .work path is the local fallback: it exists only if someone ran
# `make pin-delta` in this working tree since the last `make down`.
# An explicitly-set path wins absolutely. If CI sets STORAGE_VERDICT_FILE and the
# artifact download produced nothing, the honest answer is `unavailable` -- NOT
# to quietly fall through to a local file left over from some earlier run, which
# is how a stale verdict would get believed in exactly the situation the pins
# check exists to prevent. The fallback applies only when nobody named a file.
if [ -n "${STORAGE_VERDICT_FILE:-}" ]; then
	CANDIDATES=("$STORAGE_VERDICT_FILE")
else
	CANDIDATES=('.work/pin-delta/storage-verdict.txt')
fi

# The same four components pin-delta walks, in the same order. This table is
# duplicated, and the duplication is deliberate rather than unnoticed: if it
# ever drifts from pin-delta's, the rebuilt `pins:` string stops matching and
# every verdict reads as `unavailable`. Drift degrades to "we do not know",
# which is the safe direction -- it can never produce a confident wrong answer.
want="cert-manager:${UPGRADE_FROM_CERT_MANAGER}>${CERT_MANAGER_CHART_VERSION}"
want="$want envoy-gateway:${UPGRADE_FROM_ENVOY_GATEWAY}>${ENVOY_GATEWAY_CHART_VERSION}"
want="$want kyverno:${UPGRADE_FROM_KYVERNO}>${KYVERNO_CHART_VERSION}"
want="$want otel-collector:${UPGRADE_FROM_OTEL_COLLECTOR}>${OTEL_COLLECTOR_CHART_VERSION}"

unavailable() {
	echo 'unavailable'
	printf '%s\n' "$1"
	exit 0
}

file=''
for c in "${CANDIDATES[@]}"; do
	[ -n "$c" ] || continue
	if [ -s "$c" ]; then file="$c"; break; fi
done
[ -n "$file" ] || unavailable "no verdict file: looked at ${CANDIDATES[*]}"

got="$(sed -n 's/^pins: //p' "$file" | head -1)"
[ -n "$got" ] || unavailable "verdict file ${file} has no pins line"
[ "$got" = "$want" ] || unavailable "verdict file ${file} was computed for different pins
    it compared:  ${got}
    versions.env: ${want}"

case "$(sed -n 's/^verdict: //p' "$file" | head -1)" in
	none)
		echo 'none'
		printf 'no CRD storage version moved between these pins (%s)\n' "$file"
		;;
	moved)
		echo 'moved'
		grep -vE '^(#|pins:|verdict:)' "$file" | grep -v '^$'
		;;
	*)
		unavailable "verdict file ${file} has no readable verdict line"
		;;
esac
