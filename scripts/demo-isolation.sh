#!/usr/bin/env bash
#
# The fault injector is not reachable through the gateway. Asserted both ways.
#
# The incident this is made of: the sample workload serves /admin/inject, an
# unauthenticated endpoint whose entire job is to make the service inject
# latency and errors. It shared a listener with /api/quote on 8080, and this
# repository's chart publishes 8080 through an HTTPRoute whose default match is
# PathPrefix `/` -- everything. So on a public demo, anyone who could reach the
# gateway could degrade the service by path alone. It was written down in the
# sibling repository's SECURITY.md as a known sharp edge, which reads as
# accepted rather than exposed, and a documented hole is still a hole.
#
# The fix was not a check in code. The injector moved to a third listener,
# ADMIN_ADDR (:8082), and nothing in the Service names that port -- so it is
# unreachable by construction rather than by an if-statement somebody can
# delete. This script is that incident turned into a regression test.
#
# Two halves, because either alone is worthless:
#
#   the CLOSED path   the public HTTPS route, where /admin/inject must 404
#   the OPEN path     a port-forward to :8082, where it must answer 200
#
# Half one passes trivially if the pod never started, the route is broken, or
# the whole platform is down. Half two, and the liveness checks around both, are
# what make half one mean anything. And the sharpest assertion is neither: POST
# an injection through the CLOSED path, then read the injector's state back
# through the OPEN path and require it to be UNCHANGED. A 404 is a response.
# Unchanged state is a guarantee.
#
# Unlike scripts/demo-https.sh, which prints and asserts nothing, this exits
# non-zero when it finds a problem -- and exits with a DIFFERENT code when it
# could not run at all. Those are not the same event and a caller must not have
# to guess which one it got.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

NS='tenant-quotes'
DEPLOY='quote-api'
HOST="quote-api.${APPS_DOMAIN}"
CA=.work/platform-ca.crt

# The port the injector listens on inside the pod. Deliberately absent from
# charts/paved-road/templates/service.yaml, which is the whole security
# property; if this ever appears in a Service, this test is why it must not.
ADMIN_PORT=8082
# The local end of the port-forward. Overridable because 8082 is a popular
# number on a developer's machine and a collision here is a broken test run,
# not a finding.
PF_PORT="${ADMIN_PF_PORT:-8082}"

# Ceilings. Every wait in this script has one; none of them poll forever.
PF_DEADLINE=30          # for the port-forward to start answering
READY_DEADLINE=60       # for the workload to have one ready replica
CURL_MAX_TIME=10        # any single request through the edge

# Exit codes. The distinction is the point: a port-forward that never
# established is not the same event as an injector that answered when it should
# not have, and collapsing the two into `exit 1` makes a broken harness look
# like a breached boundary -- or, far worse, the other way round.
E_FAILED=1              # an assertion failed: the boundary is broken
E_PRECONDITION=2        # could not run: no cluster, no workload, no tooling
E_HARNESS=3             # could not finish: the port-forward or a wait failed

pass=0; fail=0; skip=0

