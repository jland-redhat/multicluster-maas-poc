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
  1. Hub can mint an API key (OpenShift token)
  2. Client rejects mint/search key endpoints
  3. Hub-minted key reaches maas-api health on client (optional curl checks)
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
  local base
  base="$(maas_api_base_url)"
  log "${label}: GET ${base}/health"
  curl -skS -f "${base}/health" >/dev/null \
    || die "${label} maas-api health check failed"
}

mint_key_on_hub() {
  export KUBECONFIG="${HUB_KUBECONFIG}"
  local base token response key
  base="$(maas_api_base_url)"
  token="$(oc whoami -t)"
  [[ -n "${token}" ]] || die "hub: oc whoami -t failed"

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

client_denies_key_apis() {
  export KUBECONFIG="${CLIENT_KUBECONFIG}"
  local base token code
  base="$(maas_api_base_url)"
  token="$(oc whoami -t)"

  log "Client: POST /v1/api-keys should be denied..."
  code="$(curl -skS -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{"name":"should-fail"}' \
    "${base}/v1/api-keys")"
  [[ "${code}" == "403" || "${code}" == "401" || "${code}" == "404" ]] \
    || die "expected client mint to be denied, got HTTP ${code}"

  log "Client: GET /v1/api-keys/search should be denied..."
  code="$(curl -skS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    "${base}/v1/api-keys/search")"
  [[ "${code}" == "403" || "${code}" == "401" || "${code}" == "404" ]] \
    || die "expected client search to be denied, got HTTP ${code}"
}

inference_with_key() {
  local kubeconfig=$1
  local label=$2
  local key=$3
  export KUBECONFIG="${kubeconfig}"
  local host code
  host="$(cluster_ingress_host)"
  local url="https://${host}/llm/facebook-opt-125m-simulated/v1/chat/completions"
  log "${label}: inference smoke via ${url}..."
  code="$(curl -skS -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    -d '{"model":"facebook-opt-125m-simulated","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
    "${url}" 2>/dev/null || echo "000")"
  if [[ "${code}" == "000" ]]; then
    url="http://${host}/llm/facebook-opt-125m-simulated/v1/chat/completions"
    code="$(curl -skS -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer ${key}" \
      -H "Content-Type: application/json" \
      -d '{"model":"facebook-opt-125m-simulated","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
      "${url}")"
  fi
  [[ "${code}" == "200" ]] || warn "${label} inference returned HTTP ${code} (model path may differ until LLMIS is Ready)"
}

log "=== Multicluster PoC validation ==="
check_health "${HUB_KUBECONFIG}" "Hub"
check_health "${CLIENT_KUBECONFIG}" "Client"
API_KEY="$(mint_key_on_hub)"
client_denies_key_apis
inference_with_key "${CLIENT_KUBECONFIG}" "Client" "${API_KEY}"
log "Validation complete."
