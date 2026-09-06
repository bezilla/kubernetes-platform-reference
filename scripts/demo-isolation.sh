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
# The Service the HTTPRoute targets. Named separately from DEPLOY because the
# state sweep below enumerates what is behind the SERVICE -- that is the set a
# request through the gateway can be routed to, which is the set that matters.
SVC='quote-api'
HOST="quote-api.${APPS_DOMAIN}"
CA=.work/platform-ca.crt

# The port the injector listens on inside the pod. Deliberately absent from
# charts/paved-road/templates/service.yaml, which is the whole security
# property; if this ever appears in a Service, this test is why it must not.
#
# UNVERIFIED, AND THE MORE LIKELY OF THE TWO TO BITE. This number is hardcoded
# here while the deployment does not set it anywhere: apps/quote-api/values.yaml
# writes no ADMIN_ADDR, so the container falls back to the `:8082` default in
# the sibling repository's cmd/service/main.go. Two independent 8082s that agree
# by coincidence, not by reference -- and nothing in this repository would notice
# them diverging.
#
# So if anyone later pins ADMIN_ADDR in values.yaml to something else, or the
# sibling changes its default, this constant goes stale silently and the open
# half of the test stops testing the injector. It fails safe -- the port-forward
# answers nothing and the script exits 3, "could not finish" -- but exit 3 does
# not say "your constant is wrong", so read this first when it appears.
#
# Not fixed by editing values.yaml. Pinning it there is a real option and a
# separate decision; a test is not the place to make it on someone's behalf.
ADMIN_PORT=8082
# The local end of the port-forward. Overridable because 8082 is a popular
# number on a developer's machine and a collision here is a broken test run,
# not a finding.
PF_PORT="${ADMIN_PF_PORT:-8082}"
# A second local port, for the per-pod port-forwards in the state sweep below.
# It has to differ from PF_PORT: the deployment-level forward stays up for the
# whole run, so a sweep reusing that local port would collide with it and report
# a harness error on every pod.
PF_POD_PORT="${ADMIN_PF_POD_PORT:-$((PF_PORT + 1))}"
# A guaranteed collision, and worth refusing by name: the deployment-level
# forward holds PF_PORT for the whole run, so an equal PF_POD_PORT could only
# ever read that one pod while labelling it as each replica in turn.
[ "$PF_POD_PORT" != "$PF_PORT" ] || {
	printf '\ndemo-isolation: cannot run -- ADMIN_PF_POD_PORT (%s) must differ from ADMIN_PF_PORT (%s)\n' \
		"$PF_POD_PORT" "$PF_PORT" >&2
	exit 2
}

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
# pod_admin_state runs inside a command substitution, so the pid of the forward
# it starts is set in a SUBSHELL and never reaches the trap below. A file
# crosses that boundary; a variable does not.
POD_PF_PIDFILE="$(mktemp "${TMPDIR:-/tmp}/demo-isolation-podpid.XXXXXX")"
BODY="$(mktemp "${TMPDIR:-/tmp}/demo-isolation-body.XXXXXX")"
pf_pid=''
pod_pf_pid=''

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
	# The sweep's per-pod forward. Short-lived in the normal path -- started and
	# killed inside pod_admin_state -- but a Ctrl-C lands between those two, and
	# a leaked forward holds PF_POD_PORT open against the next run.
	local stray
	stray="$(cat "$POD_PF_PIDFILE" 2>/dev/null || true)"
	if [ -n "$stray" ]; then
		kill "$stray" 2>/dev/null || true
		wait "$stray" 2>/dev/null || true
	fi
	rm -f "$PF_LOG" "$BODY" "$POD_PF_PIDFILE" 2>/dev/null || true
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

# The pods behind the Service: the exact set a request through the gateway can
# be routed to. Read from the Service's EndpointSlices rather than from a bare
# label selector, because readiness is what decides routing -- a pod that is not
# a ready endpoint cannot have taken the write this test is chasing.
service_pods() {
	kubectl -n "$NS" get endpointslices -l "kubernetes.io/service-name=${SVC}" \
		-o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{" "}{.conditions.ready}{"\n"}{end}' \
		--request-timeout=20s 2>/dev/null \
		| awk '$2 == "true" { print $1 }' | sort -u
}

