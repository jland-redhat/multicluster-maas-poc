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

Deploys ephemeral PostgreSQL with LoadBalancer service and the
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

log "Deploying hub PostgreSQL..."
kustomize build "${POC_ROOT}/kustomize/hub/postgres" | oc apply -f -

wait_for_deployment postgres "${POSTGRES_NAMESPACE}" 180

PASS="$(oc get secret postgres-creds -n "${POSTGRES_NAMESPACE}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
ENCODED="$(urlencode_password "${PASS}")"
DB_URL="postgresql://maas:${ENCODED}@postgres.${POSTGRES_NAMESPACE}.svc:5432/maas?sslmode=disable"
create_maas_db_config "${APP_NAMESPACE}" "${DB_URL}"

IFS='|' read -r ENDPOINT_TYPE EXT_HOST EXT_PORT <<< "$(hub_postgres_external_endpoint "${KUBECONFIG}" "${POSTGRES_NAMESPACE}")"

log "Hub PostgreSQL ready."
log "  In-cluster URL: postgres.${POSTGRES_NAMESPACE}.svc:5432"
if [[ -n "${EXT_HOST}" ]]; then
  log "  External ${ENDPOINT_TYPE}: ${EXT_HOST}:${EXT_PORT} (sslmode=disable)"
else
  warn "External postgres endpoint not ready yet (LoadBalancer or Route)"
fi
