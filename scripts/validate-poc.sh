#!/usr/bin/env bash
# End-to-end validation for the multicluster PoC.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

HUB_KUBECONFIG=""
CLIENT_KUBECONFIG=""

usage() {
  cat <<'EOF'
Usage: validate-poc.sh \
         --hub-kubeconfig PATH \
         --client-kubeconfig PATH

Checks:
  1. Hub maas-api health (hub OpenShift token)
  2. Client maas-api health (client OpenShift token)
  3. Hub can mint a MaaS API key (hub OpenShift token; key stored in hub PostgreSQL)
  4. Hub-minted MaaS API key works for inference on the client
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub-kubeconfig) HUB_KUBECONFIG="$2"; shift 2 ;;
    --client-kubeconfig) CLIENT_KUBECONFIG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "${HUB_KUBECONFIG}" && -n "${CLIENT_KUBECONFIG}" ]] \
  || die "both kubeconfig paths are required"

require_cmd jq
require_cmd curl

check_health() {
  local kubeconfig=$1
  local label=$2
  export KUBECONFIG="${kubeconfig}"
  local base token code
  base="$(maas_api_base_url)"
  token="$(cluster_openshift_token "${kubeconfig}")"
  log "${label}: GET ${base}/health (cluster OpenShift token)"
  code="$(curl -skS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    "${base}/health" 2>/dev/null || echo "000")"
  [[ "${code}" == "200" ]] \
    || die "${label} maas-api health check failed (HTTP ${code})"
}

mint_key_on_hub() {
  export KUBECONFIG="${HUB_KUBECONFIG}"
  local base token response key
  base="$(maas_api_base_url)"
  token="$(cluster_openshift_token "${HUB_KUBECONFIG}")"

  log "Hub: minting API key (subscription=simulator-subscription)..."
  response="$(curl -skS -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{"name":"multicluster-poc-test","subscription":"simulator-subscription","expiresIn":"2h"}' \
    "${base}/v1/api-keys")"

  key="$(printf '%s' "${response}" | jq -r '.key // empty')"
  [[ -n "${key}" && "${key}" != null ]] || die "hub mint failed: ${response}"
  printf '%s' "${key}"
}

inference_with_key() {
  local kubeconfig=$1
  local label=$2
  local key=$3
  export KUBECONFIG="${kubeconfig}"
  local base model_name model_url code response payload
  base="$(maas_api_base_url)"

  log "${label}: listing models via ${base}/v1/models..."
  response="$(curl -skS \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    "${base}/v1/models")"
  model_name="$(printf '%s' "${response}" | jq -r '.data[0].id // empty')"
  model_url="$(printf '%s' "${response}" | jq -r '.data[0].url // empty')"
  [[ -n "${model_name}" && -n "${model_url}" ]] \
    || die "${label} could not resolve model from /v1/models: ${response}"

  log "${label}: inference smoke via ${model_url}/v1/chat/completions (model=${model_name})..."
  payload="$(jq -nc --arg model "${model_name}" \
    '{model: $model, messages: [{role: "user", content: "hi"}], max_tokens: 5}')"
  response="$(curl -skS -X POST \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    -w $'\nHTTPSTATUS:%{http_code}' \
    "${model_url}/v1/chat/completions" || true)"
  code="${response##*HTTPSTATUS:}"
  response="${response%HTTPSTATUS:*}"
  response="${response%$'\n'}"
  [[ "${code}" == "200" ]] \
    || die "${label} inference failed (HTTP ${code:-unknown}): ${response}"
  log "${label} inference response:"
  printf '%s' "${response}" | jq .
}

log "=== Multicluster PoC validation ==="
check_health "${HUB_KUBECONFIG}" "Hub"
check_health "${CLIENT_KUBECONFIG}" "Client"
API_KEY="$(mint_key_on_hub)"
inference_with_key "${CLIENT_KUBECONFIG}" "Client" "${API_KEY}"
log "Validation complete."