# Wait until OUR port-forward actually owns the local port, before trusting
# anything that answers on it.
#
# Without this the read races, and it races into a false PASS. If the forward
# fails to bind -- most often because something else already holds that local
# port -- the process exits, but a curl issued in the window before it does is
# answered by WHATEVER does hold the port. The sweep then records some other
# pod's state under this pod's name, and reports "unchanged" across replicas it
# never actually read. That is the same defect this assertion exists to catch,
# one level down, so it fails closed: no confirmed bind, no reading, E_HARNESS.
#
# Confirmed by kubectl's own "Forwarding from" line rather than by probing the
# port, because a successful probe is exactly what a collision also produces.
pf_bound() {
	local log="$1" pid="$2" start=$SECONDS
	while :; do
		grep -q 'Forwarding from' "$log" 2>/dev/null && return 0
		grep -qi 'address already in use\|unable to listen\|error forwarding' "$log" 2>/dev/null && return 1
		kill -0 "$pid" 2>/dev/null || return 1
		[ $((SECONDS - start)) -ge "$PF_DEADLINE" ] && return 1
		sleep 1
	done
}

# GET the injector on ONE named pod, through a port-forward of its own. Echoes
# the canonical (jq -S -c) JSON and returns 0; returns 1 with no output if that
# pod could not be read.
#
# The caller MUST turn a non-zero return into E_HARNESS, never into a failed
# assertion. A pod nobody could read is an unfinished test, not a breached
# boundary -- reporting it as a failure would claim the injector was written to
# when what actually happened is that nobody looked.
pod_admin_state() {
	local pod="$1" body log code state start
	body="$(mktemp "${TMPDIR:-/tmp}/demo-isolation-pod.XXXXXX")"
	log="$(mktemp "${TMPDIR:-/tmp}/demo-isolation-podpf.XXXXXX")"
	kubectl -n "$NS" port-forward "pod/${pod}" "${PF_POD_PORT}:${ADMIN_PORT}" >"$log" 2>&1 &
	pod_pf_pid=$!
	printf '%s' "$pod_pf_pid" > "$POD_PF_PIDFILE"
	state=''
	if ! pf_bound "$log" "$pod_pf_pid"; then
		kill "$pod_pf_pid" 2>/dev/null || true
		wait "$pod_pf_pid" 2>/dev/null || true
		pod_pf_pid=''
		: > "$POD_PF_PIDFILE"
		cat "$log" >> "$PF_LOG" 2>/dev/null || true
		rm -f "$body" "$log" 2>/dev/null || true
		return 1
	fi
	start=$SECONDS
	while :; do
		kill -0 "$pod_pf_pid" 2>/dev/null || break
		code="$(curl -sS -o "$body" -w '%{http_code}' --max-time "$CURL_MAX_TIME" \
			"http://127.0.0.1:${PF_POD_PORT}/admin/inject" 2>/dev/null)"
		if [ "${code:-000}" = '200' ]; then
			state="$(jq -S -c . < "$body" 2>/dev/null || true)"
			break
		fi
		[ $((SECONDS - start)) -ge "$PF_DEADLINE" ] && break
		sleep 1
	done
	kill "$pod_pf_pid" 2>/dev/null || true
	wait "$pod_pf_pid" 2>/dev/null || true
	pod_pf_pid=''
	: > "$POD_PF_PIDFILE"
	cat "$log" >> "$PF_LOG" 2>/dev/null || true
	rm -f "$body" "$log" 2>/dev/null || true
	[ -n "$state" ] || return 1
	printf '%s' "$state"
}

