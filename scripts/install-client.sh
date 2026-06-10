#!/usr/bin/env bash
# Full client cluster install sequence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KUBECONFIG_PATH=""
HUB_KUBECONFIG=""
CLUSTER_NAME="client1"
GIT_REPO="${DEFAULT_GIT_REPO}"
SKIP_GITOPS_APPS=false

usage() {
  cat <<'EOF'
Usage: install-client.sh \
         --hub-kubeconfig PATH \
         [--kubeconfig PATH] \
         [--cluster client1|client2] \
         [--git-repo URL] \
         [--skip-gitops-apps]

Runs the client install sequence:
  install-rhoai -> install-rhcl -> bootstrap-gitops -> setup-gateway ->
  sync-hub-db -> enable-maas -> apply-models

Note: enable-maas requires maas-db-config. Run sync-hub-db-to-clients.sh before
enable-maas if following steps manually. This script syncs DB before enable-maas
when --hub-kubeconfig is provided.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
    --hub-kubeconfig) HUB_KUBECONFIG="$2"; shift 2 ;;
    --cluster) CLUSTER_NAME="$2"; shift 2 ;;
    --git-repo) GIT_REPO="$2"; shift 2 ;;
    --skip-gitops-apps) SKIP_GITOPS_APPS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${HUB_KUBECONFIG}" ]] || { echo "ERROR: --hub-kubeconfig is required" >&2; exit 1; }
[[ -n "${KUBECONFIG_PATH}" ]] || { echo "ERROR: --kubeconfig is required for the client cluster" >&2; exit 1; }

KC_ARGS=(--kubeconfig "${KUBECONFIG_PATH}")

GITOPS_ARGS=(--cluster "${CLUSTER_NAME}" --git-repo "${GIT_REPO}")
[[ "${SKIP_GITOPS_APPS}" == true ]] && GITOPS_ARGS+=(--skip-apps)

"${SCRIPT_DIR}/install-rhoai.sh" "${KC_ARGS[@]}"
"${SCRIPT_DIR}/install-rhcl.sh" "${KC_ARGS[@]}"
"${SCRIPT_DIR}/bootstrap-gitops.sh" "${GITOPS_ARGS[@]}" "${KC_ARGS[@]}"
"${SCRIPT_DIR}/setup-gateway.sh" "${KC_ARGS[@]}"

"${SCRIPT_DIR}/sync-hub-db-to-clients.sh" \
  --hub-kubeconfig "${HUB_KUBECONFIG}" \
  --client-kubeconfig "${KUBECONFIG_PATH}" \
  --test-connection

"${SCRIPT_DIR}/enable-maas.sh" "${KC_ARGS[@]}"
"${SCRIPT_DIR}/apply-models.sh" "${KC_ARGS[@]}"

echo "[multicluster-poc] Client install complete."
