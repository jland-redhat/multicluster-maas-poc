#!/usr/bin/env bash
# Shared helpers for multicluster-poc scripts.
set -euo pipefail

POC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

APP_NAMESPACE="${APP_NAMESPACE:-redhat-ods-applications}"
POSTGRES_NAMESPACE="${POSTGRES_NAMESPACE:-postgres}"
AUTHORINO_NAMESPACE="${AUTHORINO_NAMESPACE:-kuadrant-system}"
RHCL_NAMESPACE="${RHCL_NAMESPACE:-kuadrant-system}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshift-ingress}"
DEFAULT_GIT_REPO="${DEFAULT_GIT_REPO:-https://github.com/jland-redhat/multicluster-maas-poc.git}"
DEFAULT_GIT_REVISION="${DEFAULT_GIT_REVISION:-main}"

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
  local deadline=$((SECONDS + timeout))
  local logged=false

  while ! oc get "deployment/${name}" -n "${ns}" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      die "deployment/${name} not found in ${ns} after ${timeout}s"
    fi
    if [[ "${logged}" == false ]]; then
      log "Waiting for deployment/${name} to appear in ${ns}..."
      logged=true
    fi
    sleep 5
  done

  local remaining=$((deadline - SECONDS))
  (( remaining < 1 )) && remaining=1
  oc wait --for=condition=Available "deployment/${name}" -n "${ns}" --timeout="${remaining}s"
}

wait_for_crd() {
  local name=$1
  local timeout=${2:-600}
  local deadline=$((SECONDS + timeout))
  log "Waiting for CRD ${name}..."
  while ! oc get crd "${name}" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      die "CRD ${name} not available after ${timeout}s"
    fi
    sleep 5
  done
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

find_hub_postgres_namespace() {
  local kubeconfig="${1:-${KUBECONFIG:-}}"
  local ns
  for ns in "${POSTGRES_NAMESPACE}" redhat-ods-applications; do
    if KUBECONFIG="${kubeconfig}" oc get secret postgres-creds -n "${ns}" >/dev/null 2>&1; then
      if [[ "${ns}" != "${POSTGRES_NAMESPACE}" ]]; then
        warn "Using legacy hub postgres in ${ns} (expected ${POSTGRES_NAMESPACE}). Run apply-hub-postgres.sh on the hub to migrate."
      fi
      printf '%s' "${ns}"
      return 0
    fi
  done
  die "hub postgres-creds not found in ${POSTGRES_NAMESPACE} or redhat-ods-applications — run apply-hub-postgres.sh on the hub"
}

# Prints: lb|HOST|PORT or route|HOST|PORT
hub_postgres_external_endpoint() {
  local kubeconfig=$1
  local ns=$2
  local host

  host="$(KUBECONFIG="${kubeconfig}" oc get svc postgres -n "${ns}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -z "${host}" ]]; then
    host="$(KUBECONFIG="${kubeconfig}" oc get svc postgres -n "${ns}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  fi
  if [[ -n "${host}" ]]; then
    printf 'lb|%s|5432' "${host}"
    return 0
  fi

  host="$(KUBECONFIG="${kubeconfig}" oc get route postgres-hub -n "${ns}" \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    printf 'route|%s|443' "${host}"
    return 0
  fi

  die "hub postgres external endpoint not found (LoadBalancer or postgres-hub Route) in namespace ${ns}"
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