# POST a config to ONE named pod, used only to put back what a leaked write
# changed. Best effort: its result never affects a verdict.
pod_admin_post() {
	local pod="$1" data="$2" log start done_=''
	log="$(mktemp "${TMPDIR:-/tmp}/demo-isolation-podpf.XXXXXX")"
	kubectl -n "$NS" port-forward "pod/${pod}" "${PF_POD_PORT}:${ADMIN_PORT}" >"$log" 2>&1 &
	pod_pf_pid=$!
	printf '%s' "$pod_pf_pid" > "$POD_PF_PIDFILE"
	if ! pf_bound "$log" "$pod_pf_pid"; then
		kill "$pod_pf_pid" 2>/dev/null || true
		wait "$pod_pf_pid" 2>/dev/null || true
		pod_pf_pid=''
		: > "$POD_PF_PIDFILE"
		rm -f "$log" 2>/dev/null || true
		return 1
	fi
	start=$SECONDS
	while :; do
		kill -0 "$pod_pf_pid" 2>/dev/null || break
		if curl -sS -o /dev/null --max-time "$CURL_MAX_TIME" \
			-X POST -H 'content-type: application/json' --data "$data" \
			"http://127.0.0.1:${PF_POD_PORT}/admin/inject" 2>/dev/null; then
			done_=1
			break
		fi
		[ $((SECONDS - start)) -ge "$PF_DEADLINE" ] && break
		sleep 1
	done
	kill "$pod_pf_pid" 2>/dev/null || true
	wait "$pod_pf_pid" 2>/dev/null || true
	pod_pf_pid=''
	: > "$POD_PF_PIDFILE"
	rm -f "$log" 2>/dev/null || true
	[ -n "$done_" ]
}

# Reads every pod in $POD_LIST, writing one "<pod><TAB><json>" line per pod to
# the file named in $1. Sets UNREACHABLE_POD and returns 1 the moment one cannot
# be read.
#
# Writes to a file rather than to stdout so the caller can invoke it directly.
# Called as "$(sweep_admin_state)" it would run in a subshell, and UNREACHABLE_POD
# -- the whole diagnostic value of the failure -- would be set on a copy of the
# shell that exits a microsecond later, leaving the harness message naming no pod
# at all.
UNREACHABLE_POD=''
sweep_admin_state() {
	local out="$1" pod state
	UNREACHABLE_POD=''
	: > "$out"
	for pod in $POD_LIST; do
		if ! state="$(pod_admin_state "$pod")"; then
			UNREACHABLE_POD="$pod"
			return 1
		fi
		printf '%s\t%s\n' "$pod" "$state" >> "$out"
	done
}

# The state recorded for one pod in a sweep's output.
state_of() {
	printf '%s\n' "$2" | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }'
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

# UNVERIFIED, AND THE LARGEST CLAIM IN THIS SCRIPT. The whole open half rests on
# `kubectl port-forward` reaching a port that is NOT a declared containerPort:
# apps/quote-api/values.yaml declares 8080 and 8081 and says nothing about 8082.
#
# The reasoning is that port-forward attaches to the pod's network namespace and
# dials the port there, so a containerPort entry -- which is documentation for
# humans and schedulers, not a firewall -- should not gate it. That is a reading
# of how the mechanism works, not something this script's author watched happen
# against a live cluster.
#
# If the reading is wrong, this fails to exit 3 and not to a false pass: nothing
# answers on PF_PORT, the readiness loop below runs out its ceiling, and the
# script reports "could not finish" with kubectl's own log. It cannot turn a
# reachable injector into a green run. That asymmetry is why the claim was left
# unverified rather than worked around.
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
#
# WHY THIS READS EVERY REPLICA AND NOT ONE.
#
# The write and the read do not select a pod the same way. The POST goes through
# the gateway, which load-balances across every ready endpoint of the Service;
# the read-back comes through a port-forward, which pins to exactly one pod. So
# the pod that takes the write is usually NOT the pod the read lands on. A
# single-pod read is only sound at one replica. At three it misses a write that
# genuinely landed roughly two times in three -- and reports "unchanged" with
# full confidence, which is worse than not asserting at all.
#
# Observed, not theorised. With the injector deliberately mounted on the public
# listener, a POST through the gateway set error_rate=1 on one of three replicas
# while the single-pod read-back returned a different pod's untouched config.
# This assertion passed. The breach surfaced two assertions later, and only as a
# side effect: a third of the traffic began returning 500, so the liveness check
# went red. The sharp assertion was blunt, and the one that caught it was not
# aiming at this.
#
# So: enumerate the pods behind the Service, read all of them before the write
# and all of them after, and fail if ANY of them changed. The replica count is
# not this test's to change -- reducing the Deployment to one pod would make the
# old single read sound and the test worthless, because the topology it has to
# hold under is the one that ships.
#
# This is the second assumption in this script that was true in one topology and
# false in another; the ADMIN_PORT note above is the first. Same lesson twice: a
# claim verified at one replica, on one machine, is not the claim being made.
#
# A pod that cannot be read is E_HARNESS, never E_FAILED. "Nobody looked" and
# "somebody wrote" are different findings and this script already knows that.

