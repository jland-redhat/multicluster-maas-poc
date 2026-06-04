#!/usr/bin/env bash
# Full hub cluster install sequence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUBECONFIG_PATH=""
GIT_REPO=""

usage() {
  cat <<'EOF'
Usage: install-hub.sh [--kubeconfig PATH] [--git-repo URL]

Runs the hub install sequence on a fresh OpenShift cluster:
  install-rhoai -> bootstrap-gitops -> apply-hub-postgres ->
  setup-gateway -> enable-maas
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
    --git-repo) GIT_REPO="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

KC_ARGS=()
[[ -n "${KUBECONFIG_PATH}" ]] && KC_ARGS=(--kubeconfig "${KUBECONFIG_PATH}")

"${SCRIPT_DIR}/install-rhoai.sh" "${KC_ARGS[@]}"
"${SCRIPT_DIR}/bootstrap-gitops.sh" --cluster hub "${KC_ARGS[@]}" ${GIT_REPO:+--git-repo "${GIT_REPO}"}
"${SCRIPT_DIR}/apply-hub-postgres.sh" "${KC_ARGS[@]}"
"${SCRIPT_DIR}/setup-gateway.sh" "${KC_ARGS[@]}"
"${SCRIPT_DIR}/enable-maas.sh" "${KC_ARGS[@]}"

echo "[multicluster-poc] Hub install complete."
