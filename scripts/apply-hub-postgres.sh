#!/usr/bin/env bash
# Deploy hub PostgreSQL and in-cluster maas-db-config Secret.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KUBECONFIG_PATH=""

usage() {
  cat <<'EOF'
Usage: apply-hub-postgres.sh [--kubeconfig PATH]

Deploys ephemeral PostgreSQL, a TCP passthrough Route (postgres-hub), and the
in-cluster maas-db-config Secret for hub minting.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

setup_kubeconfig "${KUBECONFIG_PATH}"
require_cmd kustomize

oc create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

log "Deploying hub PostgreSQL..."
kustomize build "${POC_ROOT}/kustomize/hub/postgres" | oc apply -f -

wait_for_deployment postgres "${APP_NAMESPACE}" 180

PASS="$(oc get secret postgres-creds -n "${APP_NAMESPACE}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
ENCODED="$(urlencode_password "${PASS}")"
DB_URL="postgresql://maas:${ENCODED}@postgres.${APP_NAMESPACE}.svc:5432/maas?sslmode=disable"
create_maas_db_config "${APP_NAMESPACE}" "${DB_URL}"

ROUTE_HOST="$(oc get route postgres-hub -n "${APP_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
log "Hub PostgreSQL ready."
log "  In-cluster URL: postgres.${APP_NAMESPACE}.svc:5432"
if [[ -n "${ROUTE_HOST}" ]]; then
  log "  External Route: ${ROUTE_HOST}:443 (passthrough, sslmode=disable)"
fi
