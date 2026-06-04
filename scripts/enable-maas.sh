#!/usr/bin/env bash
# Enable MaaS via RHOAI DataScienceCluster (operator-managed platform).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KUBECONFIG_PATH=""

usage() {
  cat <<'EOF'
Usage: enable-maas.sh [--kubeconfig PATH]

Prerequisites:
  - RHOAI operator installed (install-rhoai.sh)
  - maas-db-config Secret in redhat-ods-applications
  - maas-default-gateway Programmed (setup-gateway.sh)
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

oc get secret maas-db-config -n "${APP_NAMESPACE}" >/dev/null 2>&1 \
  || die "maas-db-config not found in ${APP_NAMESPACE} — create it first"

log "Applying DataScienceCluster with modelsAsService: Managed..."
oc apply -f "${POC_ROOT}/kustomize/common/datasciencecluster.yaml"

wait_for_maas_ready
log "MaaS platform enabled."
