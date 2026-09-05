#!/usr/bin/env bash
#
# Opens the Argo CD UI. Port-forward rather than routing it through the
# platform's own Gateway on purpose: the reconciler should not depend on the
# edge it reconciles, or a broken Gateway becomes a Gateway you cannot fix.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source versions.env

pw="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
printf '\n  URL       http://localhost:%s\n  username  admin\n  password  %s\n\n' "$ARGOCD_PORT" "$pw"
printf '  Ctrl-C to stop the port-forward.\n\n'
exec kubectl -n argocd port-forward svc/argocd-server "${ARGOCD_PORT}:80"
