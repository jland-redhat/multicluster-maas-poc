#!/usr/bin/env bash
# Install OpenShift GitOps and optional Argo CD Applications.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KUBECONFIG_PATH=""
CLUSTER_ROLE="client"
GIT_REPO="${GIT_REPO:-${DEFAULT_GIT_REPO}}"
GIT_REVISION="${GIT_REVISION:-${DEFAULT_GIT_REVISION}}"
SKIP_APPS=false

usage() {
  cat <<'EOF'
Usage: bootstrap-gitops.sh --cluster hub|client1|client2 [options]

Options:
  --kubeconfig PATH     Kubeconfig for target cluster
  --git-repo URL        Git repo for Argo CD Applications (default: DEFAULT_GIT_REPO)
  --git-revision REF    Git branch/tag (default: main)
  --skip-apps           Install operator only; do not create Applications

Maps cluster roles for Helm values:
  hub     -> maas-poc-hub-postgres + maas-poc-models Argo Applications
  client* -> maas-poc-models Argo Application

Argo Applications are enabled by default using this repo's GitHub URL.
Use --skip-apps to install only the GitOps operator (manifests via oc apply scripts).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER_ROLE="$2"; shift 2 ;;
    --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
    --git-repo) GIT_REPO="$2"; shift 2 ;;
    --git-revision) GIT_REVISION="$2"; shift 2 ;;
    --skip-apps) SKIP_APPS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "${CLUSTER_ROLE}" ]] || die "--cluster is required"

setup_kubeconfig "${KUBECONFIG_PATH}"
require_cmd helm

HELM_ROLE="client"
if [[ "${CLUSTER_ROLE}" == "hub" ]]; then
  HELM_ROLE="hub"
fi

GITOPS_OPERATOR_NS="openshift-gitops-operator"
GITOPS_HELM_NS="${GITOPS_OPERATOR_NS}"
GITOPS_SUB="openshift-gitops-operator"
LEGACY_GITOPS_NS="openshift-operators"

