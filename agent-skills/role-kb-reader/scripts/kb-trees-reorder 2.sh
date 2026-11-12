#!/usr/bin/env bash
# version: 1.2.1
# Reorder the caller personal KB tree shelf (not global tree order).
# File: kb-trees-reorder.sh
#
# Changes in v1.2.1:
# - Auth wrapper resolution: REQUEST_SCRIPT / role-request.sh / ../../role-auth/scripts/ (renamed from evi-*).
#
# Changes in v1.2.0:
# - Moved from role-kb-admin; documents personal shelf reorder semantics (0.20.17).
#
# Changes in v1.1.0:
# - Self-contained auth wrapper resolution: REQUEST_SCRIPT override,
#   vendored scripts/_lib copy, then monorepo role-auth path.
#
# Changes in v1.0.0:
# - Initial script: PUT /api/kb/trees/reorder with JSON payload file.

set -euo pipefail

die() {
  echo "kb-trees-reorder: $*" >&2
  exit 1
}

usage() {
  echo "Usage: kb-trees-reorder.sh <payload.json>" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
PAYLOAD_FILE="$1"
[[ -f "$PAYLOAD_FILE" ]] || die "payload file not found: ${PAYLOAD_FILE}"

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

bash "$AUTH_REQUEST_SCRIPT" PUT /api/kb/trees/reorder \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"
