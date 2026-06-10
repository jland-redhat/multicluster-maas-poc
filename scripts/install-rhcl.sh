#!/usr/bin/env bash
# Install cert-manager and Red Hat Connectivity Link (RHCL) for MaaS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KUBECONFIG_PATH=""

CERT_MANAGER_OPERATOR_NS="${CERT_MANAGER_OPERATOR_NS:-cert-manager-operator}"
CERT_MANAGER_OPERAND_NS="${CERT_MANAGER_OPERAND_NS:-cert-manager}"
CERT_MANAGER_SUB="${CERT_MANAGER_SUB:-openshift-cert-manager-operator}"
CERT_MANAGER_CHANNEL="${CERT_MANAGER_CHANNEL:-stable-v1}"

RHCL_NS="${RHCL_NAMESPACE:-kuadrant-system}"
RHCL_OG="${RHCL_OG:-kuadrant-operator-group}"
RHCL_SUB="${RHCL_SUB:-rhcl-operator}"
RHCL_CHANNEL="${RHCL_CHANNEL:-stable}"

usage() {
  cat <<'EOF'
Usage: install-rhcl.sh [--kubeconfig PATH]

Installs prerequisites for RHOAI Models-as-a-Service:
  - cert-manager Operator for Red Hat OpenShift
  - Red Hat Connectivity Link (RHCL) operator + Kuadrant instance

Run before setup-gateway.sh / enable-maas.sh.
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

ensure_single_operatorgroup() {
  local ns=$1
  local preferred=$2
  mapfile -t ogs < <(oc get operatorgroup -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  if [[ "${#ogs[@]}" -gt 1 ]]; then
    warn "Multiple OperatorGroups in ${ns}; keeping ${preferred}."
    for og in "${ogs[@]}"; do
      if [[ "${og}" != "${preferred}" ]]; then
        oc delete operatorgroup "${og}" -n "${ns}" --wait=true
      fi
    done
  fi
}

wait_for_subscription() {
  local name=$1
  local ns=$2
  log "Waiting for subscription/${name} in ${ns}..."
  if ! oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
    "subscription/${name}" -n "${ns}" --timeout=600s; then
    die "subscription/${name} did not reach AtLatestKnown — check: oc get operatorgroup -n ${ns}"
  fi
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

install_cert_manager() {
  if oc get subscription "${CERT_MANAGER_SUB}" -n "${CERT_MANAGER_OPERATOR_NS}" >/dev/null 2>&1; then
    log "cert-manager operator subscription already exists."
  else
    log "Installing cert-manager operator..."
    oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${CERT_MANAGER_OPERATOR_NS}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${CERT_MANAGER_SUB}
  namespace: ${CERT_MANAGER_OPERATOR_NS}
spec:
  targetNamespaces:
    - ${CERT_MANAGER_OPERATOR_NS}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${CERT_MANAGER_SUB}
  namespace: ${CERT_MANAGER_OPERATOR_NS}
spec:
  channel: ${CERT_MANAGER_CHANNEL}
  installPlanApproval: Automatic
  name: ${CERT_MANAGER_SUB}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  fi

  ensure_single_operatorgroup "${CERT_MANAGER_OPERATOR_NS}" "${CERT_MANAGER_SUB}"
  wait_for_subscription "${CERT_MANAGER_SUB}" "${CERT_MANAGER_OPERATOR_NS}"
  wait_for_deployment cert-manager "${CERT_MANAGER_OPERAND_NS}" 600
  log "cert-manager is ready."
}

install_rhcl() {
  local rhcl_fresh_install=false

  if oc get subscription "${RHCL_SUB}" -n "${RHCL_NS}" >/dev/null 2>&1; then
    log "RHCL operator subscription already exists."
  else
    rhcl_fresh_install=true
    log "Installing Red Hat Connectivity Link operator..."
    oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${RHCL_NS}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${RHCL_OG}
  namespace: ${RHCL_NS}
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${RHCL_SUB}
  namespace: ${RHCL_NS}
spec:
  channel: ${RHCL_CHANNEL}
  installPlanApproval: Automatic
  name: ${RHCL_SUB}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  fi

  ensure_single_operatorgroup "${RHCL_NS}" "${RHCL_OG}"
  wait_for_subscription "${RHCL_SUB}" "${RHCL_NS}"

  local rhcl_csv
  rhcl_csv="$(oc get subscription "${RHCL_SUB}" -n "${RHCL_NS}" -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)"
  [[ -n "${rhcl_csv}" ]] || die "RHCL subscription has no currentCSV yet"
  wait_for_csv "${rhcl_csv}" "${RHCL_NS}" 600

  if ! oc get kuadrant kuadrant -n "${RHCL_NS}" >/dev/null 2>&1; then
    if [[ "${rhcl_fresh_install}" == true ]]; then
      log "Pausing 10s for Kuadrant CRD registration before creating Kuadrant instance..."
      sleep 10
    fi
    log "Creating Kuadrant instance..."
    oc apply -f - <<EOF
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: ${RHCL_NS}
EOF
  fi

  wait_for_crd authconfigs.authorino.kuadrant.io 600
  wait_for_crd authpolicies.kuadrant.io 600
  wait_for_crd tokenratelimitpolicies.kuadrant.io 600
  wait_for_deployment authorino "${RHCL_NS}" 600
  log "RHCL (Kuadrant + Authorino) is ready."
}

install_cert_manager
install_rhcl

log "Connectivity prerequisites install complete."