step()    { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()      { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad()     { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
skipped() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; skip=$((skip + 1)); }

precondition() {
	printf '\ndemo-isolation: cannot run -- %s\n' "$1" >&2
	exit "$E_PRECONDITION"
}

# Dumps the state a reader needs to tell a broken port-forward from a broken
# platform, then exits with the harness code rather than the failure code.
harness() {
	printf '\ndemo-isolation: could not complete -- %s\n' "$1" >&2
	printf '\n  kubectl port-forward said:\n' >&2
	sed 's/^/    /' "$PF_LOG" >&2 2>/dev/null || printf '    (nothing)\n' >&2
	printf '\n  workload state:\n' >&2
	kubectl -n "$NS" get pods -l "app.kubernetes.io/name=${DEPLOY}" \
		-o wide --request-timeout=20s 2>&1 | sed 's/^/    /' >&2
	kubectl -n "$NS" get deploy "$DEPLOY" \
		-o custom-columns='DEPLOYMENT:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas' \
		--no-headers --request-timeout=20s 2>&1 | sed 's/^/    /' >&2
	exit "$E_HARNESS"
}

PF_LOG="$(mktemp "${TMPDIR:-/tmp}/demo-isolation-pf.XXXXXX")"
BODY="$(mktemp "${TMPDIR:-/tmp}/demo-isolation-body.XXXXXX")"
pf_pid=''

# Runs on every exit path, including the failing ones and Ctrl-C. A leaked
# port-forward is a process holding 8082 open on the developer's machine, which
# makes the NEXT run of this script fail to bind and report a harness error for
# a reason that has nothing to do with the platform.
cleanup() {
	if [ -n "$pf_pid" ]; then
		kill "$pf_pid" 2>/dev/null || true
		wait "$pf_pid" 2>/dev/null || true
		pf_pid=''
	fi
	rm -f "$PF_LOG" "$BODY" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Status code through the public HTTPS edge, verified against the platform CA
# exactly as demo-https.sh does it: --resolve rather than an /etc/hosts entry so
# this needs no sudo, --cacert rather than -k because -k would prove the port
# answers and nothing about the certificate.
#
# "000" is curl's own code for "no HTTP response at all" and is returned here
# verbatim -- connection refused is a legitimate PASS for the closed path, and
# it has to be distinguishable from a 404 in the output.
edge_code() {
	local method="$1" path="$2" body="${3:-}" out
	if [ -n "$body" ]; then
		out="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$CURL_MAX_TIME" \
			--cacert "$CA" --resolve "${HOST}:${EDGE_HTTPS_PORT}:127.0.0.1" \
			-X "$method" -H 'content-type: application/json' --data "$body" \
			"https://${HOST}:${EDGE_HTTPS_PORT}${path}" 2>/dev/null)"
	else
		out="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$CURL_MAX_TIME" \
			--cacert "$CA" --resolve "${HOST}:${EDGE_HTTPS_PORT}:127.0.0.1" \
			-X "$method" \
			"https://${HOST}:${EDGE_HTTPS_PORT}${path}" 2>/dev/null)"
	fi
	printf '%s' "${out:-000}"
}

# Body through the edge, for the one place that needs to read what came back.
edge_body() {
	curl -sS --max-time "$CURL_MAX_TIME" \
		--cacert "$CA" --resolve "${HOST}:${EDGE_HTTPS_PORT}:127.0.0.1" \
		"https://${HOST}:${EDGE_HTTPS_PORT}${1}" 2>/dev/null || true
}

# GET the injector through the port-forward. Body to $BODY, code to stdout.
admin_get() {
	local out
	out="$(curl -sS -o "$BODY" -w '%{http_code}' --max-time "$CURL_MAX_TIME" \
		"http://127.0.0.1:${PF_PORT}/admin/inject" 2>/dev/null)"
	printf '%s' "${out:-000}"
}

# --- preconditions: everything that is "could not run", not "found a problem" -

for tool in kubectl curl jq openssl; do
	command -v "$tool" >/dev/null 2>&1 || precondition "${tool} is not installed"
done

kubectl cluster-info --request-timeout=20s >/dev/null 2>&1 \
	|| precondition "no reachable cluster. Run 'make up'."

kubectl -n "$NS" get deploy "$DEPLOY" --request-timeout=20s >/dev/null 2>&1 \
	|| precondition "no ${DEPLOY} in ${NS}. Run 'make up'."

mkdir -p .work
kubectl -n cert-manager get secret platform-root-ca \
	-o jsonpath='{.data.tls\.crt}' --request-timeout=20s 2>/dev/null | base64 -d > "$CA"
[ -s "$CA" ] || precondition "could not read the platform CA. Run 'make up'."

# A workload mid-rollout is not a finding about the injector, so wait -- but
# only for a bounded time, and then say so rather than testing a pod that is
# not there.
start=$SECONDS
while :; do
	ready="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' \
		--request-timeout=20s 2>/dev/null)"
	[ "${ready:-0}" -ge 1 ] 2>/dev/null && break
	if [ $((SECONDS - start)) -ge "$READY_DEADLINE" ]; then
		harness "no ready ${DEPLOY} replica within ${READY_DEADLINE}s"
	fi
	sleep 3
done

# --- 1. the service is alive, before anything is poked ------------------------
# This runs FIRST and its result is load-bearing. Every "the injector is not
# reachable" assertion below is satisfied just as well by a dead pod, a broken
# HTTPRoute or a gateway that is not listening. Proving the public surface works
# is what turns those 404s from an absence into a boundary.

step 'The service, through the public HTTPS route'

health_code="$(edge_code GET /healthz)"
if [ "$health_code" = '200' ]; then
	ok "GET /healthz -> 200 through the gateway"
else
	bad "GET /healthz -> ${health_code}, want 200 -- the edge or the workload is down, so nothing below is meaningful"
fi

quote_code="$(edge_code GET '/api/quote?sku=SKU-1')"
quote_body="$(edge_body '/api/quote?sku=SKU-1')"
if [ "$quote_code" = '200' ]; then
	ok "GET /api/quote -> 200 through the gateway"
else
	bad "GET /api/quote -> ${quote_code}, want 200"
fi
printf '        %s\n' "$(printf '%s' "$quote_body" | head -c 120)"

if [ "$fail" -ne 0 ]; then
	printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
	printf '\ndemo-isolation: the public surface is not healthy. Fix that first --\n' >&2
	printf '  a closed admin path proves nothing about a service that is not answering.\n' >&2
	exit "$E_FAILED"
fi

# Which workload is deployed, decided by what it answers rather than by its
# image tag -- scripts/sample-image.sh gives the real service and the fallback
# the SAME tag, so the tag cannot tell them apart. The real service returns JSON
# with an "sku" field; the fallback returns a line of plain text. This is the
# same probe demo-telemetry.sh uses, for the same reason.
if ! printf '%s' "$quote_body" | jq -e 'has("sku")' >/dev/null 2>&1; then
	step 'This is the fallback workload, and it has no injector to isolate'
	cat <<-EOF
	  bootstrap/fallback-workload is a pinned nginx that serves /healthz so the
	  chart's probes pass. It has no :8082, no /admin/inject and no injector, so
	  neither half of this test can be exercised against it -- and its nginx
	  config answers 200 on every unmatched path, so asserting a 404 on
	  /admin/inject here would fail on a placeholder rather than on a defect.

	  That is a documented configuration, not a fault, so this exits 0 having
	  proved nothing about the injector. What it did prove is above: the edge,
	  the certificate and the route are working.

	  Clone ../otel-service-reference next to this repository and re-run
	  'make up' to exercise the boundary this test exists for.
	EOF
	skipped 'the closed path (no injector in this workload)'
	skipped 'the open path (no injector in this workload)'
	skipped 'state unchanged after a write to the closed path'
	printf '\n%d passed, %d failed, %d skipped\n\n' "$pass" "$fail" "$skip"
	exit 0
fi

# --- 2. the closed path: /admin/inject through the gateway --------------------
# 404 and "connection refused" are both correct answers here and the script
# treats them as one PASS with two spellings. Accepting 000 is only safe because
# step 1 already proved the same host, port and certificate serve /healthz --
# without that, "the gateway is down" would be indistinguishable from "the
# gateway refuses this path", and this suite would report success at its
# loudest exactly when the platform was most broken.

step 'The closed path: /admin/inject through the public HTTPS route'

get_code="$(edge_code GET /admin/inject)"
case "$get_code" in
	404) ok "GET /admin/inject -> 404 at ${HOST}:${EDGE_HTTPS_PORT}" ;;
	000) ok "GET /admin/inject -> connection refused at ${HOST}:${EDGE_HTTPS_PORT}" ;;
	2*)  bad "GET /admin/inject -> ${get_code} -- THE INJECTOR IS REACHABLE THROUGH THE GATEWAY. This is the incident, live." ;;
	*)   bad "GET /admin/inject -> ${get_code}, want 404 or no connection. Anything else means the path is being handled somewhere." ;;
