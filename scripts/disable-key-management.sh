#!/usr/bin/env bash
# Block public API key management endpoints on client clusters.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KUBECONFIG_PATH=""

usage() {
  cat <<'EOF'
Usage: disable-key-management.sh [--kubeconfig PATH]

Applies an AuthPolicy that denies all /maas-api/v1/api-keys* gateway paths.
Re-run if the operator reconciles and removes the policy.

Does not affect internal Authorino validation callbacks to maas-api.
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

oc get httproute maas-api-route -n "${APP_NAMESPACE}" >/dev/null 2>&1 \
  || die "maas-api-route not found — run enable-maas.sh first"

log "Applying key-management deny AuthPolicy..."
kustomize build "${POC_ROOT}/kustomize/client/disable-key-management" | oc apply -f -

log "Key management disabled on gateway paths."
