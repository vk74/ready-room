#!/usr/bin/env bash
# version: 1.0.1
# Remove a KB tree from the caller personal shelf.
# File: kb-library-shelf-remove.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: DELETE /api/kb/library/:treeId/shelf via shared auth request wrapper.

set -euo pipefail

die() {
  echo "kb-library-shelf-remove: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-library-shelf-remove.sh <tree_id>" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
TREE_ID="$(printf '%s' "$1" | xargs)"
[[ -n "$TREE_ID" ]] || usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve the shared auth wrapper: env override, vendored copy, monorepo path.
AUTH_REQUEST_SCRIPT="${REQUEST_SCRIPT:-}"
if [[ -z "$AUTH_REQUEST_SCRIPT" ]]; then
  for candidate in "${SCRIPT_DIR}/_lib/role-request.sh" "${SCRIPT_DIR}/../../role-auth/scripts/role-request.sh"; do
    if [[ -f "$candidate" ]]; then
      AUTH_REQUEST_SCRIPT="$candidate"
      break
    fi
  done
fi
[[ -n "$AUTH_REQUEST_SCRIPT" && -f "$AUTH_REQUEST_SCRIPT" ]] || die "cannot locate role-request.sh (set REQUEST_SCRIPT or restore scripts/_lib/)"

bash "$AUTH_REQUEST_SCRIPT" DELETE "/api/kb/library/${TREE_ID}/shelf"
