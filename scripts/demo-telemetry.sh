#!/usr/bin/env bash
#
# The observability seam, shown rather than asserted.
#
# The other three demos prove things the platform DOES. This one proves a thing
# the platform GIVES: an app team writes no OTLP endpoint, no exporter and no
# SDK configuration, and its spans still arrive at a collector it never named.
#
# It is here because "telemetry is wired up" was, for a while, a claim this
# repository made about itself and never demonstrated -- the collector was
# installed, the environment variables were rendered, and nothing checked that
# a span ever crossed the gap. An installed collector with no data through it
# is the observability equivalent of a policy that matches nothing.
#
# The collector's exporter is `debug`, which writes to its own pod log. That is
# what makes this checkable without a backend: the proof is `kubectl logs`. Swap
# that exporter for Tempo and nothing upstream changes -- which is the point.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

NS_APP='tenant-quotes'
NS_OBS='platform-observability'
DEPLOY='quote-api'
HOST="quote-api.${APPS_DOMAIN}"
CA=.work/platform-ca.crt
REQUESTS=12

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

kubectl -n "$NS_OBS" get deploy -o name >/dev/null 2>&1 || {
	echo "demo-telemetry: no collector in ${NS_OBS}. Run 'make up'." >&2; exit 1; }

collector="$(kubectl -n "$NS_OBS" get pod -l app.kubernetes.io/name=opentelemetry-collector \
	-o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[ -n "$collector" ] || { echo "demo-telemetry: could not find the collector pod." >&2; exit 1; }

# --- 1. what the team wrote, and what it received -----------------------------
step 'What the app team wrote about telemetry'
# Comments and the human-readable description are stripped first. Both mention
# OpenTelemetry, and counting prose as configuration would make this step prove
# the opposite of what it claims. Only a real key counts.
settings="$(sed 's/#.*//' apps/quote-api/values.yaml \
	| grep -nE '^[[:space:]]*(otel|otlp|tracing|telemetry|exporter|endpoint)' || true)"
if [ -n "$settings" ]; then
	printf '%s\n' "$settings" | sed 's/^/  /'
else
	printf '  nothing. Not one key. apps/quote-api/values.yaml is the whole of\n'
	printf '  what the payments team writes, and it names no endpoint, no\n'
	printf '  exporter, no SDK setting and no collector.\n'
fi

step 'What the platform injected on their behalf'
kubectl -n "$NS_APP" get deploy "$DEPLOY" -o json 2>/dev/null \
	| jq -r '.spec.template.spec.containers[0].env[]?
	         | select(.name | startswith("OTEL_"))
	         | "  \(.name)=\(.value)"'

step 'Where those spans land'
kubectl -n "$NS_OBS" get svc -o json 2>/dev/null \
	| jq -r '.items[] | select(.spec.ports[]?.port == 4317)
	         | "  \(.metadata.name)  OTLP/gRPC :4317  ClusterIP \(.spec.clusterIP)"'
printf '  exporter: debug -> the collector pod log, so the proof is kubectl logs\n'

# --- 2. drive some traffic ----------------------------------------------------
step "Generating ${REQUESTS} requests through the edge"
if [ ! -s "$CA" ]; then
	mkdir -p .work
	kubectl -n cert-manager get secret platform-root-ca \
		-o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$CA"
fi
codes=''
for _ in $(seq 1 "$REQUESTS"); do
	c="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
		--cacert "$CA" --resolve "${HOST}:${EDGE_HTTPS_PORT}:127.0.0.1" \
		"https://${HOST}:${EDGE_HTTPS_PORT}/api/quote?sku=SKU-1" 2>/dev/null || echo '000')"
	codes="${codes}${c} "
done
printf '  responses: %s\n' "$codes"

# The collector batches, so a span emitted now is not in the log now.
printf '  waiting for the batch processor to flush'
for _ in $(seq 1 15); do printf '.'; sleep 1; done
printf '\n'

