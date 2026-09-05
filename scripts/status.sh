#!/usr/bin/env bash
#
# What the platform is doing right now, on one screen.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

if ! kubectl cluster-info >/dev/null 2>&1; then
	echo "status: no reachable cluster. Run 'make up'." >&2
	exit 1
fi

printf '\n\033[1mApplications\033[0m  (Argo CD reconciles each of these from Git)\n'
kubectl -n argocd get applications 2>/dev/null | sed 's/^/  /'

printf '\n\033[1mEdge\033[0m\n'
kubectl get gatewayclass -o custom-columns='CLASS:.metadata.name,ACCEPTED:.status.conditions[?(@.type=="Accepted")].status' 2>/dev/null | sed 's/^/  /'
kubectl -n platform-edge get gateway -o custom-columns='GATEWAY:.metadata.name,PROGRAMMED:.status.conditions[?(@.type=="Programmed")].status,ADDRESS:.status.addresses[0].value' 2>/dev/null | sed 's/^/  /'
kubectl get certificate -A -o custom-columns='NAMESPACE:.metadata.namespace,CERT:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null | sed 's/^/  /'

printf '\n\033[1mGuardrails\033[0m  (Enforce means a violating deploy is rejected, not reported)\n'
kubectl get clusterpolicy -o custom-columns='POLICY:.metadata.name,ACTION:.spec.validationFailureAction,READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null | sed 's/^/  /'

printf '\n\033[1mTenant workloads\033[0m  (deployed through charts/paved-road)\n'
kubectl get deploy -A -l app.kubernetes.io/part-of=paved-road \
	-o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas,TEAM:.metadata.labels.platform\.internal/team' 2>/dev/null | sed 's/^/  /'
kubectl get httproute -A -o custom-columns='NAMESPACE:.metadata.namespace,ROUTE:.metadata.name,HOSTNAMES:.spec.hostnames[*]' 2>/dev/null | sed 's/^/  /'

printf '\n\033[1mURLs\033[0m\n'
printf '  https://quote-api.apps.platform.test:%s/api/quote?sku=SKU-1   (make demo, or see README for the CA)\n' "$EDGE_HTTPS_PORT"
printf '  Argo CD UI:  make argo\n\n'
