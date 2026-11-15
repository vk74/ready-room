#!/usr/bin/env bash
# version: 0.28.3
# Delete one or more admin services.
# File: admin-services-delete.sh
#
# Changes in v0.28.3:
# - Initial script: POST /api/admin/app/services/deleteservices with a JSON body.
# - Warns that deletion is destructive. The response can be success with per-id errors.
# - Sends Content-Type: application/json.

set -euo pipefail

die() {
  echo "admin-services-delete: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-services-delete.sh <payload.json>" >&2
  echo 'Payload: { "serviceIds": ["<uuid>", ...] }' >&2
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

echo "admin-services-delete: warning: destructive — deletes the listed services. A referenced service is reported in data.errors and is not deleted. Read totalErrors." >&2

bash "$AUTH_REQUEST_SCRIPT" POST /api/admin/app/services/deleteservices \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"