# --- 3. did anything arrive? --------------------------------------------------
# Counted from the shape this collector actually logs, which is not the shape
# that reads most naturally. With `verbosity: basic` the debug exporter never
# writes "Span #" -- that is `detailed` -- and the message is "Traces", not
# "TracesExporter". Grepping for either of the plausible-looking strings returns
# zero against a pipeline that is working perfectly, and zero here would be
# reported as "no telemetry". The count comes from summing the exporter's own
# "spans": N field on lines carrying the traces signal.
sum_field() { grep -oE "\"$2\": [0-9]+" <<<"$1" | awk -F': ' '{s+=$2} END {print s+0}'; }

step 'What the collector received'
logs="$(kubectl -n "$NS_OBS" logs "$collector" --tail=-1 2>/dev/null)"
trace_lines="$(printf '%s\n' "$logs" | grep '"otelcol.signal": "traces"' || true)"
metric_lines="$(printf '%s\n' "$logs" | grep '"otelcol.signal": "metrics"' || true)"
spans="$(sum_field "$trace_lines" spans)"
rspans="$(sum_field "$trace_lines" 'resource spans')"
points="$(sum_field "$metric_lines" 'data points')"

printf '  spans received:               %s  (across %s resource spans)\n' "${spans:-0}" "${rspans:-0}"
printf '  trace export batches:         %s\n' "$(printf '%s\n' "$trace_lines" | grep -c . || true)"
printf '  metric data points:           %s\n' "${points:-0}"

if [ "${spans:-0}" -gt 0 ]; then
	step 'The collector saying so, in its own log'
	printf '%s\n' "$trace_lines" | tail -2 \
		| sed -E 's/\{"resource".*"otelcol\.signal"/{... "otelcol.signal"/' \
		| cut -c1-150 | sed 's/^/  /'

	step 'The same requests, from the workload side'
	kubectl -n "$NS_APP" logs deploy/"$DEPLOY" --tail=-1 2>/dev/null \
		| grep -o '"msg":"quote served".*"trace_id":"[a-f0-9]*"' | tail -3 \
		| sed -E 's/.*"sku":"([^"]*)".*"trace_id":"([a-f0-9]*)".*/  sku=\1  trace_id=\2/' || true

	printf '\n  \033[32mThe team configured nothing. The spans arrived anyway.\033[0m\n\n'
	exit 0
fi

# --- 4. no spans: say which of the two reasons it is --------------------------
# Not a failure in every case, and the difference matters. The fallback workload
# is a placeholder that serves /healthz and emits no telemetry, so zero spans is
# the correct and documented outcome there. Zero spans from the instrumented
# service is a real defect. Distinguish them rather than printing one number.
step 'No spans arrived'
image="$(kubectl -n "$NS_APP" get deploy "$DEPLOY" \
	-o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
# Which workload this is, decided by what it answers rather than by exec'ing
# into it: the runtime image is distroless and has no shell, so an exec probe
# reports "not instrumented" for the instrumented service and states it with
# total confidence. The quote endpoint returns JSON from the real service and
# plain text from the placeholder.
body="$(curl -sS --max-time 10 --cacert "$CA" \
	--resolve "${HOST}:${EDGE_HTTPS_PORT}:127.0.0.1" \
	"https://${HOST}:${EDGE_HTTPS_PORT}/api/quote?sku=SKU-1" 2>/dev/null || true)"
if printf '%s' "$body" | grep -q '"sku"'; then
	instrumented='yes'
else
	instrumented='no'
fi
printf '  workload image:   %s\n' "$image"
printf '  instrumented:     %s\n' "$instrumented"
if [ "$instrumented" = 'no' ]; then
	cat <<-EOF

	  This is the fallback workload from bootstrap/fallback-workload -- a pinned
	  nginx that satisfies the chart's contract and emits no telemetry. Zero
	  spans is the correct result for it, and it is the documented cost of
	  running without ../otel-service-reference on disk.

	  The seam is still demonstrated above: the collector is running, the OTLP
	  endpoint is injected, and nothing in the team's values file mentions it.
	  What is missing is a workload that speaks OTLP.

	  Clone the sibling repository next to this one and re-run 'make up' to see
	  spans arrive.
	EOF
	exit 0
fi
cat >&2 <<-EOF

	  The instrumented workload is deployed and no spans arrived. That is a
	  defect, not a configuration choice. Check the collector's receivers and
	  that OTEL_EXPORTER_OTLP_ENDPOINT resolves from the workload's namespace.
EOF
exit 1
