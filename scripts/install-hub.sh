#!/usr/bin/env bash
# Full hub cluster install sequence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KUBECONFIG_PATH=""
GIT_REPO="${DEFAULT_GIT_REPO}"

usage() {
  cat <<'EOF'
Usage: install-hub.sh [--kubeconfig PATH] [--git-repo URL] [--skip-gitops-apps]

Runs the hub install sequence on a fresh OpenShift cluster:
  install-rhoai -> install-rhcl -> bootstrap-gitops -> apply-hub-postgres ->
  setup-gateway -> enable-maas -> apply-models

Hub gets the same simulator models, MaaSSubscriptions, and MaaSAuthPolicies as
clients (shared subscription names for cross-cluster API keys).
EOF
}

SKIP_GITOPS_APPS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
    --git-repo) GIT_REPO="$2"; shift 2 ;;
    --skip-gitops-apps) SKIP_GITOPS_APPS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

KC_ARGS=()
[[ -n "${KUBECONFIG_PATH}" ]] && KC_ARGS=(--kubeconfig "${KUBECONFIG_PATH}")

GITOPS_ARGS=(--cluster hub --git-repo "${GIT_REPO}")
[[ "${SKIP_GITOPS_APPS}" == true ]] && GITOPS_ARGS+=(--skip-apps)

"${SCRIPT_DIR}/install-rhoai.sh" "${KC_ARGS[@]}"
"${SCRIPT_DIR}/install-rhcl.sh" "${KC_ARGS[@]}"
"${SCRIPT_DIR}/bootstrap-gitops.sh" "${GITOPS_ARGS[@]}" "${KC_ARGS[@]}"
"${SCRIPT_DIR}/apply-hub-postgres.sh" "${KC_ARGS[@]}"
"${SCRIPT_DIR}/setup-gateway.sh" "${KC_ARGS[@]}"
"${SCRIPT_DIR}/enable-maas.sh" "${KC_ARGS[@]}"
"${SCRIPT_DIR}/apply-models.sh" "${KC_ARGS[@]}"

echo "[multicluster-poc] Hub install complete."
