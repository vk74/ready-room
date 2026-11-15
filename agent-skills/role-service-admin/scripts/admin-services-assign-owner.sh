#!/usr/bin/env bash
# version: 0.28.3
# Assign one active standard or bot owner to one or more services.
# File: admin-services-assign-owner.sh
#
# Changes in v0.28.3:
# - Initial script: POST /api/admin/app/services/assign-owner with a JSON body.
# - Sends Content-Type: application/json.

set -euo pipefail

die() {
  echo "admin-services-assign-owner: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-services-assign-owner.sh <payload.json>" >&2
  echo 'Payload: { "serviceIds": ["<uuid>", ...], "newOwnerUsername": "<username>" }' >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
PAYLOAD_FILE="$1"
[[ -f "$PAYLOAD_FILE" ]] || die "payload file not found: ${PAYLOAD_FILE}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

bash "$AUTH_REQUEST_SCRIPT" POST /api/admin/app/services/assign-owner \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"
