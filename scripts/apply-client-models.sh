#!/usr/bin/env bash
# Backward-compatible wrapper for apply-models.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/apply-models.sh" "$@"
