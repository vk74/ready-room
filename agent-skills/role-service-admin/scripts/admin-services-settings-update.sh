#!/usr/bin/env bash
# version: 0.28.3
# Update one application setting. This role writes AdminApp.Services, AdminApp.Forms, and AdminApp.Practices.
# File: admin-services-settings-update.sh
#
# Changes in v0.28.3:
# - Initial script: POST /api/admin/settings/update with a JSON body.
# - Sends Content-Type: application/json. One setting per request.

set -euo pipefail

die() {
  echo "admin-services-settings-update: $*" >&2
  exit 1
}

usage() {
  echo "Usage: admin-services-settings-update.sh <payload.json>" >&2
  echo 'Payload: { "sectionPath": "AdminApp.Services|AdminApp.Forms|AdminApp.Practices", "settingName": "...", "value": ... }' >&2
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

bash "$AUTH_REQUEST_SCRIPT" POST /api/admin/settings/update \
  -H "Content-Type: application/json" \
  --data-binary "@${PAYLOAD_FILE}"
