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
helm upgrade --install maas-poc-gitops "${POC_ROOT}/helm/gitops-bootstrap" \
  --namespace "${GITOPS_HELM_NS}" \
  --create-namespace \
  --set "git.clusterRole=${HELM_ROLE}" \
  --set "git.repoURL=${GIT_REPO}" \
  --set "git.revision=${GIT_REVISION}"

log "Waiting for OpenShift GitOps subscription..."
if ! oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  "subscription/${GITOPS_SUB}" -n "${GITOPS_OPERATOR_NS}" --timeout=600s; then
  oc get subscription "${GITOPS_SUB}" -n "${GITOPS_OPERATOR_NS}" -o yaml | sed -n '/^status:/,$p' >&2 || true
  die "OpenShift GitOps subscription did not reach AtLatestKnown — check: oc get subscription,installplan -n ${GITOPS_OPERATOR_NS}"
fi

log "Waiting for openshift-gitops Argo CD server..."
for _ in $(seq 1 60); do
  if oc get deployment openshift-gitops-server -n openshift-gitops >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
wait_for_deployment openshift-gitops-server openshift-gitops 600 || \
  warn "openshift-gitops-server not ready — check operator status"

if [[ "${SKIP_APPS}" == true ]]; then
  warn "Skipping Argo CD Applications (--skip-apps set)."
  warn "Apply manifests with apply-hub-postgres.sh / apply-models.sh instead."
else
  log "Argo CD Applications configured for ${HELM_ROLE} cluster (repo=${GIT_REPO})."
  log "  Hub: maas-poc-hub-postgres, maas-poc-models"
  log "  Client: maas-poc-models"
  log "Open Argo CD: oc get route openshift-gitops-server -n openshift-gitops"
fi
