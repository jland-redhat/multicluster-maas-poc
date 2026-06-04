#!/usr/bin/env bash
# Install OpenShift GitOps and optional Argo CD Applications.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KUBECONFIG_PATH=""
CLUSTER_ROLE="client"
GIT_REPO=""
GIT_REVISION="main"
SKIP_APPS=false

usage() {
  cat <<'EOF'
Usage: bootstrap-gitops.sh --cluster hub|client1|client2 [options]

Options:
  --kubeconfig PATH     Kubeconfig for target cluster
  --git-repo URL        Git repo containing multicluster-poc/ (required for Argo apps)
  --git-revision REF    Git branch/tag (default: main)
  --skip-apps           Install operator only; do not create Applications

Maps cluster roles for Helm values:
  hub     -> git.clusterRole=hub
  client* -> git.clusterRole=client

Without --git-repo, only the OpenShift GitOps operator is installed.
Use direct oc apply scripts for manifests until a git remote is configured.
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

log "Installing OpenShift GitOps operator via Helm..."
helm upgrade --install maas-poc-gitops "${POC_ROOT}/helm/gitops-bootstrap" \
  --namespace openshift-operators \
  --set "git.clusterRole=${HELM_ROLE}" \
  --set "git.repoURL=${GIT_REPO}" \
  --set "git.revision=${GIT_REVISION}"

log "Waiting for openshift-gitops Argo CD server..."
for _ in $(seq 1 60); do
  if oc get deployment openshift-gitops-server -n openshift-gitops >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
wait_for_deployment openshift-gitops-server openshift-gitops 600 || \
  warn "openshift-gitops-server not ready — check operator status"

if [[ "${SKIP_APPS}" == true || -z "${GIT_REPO}" ]]; then
  warn "Skipping Argo CD Applications (no --git-repo or --skip-apps set)."
  warn "Apply manifests with apply-hub-postgres.sh / apply-client-models.sh instead."
else
  log "Argo CD Applications configured for ${HELM_ROLE} cluster."
  log "Open Argo CD: oc get route openshift-gitops-server -n openshift-gitops"
fi