step 'A write through the closed path, read back through the open one'

POD_LIST="$(service_pods)"
[ -n "$POD_LIST" ] || harness "the ${SVC} Service has no ready endpoints, so there is nothing to read the injector on"
pod_count="$(printf '%s\n' "$POD_LIST" | grep -c .)"

SWEEP_FILE="$(mktemp "${TMPDIR:-/tmp}/demo-isolation-sweep.XXXXXX")"
sweep_admin_state "$SWEEP_FILE" || harness \
	"could not read the injector on pod ${UNREACHABLE_POD}. Every replica has to be readable before 'unchanged' can mean anything."
before_all="$(cat "$SWEEP_FILE")"

printf '        %s replica(s) behind %s; reading the injector on each\n' "$pod_count" "$SVC"

# Pick a value no replica is already set to, so "unchanged" cannot be satisfied
# by accident. Checked across ALL of them for the same reason the read-back is:
# a value that looks novel on the first pod may be exactly what another pod is
# already sitting at, and the write would then be invisible there.
target='1.0'
if printf '%s\n' "$before_all" | cut -f2- | grep -q . \
	&& printf '%s\n' "$before_all" | cut -f2- | jq -e -s 'any(.[]; .error_rate == 1)' >/dev/null 2>&1; then
	target='0.5'
fi
payload="{\"error_rate\":${target}}"

printf '        POSTing error_rate=%s through the gateway\n' "$target"

post_code="$(edge_code POST /admin/inject "$payload")"
case "$post_code" in
	404) ok "POST /admin/inject -> 404 at ${HOST}:${EDGE_HTTPS_PORT}" ;;
	000) ok "POST /admin/inject -> connection refused at ${HOST}:${EDGE_HTTPS_PORT}" ;;
	2*)  bad "POST /admin/inject -> ${post_code} -- a write to the injector was ACCEPTED through the public gateway" ;;
	*)   bad "POST /admin/inject -> ${post_code}, want 404 or no connection" ;;
esac

sweep_admin_state "$SWEEP_FILE" || harness \
	"the injector on pod ${UNREACHABLE_POD} stopped answering before its state could be re-read"
after_all="$(cat "$SWEEP_FILE")"
rm -f "$SWEEP_FILE" 2>/dev/null || true

changed_pods=''
while IFS= read -r line; do
	[ -n "$line" ] || continue
	pod="${line%%$'\t'*}"
	now="${line#*$'\t'}"
	was="$(state_of "$pod" "$before_all")"
	[ "$was" = "$now" ] || changed_pods="${changed_pods}${pod} "
done <<<"$after_all"

if [ -z "$changed_pods" ]; then
	ok "the injector state is byte-for-byte unchanged on all ${pod_count} replica(s)"
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		printf '        %-30s %s\n' "${line%%$'\t'*}" "${line#*$'\t'}"
	done <<<"$before_all"
else
	bad "the injector state CHANGED on ${changed_pods% } after a write to the closed path"
	for pod in $changed_pods; do
		printf '        %-30s before %s\n' "$pod" "$(state_of "$pod" "$before_all")"
		printf '        %-30s after  %s\n' '' "$(state_of "$pod" "$after_all")"
	done
	# Best effort, and it does not affect the verdict: leaving a demo cluster
	# with error_rate at 1.0 makes every subsequent demo fail for a reason
	# nobody will connect to this script. Restored per pod, because only the
	# pods that took the write are the ones that drifted.
	for pod in $changed_pods; do
		printf '        restoring %s through its own admin port\n' "$pod"
		pod_admin_post "$pod" "$(state_of "$pod" "$before_all")" \
			|| printf '        could not restore %s\n' "$pod"
	done
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
