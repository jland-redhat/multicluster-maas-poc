#!/usr/bin/env bash
# Install RHOAI 3.x operator on a fresh OpenShift cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KUBECONFIG_PATH=""

usage() {
  cat <<'EOF'
Usage: install-rhoai.sh [--kubeconfig PATH]

Installs the Red Hat OpenShift AI operator (stable-3.4 channel) and waits for
the operator deployment to become available. Creates DSCInitialization if missing.
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

RHOAI_NS="redhat-ods-operator"
OG_NAME="rhoai3-operatorgroup"
SUB_NAME="rhoai3-operator"
RHOAI_CHANNEL="stable-3.4"

log "Installing RHOAI operator..."
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${RHOAI_NS}
EOF

# OLM allows only one OperatorGroup per namespace. A prior console install may leave
# an auto-generated group; creating a second blocks subscription resolution ("Unknown failure").
mapfile -t EXISTING_OGS < <(oc get operatorgroup -n "${RHOAI_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [[ "${#EXISTING_OGS[@]}" -gt 1 ]]; then
  warn "Multiple OperatorGroups in ${RHOAI_NS}; removing extras so OLM can resolve the subscription."
  for og in "${EXISTING_OGS[@]}"; do
    if [[ "${og}" != "${OG_NAME}" ]]; then
      oc delete operatorgroup "${og}" -n "${RHOAI_NS}" --wait=true
    fi
  done
fi

if ! oc get operatorgroup "${OG_NAME}" -n "${RHOAI_NS}" >/dev/null 2>&1; then
  if [[ "${#EXISTING_OGS[@]}" -eq 1 ]]; then
    log "Reusing existing OperatorGroup ${EXISTING_OGS[0]} in ${RHOAI_NS}."
  else
    log "Creating OperatorGroup ${OG_NAME}..."
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${OG_NAME}
  namespace: ${RHOAI_NS}
spec: {}
EOF
  fi
fi

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUB_NAME}
  namespace: ${RHOAI_NS}
spec:
  channel: ${RHOAI_CHANNEL}
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

log "Waiting for RHOAI subscription..."
if ! oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  "subscription/${SUB_NAME}" -n "${RHOAI_NS}" --timeout=600s; then
  oc get subscription "${SUB_NAME}" -n "${RHOAI_NS}" -o yaml | sed -n '/^status:/,$p' >&2 || true
  die "RHOAI subscription did not reach AtLatestKnown — check for duplicate OperatorGroups: oc get operatorgroup -n ${RHOAI_NS}"
fi

wait_for_deployment rhods-operator redhat-ods-operator 600

log "Ensuring DSCInitialization..."
if ! oc get dscinitialization default-dsci >/dev/null 2>&1; then
  oc apply -f - <<EOF
apiVersion: dscinitialization.opendatahub.io/v2
kind: DSCInitialization
metadata:
  name: default-dsci
  labels:
    app.kubernetes.io/name: dscinitialization
spec:
  applicationsNamespace: redhat-ods-applications
  monitoring:
    managementState: Managed
    metrics: {}
    namespace: redhat-ods-monitoring
  trustedCABundle:
    customCABundle: ""
    managementState: Managed
EOF
fi

log "Waiting for DSCInitialization..."
for _ in $(seq 1 60); do
  if oc get dscinitialization default-dsci >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
oc get dscinitialization default-dsci >/dev/null 2>&1 \
  || die "DSCInitialization default-dsci not found — check operator logs"

log "RHOAI operator install complete."
