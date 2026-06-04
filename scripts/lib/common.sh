#!/usr/bin/env bash
# Shared helpers for multicluster-poc scripts.
set -euo pipefail

POC_ROOT="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
MAAS_REPO_ROOT="$(cd "${POC_ROOT}/.." && pwd)"

APP_NAMESPACE="${APP_NAMESPACE:-redhat-ods-applications}"
AUTHORINO_NAMESPACE="${AUTHORINO_NAMESPACE:-rh-connectivity-link}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshift-ingress}"

log() { printf '[multicluster-poc] %s\n' "$*"; }
warn() { printf '[multicluster-poc] WARN: %s\n' "$*" >&2; }
die() { printf '[multicluster-poc] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local cmd=$1
  command -v "${cmd}" >/dev/null 2>&1 || die "required command not found: ${cmd}"
}

setup_kubeconfig() {
  local kubeconfig="${1:-}"
  if [[ -n "${kubeconfig}" ]]; then
    export KUBECONFIG="${kubeconfig}"
  fi
  require_cmd oc
  oc whoami >/dev/null 2>&1 || die "not logged in (oc login required)"
}

wait_for_csv() {
  local name=$1
  local ns=$2
  local timeout=${3:-600}
  log "Waiting for CSV ${name} in ${ns} (timeout ${timeout}s)..."
  oc wait --for=jsonpath='{.status.phase}'=Succeeded \
    "csv/${name}" -n "${ns}" --timeout="${timeout}s"
}

wait_for_deployment() {
  local name=$1
  local ns=$2
  local timeout=${3:-300}
  oc wait --for=condition=Available "deployment/${name}" -n "${ns}" --timeout="${timeout}s"
}

wait_for_gateway() {
  log "Waiting for maas-default-gateway to be Programmed..."
  oc wait --for=condition=Programmed \
    "gateway/maas-default-gateway" -n "${GATEWAY_NAMESPACE}" --timeout=120s
}

wait_for_maas_ready() {
  log "Waiting for DataScienceCluster MaaS components..."
  oc wait --for=jsonpath='{.status.conditions[?(@.type=="KserveReady")].status}'=True \
    datasciencecluster/default-dsc --timeout=600s || warn "KserveReady wait timed out"
  oc wait --for=jsonpath='{.status.conditions[?(@.type=="ModelControllerReady")].status}'=True \
    datasciencecluster/default-dsc --timeout=600s || warn "ModelControllerReady wait timed out"
  wait_for_deployment maas-api "${APP_NAMESPACE}" 300 || warn "maas-api not ready yet"
}

cluster_ingress_host() {
  local domain
  domain="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  [[ -n "${domain}" ]] || die "could not detect cluster ingress domain"
  printf 'maas.%s' "${domain}"
}

maas_api_base_url() {
  local host
  host="$(cluster_ingress_host)"
  if curl -skS -m 5 "https://${host}/maas-api/health" -o /dev/null 2>/dev/null; then
    printf 'https://%s/maas-api' "${host}"
  else
    printf 'http://%s/maas-api' "${host}"
  fi
}

urlencode_password() {
  local password=$1
  printf '%s' "${password}" | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g'
}

create_maas_db_config() {
  local namespace=$1
  local db_url=$2
  oc create secret generic maas-db-config \
    --from-literal=DB_CONNECTION_URL="${db_url}" \
    -n "${namespace}" \
    --dry-run=client -o yaml | oc apply -f -
}

restart_maas_api() {
  if oc get deployment maas-api -n "${APP_NAMESPACE}" >/dev/null 2>&1; then
    log "Restarting maas-api to pick up database config..."
    oc rollout restart deployment/maas-api -n "${APP_NAMESPACE}"
    oc rollout status deployment/maas-api -n "${APP_NAMESPACE}" --timeout=300s || true
  fi
}
