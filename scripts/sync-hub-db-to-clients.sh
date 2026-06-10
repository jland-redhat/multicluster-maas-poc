#!/usr/bin/env bash
# Copy hub PostgreSQL credentials to a client cluster maas-db-config Secret.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

HUB_KUBECONFIG=""
CLIENT_KUBECONFIG=""
TEST_CONNECTION=false

usage() {
  cat <<'EOF'
Usage: sync-hub-db-to-clients.sh \
         --hub-kubeconfig PATH \
         --client-kubeconfig PATH \
         [--test-connection]

Reads postgres-creds from the hub (postgres namespace, or legacy
redhat-ods-applications), builds an external DB_CONNECTION_URL from the
LoadBalancer or postgres-hub Route, and applies maas-db-config on the client.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub-kubeconfig) HUB_KUBECONFIG="$2"; shift 2 ;;
    --client-kubeconfig) CLIENT_KUBECONFIG="$2"; shift 2 ;;
    --test-connection) TEST_CONNECTION=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "${HUB_KUBECONFIG}" && -n "${CLIENT_KUBECONFIG}" ]] \
  || die "both --hub-kubeconfig and --client-kubeconfig are required"

log "Reading hub database credentials..."
HUB_PG_NS="$(find_hub_postgres_namespace "${HUB_KUBECONFIG}")"
HUB_PASS="$(KUBECONFIG="${HUB_KUBECONFIG}" oc get secret postgres-creds \
  -n "${HUB_PG_NS}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"

IFS='|' read -r ENDPOINT_TYPE LB_HOST LB_PORT <<< "$(hub_postgres_external_endpoint "${HUB_KUBECONFIG}" "${HUB_PG_NS}")"
[[ -n "${HUB_PASS}" && -n "${LB_HOST}" && -n "${LB_PORT}" ]] \
  || die "hub postgres credentials or external endpoint not ready"

ENCODED="$(urlencode_password "${HUB_PASS}")"
EXTERNAL_URL="postgresql://maas:${ENCODED}@${LB_HOST}:${LB_PORT}/maas?sslmode=disable"

log "Applying maas-db-config on client (${ENDPOINT_TYPE}=${LB_HOST}:${LB_PORT})..."
export KUBECONFIG="${CLIENT_KUBECONFIG}"
create_maas_db_config "${APP_NAMESPACE}" "${EXTERNAL_URL}"
restart_maas_api

if [[ "${TEST_CONNECTION}" == true ]]; then
  log "Testing PostgreSQL connectivity from client cluster..."
  oc run pg-test-"${RANDOM}" \
    --image=registry.redhat.io/rhel9/postgresql-16:latest \
    --restart=Never \
    -n "${APP_NAMESPACE}" \
    --command -- \
    bash -lc "PGPASSWORD='${HUB_PASS}' pg_isready -h '${LB_HOST}' -p ${LB_PORT} -U maas -d maas" \
    || warn "pg_isready failed — check network/firewall to hub postgres endpoint"
  oc delete pod -n "${APP_NAMESPACE}" -l run=pg-test --ignore-not-found >/dev/null 2>&1 || true
fi

log "Client database sync complete."
