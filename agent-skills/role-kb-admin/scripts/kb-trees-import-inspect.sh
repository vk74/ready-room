#!/usr/bin/env bash
# version: 1.0.1
# Inspect an uploaded KB tree import package without committing.
# File: kb-trees-import-inspect.sh
#
# Changes in v1.0.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.0.0:
# - Initial script: POST /api/kb/trees/import/:sessionId/inspect with {}.
#   Success KB-SUC-028.

set -euo pipefail

die() {
  echo "kb-trees-import-inspect: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-trees-import-inspect.sh <session_id>" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
SESSION_ID="$(printf '%s' "$1" | xargs)"
[[ -n "$SESSION_ID" ]] || usage

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

bash "$AUTH_REQUEST_SCRIPT" POST "/api/kb/trees/import/${SESSION_ID}/inspect" \
  -H "Content-Type: application/json" \
  --data '{}'
