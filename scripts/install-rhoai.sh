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

Installs the Red Hat OpenShift AI operator (stable-3.x channel) and waits for
the operator deployment to become available. DSCInitialization is created
automatically by the operator.
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

log "Installing RHOAI operator..."
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: redhat-ods-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhoai3-operatorgroup
  namespace: redhat-ods-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhoai3-operator
  namespace: redhat-ods-operator
spec:
  channel: stable-3.x
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

log "Waiting for RHOAI subscription..."
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  subscription/rhoai3-operator -n redhat-ods-operator --timeout=600s

wait_for_deployment rhods-operator redhat-ods-operator 600

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