# Older chart versions subscribed in openshift-operators/global-operators. That OG
# also contains servicemeshoperator3 (installPlanApproval: Manual), so OLM merges
# InstallPlans and GitOps shows "Functioning as manual" until a human approves both.
if oc get subscription "${GITOPS_SUB}" -n "${LEGACY_GITOPS_NS}" >/dev/null 2>&1; then
  warn "Removing legacy GitOps subscription from ${LEGACY_GITOPS_NS}."
  helm uninstall maas-poc-gitops -n "${LEGACY_GITOPS_NS}" 2>/dev/null || true
  oc delete subscription "${GITOPS_SUB}" -n "${LEGACY_GITOPS_NS}" --wait=true
  # Drop merged Manual InstallPlans that bundled GitOps with Service Mesh.
  while IFS= read -r ip; do
    [[ -n "${ip}" ]] || continue
    warn "Deleting stale InstallPlan ${ip} in ${LEGACY_GITOPS_NS}."
    oc delete installplan "${ip}" -n "${LEGACY_GITOPS_NS}" --wait=true 2>/dev/null || true
  done < <(oc get installplan -n "${LEGACY_GITOPS_NS}" -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
fi

log "Installing OpenShift GitOps operator via Helm..."
helm_gitops() {
  local deploy_apps=$1
  helm upgrade --install maas-poc-gitops "${POC_ROOT}/helm/gitops-bootstrap" \
    --namespace "${GITOPS_HELM_NS}" \
    --create-namespace \
    --set "git.clusterRole=${HELM_ROLE}" \
    --set "git.repoURL=${GIT_REPO}" \
    --set "git.revision=${GIT_REVISION}" \
    --set "git.deployApplications=${deploy_apps}"
}

# Phase 1: operator Subscription only (Application CRD does not exist yet).
ensure_gitops_operator_group() {
  log "Ensuring GitOps OperatorGroup uses AllNamespaces..."
  oc create namespace "${GITOPS_OPERATOR_NS}" --dry-run=client -o yaml | oc apply -f -
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator-group
  namespace: ${GITOPS_OPERATOR_NS}
spec:
  upgradeStrategy: Default
EOF
  # Helm three-way merge keeps stale targetNamespaces on upgrade; GitOps rejects OwnNamespace.
  if oc get og openshift-gitops-operator-group -n "${GITOPS_OPERATOR_NS}" \
    -o jsonpath='{.spec.targetNamespaces}' 2>/dev/null | grep -q .; then
    warn "Removing targetNamespaces from GitOps OperatorGroup (OwnNamespace unsupported)."
    oc patch og openshift-gitops-operator-group -n "${GITOPS_OPERATOR_NS}" --type=json \
      -p='[{"op": "remove", "path": "/spec/targetNamespaces"}]'
  fi
}

reset_gitops_csv_if_stuck() {
  local csv phase reason bad_og
  csv="$(oc get csv -n "${GITOPS_OPERATOR_NS}" -o jsonpath='{range .items[?(@.spec.displayName=="Red Hat OpenShift GitOps")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)"
  [[ -n "${csv}" ]] || return 1

  phase="$(oc get "csv/${csv}" -n "${GITOPS_OPERATOR_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  reason="$(oc get "csv/${csv}" -n "${GITOPS_OPERATOR_NS}" -o jsonpath='{.status.reason}' 2>/dev/null || true)"
  bad_og="$(oc get "csv/${csv}" -n "${GITOPS_OPERATOR_NS}" -o jsonpath='{range .status.conditions[?(@.reason=="UnsupportedOperatorGroup")]}{.reason}{"\n"}{end}' 2>/dev/null | head -1 || true)"

  # Succeeded CSVs may retain old UnsupportedOperatorGroup conditions in status history.
  if [[ "${phase}" == "Succeeded" ]]; then
    return 1
  fi

  if [[ "${reason}" == "UnsupportedOperatorGroup" ]] \
    || { [[ -n "${bad_og}" ]] && [[ "${phase}" != "Succeeded" ]]; }; then
    warn "Resetting stuck GitOps CSV ${csv} (${phase}/${reason:-unknown})."
    oc delete "csv/${csv}" -n "${GITOPS_OPERATOR_NS}" --wait=true
    while IFS= read -r ip; do
      [[ -n "${ip}" ]] || continue
      oc delete installplan "${ip}" -n "${GITOPS_OPERATOR_NS}" --wait=true 2>/dev/null || true
    done < <(oc get installplan -n "${GITOPS_OPERATOR_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    if oc get subscription "${GITOPS_SUB}" -n "${GITOPS_OPERATOR_NS}" >/dev/null 2>&1; then
      warn "Recreating GitOps subscription after CSV reset."
      oc delete subscription "${GITOPS_SUB}" -n "${GITOPS_OPERATOR_NS}" --wait=true
    fi
    return 0
  fi
  return 1
}

repair_gitops_subscription() {
  if ! oc get subscription "${GITOPS_SUB}" -n "${GITOPS_OPERATOR_NS}" >/dev/null 2>&1; then
    return 1
  fi

  local state missing installed_csv
  state="$(oc get subscription "${GITOPS_SUB}" -n "${GITOPS_OPERATOR_NS}" -o jsonpath='{.status.state}' 2>/dev/null || true)"
  missing="$(oc get subscription "${GITOPS_SUB}" -n "${GITOPS_OPERATOR_NS}" \
    -o jsonpath='{.status.conditions[?(@.type=="InstallPlanMissing")].status}' 2>/dev/null || true)"
  installed_csv="$(oc get subscription "${GITOPS_SUB}" -n "${GITOPS_OPERATOR_NS}" \
    -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"

  if [[ "${missing}" == "True" ]] \
    || [[ "${state}" == "UpgradePending" && "${missing}" == "True" ]] \
    || { [[ -n "${installed_csv}" ]] && ! oc get "csv/${installed_csv}" -n "${GITOPS_OPERATOR_NS}" >/dev/null 2>&1; }; then
    warn "Recreating GitOps subscription (state=${state:-unknown}, InstallPlanMissing=${missing:-false})."
    oc delete subscription "${GITOPS_SUB}" -n "${GITOPS_OPERATOR_NS}" --wait=true
    return 0
  fi
  return 1
}

ensure_gitops_operator_group
helm_gitops false
ensure_gitops_operator_group
if reset_gitops_csv_if_stuck || repair_gitops_subscription; then
  helm_gitops false
fi

log "Waiting for OpenShift GitOps subscription..."
if ! oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  "subscription/${GITOPS_SUB}" -n "${GITOPS_OPERATOR_NS}" --timeout=600s; then
  oc get subscription "${GITOPS_SUB}" -n "${GITOPS_OPERATOR_NS}" -o yaml | sed -n '/^status:/,$p' >&2 || true
  die "OpenShift GitOps subscription did not reach AtLatestKnown — check: oc get subscription,installplan -n ${GITOPS_OPERATOR_NS}"
fi

log "Waiting for OpenShift GitOps CSV..."
GITOPS_CSV="$(oc get subscription "${GITOPS_SUB}" -n "${GITOPS_OPERATOR_NS}" -o jsonpath='{.status.currentCSV}')"
[[ -n "${GITOPS_CSV}" ]] || die "subscription has no currentCSV yet"
wait_for_csv "${GITOPS_CSV}" "${GITOPS_OPERATOR_NS}" 600

log "Waiting for openshift-gitops Argo CD server..."
wait_for_deployment openshift-gitops-server openshift-gitops 600

if [[ "${SKIP_APPS}" == true ]]; then
  warn "Skipping Argo CD Applications (--skip-apps set)."
  warn "Apply manifests with apply-hub-postgres.sh / apply-models.sh instead."
else
  wait_for_crd applications.argoproj.io 600
  log "Creating Argo CD Applications..."
  helm_gitops true
  log "Argo CD Applications configured for ${HELM_ROLE} cluster (repo=${GIT_REPO})."
  log "  Hub: maas-poc-hub-postgres, maas-poc-models"
  log "  Client: maas-poc-models"
  log "Open Argo CD: oc get route openshift-gitops-server -n openshift-gitops"
fi
