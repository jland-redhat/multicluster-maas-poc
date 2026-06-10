#!/usr/bin/env bash
# Deploy simulator models and MaaS CRs (hub and client clusters).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KUBECONFIG_PATH=""

usage() {
  cat <<'EOF'
Usage: apply-models.sh [--kubeconfig PATH]

Deploys free + premium simulator bundles (LLMInferenceService, MaaSModelRef,
MaaSAuthPolicy, MaaSSubscription). Use the same manifest on hub and clients so
subscription names and auth policies match for shared API keys.
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

oc create namespace llm --dry-run=client -o yaml | oc apply -f -
oc create namespace models-as-a-service --dry-run=client -o yaml | oc apply -f -

log "Deploying simulator models and MaaS resources..."
kustomize build "${POC_ROOT}/kustomize/common/models" | oc apply -f -

log "Waiting for LLMInferenceServices..."
for name in facebook-opt-125m-simulated premium-simulated-simulated-premium; do
  oc wait --for=condition=Ready "llminferenceservice/${name}" -n llm --timeout=600s \
    || warn "LLMInferenceService ${name} not Ready yet"
done

log "Models and MaaS resources applied."
