#!/usr/bin/env bash
# Copy hub PostgreSQL Route credentials to a client cluster maas-db-config Secret.
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

Reads postgres-creds and postgres-hub Route from the hub, builds an external
DB_CONNECTION_URL (Route host:443, sslmode=disable), and applies maas-db-config
on the client cluster.
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
HUB_PASS="$(KUBECONFIG="${HUB_KUBECONFIG}" oc get secret postgres-creds \
  -n "${POSTGRES_NAMESPACE}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
ROUTE_HOST="$(KUBECONFIG="${HUB_KUBECONFIG}" oc get route postgres-hub \
  -n "${POSTGRES_NAMESPACE}" -o jsonpath='{.spec.host}')"
[[ -n "${HUB_PASS}" && -n "${ROUTE_HOST}" ]] \
  || die "hub postgres-creds or postgres-hub Route not found"

ENCODED="$(urlencode_password "${HUB_PASS}")"
EXTERNAL_URL="postgresql://maas:${ENCODED}@${ROUTE_HOST}:443/maas?sslmode=disable"

log "Applying maas-db-config on client (host=${ROUTE_HOST})..."
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
    bash -lc "PGPASSWORD='${HUB_PASS}' pg_isready -h '${ROUTE_HOST}' -p 443 -U maas -d maas" \
    || warn "pg_isready failed — check network/firewall to hub Route"
  oc delete pod -n "${APP_NAMESPACE}" -l run=pg-test --ignore-not-found >/dev/null 2>&1 || true
fi

log "Client database sync complete."
