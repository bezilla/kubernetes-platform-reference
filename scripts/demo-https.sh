#!/usr/bin/env bash
#
# The sample workload, over HTTPS, through Gateway API, on a cert-manager
# certificate -- reached the way anything outside the cluster would reach it.
#
# --resolve rather than an /etc/hosts entry: this demonstration should not need
# sudo, and editing a machine's hosts file to run someone's reference repo is a
# bad trade. --cacert rather than -k, because -k would prove the port answers
# and nothing about the certificate, and the certificate is the point.
#
# WHAT THIS ASSERTS, and what it asserted before --fail was added.
#
# It always asserted the certificate: --cacert makes curl exit 60 when the chain
# does not verify, and under `set -e` that fails the script. It always asserted
# that the gateway completes a TLS handshake, because openssl x509 gets no input
# otherwise and pipefail takes the run down.
#
# It did NOT assert that anything answered. `curl -sS` without --fail exits 0 on
# any HTTP status: measured, a 502 gives "status 502" and exit 0. So an Envoy
# gateway holding a valid certificate and routing to nothing passed this script,
# and the run printed 502 in green text on its way to exiting 0. That mattered
# more than one demo, because `make demo` runs on all three matrix legs and the
# rollback leg calls this for its workload-still-answers assertion -- which
# inherited exactly the same gap.
#
# With --fail on all three requests, a non-2xx now fails the script, so the
# claim in each heading is the claim being tested. The plaintext check needs one
# more thing: --fail triggers on >= 400 and a redirect is 3xx, so it would pass
# a plaintext port that served 200 just as happily as one that redirected. The
# status is compared explicitly for that reason.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

HOST="quote-api.${APPS_DOMAIN}"
CA=.work/platform-ca.crt

mkdir -p .work
kubectl -n cert-manager get secret platform-root-ca -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$CA"
[ -s "$CA" ] || { echo "demo-https: could not read the platform CA. Run 'make up'." >&2; exit 1; }

printf '\n\033[1mThe platform CA\033[0m  (created by cert-manager at install time)\n'
openssl x509 -in "$CA" -noout -subject -dates | sed 's/^/  /'

printf '\n\033[1mThe certificate the Gateway is serving\033[0m\n'
echo | openssl s_client -connect "127.0.0.1:${EDGE_HTTPS_PORT}" -servername "$HOST" -CAfile "$CA" 2>/dev/null \
	| openssl x509 -noout -subject -issuer -ext subjectAltName 2>/dev/null | sed 's/^/  /'

printf '\n\033[1mHTTPS through the Gateway\033[0m\n'
curl -sS --fail --cacert "$CA" --resolve "${HOST}:${EDGE_HTTPS_PORT}:127.0.0.1" \
	-o /dev/null -w '  status %{http_code}   tls_verify %{ssl_verify_result} (0 = verified against the platform CA)\n' \
	"https://${HOST}:${EDGE_HTTPS_PORT}/healthz"

printf '\n\033[1mThe application response\033[0m\n'
curl -sS --fail --cacert "$CA" --resolve "${HOST}:${EDGE_HTTPS_PORT}:127.0.0.1" \
	"https://${HOST}:${EDGE_HTTPS_PORT}/api/quote?sku=SKU-1" | sed 's/^/  /'

printf '\n\n\033[1mPlaintext is answered, never served\033[0m\n'
plain="$(curl -sS --fail -o /dev/null -w '%{http_code} %{redirect_url}' \
	--resolve "${HOST}:${EDGE_HTTP_PORT}:127.0.0.1" "http://${HOST}:${EDGE_HTTP_PORT}/healthz")"
# Unquoted on purpose: $plain is "code url" and the split feeds the two %s.
# shellcheck disable=SC2086
printf '  status %s  ->  %s\n' $plain
case "$plain" in
	3??\ https://*) ;;
	*) printf '\ndemo-https: plaintext did not redirect to HTTPS: %s\n' "$plain" >&2
	   printf 'demo-https: the heading above claims plaintext is answered and never served.\n' >&2
	   exit 1 ;;
esac

printf '\n  To trust this CA in a browser, import .work/platform-ca.crt.\n'
printf '  It is generated per cluster and is worthless anywhere else.\n\n'