esac

# --- 3. the open path: /admin/inject through a port-forward -------------------
# The other half. If this fails the test is worthless in the reassuring
# direction: an injector that answers nowhere would pass every assertion in
# step 2 while telling you nothing about routing.

step "The open path: port-forward ${PF_PORT} -> ${DEPLOY}:${ADMIN_PORT}"

kubectl -n "$NS" port-forward "deploy/${DEPLOY}" "${PF_PORT}:${ADMIN_PORT}" \
	>"$PF_LOG" 2>&1 &
pf_pid=$!

pf_ready=''
start=$SECONDS
while :; do
	# The process dying is its own outcome, and its log says why -- almost
	# always "address already in use" or "unable to listen". Polling for the
	# full deadline against a process that exited two seconds ago wastes 28s
	# and then reports the wrong reason.
	if ! kill -0 "$pf_pid" 2>/dev/null; then
		break
	fi
	if [ "$(admin_get)" = '200' ]; then
		pf_ready=1
		break
	fi
	if [ $((SECONDS - start)) -ge "$PF_DEADLINE" ]; then
		break
	fi
	sleep 1
done

if [ -z "$pf_ready" ]; then
	if grep -qi 'address already in use\|unable to listen' "$PF_LOG" 2>/dev/null; then
		harness "local port ${PF_PORT} is already in use. Set ADMIN_PF_PORT to a free port."
	fi
	harness "the port-forward to ${DEPLOY}:${ADMIN_PORT} never answered within ${PF_DEADLINE}s"
fi

get_admin_code="$(admin_get)"
before="$(jq -S -c . < "$BODY" 2>/dev/null || true)"

