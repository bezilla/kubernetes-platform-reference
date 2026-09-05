#!/usr/bin/env bash
#
# The sample workload, over HTTPS, through Gateway API, on a cert-manager
# certificate -- reached the way anything outside the cluster would reach it.
#
# --resolve rather than an /etc/hosts entry: this demonstration should not need
# sudo, and editing a machine's hosts file to run someone's reference repo is a
# bad trade. --cacert rather than -k, because -k would prove the port answers
# and nothing about the certificate, and the certificate is the point.

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
curl -sS --cacert "$CA" --resolve "${HOST}:${EDGE_HTTPS_PORT}:127.0.0.1" \
	-o /dev/null -w '  status %{http_code}   tls_verify %{ssl_verify_result} (0 = verified against the platform CA)\n' \
	"https://${HOST}:${EDGE_HTTPS_PORT}/healthz"

printf '\n\033[1mThe application response\033[0m\n'
curl -sS --cacert "$CA" --resolve "${HOST}:${EDGE_HTTPS_PORT}:127.0.0.1" \
	"https://${HOST}:${EDGE_HTTPS_PORT}/api/quote?sku=SKU-1" | sed 's/^/  /'

printf '\n\n\033[1mPlaintext is answered, never served\033[0m\n'
curl -sS -o /dev/null -w '  status %{http_code}  ->  %{redirect_url}\n' \
	--resolve "${HOST}:${EDGE_HTTP_PORT}:127.0.0.1" "http://${HOST}:${EDGE_HTTP_PORT}/healthz"

printf '\n  To trust this CA in a browser, import .work/platform-ca.crt.\n'
printf '  It is generated per cluster and is worthless anywhere else.\n\n'
