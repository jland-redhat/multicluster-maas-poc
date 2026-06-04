#!/usr/bin/env bash
# Create maas-default-gateway using upstream maas-billing setup-gateway.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KUBECONFIG_PATH=""
INGRESS_MODE="${INGRESS_MODE:-route}"

usage() {
  cat <<'EOF'
Usage: setup-gateway.sh [--kubeconfig PATH]

Creates maas-default-gateway in openshift-ingress using the parent repo's
scripts/setup-gateway.sh. Run Authorino TLS bootstrap afterward on RHOAI:

  AUTHORINO_NAMESPACE=rh-connectivity-link \
    <maas-billing>/scripts/setup-authorino-tls.sh
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

GATEWAY_SCRIPT="${MAAS_REPO_ROOT}/scripts/setup-gateway.sh"
[[ -f "${GATEWAY_SCRIPT}" ]] || die "missing ${GATEWAY_SCRIPT}"

log "Creating maas-default-gateway (INGRESS_MODE=${INGRESS_MODE})..."
INGRESS_MODE="${INGRESS_MODE}" "${GATEWAY_SCRIPT}"

wait_for_gateway

TLS_SCRIPT="${MAAS_REPO_ROOT}/scripts/setup-authorino-tls.sh"
if [[ -f "${TLS_SCRIPT}" ]]; then
  log "Bootstrapping Authorino TLS for RHCL..."
  AUTHORINO_NAMESPACE="${AUTHORINO_NAMESPACE}" "${TLS_SCRIPT}"
else
  warn "setup-authorino-tls.sh not found — run it manually if auth fails"
fi

log "Gateway setup complete."