if [ "$get_admin_code" = '200' ]; then
	ok "GET /admin/inject -> 200 on 127.0.0.1:${PF_PORT}"
else
	bad "GET /admin/inject -> ${get_admin_code} on the admin port, want 200"
fi

# "200" alone would also be satisfied by an empty body or an error page. The
# echoed configuration is the thing being asserted, so check the shape.
if printf '%s' "$before" | jq -e '
		has("base_latency_ms") and has("tail_latency_ms")
		and has("tail_percent") and has("error_rate")' >/dev/null 2>&1; then
	ok 'the injector echoed its configuration back'
	printf '        %s\n' "$before"
else
	bad 'the admin port answered but did not return an injector config'
	printf '        %s\n' "$(head -c 200 "$BODY")"
fi

# --- 4. the sharp one: a write to the closed path changes nothing -------------
# The assertion the other three exist to support. A 404 says the request was
# refused by whatever answered it; unchanged state says the request never
# reached the thing it was aimed at. Only the second is a guarantee.

step 'A write through the closed path, read back through the open one'

# Pick a value the injector is not already set to, so "unchanged" cannot be
# satisfied by accident. If someone has already driven error_rate to 1.0 by
# hand, POSTing 1.0 would pass this test while proving nothing.
current_rate="$(printf '%s' "$before" | jq -r '.error_rate' 2>/dev/null || echo 0)"
if [ "$current_rate" = '1' ] || [ "$current_rate" = '1.0' ]; then
	target='0.5'
else
	target='1.0'
fi
payload="{\"error_rate\":${target}}"

printf '        error_rate is %s; POSTing %s through the gateway\n' "${current_rate:-?}" "$target"

post_code="$(edge_code POST /admin/inject "$payload")"
case "$post_code" in
	404) ok "POST /admin/inject -> 404 at ${HOST}:${EDGE_HTTPS_PORT}" ;;
	000) ok "POST /admin/inject -> connection refused at ${HOST}:${EDGE_HTTPS_PORT}" ;;
	2*)  bad "POST /admin/inject -> ${post_code} -- a write to the injector was ACCEPTED through the public gateway" ;;
	*)   bad "POST /admin/inject -> ${post_code}, want 404 or no connection" ;;
esac

after_code="$(admin_get)"
after="$(jq -S -c . < "$BODY" 2>/dev/null || true)"

if [ "$after_code" != '200' ]; then
	# Losing the port-forward between the write and the read is a broken test
	# run, not a verdict. Saying "unchanged" here would be a guess.
	harness "the admin port stopped answering (${after_code}) before the state could be re-read"
fi

if [ -n "$before" ] && [ "$before" = "$after" ]; then
	ok 'the injector state is byte-for-byte unchanged'
	printf '        %s\n' "$after"
else
	bad 'the injector state CHANGED after a write to the closed path'
	printf '        before  %s\n' "$before"
	printf '        after   %s\n' "$after"
	# Best effort, and it does not affect the verdict: leaving a demo cluster
	# with error_rate at 1.0 makes every subsequent demo fail for a reason
	# nobody will connect to this script.
	printf '        restoring the previous state through the admin port\n'
	curl -sS -o /dev/null --max-time "$CURL_MAX_TIME" \
		-X POST -H 'content-type: application/json' --data "$before" \
		"http://127.0.0.1:${PF_PORT}/admin/inject" 2>/dev/null || true
fi

# --- 5. and it is still alive afterwards --------------------------------------
# "While all this happens" is part of the claim. A run that ends with the
# service degraded has not demonstrated isolation; it has demonstrated that
# something got through.

step 'The service, after all of that'

health_after="$(edge_code GET /healthz)"
quote_after="$(edge_code GET '/api/quote?sku=SKU-1')"
if [ "$health_after" = '200' ] && [ "$quote_after" = '200' ]; then
	ok "/healthz and /api/quote still 200 through the gateway"
else
	bad "/healthz ${health_after}, /api/quote ${quote_after} -- the service is degraded after the attempted injection"
fi

# --- verdict ------------------------------------------------------------------

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
if [ "$fail" -eq 0 ]; then
	printf '\n  \033[32mThe injector answers on a port nothing publishes, and a write aimed\n'
	printf '  at the public route changed nothing. Unreachable by construction.\033[0m\n\n'
	exit 0
fi
printf '\n  \033[31mThe boundary between the public route and the fault injector is not intact.\033[0m\n' >&2
printf '  See charts/paved-road/templates/service.yaml and httproute.yaml: the Service\n' >&2
printf '  must publish exactly one port, targeting the container port named http.\n\n' >&2
exit "$E_FAILED"
